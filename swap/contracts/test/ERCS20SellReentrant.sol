// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Attempts a second `transfer(token, token, ...)` sell while the first `_transfer` is still executing (native callback).
contract ERCS20SellReentrant {
    IERC20Like public immutable token;

    uint256 private reenterAmount;

    constructor(address _token) {
        token = IERC20Like(_token);
    }

    function attack(uint256 sellAmount, uint256 _reenterAmount) external {
        reenterAmount = _reenterAmount;
        token.transfer(address(token), sellAmount);
    }

    receive() external payable {
        uint256 amt = reenterAmount;
        if (amt == 0) return;
        reenterAmount = 0;
        token.transfer(address(token), amt);
    }
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}
