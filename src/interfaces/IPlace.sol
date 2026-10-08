// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IPlaceHook {
    function getPoolKey() external view returns (PoolKey memory);
    function imd() external view returns (address);
    function pay(address to, uint256 amount) external;
}

interface ICanvas {
    function imd() external view returns (address);
    function frozenRanks(uint256 season, address artist, uint16[] calldata ids)
        external
        view
        returns (uint16[] memory);
    function coloursOf(uint256 season) external view returns (bytes memory);
    function getPalette() external view returns (uint24[16] memory);
    function releasePot(uint256 season) external returns (uint256);
    function rollPot(uint256 season) external;
}
