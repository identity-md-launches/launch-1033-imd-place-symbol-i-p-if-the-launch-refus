// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolFixture} from "./helpers/PoolFixture.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Canvas} from "../src/Canvas.sol";
import {Seasons} from "../src/Seasons.sol";

contract CallbackToken is MockERC20 {
    address public target;
    bytes public payload;
    bool public entered;
    bool public callbackSucceeded;
    uint256 public attempts;
    mapping(address => bool) public blocked;
    constructor() MockERC20("Identity.md", "IMD", 1_000_000_000 ether) {}

    function configure(address target_, bytes calldata data) external {
        target = target_;
        payload = data;
    }

    function blockAddress(address user) external {
        blocked[user] = true;
    }

    function unblockAddress(address user) external {
        blocked[user] = false;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        _callback();
        return ok;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool ok = super.transferFrom(from, to, value);
        _callback();
        return ok;
    }

    function _callback() private {
        if (target != address(0) && !entered) {
            entered = true;
            ++attempts;
            (callbackSucceeded,) = target.call(payload);
            entered = false;
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blocked");
        super._update(from, to, value);
    }
}

contract RouterReentrancyTest is PoolFixture {
    function _newIMD() internal override returns (MockERC20) {
        return new CallbackToken();
    }

    function testTransferCallbackCannotReplaceSwapPayerOrSpendAgain() public {
        _setup(false);
        CallbackToken attack = CallbackToken(address(imd));
        attack.configure(
            address(router),
            abi.encodeCall(router.swap, (true, true, 1 ether, 1, _limit(true), block.timestamp))
        );
        uint256 beforeBalance = imd.balanceOf(alice);
        _swap(alice, true, true, 1 ether, 1);
        assertGt(attack.attempts(), 0);
        assertFalse(attack.callbackSucceeded());
        assertEq(beforeBalance - imd.balanceOf(alice), 1 ether);
        assertEq(canvas.drops(alice), 20);
        assertEq(imd.balanceOf(address(router)), 0);
    }
}

contract AuctionReentrancyTest is Test {
    MockERC20 internal imd;
    Canvas internal canvas;
    Seasons internal seasons;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function pay(address to, uint256 amount) external {
        require(msg.sender == address(canvas));
        require(imd.transfer(to, amount));
    }

    function _paint(address who, uint16 id, uint8 colour) internal {
        uint16[] memory ids = new uint16[](1);
        ids[0] = id;
        uint8[] memory cs = new uint8[](1);
        cs[0] = colour;
        vm.prank(who);
        canvas.paint(ids, cs);
    }

    function _end() internal {
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        CallbackToken attack = new CallbackToken();
        imd = attack;
        canvas = new Canvas(address(this));
        canvas.start(address(imd));
        seasons = canvas.seasons();
        canvas.credit(alice, 100);
        canvas.credit(bob, 100);
        imd.transfer(alice, 1000 ether);
        imd.transfer(bob, 1000 ether);
        vm.prank(alice);
        imd.approve(address(seasons), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(seasons), type(uint256).max);
    }

    function testBidCallbackCannotReenterAuction() public {
        _paint(alice, 0, 1);
        _end();
        CallbackToken attack = CallbackToken(address(imd));
        attack.configure(address(seasons), abi.encodeCall(seasons.bid, (1, 110 ether)));
        vm.prank(alice);
        seasons.bid(1, 100 ether);
        assertFalse(attack.callbackSucceeded());
        assertEq(attack.attempts(), 1);
        assertEq(seasons.totalEscrow(), 100 ether);
    }

    function testBlockedRefundCannotBlockBidFinalizeOrArtists() public {
        _paint(alice, 0, 1);
        _end();
        vm.prank(alice);
        seasons.bid(1, 100 ether);
        CallbackToken(address(imd)).blockAddress(alice);
        uint256 beforeBalance = imd.balanceOf(bob);
        vm.prank(bob);
        seasons.bid(1, 105 ether);
        assertEq(imd.balanceOf(bob), beforeBalance - 105 ether);
        assertEq(seasons.minimumBid(1), 110.25 ether);
        assertEq(seasons.pendingRefunds(alice), 100 ether);
        assertEq(seasons.totalEscrow(), 205 ether);
        vm.prank(alice);
        vm.expectRevert();
        seasons.withdrawRefund();
        assertEq(seasons.pendingRefunds(alice), 100 ether);
        assertEq(seasons.totalEscrow(), 205 ether);
        vm.warp(block.timestamp + 1 days);
        seasons.finalize(1);
        assertEq(seasons.ownerOf(1), bob);
        CallbackToken(address(imd)).unblockAddress(alice);
        uint16[] memory ids = new uint16[](1);
        vm.prank(alice);
        assertEq(seasons.claim(1, ids), 105 ether);
        assertEq(seasons.totalEscrow(), 100 ether);
        assertEq(imd.balanceOf(address(seasons)), 100 ether);
        vm.prank(alice);
        assertEq(seasons.withdrawRefund(), 100 ether);
        assertEq(seasons.totalEscrow(), 0);
        assertEq(imd.balanceOf(address(seasons)), 0);
    }

    function testRefundCallbackCannotReenterOrWithdrawAnotherBidderCredit() public {
        _paint(alice, 0, 1);
        _end();
        vm.prank(alice);
        seasons.bid(1, 100 ether);
        vm.prank(bob);
        seasons.bid(1, 105 ether);
        CallbackToken attack = CallbackToken(address(imd));
        attack.configure(address(seasons), abi.encodeCall(seasons.withdrawRefund, ()));
        uint256 balance = imd.balanceOf(alice);
        vm.prank(alice);
        assertEq(seasons.withdrawRefund(), 100 ether);
        assertFalse(attack.callbackSucceeded());
        assertEq(attack.attempts(), 1);
        assertEq(imd.balanceOf(alice), balance + 100 ether);
        assertEq(seasons.pendingRefunds(alice), 0);
        assertEq(seasons.totalEscrow(), 105 ether);
    }
}
