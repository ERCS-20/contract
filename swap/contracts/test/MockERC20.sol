// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC20 for rescue / integration tests.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 10 ** 30);
    }
}
