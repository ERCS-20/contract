// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Funding rate oracle: caches a unitless rate per market, samples from perp last vs spot.
/// @dev `valueX18` is 1e18-fixed. Positive funding means longs pay shorts.
interface IFundingOracle {
    /// @notice Resample the cached funding rate for `marketId` using perp `lastPriceX18` and spot `ercs20`.
    /// @dev Intended to be called by PerpsExchange (operator path). May no-op if min interval not met.
    /// @return updated True if a new sample was taken.
    function update(uint256 marketId, uint256 lastPriceX18, address ercs20) external returns (bool updated);

    /// @notice Accumulated unitless funding over `timeDelta` using the cached rate for `marketId`.
    /// @return isPositive True if longs pay shorts.
    /// @return valueX18 Unitless accumulated funding (typically ratePerSecond * timeDelta).
    function getFunding(uint256 marketId, uint256 timeDelta)
        external
        view
        returns (bool isPositive, uint256 valueX18);
}
