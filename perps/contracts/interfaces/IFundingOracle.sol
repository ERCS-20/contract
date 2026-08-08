// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Funding rate oracle: caches a unitless rate, samples from perp last vs spot.
/// @dev `valueX18` is 1e18-fixed. Positive funding means longs pay shorts.
interface IFundingOracle {
    /// @notice Resample the cached funding rate using perp `lastPriceX18` (and spot internally).
    /// @dev Intended to be called by PerpsExchange (operator path). May no-op if min interval not met.
    /// @param lastPriceX18 Perp last trade price (1e18 quote per base).
    /// @return updated True if a new sample was taken.
    function update(uint256 lastPriceX18) external returns (bool updated);

    /// @notice Accumulated unitless funding over `timeDelta` using the cached rate.
    /// @param timeDelta Elapsed seconds since the previous index update.
    /// @return isPositive True if longs pay shorts.
    /// @return valueX18 Unitless accumulated funding (typically ratePerSecond * timeDelta).
    function getFunding(uint256 timeDelta) external view returns (bool isPositive, uint256 valueX18);
}
