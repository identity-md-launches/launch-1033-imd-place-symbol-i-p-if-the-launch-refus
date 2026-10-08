// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Canvas} from "./Canvas.sol";
import {PlaceRouter} from "./PlaceRouter.sol";

/// @notice Immutable, single-pool IMD fees and buy-only paint issuance.
contract PlaceHook is IUnlockCallback {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable factory;
    Canvas public immutable canvas;
    PlaceRouter public immutable router;
    address public imd;
    uint256 public dropUnit;
    uint256 public launchTime;
    bool public initialized;
    PoolKey private pool;
    PoolId public poolId;
    bytes32 private paymentHash;

    error Unauthorized();
    error InvalidPool();
    error PartialFill();
    error InvalidBuyer();
    error InvalidPayment();

    event PoolBound(PoolId indexed poolId, address indexed imd, uint256 launchTime);
    event SwapFee(bool indexed buy, address indexed buyer, uint256 grossIMD, uint256 fee, uint256 drops);

    constructor(IPoolManager poolManager_, address token_, address factory_) {
        require(
            address(poolManager_).code.length > 0 && token_.code.length > 0 && factory_ != address(0),
            "configuration required"
        );
        poolManager = poolManager_;
        token = token_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        canvas = new Canvas(address(this));
        router = new PlaceRouter(poolManager_, address(this));
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyManager
        returns (bytes4)
    {
        if (sender != factory || initialized || key.fee != 12500 || address(key.hooks) != address(this)) revert InvalidPool();
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        address pair = a == token ? b : (b == token ? a : address(0));
        if (pair.code.length == 0 || pair == token) revert InvalidPool();
        uint8 decimals = IERC20Metadata(pair).decimals();
        if (decimals < 2 || decimals > 36) revert InvalidPool();
        imd = pair;
        dropUnit = 10 ** uint256(decimals) / 20;
        pool = key;
        poolId = key.toId();
        initialized = true;
        launchTime = block.timestamp;
        emit PoolBound(poolId, pair, block.timestamp);
        canvas.start(pair);
        return IHooks.beforeInitialize.selector;
    }

    function getPoolKey() external view returns (PoolKey memory) {
        if (!initialized) revert InvalidPool();
        return pool;
    }

    function feeBps() public view returns (uint256) {
        if (!initialized) return 3500;
        uint256 elapsed = block.timestamp - launchTime;
        return elapsed >= 30 minutes ? 200 : 200 + 3300 * (30 minutes - elapsed) / 30 minutes;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    function _specifiedFee(bool buy, int256 specified, uint256 bps) private pure returns (uint256) {
        if (buy) return uint256(-specified) * bps / 10_000;
        // Exact-output IMD: gross up so the user's requested output is net of the hook fee.
        return (uint256(specified) * bps + (10_000 - bps) - 1) / (10_000 - bps);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        bool buy = params.zeroForOne == (Currency.unwrap(key.currency0) == imd);
        bool specifiedIMD = buy == (params.amountSpecified < 0);
        uint256 fee = 0;
        if (specifiedIMD) fee = _specifiedFee(buy, params.amountSpecified, feeBps());
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(key);
        bool imd0 = Currency.unwrap(key.currency0) == imd;
        bool buy = params.zeroForOne == imd0;
        bool specifiedIMD = buy == (params.amountSpecified < 0);
        int128 pairDelta = imd0 ? delta.amount0() : delta.amount1();
        if ((buy && pairDelta >= 0) || (!buy && pairDelta <= 0)) revert PartialFill();
        uint256 poolIMD = buy ? uint256(-int256(pairDelta)) : uint256(uint128(pairDelta));
        uint256 fee = 0;
        int128 returned = 0;
        uint256 bps = feeBps();
        if (specifiedIMD) {
            fee = _specifiedFee(buy, params.amountSpecified, bps);
            uint256 expected =
                buy ? uint256(-params.amountSpecified) - fee : uint256(params.amountSpecified) + fee;
            // A beforeSwap specified delta cannot be refunded on that side in afterSwap.
            // Revert partial fills instead of taxing IMD that never traded.
            if (poolIMD != expected) revert PartialFill();
        } else {
            fee = buy ? (poolIMD * bps + (10_000 - bps) - 1) / (10_000 - bps) : poolIMD * bps / 10_000;
            returned = fee.toInt128();
        }
        uint256 gross = buy ? poolIMD + fee : poolIMD;
        address buyer = tx.origin;
        if (data.length > 0) {
            if (sender != address(router) || data.length != 32) revert InvalidBuyer();
            buyer = abi.decode(data, (address));
            if (buyer == address(0)) revert InvalidBuyer();
        }
        uint256 paintDrops = buy ? gross / dropUnit : 0;
        if (fee > 0) {
            // Claims do not need a pre-funded IMD balance in a fresh PoolManager.
            poolManager.mint(address(this), uint256(uint160(imd)), fee);
            canvas.recordFee(fee, gross * 200 / 10_000);
        }
        if (paintDrops > 0) canvas.credit(buyer, paintDrops);
        emit SwapFee(buy, buyer, gross, fee, paintDrops);
        return (IHooks.afterSwap.selector, returned);
    }

    /// @dev Canvas fixes every recipient to an earned balance, frozen pot or the fixed treasury.
    function pay(address to, uint256 amount) external {
        if (msg.sender != address(canvas) || paymentHash != bytes32(0) || to == address(0)) {
            revert Unauthorized();
        }
        bytes memory data = abi.encode(to, amount);
        paymentHash = keccak256(data);
        bytes memory result = poolManager.unlock(data);
        if (result.length != 0 || paymentHash != bytes32(0)) revert InvalidPayment();
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (paymentHash == bytes32(0) || keccak256(data) != paymentHash) revert InvalidPayment();
        delete paymentHash;
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), uint256(uint160(imd)), amount);
        poolManager.take(Currency.wrap(imd), to, amount);
        return bytes("");
    }
}
