// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Optional hook for oracles that need operator/exchange-driven sampling (e.g. TWAP).
interface IOracleSampler {
    /// @return updated True if a new sample was taken for `marketId`.
    function update(uint256 marketId, address ercs20) external returns (bool updated);
}
