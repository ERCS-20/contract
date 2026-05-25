// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Minimal ERCS20Factory stand-in for SpotPairFactory tests.
contract MockERCS20Factory {
    mapping(address => bool) public ercs20s;

    function setERCS20(address token, bool allowed) external {
        ercs20s[token] = allowed;
    }
}
