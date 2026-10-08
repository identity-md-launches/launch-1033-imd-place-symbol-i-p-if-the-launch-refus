// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Local browser-integration fixture only; not part of the production launch.
contract TestDeployer {
    function deploy(bytes32 salt, bytes memory creationCode) external returns (address at) {
        assembly ("memory-safe") { at := create2(0, add(creationCode, 32), mload(creationCode), salt) }
        require(at != address(0), "create2 failed");
    }
}
