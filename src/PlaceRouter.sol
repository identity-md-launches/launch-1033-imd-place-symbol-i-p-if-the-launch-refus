// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPlaceHook} from "./interfaces/IPlace.sol";

/// @notice A single-pool router. Funds are pulled ONLY from msg.sender before unlock.
contract PlaceRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    IPlaceHook public immutable hook;
    address private payer;
    bytes32 private callbackHash;

    struct Request {
        bool buy;
        bool exactInput;
        uint256 amount;
        uint256 limit;
        uint160 sqrtPriceLimitX96;
    }
    error UnauthorizedCallback();
    error InvalidSwap();
    error Slippage();
    event Swapped(address indexed trader, bool buy, uint256 spent, uint256 received);

    constructor(IPoolManager manager_, address hook_) {
        require(address(manager_).code.length > 0 && hook_ != address(0), "configuration required");
        manager = manager_;
        hook = IPlaceHook(hook_);
    }

    function swap(
        bool buy,
        bool exactInput,
        uint256 amount,
        uint256 limit,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external nonReentrant returns (uint256 spent, uint256 received) {
        if (
            block.timestamp > deadline || amount == 0 || limit == 0
                || amount > uint256(uint128(type(int128).max))
        ) {
            revert InvalidSwap();
        }
        PoolKey memory key = hook.getPoolKey();
        address imd = hook.imd();
        address input = buy
            ? imd
            : (Currency.unwrap(key.currency0) == imd
                    ? Currency.unwrap(key.currency1)
                    : Currency.unwrap(key.currency0));
        uint256 budget = exactInput ? amount : limit;
        IERC20 token = IERC20(input);
        // No user-supplied payer exists, either here or in unlockCallback.
        token.safeTransferFrom(msg.sender, address(this), budget);
        // A single guarded swap owns this budget. Settlement also checks the actual amount received.
        if (token.balanceOf(address(this)) < budget) revert InvalidSwap();
        bytes memory data = abi.encode(Request(buy, exactInput, amount, limit, sqrtPriceLimitX96));
        payer = msg.sender;
        callbackHash = keccak256(data);
        (spent, received) = abi.decode(manager.unlock(data), (uint256, uint256));
        delete payer;
        delete callbackHash;
        emit Swapped(msg.sender, buy, spent, received);
        if (budget > spent) token.safeTransfer(msg.sender, budget - spent);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || callbackHash == bytes32(0) || keccak256(data) != callbackHash) {
            revert UnauthorizedCallback();
        }
        delete callbackHash;
        Request memory r = abi.decode(data, (Request));
        PoolKey memory key = hook.getPoolKey();
        bool imd0 = Currency.unwrap(key.currency0) == hook.imd();
        bool zeroForOne = r.buy == imd0;
        int256 amount = r.exactInput ? -int256(r.amount) : int256(r.amount);
        BalanceDelta delta =
            manager.swap(key, SwapParams(zeroForOne, amount, r.sqrtPriceLimitX96), abi.encode(payer));
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwap();
        uint256 spent = uint256(-int256(inputDelta));
        uint256 received = uint256(uint128(outputDelta));
        if (spent > (r.exactInput ? r.amount : r.limit) || received < (r.exactInput ? r.limit : r.amount)) {
            revert Slippage();
        }
        Currency payCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency receiveCurrency = zeroForOne ? key.currency1 : key.currency0;
        manager.sync(payCurrency);
        IERC20(Currency.unwrap(payCurrency)).safeTransfer(address(manager), spent);
        uint256 settled = manager.settle();
        if (settled != spent) revert InvalidSwap();
        manager.take(receiveCurrency, payer, received);
        return abi.encode(spent, received);
    }
}
