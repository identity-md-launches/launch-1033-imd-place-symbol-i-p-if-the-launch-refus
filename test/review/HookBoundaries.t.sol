// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolFixture} from "../helpers/PoolFixture.sol";
import {PlaceHook} from "src/PlaceHook.sol";
import {PlaceRouter} from "src/PlaceRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract HookBoundariesTest is PoolFixture {
    function setUp() public {
        _setup(false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DecayingExtraGoesOnlyToPot(uint16 rawTime, uint96 rawAmount) public {
        _swap(alice, true, true, 0.05 ether, 1);
        _paint(alice, 4095, 15);
        uint256 elapsed = bound(uint256(rawTime), 0, 1 hours);
        vm.warp(hook.launchTime() + elapsed);
        uint256 gross = bound(uint256(rawAmount), 0.05 ether, 100 ether);
        uint256 feeBefore = canvas.totalFees();
        uint256 potBefore = canvas.seasonPot();
        uint256 treasuryBefore = canvas.treasuryCredit();
        uint256 artistsBefore = canvas.totalArtistFees();
        _swap(bob, true, true, gross, 1);
        uint256 bps = elapsed >= 1800 ? 200 : 3500 - (3300 * elapsed + 1799) / 1800;
        uint256 total = gross * bps / 10_000;
        uint256 base = gross * 2 / 100;
        uint256 artist = base * 67 / 100;
        uint256 treasury = base * 8 / 100;
        assertEq(hook.feeBps(), bps);
        assertEq(canvas.totalFees() - feeBefore, total);
        assertEq(canvas.totalArtistFees() - artistsBefore, artist);
        assertEq(canvas.claimable(alice), artist);
        assertEq(canvas.treasuryCredit() - treasuryBefore, treasury);
        assertEq(canvas.seasonPot() - potBefore, total - artist - treasury);
        assertEq(canvas.drops(bob), gross / 0.05 ether);
    }

    function test_RouterBuyerIsCallerEvenWhenOriginIsDifferent() public {
        vm.prank(bob, alice);
        router.swap(true, true, 1 ether, 1, _limit(true), block.timestamp);
        assertEq(canvas.drops(bob), 20);
        assertEq(canvas.drops(alice), 0);
        assertEq(canvas.drops(address(router)), 0);
        vm.prank(bob, alice);
        router.swap(false, true, 0.1 ether, 1, _limit(false), block.timestamp);
        assertEq(canvas.drops(bob), 20);
        assertEq(canvas.drops(alice), 0);
    }

    function test_PaintThresholdAndPersistenceAcrossSeasonRollover() public {
        vm.warp(hook.launchTime() + 30 minutes);
        _swap(alice, true, true, 0.05 ether - 1, 1);
        assertEq(canvas.drops(alice), 0);
        _swap(alice, true, true, 0.05 ether, 1);
        assertEq(canvas.drops(alice), 1);
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
        vm.warp(block.timestamp + 1 days);
        seasons.finalize(1);
        assertEq(canvas.drops(alice), 1);
        _paint(alice, 0, 0);
        assertEq(canvas.drops(alice), 0);
    }

    function test_ManagerCannotReplayUnsolicitedPaymentCallback() public {
        _swap(alice, true, true, 1 ether, 1);
        uint256 claims = manager.balanceOf(address(hook), uint160(address(imd)));
        vm.expectRevert(PlaceHook.InvalidPayment.selector);
        vm.prank(address(manager));
        hook.unlockCallback(abi.encode(bob, claims));
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), claims);
        vm.expectRevert(PlaceRouter.UnauthorizedCallback.selector);
        vm.prank(address(manager));
        router.unlockCallback(abi.encode(true, true, 1 ether, 1, _limit(true)));
    }

    function test_AuthenticatedManagerStillCannotUseAnotherPool() public {
        PoolKey memory other = key;
        other.fee = 3000;
        SwapParams memory params = SwapParams(true, -1 ether, _limit(true));
        vm.expectRevert(PlaceHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), other, params, "");
        vm.expectRevert(PlaceHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(router), other, params, BalanceDelta.wrap(0), "");
    }

    function test_MalformedOrZeroBuyerFailsBeforeMintingClaims() public {
        bool imd0 = Currency.unwrap(key.currency0) == address(imd);
        SwapParams memory params = SwapParams(imd0, -1 ether, _limit(true));
        BalanceDelta delta =
            imd0 ? toBalanceDelta(-0.65 ether, 0.6 ether) : toBalanceDelta(0.6 ether, -0.65 ether);
        bytes[4] memory payloads =
            [bytes(hex"01"), abi.encode(address(0)), abi.encode(alice, bob), new bytes(31)];
        for (uint256 i; i < payloads.length; ++i) {
            vm.expectRevert(PlaceHook.InvalidBuyer.selector);
            vm.prank(address(manager));
            hook.afterSwap(address(router), key, params, delta, payloads[i]);
        }
        vm.expectRevert(PlaceHook.InvalidBuyer.selector);
        vm.prank(address(manager));
        hook.afterSwap(bob, key, params, delta, abi.encode(alice));
        assertEq(canvas.totalFees(), 0);
        assertEq(canvas.drops(alice), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), 0);
    }

    function test_InvalidSwapBoundsPreserveBalancesAndAccounting() public {
        uint256 balance = imd.balanceOf(alice);
        uint256[3] memory amounts = [uint256(0), 1 ether, uint256(uint128(type(int128).max)) + 1];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectRevert(PlaceRouter.InvalidSwap.selector);
            vm.prank(alice);
            router.swap(true, true, amounts[i], i == 1 ? 0 : 1, _limit(true), block.timestamp);
        }
        assertEq(imd.balanceOf(alice), balance);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(canvas.drops(alice), 0);
        assertEq(canvas.totalFees(), 0);
    }
}
