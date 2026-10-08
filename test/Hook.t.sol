// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolFixture, ForeignRouter} from "./helpers/PoolFixture.sol";
import {PlaceHook} from "../src/PlaceHook.sol";
import {PlaceRouter} from "../src/PlaceRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract HookTest is PoolFixture {
    function setUp() public {
        _setup(false);
    }

    function testTokenSupplyAndTransfers() public {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "imd/place");
        assertEq(token.symbol(), "i/p");
        uint256 beforeBalance = token.balanceOf(alice);
        token.transfer(alice, 5 ether);
        assertEq(token.balanceOf(alice), beforeBalance + 5 ether);
    }

    function testFlagsAndCallbackAuthorization() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta
                && p.afterSwapReturnDelta
        );
        assertTrue(HookFlags.matches(address(hook), HookFlags.PLACE));
        vm.expectRevert(PlaceHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        SwapParams memory sp = SwapParams(true, -1 ether, uint160(1 << 95));
        vm.expectRevert(PlaceHook.Unauthorized.selector);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(PlaceHook.Unauthorized.selector);
        hook.afterSwap(address(this), key, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(PlaceHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(alice, 1));
        vm.expectRevert(PlaceHook.Unauthorized.selector);
        hook.pay(alice, 1);
        vm.expectRevert(PlaceRouter.UnauthorizedCallback.selector);
        router.unlockCallback("");
    }

    function testCannotInitializeAnotherPool() public {
        PoolKey memory other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, uint160(1 << 96));
    }

    function testLaunchDecayAndNoPixelFeeSplit() public {
        assertEq(hook.feeBps(), 3500);
        _swap(alice, true, true, 100 ether, 1);
        assertEq(canvas.totalFees(), 35 ether);
        assertEq(canvas.seasonPot(), 3484e16);
        assertEq(canvas.treasuryCredit(), 16e16);
        assertEq(canvas.drops(alice), 2000);
        vm.warp(hook.launchTime() + 15 minutes);
        assertEq(hook.feeBps(), 1850);
        vm.warp(hook.launchTime() + 30 minutes);
        assertEq(hook.feeBps(), 200);
        vm.warp(block.timestamp + 100 days);
        assertEq(hook.feeBps(), 200);
    }

    function testFourSwapModesCreditOnlyBuysAndSettle() public {
        vm.warp(block.timestamp + 30 minutes);
        (uint256 spent, uint256 out) = _swap(alice, true, true, 10 ether, 1);
        assertEq(spent, 10 ether);
        assertGt(out, 0);
        assertEq(canvas.drops(alice), 200);
        (spent, out) = _swap(alice, true, false, 2 ether, 10 ether);
        assertEq(out, 2 ether);
        uint256 expectedDrops = 200 + spent / 0.05 ether;
        assertEq(canvas.drops(alice), expectedDrops);
        _swap(alice, false, true, 2 ether, 1);
        assertEq(canvas.drops(alice), expectedDrops);
        (, out) = _swap(alice, false, false, 1 ether, 10 ether);
        assertEq(out, 1 ether);
        assertEq(canvas.drops(alice), expectedDrops);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(imd)))), canvas.totalFees());
    }

    function testBaseSplitWithOwnedPixelAndClaims() public {
        vm.warp(block.timestamp + 30 minutes);
        _swap(alice, true, true, 1 ether, 1);
        _paint(alice, 0, 4);
        uint256 beforePot = canvas.seasonPot();
        uint256 beforeTreasury = canvas.treasuryCredit();
        _swap(bob, true, true, 100 ether, 1);
        assertEq(canvas.claimable(alice), 134e16);
        assertEq(canvas.seasonPot() - beforePot, 50e16);
        assertEq(canvas.treasuryCredit() - beforeTreasury, 16e16);
        uint256 beforeBalance = imd.balanceOf(alice);
        vm.prank(alice);
        canvas.claim();
        assertEq(imd.balanceOf(alice) - beforeBalance, 134e16);
        assertEq(canvas.claimable(alice), 0);
        uint256 recipientBefore = imd.balanceOf(canvas.TREASURY());
        uint256 expected = canvas.treasuryCredit();
        vm.prank(bob);
        canvas.claimTreasury();
        assertEq(imd.balanceOf(canvas.TREASURY()) - recipientBefore, expected);
    }

    function testOriginFallbackAndSpoofedDataRefused() public {
        ForeignRouter foreign = new ForeignRouter(manager);
        imd.transfer(address(foreign), 100 ether);
        bool direction = Currency.unwrap(key.currency0) == address(imd);
        SwapParams memory sp = SwapParams(direction, -1 ether, _limit(true));
        vm.prank(bob, alice);
        foreign.swap(key, sp, "");
        assertEq(canvas.drops(alice), 20);
        assertEq(canvas.drops(bob), 0);
        vm.expectRevert();
        foreign.swap(key, sp, abi.encode(bob));
    }

    function testRouterNeverSpendsVictimAllowance() public {
        uint256 beforeBalance = imd.balanceOf(alice);
        bytes memory forged = abi.encode(alice, true, true, 50 ether, 1, _limit(true));
        vm.prank(bob);
        vm.expectRevert(PlaceRouter.UnauthorizedCallback.selector);
        router.unlockCallback(forged);
        vm.prank(address(manager));
        vm.expectRevert(PlaceRouter.UnauthorizedCallback.selector);
        router.unlockCallback(forged);
        vm.prank(bob);
        router.swap(true, true, 1 ether, 1, _limit(true), block.timestamp);
        assertEq(imd.balanceOf(alice), beforeBalance);
        assertEq(canvas.drops(bob), 20);
        assertEq(canvas.drops(alice), 0);
    }

    function testDeadlineSlippageAndPartialFillRollBack() public {
        uint256 beforeBalance = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(PlaceRouter.InvalidSwap.selector);
        router.swap(true, true, 1 ether, 1, _limit(true), block.timestamp - 1);
        vm.prank(alice);
        vm.expectRevert(PlaceRouter.Slippage.selector);
        router.swap(true, true, 1 ether, 100 ether, _limit(true), block.timestamp);
        uint160 closeLimit =
            Currency.unwrap(key.currency0) == address(imd) ? uint160((1 << 96) - 1) : uint160((1 << 96) + 1);
        vm.prank(alice);
        vm.expectRevert();
        router.swap(true, true, 1 ether, 1, closeLimit, block.timestamp);
        assertEq(imd.balanceOf(alice), beforeBalance);
        assertEq(canvas.totalFees(), 0);
        assertEq(canvas.drops(alice), 0);
    }

    function testFuzzBuySellConservation(uint96 raw, bool exactInput) public {
        uint256 amount = bound(uint256(raw), 0.05 ether, 100 ether);
        vm.warp(block.timestamp + 30 minutes);
        (uint256 spent, uint256 received) = _swap(alice, true, exactInput, amount, exactInput ? 1 : 200 ether);
        assertEq(canvas.drops(alice), spent / 0.05 ether);
        uint256 paint = canvas.drops(alice);
        _swap(alice, false, true, received, 1);
        assertEq(canvas.drops(alice), paint);
        assertLe(canvas.totalPaid(), canvas.totalArtistFees());
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(imd)))), canvas.totalFees());
    }
}

contract FreshManagerTest is PoolFixture {
    function testFirstBuyTokenOnlyLiquidity() public {
        _setup(true);
        assertEq(imd.balanceOf(address(manager)), 0);
        _swap(alice, true, true, 10 ether, 1);
        assertEq(canvas.drops(alice), 200);
        assertEq(canvas.totalFees(), 3.5 ether);
        canvas.claimTreasury();
        _swap(alice, false, true, 1 ether, 1);
        assertEq(canvas.drops(alice), 200);
    }
}
