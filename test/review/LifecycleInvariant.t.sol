// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolFixture} from "../helpers/PoolFixture.sol";
import {PlaceHook} from "src/PlaceHook.sol";
import {PlaceRouter} from "src/PlaceRouter.sol";
import {Canvas} from "src/Canvas.sol";
import {Seasons} from "src/Seasons.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev All money enters through real swaps or funded bids. No storage edits, invented
/// fee credits, or swallowed reverts. Ghosts record external cash flows independently.
contract LifecycleHandler is Test {
    PlaceHook public hook;
    PlaceRouter public router;
    Canvas public canvas;
    Seasons public seasons;
    IERC20 public imd;
    IERC20 public token;
    address[4] public actors;
    uint16[8] public ids = [0, 1, 255, 256, 511, 512, 4094, 4095];
    uint160 internal buyLimit;
    uint160 internal sellLimit;
    uint256 public fees;
    uint256 public bids;
    uint256 public refundsPaid;
    uint256 public artistsPaid;
    uint256 public treasuryPaid;
    uint256 public potsReleased;
    uint256 public auctionPaid;
    mapping(address => uint256) public paintBalance;
    mapping(address => uint256) public refunds;
    mapping(uint256 => address) public leader;
    mapping(uint256 => uint256) public highBid;
    mapping(uint256 => uint256) public payoutLeft;
    mapping(uint256 => bool) public finalized;
    mapping(uint256 => mapping(uint16 => bool)) public claimed;
    mapping(uint256 => mapping(uint16 => Canvas.Pixel)) internal modelPixels;
    mapping(uint256 => uint16) public occupied;
    mapping(uint256 => mapping(address => uint256)) internal paintCounts;
    mapping(uint256 => address) internal topPainter;
    mapping(uint256 => uint256) internal topCount;
    mapping(bytes4 => uint256) public calls;

    constructor(PlaceHook h, address[4] memory users, uint160 buy_, uint160 sell_) {
        hook = h;
        router = h.router();
        canvas = h.canvas();
        seasons = canvas.seasons();
        imd = IERC20(h.imd());
        token = IERC20(h.token());
        actors = users;
        buyLimit = buy_;
        sellLimit = sell_;
    }

    function trade(uint8 who, bool buy, bool exactInput, uint96 raw) public {
        address actor = actors[who % 4];
        uint256 amount = bound(uint256(raw), 0.05 ether, 5 ether);
        uint256 imdBefore = imd.balanceOf(actor);
        uint256 tokenBefore = token.balanceOf(actor);
        uint256 claimsBefore = hook.poolManager().balanceOf(address(hook), uint160(address(imd)));
        vm.prank(actor);
        (uint256 spent, uint256 received) = router.swap(
            buy, exactInput, amount, exactInput ? 1 : 20 ether, buy ? buyLimit : sellLimit, block.timestamp
        );
        uint256 fee = hook.poolManager().balanceOf(address(hook), uint160(address(imd))) - claimsBefore;
        fees += fee;
        if (buy) {
            assertEq(imd.balanceOf(actor), imdBefore - spent);
            assertEq(token.balanceOf(actor), tokenBefore + received);
            paintBalance[actor] += spent / 0.05 ether;
        } else {
            assertEq(imd.balanceOf(actor), imdBefore + received);
            assertEq(token.balanceOf(actor), tokenBefore - spent);
        }
        assertEq(canvas.drops(actor), paintBalance[actor], "only buys credit paint");
        ++calls[this.trade.selector];
    }

    function paint(uint8 who, uint8 pixel, uint8 colour) public {
        if (block.timestamp >= canvas.seasonStart() + 7 days) return;
        address actor = actors[who % 4];
        uint256 season = canvas.currentSeason();
        uint16 id = ids[pixel % 8];
        Canvas.Pixel storage p = modelPixels[season][id];
        bool reset = p.owner == address(0) || block.timestamp >= uint256(p.windowStart) + 1 days;
        uint256 cost = reset ? 1 : 2 ** (p.paints > 10 ? 10 : p.paints);
        if (paintBalance[actor] < cost) return;
        uint16[] memory pixels = new uint16[](1);
        uint8[] memory colours = new uint8[](1);
        pixels[0] = id;
        colours[0] = colour % 16;
        vm.prank(actor);
        canvas.paintWithLimit(pixels, colours, cost);
        paintBalance[actor] -= cost;
        if (p.owner == address(0)) p.rank = ++occupied[season];
        p.owner = actor;
        p.colour = colour % 16;
        p.paints = reset ? 1 : p.paints + 1;
        if (reset) p.windowStart = uint40(block.timestamp);
        uint256 count = ++paintCounts[season][actor];
        if (count > topCount[season]) {
            topCount[season] = count;
            topPainter[season] = actor;
        }
        ++calls[this.paint.selector];
    }

    // Boundary-directed time moves make season and auction transitions reachable.
    function advance(uint8 mode, uint32 raw) public {
        uint256 next = block.timestamp + uint256(raw) % 2 days;
        if (mode % 3 == 0) next = canvas.seasonStart() + 7 days;
        if (next > block.timestamp) vm.warp(next);
        ++calls[this.advance.selector];
    }

    function endSeason() public {
        uint256 id = canvas.currentSeason();
        if (id >= 12 || block.timestamp < canvas.seasonStart() + 7 days) return;
        if (id > 1 && !finalized[id - 1] && highBid[id - 1] == 0) return;
        canvas.endSeason();
        assertEq(seasons.ownerOf(id), address(seasons));
        assertEq(canvas.currentSeason(), id + 1);
        ++calls[this.endSeason.selector];
    }

    function _auction(uint256 id) internal view returns (Seasons.Auction memory a) {
        (
            a.end,
            a.occupied,
            a.painters,
            a.paints,
            a.topPainter,
            a.bidder,
            a.finalized,
            a.highBid,
            a.pot,
            a.payout,
            a.paid
        ) = seasons.auctions(id);
    }

    function bid(uint8 which, uint8 who, uint96 raw) public {
        uint256 count = canvas.currentSeason() - 1;
        if (count == 0) return;
        uint256 id = uint256(which) % count + 1;
        Seasons.Auction memory a = _auction(id);
        if (finalized[id] || block.timestamp >= a.end || occupied[id] == 0) return;
        address actor = actors[who % 4];
        uint256 old = highBid[id];
        uint256 minimum = old == 0 ? 1 : (old * 105 + 99) / 100;
        uint256 amount = minimum + uint256(raw) % 1 ether;
        uint256 balance = imd.balanceOf(actor);
        if (amount > balance) return;
        vm.prank(actor);
        seasons.bid(id, amount);
        assertEq(imd.balanceOf(actor), balance - amount);
        if (old > 0) refunds[leader[id]] += old;
        leader[id] = actor;
        highBid[id] = amount;
        bids += amount;
        ++calls[this.bid.selector];
    }

    function finalize(uint8 which) public {
        uint256 count = canvas.currentSeason() - 1;
        if (count == 0) return;
        uint256 id = uint256(which) % count + 1;
        Seasons.Auction memory a = _auction(id);
        if (finalized[id] || block.timestamp < a.end) return;
        uint256 frozenPot = canvas.frozenPot(id);
        seasons.finalize(id);
        finalized[id] = true;
        if (highBid[id] > 0) {
            potsReleased += frozenPot;
            payoutLeft[id] = frozenPot + highBid[id];
            assertEq(seasons.ownerOf(id), leader[id]);
        } else {
            address expected = topPainter[id];
            assertEq(seasons.ownerOf(id), expected == address(0) ? address(seasons) : expected);
        }
        assertEq(canvas.frozenPot(id), 0);
        ++calls[this.finalize.selector];
    }

    function withdraw(uint8 who) public {
        address actor = actors[who % 4];
        uint256 expected = refunds[actor];
        uint256 beforeBalance = imd.balanceOf(actor);
        vm.prank(actor);
        assertEq(seasons.withdrawRefund(), expected);
        refunds[actor] = 0;
        refundsPaid += expected;
        assertEq(imd.balanceOf(actor), beforeBalance + expected);
        ++calls[this.withdraw.selector];
    }

    function claimFees(uint8 who) public {
        address actor = actors[who % 4];
        uint256 expected = canvas.claimable(actor);
        uint256 beforeBalance = imd.balanceOf(actor);
        vm.prank(actor);
        assertEq(canvas.claim(), expected);
        artistsPaid += expected;
        assertEq(imd.balanceOf(actor), beforeBalance + expected);
        ++calls[this.claimFees.selector];
    }

    function treasury() public {
        uint256 beforeBalance = imd.balanceOf(canvas.TREASURY());
        uint256 amount = canvas.claimTreasury();
        treasuryPaid += amount;
        assertEq(imd.balanceOf(canvas.TREASURY()), beforeBalance + amount);
        ++calls[this.treasury.selector];
    }

    function claimAuction(uint8 which, uint8 pixel) public {
        uint256 count = canvas.currentSeason() - 1;
        if (count == 0) return;
        uint256 id = uint256(which) % count + 1;
        uint16 p = ids[pixel % 8];
        Canvas.Pixel memory frozen = modelPixels[id][p];
        if (!finalized[id] || highBid[id] == 0 || frozen.owner == address(0) || claimed[id][p]) return;
        Seasons.Auction memory a = _auction(id);
        uint256 expected = a.payout / occupied[id] + (frozen.rank <= a.payout % occupied[id] ? 1 : 0);
        uint16[] memory pixels = new uint16[](1);
        pixels[0] = p;
        uint256 balance = imd.balanceOf(frozen.owner);
        vm.prank(frozen.owner);
        assertEq(seasons.claim(id, pixels), expected);
        assertEq(imd.balanceOf(frozen.owner), balance + expected);
        claimed[id][p] = true;
        payoutLeft[id] -= expected;
        auctionPaid += expected;
        ++calls[this.claimAuction.selector];
    }

    function checkBacking() external view {
        assertEq(canvas.totalFees(), fees);
        assertEq(canvas.totalPaid(), artistsPaid);
        assertEq(canvas.totalTreasuryPaid(), treasuryPaid);
        assertEq(seasons.totalPaid(), auctionPaid);
        assertEq(
            hook.poolManager().balanceOf(address(hook), uint160(address(imd))),
            fees - artistsPaid - treasuryPaid - potsReleased
        );
        uint256 cash = bids + potsReleased - refundsPaid - auctionPaid;
        assertEq(imd.balanceOf(address(seasons)), cash);
        assertEq(seasons.totalEscrow(), cash);
        uint256 owed;
        uint256 artistClaims;
        uint256 reservedPots = canvas.seasonPot();
        for (uint256 i; i < 4; ++i) {
            owed += refunds[actors[i]];
            assertEq(seasons.pendingRefunds(actors[i]), refunds[actors[i]]);
            assertEq(canvas.drops(actors[i]), paintBalance[actors[i]]);
            artistClaims += canvas.claimable(actors[i]);
        }
        for (uint256 id = 1; id < canvas.currentSeason(); ++id) {
            owed += finalized[id] ? payoutLeft[id] : highBid[id];
            reservedPots += canvas.frozenPot(id);
        }
        assertEq(cash, owed, "escrow is exactly refunds plus bids plus unpaid awards");
        assertEq(
            hook.poolManager().balanceOf(address(hook), uint160(address(imd))),
            canvas.totalArtistFees() - artistsPaid + canvas.treasuryCredit() + reservedPots,
            "every retained fee backs artists, treasury, or a live/frozen pot"
        );
        assertLe(artistClaims + artistsPaid, canvas.totalArtistFees());
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(canvas)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function checkPixelsAndFrozenRights() external view {
        for (uint256 id = 1; id <= canvas.currentSeason(); ++id) {
            uint256[4] memory counts;
            for (uint256 j; j < ids.length; ++j) {
                Canvas.Pixel memory p = modelPixels[id][ids[j]];
                (address owner, uint8 colour, uint32 paints, uint40 start, uint16 rank) =
                    canvas.pixels(id, ids[j]);
                assertEq(owner, p.owner);
                assertEq(colour, p.colour);
                assertEq(paints, p.paints);
                assertEq(start, p.windowStart);
                assertEq(rank, p.rank);
                for (uint256 k; k < 4; ++k) {
                    if (owner == actors[k]) ++counts[k];
                }
            }
            for (uint256 k; k < 4; ++k) {
                assertEq(canvas.owned(id, actors[k]), counts[k]);
            }
            (uint16 count,,,,) = canvas.stats(id);
            assertEq(count, occupied[id]);
            if (id < canvas.currentSeason()) {
                Seasons.Auction memory a = _auction(id);
                assertEq(a.finalized, finalized[id]);
                assertEq(a.occupied, count);
                assertEq(a.highBid, highBid[id]);
                assertEq(a.bidder, leader[id]);
                if (finalized[id] && highBid[id] > 0) assertEq(a.payout - a.paid, payoutLeft[id]);
                address recipient = highBid[id] > 0 ? leader[id] : topPainter[id];
                assertEq(
                    seasons.ownerOf(id),
                    !finalized[id] || recipient == address(0) ? address(seasons) : recipient
                );
            }
        }
    }

    /// @dev Realize every matured liability after each random campaign. Solvency alone
    /// would miss a contract that tracks debts correctly but cannot pay them.
    function drain() external {
        vm.warp(block.timestamp + 30 days);
        for (uint8 id; id < canvas.currentSeason() - 1; ++id) {
            finalize(id);
            for (uint8 p; p < 8; ++p) {
                claimAuction(id, p);
            }
        }
        for (uint8 i; i < 4; ++i) {
            withdraw(i);
            claimFees(i);
        }
        treasury();
        assertEq(seasons.totalEscrow(), 0);
        assertEq(imd.balanceOf(address(seasons)), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LifecycleInvariantTest is PoolFixture {
    LifecycleHandler internal handler;

    function setUp() public {
        _setup(false);
        address[4] memory actors = [alice, bob, makeAddr("lifecycle carol"), makeAddr("lifecycle dave")];
        for (uint256 i; i < 4; ++i) {
            if (i > 1) {
                imd.transfer(actors[i], 100_000 ether);
                token.transfer(actors[i], 100_000 ether);
            }
            vm.startPrank(actors[i]);
            imd.approve(address(router), type(uint256).max);
            token.approve(address(router), type(uint256).max);
            imd.approve(address(seasons), type(uint256).max);
            vm.stopPrank();
        }
        handler = new LifecycleHandler(hook, actors, _limit(true), _limit(false));
        for (uint8 i; i < 4; ++i) {
            handler.trade(i, true, true, 5 ether);
            handler.paint(i, i, i);
        }
        handler.trade(0, false, false, 1 ether);
        handler.advance(0, 0);
        handler.endSeason();
        handler.bid(0, 0, 100);
        handler.bid(0, 0, 200); // self-outbid is a separate refund liability
        handler.bid(0, 1, 300);
        handler.paint(2, 7, 15);
        handler.trade(1, true, false, 1 ether);
        handler.advance(0, 0);
        handler.endSeason(); // overlap an unfinalized funded auction
        handler.finalize(0);
        handler.claimAuction(0, 0);
        handler.withdraw(0);
        handler.claimFees(0);
        handler.treasury();
        handler.advance(1, 1 days);
        handler.finalize(1); // unbid pot carries to the immediately next season

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.paint.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.endSeason.selector;
        selectors[4] = handler.bid.selector;
        selectors[5] = handler.finalize.selector;
        selectors[6] = handler.withdraw.selector;
        selectors[7] = handler.claimFees.selector;
        selectors[8] = handler.treasury.selector;
        selectors[9] = handler.claimAuction.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_CashFlowsAndLiabilitiesAreFullyBacked() public view {
        handler.checkBacking();
    }

    function invariant_PaintAndFrozenOwnershipMatchHistory() public view {
        handler.checkPixelsAndFrozenRights();
    }

    function afterInvariant() public {
        handler.drain();
        handler.checkBacking();
        handler.checkPixelsAndFrozenRights();
        assertGt(handler.calls(handler.trade.selector), 0);
        assertGt(handler.calls(handler.endSeason.selector), 0);
        assertGt(handler.calls(handler.bid.selector), 0);
        assertGt(handler.calls(handler.finalize.selector), 0);
        assertGt(handler.calls(handler.claimAuction.selector), 0);
    }
}
