// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Canvas} from "../../src/Canvas.sol";
import {Seasons} from "../../src/Seasons.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Independent liability model spanning bidding, self-outbids, withdrawals and artist payouts.
contract PullRefundAccountingTest is Test {
    Canvas internal canvas;
    Seasons internal seasons;
    MockERC20 internal imd;
    address[4] internal users;
    uint256[4] internal refunds;
    uint256 internal liabilities;

    function setUp() public {
        imd = new MockERC20("Review IMD", "IMD", 1e36);
        canvas = new Canvas(address(this));
        seasons = canvas.seasons();
        canvas.start(address(imd));
        for (uint256 i; i < users.length; ++i) {
            users[i] = makeAddr(string.concat("refund reviewer ", vm.toString(i)));
            imd.transfer(users[i], 1e24);
            canvas.credit(users[i], 1000);
            vm.prank(users[i]);
            imd.approve(address(seasons), 1e24);
        }
    }

    function pay(address to, uint256 amount) external {
        require(msg.sender == address(canvas));
        assertTrue(imd.transfer(to, amount));
    }

    function _check() internal view {
        assertEq(seasons.totalEscrow(), liabilities);
        assertEq(imd.balanceOf(address(seasons)), liabilities);
        for (uint256 i; i < users.length; ++i) {
            assertEq(seasons.pendingRefunds(users[i]), refunds[i]);
        }
    }

    function _withdraw(uint256 who) internal {
        uint256 beforeBalance = imd.balanceOf(users[who]);
        uint256 expected = refunds[who];
        refunds[who] = 0;
        liabilities -= expected;
        vm.prank(users[who]);
        assertEq(seasons.withdrawRefund(), expected);
        assertEq(imd.balanceOf(users[who]), beforeBalance + expected);
        _check();
    }

    function _open(uint256 fee) internal returns (uint256 pot) {
        for (uint256 i; i < 3; ++i) {
            uint16[] memory ids = new uint16[](1);
            ids[0] = uint16(i);
            uint8[] memory colours = new uint8[](1);
            colours[0] = uint8(i + 1);
            vm.prank(users[i]);
            canvas.paint(ids, colours);
        }
        canvas.recordFee(fee, fee);
        pot = fee - fee * 67 / 100 - fee * 8 / 100;
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
    }

    function testFuzz_RefundAndArtistLiabilitiesAcrossSeasons(uint256 seed) public {
        uint256 paid;
        for (uint256 season = 1; season <= 3; ++season) {
            uint256 pot = _open(uint256(keccak256(abi.encode(seed, season))) % 1e12 + 1);
            uint256 highBid;
            uint256 previous;
            for (uint256 step; step < 24; ++step) {
                uint256 random = uint256(keccak256(abi.encode(seed, season, step)));
                uint256 who = random % users.length;
                // The whole new bid is escrowed; the previous bid remains a separate liability.
                uint256 amount = (highBid == 0 ? 1 : highBid + (highBid + 19) / 20) + (random >> 32) % 1e9;
                uint256 beforeBalance = imd.balanceOf(users[who]);
                if (highBid > 0) refunds[previous] += highBid;
                liabilities += amount;
                vm.prank(users[who]);
                seasons.bid(season, amount);
                assertEq(imd.balanceOf(users[who]), beforeBalance - amount);
                highBid = amount;
                previous = who;
                _check();
                // Credits may be withdrawn immediately, including while leading another auction.
                if (random & 4 != 0) _withdraw((random >> 8) % users.length);
            }

            vm.warp(canvas.seasonStart() + 1 days);
            seasons.finalize(season);
            assertEq(seasons.ownerOf(season), users[previous]);
            liabilities += pot;
            _check();
            uint256 payout = pot + highBid;
            for (uint256 i; i < 3; ++i) {
                uint16[] memory ids = new uint16[](1);
                ids[0] = uint16(i);
                uint256 expected = payout / 3 + (i < payout % 3 ? 1 : 0);
                vm.prank(users[i]);
                assertEq(seasons.claim(season, ids), expected);
                liabilities -= expected;
                paid += expected;
                _check();
            }
            assertEq(seasons.totalPaid(), paid);
            // Unclaimed refund credits deliberately survive into the following season.
        }
        for (uint256 i; i < users.length; ++i) {
            _withdraw(i);
            _withdraw(i);
        }
        assertEq(liabilities, 0);
    }
}
