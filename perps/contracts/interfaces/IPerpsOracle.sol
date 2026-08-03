// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Price oracle for a perps market (1e18 quote per base).
interface IPerpsOracle {
    function getPrice(uint256 marketId) external view returns (uint256 priceX18);
}
