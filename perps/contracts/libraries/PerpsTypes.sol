// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library PerpsTypes {
    uint256 internal constant BASE = 1e18;

    /// @notice Default min collateralization ratio (1e18 = 100%).
    /// @dev 100.5% ≈ 0.5% maintenance margin (supports up to ~100x initial leverage).
    uint256 internal constant MIN_COLLATERAL_X18 = 1.005e18;

    /// @dev Continuous funding index per market (signed cumulative quote-per-base).
    struct FundingIndex {
        uint256 timestamp;
        int256 value;
    }

    /// @dev Per-market account. Margin/position are signed.
    struct Balance {
        int256 margin;
        int256 position;
    }

    struct Market {
        bool exists;
        bool paused;
        address oracle;
        /// @notice Funding rate oracle; address(0) disables funding.
        address funder;
        /// @notice ADL trigger: liquidator Balance.margin ≤ this (absolute USDC units).
        uint256 adlEquityThreshold;
        /// @notice Min collateralization ratio (1e18 = 100%). Prefer `MIN_COLLATERAL_X18`.
        uint256 minCollateralX18;
        /// @notice Last settled trade price (1e18 quote per base); 0 until first fill.
        uint256 lastPriceX18;
    }

    /// @notice EIP-712 limit order. `margin` is total collateral to lock for the full `amount`.
    struct Order {
        address trader;
        uint256 marketId;
        uint256 amount;
        uint256 margin;
        uint256 priceX18;
        bool isBuy;
        uint256 nonce;
        uint256 expiry;
    }

    struct Fulfillment {
        uint256 amount;
        uint256 priceX18;
    }

    struct TradeSettlement {
        Order takerOrder;
        bytes takerSignature;
        Order[] makerOrders;
        bytes[] makerSignatures;
        Fulfillment[] fulfillments;
    }
}
