// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolFixture, LiquidityHelper} from "../helpers/PoolFixture.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PlaceToken} from "../../src/PlaceToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract IndependentSwapModesTest is PoolFixture {
    function _setupDirection(bool imdIsZero) internal {
        vm.warp(1_800_000_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new PlaceToken();
        for (uint256 salt; salt < 256; ++salt) {
            imd = new MockERC20{salt: bytes32(salt)}("Review", "IMD", 1_000_000_000 ether);
            if ((address(imd) < address(token)) == imdIsZero) break;
        }
        assertEq(address(imd) < address(token), imdIsZero);
        hook = _deployHook(manager, address(token));
        canvas = hook.canvas();
        seasons = canvas.seasons();
        router = hook.router();
        key = PoolKey({
            currency0: Currency.wrap(imdIsZero ? address(imd) : address(token)),
            currency1: Currency.wrap(imdIsZero ? address(token) : address(imd)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, uint160(1 << 96));
        liquidity = new LiquidityHelper(manager);
        token.transfer(address(liquidity), 10_000_000 ether);
        imd.transfer(address(liquidity), 10_000_000 ether);
        liquidity.add(key, -600, 600, 10_000_000 ether);
        token.transfer(alice, 100_000 ether);
        imd.transfer(alice, 100_000 ether);
        vm.startPrank(alice);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _reviewModes() internal {
        for (uint256 phase; phase < 2; ++phase) {
            if (phase > 0) vm.warp(hook.launchTime() + 30 minutes);
            uint256 bps = hook.feeBps();
            for (uint256 mode; mode < 4; ++mode) {
                bool buy = mode < 2;
                bool exactInput = mode % 2 == 0;
                uint256 previousFee = canvas.totalFees();
                uint256 previousDrops = canvas.drops(alice);
                (uint256 spent, uint256 received) =
                    _swap(alice, buy, exactInput, 1 ether + 17, exactInput ? 1 : 10 ether);
                uint256 fee = canvas.totalFees() - previousFee;
                if (buy && exactInput) assertEq(fee, spent * bps / 10000);
                else if (buy) assertEq(fee, ((spent - fee) * bps + 9999 - bps) / (10000 - bps));
                else if (exactInput) assertEq(fee, (received + fee) * bps / 10000);
                else assertEq(fee, (received * bps + 9999 - bps) / (10000 - bps));
                assertEq(canvas.drops(alice), previousDrops + (buy ? spent / 0.05 ether : 0));
                assertEq(imd.balanceOf(address(router)), 0);
                assertEq(token.balanceOf(address(router)), 0);
                assertEq(manager.balanceOf(address(hook), uint256(uint160(address(imd)))), canvas.totalFees());
            }
        }
    }

    function test_ReviewAllModesWhenIMDIsCurrencyZero() public {
        _setupDirection(true);
        _reviewModes();
    }

    function test_ReviewAllModesWhenIMDIsCurrencyOne() public {
        _setupDirection(false);
        _reviewModes();
    }
}
