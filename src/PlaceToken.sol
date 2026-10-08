// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PlaceToken is ERC20 {
    constructor() ERC20("imd/place", "i/p") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
