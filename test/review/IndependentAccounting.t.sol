// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Canvas} from "../../src/Canvas.sol";
import {Seasons} from "../../src/Seasons.sol";

contract ReviewIMD is ERC20 {
    constructor() ERC20("Review IMD", "RIMD") {
        _mint(msg.sender, 1e36);
    }
}

contract IndependentAccountingTest is Test {
    Canvas internal canvas;
    Seasons internal seasons;
    ReviewIMD internal imd;
    address[3] internal artists = [address(0x101), address(0x202), address(0x303)];

    function setUp() public {
        imd = new ReviewIMD();
        canvas = new Canvas(address(this));
        seasons = canvas.seasons();
        canvas.start(address(imd));
        for (uint256 i; i < 3; ++i) {
            canvas.credit(artists[i], 1e12);
        }
    }

    function pay(address to, uint256 amount) external {
        require(msg.sender == address(canvas));
        imd.transfer(to, amount);
    }

    function _paint(uint16 pixel, uint256 who) internal {
        uint16[] memory ids = new uint16[](1);
        uint8[] memory colours = new uint8[](1);
        ids[0] = pixel;
        colours[0] = uint8(who + 1);
        vm.prank(artists[who]);
        canvas.paint(ids, colours);
    }

    function _claim(uint256 who) internal returns (uint256 amount) {
        vm.prank(artists[who]);
        return canvas.claim();
    }

    function testFuzz_ReviewPerPixelReferenceAccountingAcrossSeasons(uint256 seed) public {
        uint256[3] memory expected;
        uint8[12] memory holders;
        uint256 remainder;
        uint256 recorded;
        for (uint256 step; step < 100; ++step) {
            uint256 random = uint256(keccak256(abi.encode(seed, step)));
            uint16 pixel = uint16(random % 12);
            uint256 who = (random >> 8) % 3;
            _paint(pixel, who);
            holders[pixel] = uint8(who + 1);

            uint256 fee = (random >> 16) % 10000 + 1;
            uint256 count;
            for (uint256 i; i < 12; ++i) {
                if (holders[i] > 0) ++count;
            }
            uint256 numerator = (fee * 67 / 100) * canvas.SCALE() + remainder;
            uint256 perPixel = numerator / count;
            remainder = numerator % count;
            for (uint256 i; i < 12; ++i) {
                if (holders[i] > 0) expected[holders[i] - 1] += perPixel;
            }
            canvas.recordFee(fee, fee);
            recorded += fee;

            if (step % 7 == 0) {
                assertEq(_claim(who), expected[who] / canvas.SCALE());
                expected[who] %= canvas.SCALE();
            }
            if (step % 19 == 18) {
                vm.warp(canvas.seasonStart() + 7 days);
                if (canvas.currentSeason() > 1) seasons.finalize(canvas.currentSeason() - 1);
                canvas.endSeason();
                for (uint256 i; i < 12; ++i) {
                    holders[i] = 0;
                }
            }
        }
        for (uint256 who; who < 3; ++who) {
            assertEq(canvas.claimable(artists[who]), expected[who] / canvas.SCALE());
            assertEq(_claim(who), expected[who] / canvas.SCALE());
        }
        assertLe(canvas.totalPaid(), canvas.totalArtistFees());
        assertLe(canvas.totalArtistFees() + canvas.totalTreasuryPaid(), recorded);
    }

    function test_ReviewFrozenOwnersAndExactRemainderPayout() public {
        _paint(1, 0);
        _paint(200, 1);
        _paint(4095, 2);
        canvas.recordFee(100, 100);
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
        assertEq(canvas.frozenPot(1), 25);
        imd.approve(address(seasons), 7);
        seasons.bid(1, 7);
        vm.warp(block.timestamp + 1 days);
        seasons.finalize(1);
        assertEq(seasons.ownerOf(1), address(this));
        // New-season edits cannot change the rights attached to the frozen image.
        _paint(1, 2);
        uint16[] memory ids = new uint16[](1);
        ids[0] = 1;
        vm.prank(artists[0]);
        assertEq(seasons.claim(1, ids), 11);
        vm.expectRevert(Seasons.AlreadyClaimed.selector);
        vm.prank(artists[0]);
        seasons.claim(1, ids);
        ids[0] = 200;
        vm.prank(artists[1]);
        assertEq(seasons.claim(1, ids), 11);
        ids[0] = 4095;
        vm.prank(artists[2]);
        assertEq(seasons.claim(1, ids), 10);
        assertEq(seasons.totalPaid(), 32);
        assertEq(imd.balanceOf(address(seasons)), 0);
    }

    function test_ReviewOldAccrualSurvivesSkippedSeasons() public {
        _paint(2, 0);
        canvas.recordFee(10000, 10000);
        for (uint256 i; i < 4; ++i) {
            vm.warp(canvas.seasonStart() + 7 days);
            if (canvas.currentSeason() > 1) seasons.finalize(canvas.currentSeason() - 1);
            canvas.endSeason();
        }
        _paint(2, 1);
        canvas.recordFee(10000, 10000);
        assertEq(_claim(0), 6700);
        assertEq(_claim(1), 6700);
        assertEq(_claim(0), 0);
    }

    function test_ReviewDelayedRolloverCannotChooseLaterSeason() public {
        _paint(0, 0);
        canvas.recordFee(10000, 10000);
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
        assertEq(canvas.frozenPot(1), 2500);
        _paint(0, 1);
        canvas.recordFee(10000, 10000);
        vm.warp(canvas.seasonStart() + 20 days);
        vm.expectRevert(Canvas.PreviousAuctionPending.selector);
        canvas.endSeason();
        assertEq(canvas.currentSeason(), 2);
        assertEq(canvas.seasonPot(), 2500);
        // Anyone may resolve this prerequisite; there is no administrator or timer reset.
        seasons.finalize(1);
        assertEq(canvas.seasonPot(), 5000);
        assertEq(canvas.frozenPot(1), 0);
        canvas.endSeason();
        assertEq(canvas.frozenPot(2), 5000);
        assertEq(canvas.currentSeason(), 3);
        assertEq(canvas.seasonPot(), 0);
    }

    function test_ReviewConcurrentAuctionEscrowsRemainIndependent() public {
        _paint(0, 0);
        canvas.recordFee(10000, 10000);
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
        imd.approve(address(seasons), 1000);
        seasons.bid(1, 100);
        _paint(0, 1);
        canvas.recordFee(10000, 10000);
        vm.warp(canvas.seasonStart() + 7 days);
        // A funded older auction need not settle before the next canvas freezes.
        canvas.endSeason();
        seasons.bid(2, 200);
        assertEq(seasons.totalEscrow(), 300);
        seasons.finalize(1);
        assertEq(seasons.totalEscrow(), 2800);
        uint16[] memory ids = new uint16[](1);
        ids[0] = 0;
        vm.prank(artists[0]);
        assertEq(seasons.claim(1, ids), 2600);
        // Claiming season 1 leaves the complete season-2 bid in escrow.
        assertEq(seasons.totalEscrow(), 200);
        assertEq(imd.balanceOf(address(seasons)), 200);
        vm.warp(block.timestamp + 1 days);
        seasons.finalize(2);
        assertEq(seasons.totalEscrow(), 2700);
        vm.prank(artists[1]);
        assertEq(seasons.claim(2, ids), 2700);
        assertEq(seasons.totalEscrow(), 0);
        assertEq(imd.balanceOf(address(seasons)), 0);
    }
}
