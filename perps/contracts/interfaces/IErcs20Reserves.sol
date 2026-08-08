// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Minimal ERCS20 surface: spot mid = quoteReserve * 1e18 / tokenReserve.
interface IErcs20Reserves {
    function getReserves() external view returns (uint256 tokenReserve, uint256 quoteReserve);
}
