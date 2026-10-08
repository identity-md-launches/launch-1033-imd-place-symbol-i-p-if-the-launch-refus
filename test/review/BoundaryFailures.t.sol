// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Canvas} from "src/Canvas.sol";
import {Seasons} from "src/Seasons.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract BoundaryFailuresTest is Test {
    Canvas internal canvas;
    Seasons internal seasons;
    MockERC20 internal imd;
    address internal alice = makeAddr("boundary alice");
    address internal bob = makeAddr("boundary bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new MockERC20("IMD fixture", "IMD", 1e30);
        canvas = new Canvas(address(this));
        canvas.start(address(imd));
        seasons = canvas.seasons();
        canvas.credit(alice, 1_000_000);
        canvas.credit(bob, 1_000_000);
        imd.transfer(alice, 1e24);
        imd.transfer(bob, 1e24);
        vm.prank(alice);
        imd.approve(address(seasons), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(seasons), type(uint256).max);
    }

    function pay(address to, uint256 amount) external {
        require(msg.sender == address(canvas));
        assertTrue(imd.transfer(to, amount));
    }

    function _ids(uint16 a, uint16 b) internal pure returns (uint16[] memory ids) {
        ids = new uint16[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _paint(address artist, uint16 a, uint16 b) internal {
        vm.prank(artist);
        canvas.paint(_ids(a, b), new uint8[](2));
    }

    function _open() internal {
        _paint(alice, 255, 256);
        _paint(bob, 4094, 4095);
        canvas.recordFee(103, 100);
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
    }

    function _auction() internal view returns (Seasons.Auction memory a) {
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
        ) = seasons.auctions(1);
    }

    // Captures both settled and lazy accounting so a failed late entry cannot silently
    // alter ownership checkpoints, paint costs, or the old owner's accrued earnings.
    function _canvasDigest() internal view returns (bytes32) {
        bytes memory a = abi.encode(canvas.pixelPage(1, 254, 4), canvas.pixelPage(1, 4094, 2));
        (uint256 ac, uint256 ap, uint256 as_) = canvas.accounts(alice);
        (uint256 bc, uint256 bp, uint256 bs) = canvas.accounts(bob);
        (uint16 occupied, uint32 painters, uint64 paints, address top, uint64 count) = canvas.stats(1);
        return keccak256(
            abi.encode(
                a,
                ac,
                ap,
                as_,
                bc,
                bp,
                bs,
                occupied,
                painters,
                paints,
                top,
                count,
                canvas.owned(1, alice),
                canvas.owned(1, bob),
                canvas.drops(alice),
                canvas.drops(bob),
                canvas.claimable(alice),
                canvas.claimable(bob)
            )
        );
    }

    function test_LateInvalidEntriesRollBackEarlierOwnershipAndSettlement() public {
        _paint(alice, 255, 256);
        canvas.recordFee(10_001, 10_001);
        bytes32 beforeState = _canvasDigest();
        vm.expectRevert(Canvas.InvalidPixel.selector);
        vm.prank(bob);
        canvas.paint(_ids(255, 4096), new uint8[](2));
        assertEq(_canvasDigest(), beforeState);

        uint8[] memory colours = new uint8[](2);
        colours[1] = 16;
        vm.expectRevert(Canvas.InvalidPixel.selector);
        vm.prank(bob);
        canvas.paint(_ids(255, 256), colours);
        assertEq(_canvasDigest(), beforeState);

        vm.expectRevert(Canvas.InvalidBatch.selector);
        vm.prank(bob);
        canvas.paint(_ids(255, 255), new uint8[](2));
        assertEq(_canvasDigest(), beforeState);

        vm.expectRevert(Canvas.BudgetExceeded.selector);
        vm.prank(bob);
        canvas.paintWithLimit(_ids(255, 256), new uint8[](2), 3);
        assertEq(_canvasDigest(), beforeState);
        vm.prank(bob);
        canvas.paintWithLimit(_ids(255, 256), new uint8[](2), 4);
        assertEq(canvas.owned(1, alice), 0);
        assertEq(canvas.claimable(alice), 6700);
    }

    function test_InsufficientDropsRevertsAllPriorEntries() public {
        Canvas limited = new Canvas(address(this));
        limited.start(address(imd));
        limited.credit(alice, 1);
        vm.expectRevert(Canvas.InsufficientPaint.selector);
        vm.prank(alice);
        limited.paint(_ids(255, 256), new uint8[](2));
        assertEq(limited.drops(alice), 1);
        assertEq(limited.owned(1, alice), 0);
        (uint16 count, uint32 painters, uint64 paints,,) = limited.stats(1);
        assertEq(count, 0);
        assertEq(painters, 0);
        assertEq(paints, 0);
        (address owner,,,,) = limited.pixels(1, 255);
        assertEq(owner, address(0));
    }

    function test_ClaimBatchFailuresDoNotBurnAnyPixelRights() public {
        _open();
        vm.prank(bob);
        seasons.bid(1, 1); // 28 pot + 1 bid = 29, exercising remainder allocation
        vm.warp(_auction().end);
        seasons.finalize(1);
        uint256 escrow = seasons.totalEscrow();
        uint256 balance = imd.balanceOf(alice);

        vm.expectRevert(Seasons.AlreadyClaimed.selector);
        vm.prank(alice);
        seasons.claim(1, _ids(255, 255));
        assertEq(seasons.claimedBitmap(1, 0), 0);
        vm.expectRevert(Canvas.Unauthorized.selector);
        vm.prank(alice);
        seasons.claim(1, _ids(255, 4095));
        vm.expectRevert(Canvas.InvalidSeason.selector);
        vm.prank(alice);
        seasons.claim(1, new uint16[](0));
        vm.expectRevert(Canvas.InvalidSeason.selector);
        vm.prank(alice);
        seasons.claim(1, new uint16[](51));
        assertEq(seasons.totalEscrow(), escrow);
        assertEq(imd.balanceOf(alice), balance);
        assertEq(seasons.claimedBitmap(1, 0), 0);
        assertEq(seasons.claimedBitmap(1, 1), 0);

        vm.prank(alice);
        assertEq(seasons.claim(1, _ids(256, 255)), 15);
        assertEq(seasons.claimedBitmap(1, 0), uint256(1) << 255);
        assertEq(seasons.claimedBitmap(1, 1), 1);
        vm.expectRevert(Seasons.AlreadyClaimed.selector);
        vm.prank(alice);
        seasons.claim(1, _ids(255, 256));
        vm.prank(bob);
        assertEq(seasons.claim(1, _ids(4095, 4094)), 14);
        assertEq(seasons.claimedBitmap(1, 15), (uint256(1) << 255) | (uint256(1) << 254));
        assertEq(seasons.totalPaid(), 29);
        assertEq(seasons.totalEscrow(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MinimumRaiseIsTheSmallestIntegerAtLeastFivePercent(uint96 raw) public {
        _open();
        uint256 amount = bound(uint256(raw), 1, 1e22);
        vm.prank(alice);
        seasons.bid(1, amount);
        uint256 minimum = seasons.minimumBid(1);
        assertGe((minimum - amount) * 100, amount * 5);
        assertLt((minimum - amount - 1) * 100, amount * 5);
        bytes32 beforeState = keccak256(abi.encode(_auction()));
        vm.expectRevert(Seasons.BidTooLow.selector);
        vm.prank(bob);
        seasons.bid(1, minimum - 1);
        assertEq(keccak256(abi.encode(_auction())), beforeState);
        assertEq(seasons.pendingRefunds(alice), 0);
        vm.prank(bob);
        seasons.bid(1, minimum);
        assertEq(seasons.pendingRefunds(alice), amount);
        assertEq(seasons.totalEscrow(), amount + minimum);
    }

    function test_ExactExtensionBoundaryAndExactCloseTime() public {
        _open();
        uint256 end = _auction().end;
        vm.warp(end - 10 minutes - 1);
        vm.prank(alice);
        seasons.bid(1, 1);
        assertEq(_auction().end, end);
        vm.warp(end - 10 minutes);
        vm.prank(bob);
        seasons.bid(1, 2);
        assertEq(_auction().end, end + 10 minutes);
        vm.warp(end);
        vm.prank(alice);
        seasons.bid(1, 3);
        assertEq(_auction().end, end + 20 minutes);
        vm.warp(end + 20 minutes - 1);
        vm.expectRevert(Seasons.NotReady.selector);
        seasons.finalize(1);
        vm.warp(end + 20 minutes);
        vm.expectRevert(Seasons.AuctionClosed.selector);
        vm.prank(bob);
        seasons.bid(1, 4);
        seasons.finalize(1);
        assertEq(seasons.ownerOf(1), alice);
    }

    function test_FailedBidTransferRestoresRefundsDeadlineAndEscrow() public {
        _open();
        vm.prank(alice);
        seasons.bid(1, 100);
        vm.warp(_auction().end - 1);
        vm.prank(bob);
        imd.approve(address(seasons), 0);
        bytes32 beforeState = keccak256(abi.encode(_auction()));
        uint256 beforeBalance = imd.balanceOf(address(seasons));
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(seasons), 0, 105
            )
        );
        vm.prank(bob);
        seasons.bid(1, 105);
        assertEq(keccak256(abi.encode(_auction())), beforeState);
        assertEq(seasons.totalEscrow(), 100);
        assertEq(seasons.pendingRefunds(alice), 0);
        assertEq(imd.balanceOf(address(seasons)), beforeBalance);
    }

    function test_NotStartedAndNonexistentAuctionCannotMoveValue() public {
        Canvas fresh = new Canvas(address(this));
        vm.expectRevert(Canvas.NotStarted.selector);
        fresh.credit(alice, 1);
        vm.expectRevert(Canvas.NotStarted.selector);
        vm.prank(alice);
        fresh.paint(_ids(0, 1), new uint8[](2));
        vm.expectRevert(Canvas.SeasonNotReady.selector);
        fresh.endSeason();
        vm.expectRevert(Seasons.AuctionClosed.selector);
        seasons.bid(1, 1);
        vm.expectRevert(Seasons.NotReady.selector);
        seasons.finalize(1);
        vm.expectRevert(Seasons.NotReady.selector);
        seasons.claim(1, _ids(0, 1));
        vm.expectRevert(Canvas.InvalidSeason.selector);
        canvas.start(address(imd));
        assertEq(canvas.currentSeason(), 1);
        assertEq(seasons.totalEscrow(), 0);
    }
}
