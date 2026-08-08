// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Minimal reserves mock for Ercs20FundingOracle tests.
contract MockErcs20Reserves {
    uint256 public tokenReserve;
    uint256 public quoteReserve;

    function setReserves(uint256 tokenReserve_, uint256 quoteReserve_) external {
        tokenReserve = tokenReserve_;
        quoteReserve = quoteReserve_;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (tokenReserve, quoteReserve);
    }
}
