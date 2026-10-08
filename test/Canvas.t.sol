// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Canvas} from "../src/Canvas.sol";
import {Seasons} from "../src/Seasons.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev A funded fee source separates canvas accounting tests from AMM price math.
contract CanvasTest is Test {
    Canvas internal canvas;
    Seasons internal seasons;
    MockERC20 internal imd;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        imd = new MockERC20("Identity.md", "IMD", 1_000_000_000 ether);
        canvas = new Canvas(address(this));
        canvas.start(address(imd));
        seasons = canvas.seasons();
        canvas.credit(alice, 1_000_000);
        canvas.credit(bob, 1_000_000);
        canvas.credit(carol, 1_000_000);
        imd.transfer(alice, 1000 ether);
        imd.transfer(bob, 1000 ether);
        vm.prank(alice);
        imd.approve(address(seasons), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(seasons), type(uint256).max);
    }

    function pay(address recipient, uint256 amount) external {
        require(msg.sender == address(canvas));
        require(imd.transfer(recipient, amount));
    }

    function _one(uint16 id) internal pure returns (uint16[] memory ids) {
        ids = new uint16[](1);
        ids[0] = id;
    }

    function _paint(address user, uint16 id, uint8 colour) internal {
        uint8[] memory colours = new uint8[](1);
        colours[0] = colour;
        vm.prank(user);
        canvas.paint(_one(id), colours);
    }

    function _end() internal {
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
    }

    function testPackedPixelWindowDoublingAndCap() public {
        assertEq(canvas.price(42), 1);
        uint256 spent = 0;
        for (uint256 i = 0; i < 13; ++i) {
            uint256 cost = uint256(1) << (i > 10 ? 10 : i);
            assertEq(canvas.price(42), cost);
            _paint(alice, 42, 8);
            spent += cost;
        }
        assertEq(canvas.drops(alice), 1_000_000 - spent);
        (address owner, uint8 colour, uint32 paints, uint40 start, uint16 rank) = canvas.pixels(1, 42);
        assertEq(owner, alice);
        assertEq(colour, 8);
        assertEq(paints, 13);
        assertEq(rank, 1);
        vm.warp(uint256(start) + 1 days - 1);
        assertEq(canvas.price(42), 1024);
        vm.warp(uint256(start) + 1 days);
        assertEq(canvas.price(42), 1);
        _paint(bob, 42, 15);
        assertEq(canvas.price(42), 2);
    }

    function testBatchValidationAndAtomicBudget() public {
        uint16[] memory ids = new uint16[](51);
        uint8[] memory cs = new uint8[](51);
        vm.prank(alice);
        vm.expectRevert(Canvas.InvalidBatch.selector);
        canvas.paint(ids, cs);
        ids = new uint16[](50);
        cs = new uint8[](50);
        for (uint16 i = 0; i < 50; ++i) {
            ids[i] = i;
            cs[i] = uint8(i % 16);
        }
        vm.prank(alice);
        canvas.paint(ids, cs);
        assertEq(canvas.owned(1, alice), 50);
        vm.prank(alice);
        vm.expectRevert(Canvas.BudgetExceeded.selector);
        canvas.paintWithLimit(ids, cs, 99);
        assertEq(canvas.drops(alice), 999950);
        ids[1] = ids[0];
        vm.prank(alice);
        vm.expectRevert(Canvas.InvalidBatch.selector);
        canvas.paint(ids, cs);
        vm.prank(alice);
        vm.expectRevert(Canvas.InvalidBatch.selector);
        canvas.paint(new uint16[](0), new uint8[](0));
        vm.prank(alice);
        vm.expectRevert(Canvas.InvalidBatch.selector);
        canvas.paint(new uint16[](1), new uint8[](0));
        cs = new uint8[](1);
        cs[0] = 16;
        vm.prank(alice);
        vm.expectRevert(Canvas.InvalidPixel.selector);
        canvas.paint(_one(10), cs);
        cs[0] = 0;
        vm.prank(alice);
        vm.expectRevert(Canvas.InvalidPixel.selector);
        canvas.paint(_one(4096), cs);
        vm.prank(makeAddr("noPaint"));
        vm.expectRevert(Canvas.InsufficientPaint.selector);
        canvas.paint(_one(51), cs);
    }

    function testOverwritePreservesEarnedBalance() public {
        _paint(alice, 0, 1);
        _paint(alice, 1, 2);
        _paint(bob, 2, 3);
        canvas.recordFee(300 ether, 300 ether);
        assertEq(canvas.claimable(alice), 134 ether);
        assertEq(canvas.claimable(bob), 67 ether);
        _paint(bob, 0, 4);
        canvas.recordFee(300 ether, 300 ether);
        assertEq(canvas.claimable(alice), 201 ether);
        assertEq(canvas.claimable(bob), 201 ether);
        vm.prank(alice);
        canvas.claim();
        vm.prank(bob);
        canvas.claim();
        assertEq(canvas.totalPaid(), 402 ether);
        vm.prank(alice);
        canvas.claim();
        assertEq(canvas.totalPaid(), 402 ether);
    }

    function testFuzzAccumulatorAcrossManyRepaints(uint256 seed) public {
        address[3] memory artists = [alice, bob, carol];
        address[8] memory owners;
        uint256[3] memory earned;
        for (uint16 i = 0; i < 8; ++i) {
            _paint(alice, i, 1);
            owners[i] = alice;
        }
        // Fees chosen so 67% divides exactly into eight shares; independent per-pixel model.
        for (uint256 step = 0; step < 64; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint16 id = uint16(seed % 8);
            address next = artists[(seed >> 16) % 3];
            _paint(next, id, uint8(seed % 16));
            owners[id] = next;
            canvas.recordFee(80000, 80000);
            for (uint256 p = 0; p < 8; ++p) {
                for (uint256 a = 0; a < 3; ++a) {
                    if (owners[p] == artists[a]) earned[a] += 6700;
                }
            }
            if (step % 7 == 0) {
                uint256 a = (seed >> 32) % 3;
                assertEq(canvas.claimable(artists[a]), earned[a]);
                vm.prank(artists[a]);
                canvas.claim();
                earned[a] = 0;
            }
        }
        for (uint256 a = 0; a < 3; ++a) {
            assertEq(canvas.claimable(artists[a]), earned[a]);
            vm.prank(artists[a]);
            canvas.claim();
        }
        assertEq(canvas.totalPaid(), canvas.totalArtistFees());
        assertLe(canvas.totalPaid(), canvas.totalFees());
    }

    function testFuzzRoundingCannotOverclaim(uint128 raw, uint8 n) public {
        uint256 fee = bound(uint256(raw), 1, 1_000_000 ether);
        uint16 count = uint16(bound(n, 1, 40));
        for (uint16 i = 0; i < count; ++i) {
            _paint(i % 2 == 0 ? alice : bob, i, 1);
        }
        for (uint256 i = 0; i < 10; ++i) {
            canvas.recordFee(fee, fee);
            vm.prank(alice);
            canvas.claim();
            vm.prank(bob);
            canvas.claim();
        }
        assertLe(canvas.totalPaid(), canvas.totalArtistFees());
        assertLe(canvas.totalArtistFees() - canvas.totalPaid(), 2);
    }

    function testSeasonDeadlineFreezeAndReset() public {
        _paint(alice, 20, 15);
        canvas.recordFee(100 ether, 100 ether);
        bytes memory beforeImage = canvas.coloursOf(1);
        vm.warp(canvas.seasonStart() + 7 days - 1);
        vm.expectRevert(Canvas.SeasonNotReady.selector);
        canvas.endSeason();
        vm.warp(block.timestamp + 1);
        uint8[] memory cs = new uint8[](1);
        vm.prank(alice);
        vm.expectRevert(Canvas.SeasonNotReady.selector);
        canvas.paint(_one(20), cs);
        canvas.endSeason();
        assertEq(canvas.currentSeason(), 2);
        assertEq(canvas.owned(2, alice), 0);
        assertEq(canvas.price(20), 1);
        assertEq(canvas.coloursOf(1), beforeImage);
        assertEq(uint8(canvas.coloursOf(2)[20]), 255);
        assertEq(seasons.ownerOf(1), address(seasons));
        assertEq(canvas.claimable(alice), 67 ether);
        _paint(bob, 20, 3);
        assertEq(canvas.coloursOf(1), beforeImage);
        vm.prank(alice);
        canvas.claim();
        assertEq(canvas.claimable(alice), 0);
    }

    function testAuctionRefundRaiseExtensionAndExactPayout() public {
        _paint(alice, 0, 1);
        _paint(bob, 2, 3);
        _paint(alice, 3, 4);
        canvas.recordFee(101, 100);
        _end();
        assertEq(seasons.minimumBid(1), 1);
        vm.prank(alice);
        seasons.bid(1, 101);
        assertEq(seasons.minimumBid(1), 107);
        vm.prank(bob);
        vm.expectRevert(Seasons.BidTooLow.selector);
        seasons.bid(1, 106);
        uint256 refundBefore = imd.balanceOf(alice);
        vm.warp(canvas.seasonStart() + 1 days - 1);
        vm.prank(bob);
        seasons.bid(1, 107);
        assertEq(imd.balanceOf(alice), refundBefore);
        assertEq(seasons.pendingRefunds(alice), 101);
        assertEq(seasons.totalEscrow(), 208);
        vm.prank(bob);
        assertEq(seasons.withdrawRefund(), 0);
        assertEq(seasons.pendingRefunds(alice), 101);
        vm.prank(alice);
        assertEq(seasons.withdrawRefund(), 101);
        assertEq(imd.balanceOf(alice), refundBefore + 101);
        assertEq(seasons.pendingRefunds(alice), 0);
        assertEq(seasons.totalEscrow(), 107);
        vm.prank(alice);
        assertEq(seasons.withdrawRefund(), 0);
        vm.warp(canvas.seasonStart() + 1 days);
        vm.expectRevert(Seasons.NotReady.selector);
        seasons.finalize(1);
        vm.warp(canvas.seasonStart() + 1 days + 10 minutes);
        seasons.finalize(1);
        assertEq(seasons.ownerOf(1), bob);
        // Pot = 26 atomic units; bid = 107; total 133 = 45 + 44 + 44.
        vm.prank(alice);
        assertEq(seasons.claim(1, _one(0)), 45);
        vm.prank(alice);
        assertEq(seasons.claim(1, _one(3)), 44);
        vm.prank(bob);
        assertEq(seasons.claim(1, _one(2)), 44);
        assertEq(seasons.totalPaid(), 133);
        assertEq(imd.balanceOf(address(seasons)), 0);
        vm.prank(alice);
        vm.expectRevert(Seasons.AlreadyClaimed.selector);
        seasons.claim(1, _one(0));
        vm.prank(alice);
        vm.expectRevert(Canvas.Unauthorized.selector);
        seasons.claim(1, _one(2));
        vm.expectRevert(Seasons.NotReady.selector);
        seasons.finalize(1);
        vm.prank(alice);
        vm.expectRevert(Seasons.AuctionClosed.selector);
        seasons.bid(1, 1000);
    }

    function testNoBidTopPainterAndPotCarryCannotBeDelayedToThirdSeason() public {
        _paint(alice, 0, 1);
        _paint(alice, 0, 2);
        _paint(bob, 0, 3);
        canvas.recordFee(100 ether, 100 ether);
        _end();
        vm.warp(canvas.seasonStart() + 7 days);
        vm.expectRevert(Canvas.PreviousAuctionPending.selector);
        canvas.endSeason();
        seasons.finalize(1);
        assertEq(seasons.ownerOf(1), alice);
        assertEq(canvas.seasonPot(), 25 ether);
        canvas.endSeason();
        assertEq(canvas.frozenPot(2), 25 ether);
    }

    function testBlankSeasonCarriesPotAndCannotAcceptBids() public {
        canvas.recordFee(100 ether, 100 ether);
        _end();
        vm.prank(alice);
        vm.expectRevert(Seasons.AuctionClosed.selector);
        seasons.bid(1, 100);
        vm.warp(block.timestamp + 1 days);
        seasons.finalize(1);
        assertEq(canvas.seasonPot(), 92 ether);
        assertEq(seasons.ownerOf(1), address(seasons));
    }

    function testFrozenSVGAndMetadata() public {
        _paint(alice, 0, 4);
        _paint(bob, 4095, 15);
        _end();
        string memory beforeSVG = seasons.svg(1);
        assertTrue(bytes(beforeSVG).length > 0);
        assertTrue(bytes(seasons.tokenURI(1)).length > 0);
        _paint(alice, 0, 8);
        assertEq(seasons.svg(1), beforeSVG);
        assertTrue(seasons.supportsInterface(0x80ac58cd));
        assertTrue(seasons.supportsInterface(0x5b5e139f));
    }

    function testNoUnauthorizedMoneyPaintOrNFTMovement() public {
        vm.prank(bob);
        vm.expectRevert(Canvas.Unauthorized.selector);
        canvas.credit(bob, 5);
        vm.prank(bob);
        vm.expectRevert(Canvas.Unauthorized.selector);
        canvas.recordFee(100, 100);
        vm.prank(bob);
        vm.expectRevert(Canvas.Unauthorized.selector);
        canvas.releasePot(1);
        vm.prank(bob);
        vm.expectRevert(Canvas.Unauthorized.selector);
        canvas.rollPot(1);
        vm.prank(bob);
        vm.expectRevert(Seasons.Unauthorized.selector);
        seasons.open(1, 100, 1, 1, 1, bob);
        _paint(alice, 0, 1);
        _end();
        vm.prank(bob);
        vm.expectRevert();
        seasons.transferFrom(address(seasons), bob, 1);
        vm.prank(bob);
        vm.expectRevert();
        seasons.approve(bob, 1);
    }
}
