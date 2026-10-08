// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlaceHook} from "../../src/PlaceHook.sol";
import {PlaceToken} from "../../src/PlaceToken.sol";
import {PlaceRouter} from "../../src/PlaceRouter.sol";
import {Canvas} from "../../src/Canvas.sol";
import {Seasons} from "../../src/Seasons.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LiquidityHelper is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function add(PoolKey memory key, int24 lower, int24 upper, int256 amount) external {
        bytes memory result =
            manager.unlock(abi.encode(key, ModifyLiquidityParams(lower, upper, amount, bytes32(0))));
        require(result.length == 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, ModifyLiquidityParams memory p) =
            abi.decode(data, (PoolKey, ModifyLiquidityParams));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, p, "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency c, int128 d) private {
        if (d < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(manager), uint256(-int256(d)));
            require(manager.settle() == uint256(-int256(d)));
        } else if (d > 0) {
            manager.take(c, address(this), uint256(uint128(d)));
        }
    }
}

/// @dev Other routers have no authority to name a paint recipient.
contract ForeignRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory p, bytes memory hookData) external {
        bytes memory result = manager.unlock(abi.encode(key, p, hookData));
        require(result.length == 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, SwapParams memory p, bytes memory hookData) =
            abi.decode(data, (PoolKey, SwapParams, bytes));
        BalanceDelta d = manager.swap(key, p, hookData);
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 d) private {
        if (d < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(manager), uint256(-int256(d)));
            require(manager.settle() == uint256(-int256(d)));
        } else if (d > 0) {
            manager.take(c, address(this), uint256(uint128(d)));
        }
    }
}

abstract contract PoolFixture is Test {
    IPoolManager internal manager;
    PlaceToken internal token;
    MockERC20 internal imd;
    PlaceHook internal hook;
    PlaceRouter internal router;
    Canvas internal canvas;
    Seasons internal seasons;
    PoolKey internal key;
    LiquidityHelper internal liquidity;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _newIMD() internal virtual returns (MockERC20) {
        return new MockERC20("Identity.md", "IMD", 1_000_000_000 ether);
    }

    function _deployHook(IPoolManager m, address t) internal returns (PlaceHook result) {
        bytes memory code = abi.encodePacked(type(PlaceHook).creationCode, abi.encode(m, t, address(this)));
        bytes32 hash = keccak256(code);
        for (uint256 i = 0; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash))))
            );
            if (!HookFlags.matches(predicted, HookFlags.PLACE)) continue;
            address deployed;
            assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
            require(deployed == predicted && deployed.code.length > 0, "deployment failed");
            return PlaceHook(deployed);
        }
        revert("mining exhausted");
    }

    function _setup(bool singleSided) internal {
        vm.warp(1_800_000_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new PlaceToken();
        imd = _newIMD();
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
        if (!singleSided) imd.transfer(address(liquidity), 10_000_000 ether);
        if (!singleSided) liquidity.add(key, -600, 600, 10_000_000 ether);
        else if (c0 == address(token)) liquidity.add(key, 0, 600, 10_000_000 ether);
        else liquidity.add(key, -600, 0, 10_000_000 ether);
        imd.transfer(alice, 100_000 ether);
        imd.transfer(bob, 100_000 ether);
        token.transfer(alice, 100_000 ether);
        token.transfer(bob, 100_000 ether);
        vm.startPrank(alice);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _limit(bool buy) internal view returns (uint160) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swap(address user, bool buy, bool exactInput, uint256 amount, uint256 limit)
        internal
        returns (uint256 spent, uint256 received)
    {
        vm.prank(user);
        return router.swap(buy, exactInput, amount, limit, _limit(buy), block.timestamp);
    }

    function _paint(address user, uint16 pixel, uint8 colour) internal {
        uint16[] memory ids = new uint16[](1);
        ids[0] = pixel;
        uint8[] memory cs = new uint8[](1);
        cs[0] = colour;
        vm.prank(user);
        canvas.paint(ids, cs);
    }
}
