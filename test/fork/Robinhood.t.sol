// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolFixture, LiquidityHelper} from "../helpers/PoolFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PlaceToken} from "../../src/PlaceToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Opt-in with forge test --fork-url <RPC> --fork-block-number <BLOCK> --match-contract RobinhoodForkTest.
/// Default offline suite explicitly skips this rehearsal; it does not silently report a fork pass.
contract RobinhoodForkTest is PoolFixture {
    function setUp() public {
        if (block.chainid != 4663) {
            vm.skip(true);
            return;
        }
        // Test-only verified chain fixtures. Production takes $poolManager and derives IMD from the launch pool.
        manager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        imd = MockERC20(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
        assertGt(address(manager).code.length, 0);
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.decimals(), 18);
        token = new PlaceToken();
        hook = _deployHook(manager, address(token));
        canvas = hook.canvas();
        seasons = canvas.seasons();
        router = hook.router();
        (address c0, address c1) =
            address(token) < address(imd) ? (address(token), address(imd)) : (address(imd), address(token));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(hook)));
        manager.initialize(key, uint160(1 << 96));
        liquidity = new LiquidityHelper(manager);
        token.transfer(address(liquidity), 10_000_000 ether);
        // Synthetic balances fund the rehearsal; the manager and IMD execution code are real fork state.
        deal(address(imd), address(liquidity), 10_000_000 ether);
        liquidity.add(key, -600, 600, 10_000_000 ether);
        deal(address(imd), alice, 10000 ether);
        token.transfer(alice, 10000 ether);
        vm.startPrank(alice);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function testRobinhoodRealManagerBuySellAndRedeem() public {
        (uint256 spent, uint256 received) = _swap(alice, true, true, 10 ether, 1);
        assertEq(spent, 10 ether);
        assertGt(received, 0);
        assertEq(canvas.drops(alice), 200);
        _paint(alice, 12, 4);
        _swap(alice, false, true, received / 2, 1);
        assertEq(canvas.drops(alice), 199);
        vm.prank(alice);
        canvas.claim();
        canvas.claimTreasury();
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(imd)))) + canvas.totalPaid()
                + canvas.totalTreasuryPaid(),
            canvas.totalFees()
        );
        assertEq(imd.balanceOf(address(router)), 0);
    }
}
