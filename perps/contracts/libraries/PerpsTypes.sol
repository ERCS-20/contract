// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library PerpsTypes {
    /// @dev Fixed-point unit for `*X18` quantities (prices, ratios, funding index). 1.0 == 1e18.
    uint256 internal constant ONE_X18 = 1e18;

    /// @dev Continuous funding index per market (global + per-account local copy).
    struct FundingIndex {
        /// @dev Last accrual / sync time (`block.timestamp`).
        uint256 timestamp;
        /// @dev Cumulative funding index in quote-per-base, 1e18 fixed-point.
        ///      Accrual: `value += ±(unitlessFunding * markPriceX18) / ONE_X18`.
        ///      Settle into margin: `margin += -(Δvalue * position) / ONE_X18`
        ///      (`value`↑ → longs pay shorts; `value`↓ → shorts pay longs).
        int256 value;
    }

    /// @dev Per-market account. Margin/position are signed.
    struct Balance {
        int256 margin;
        int256 position;
    }

    struct Market {
        /// @notice Underlying ERCS20 spot pool.
        address ercs20;
        bool exists;
        bool paused;
        /// @notice ADL trigger: liquidator Balance.margin ≤ this (absolute USDC units).
        uint256 adlEquityThreshold;
        /// @notice Min collateralization ratio (1e18 = 100%). Factory default: 1.0055e18.
        uint256 minCollateralX18;
        /// @notice Last settled trade price (1e18 quote per base); 0 until first fill.
        uint256 lastPriceX18;
    }

    /// @notice Per-market final settlement state (separate from hot `Market` reads).
    struct MarketSettlement {
        /// @notice Irreversible: market closed; users self-settle at `settlementPriceX18`.
        bool enabled;
        /// @notice Frozen close-out price once enabled (chosen off-chain).
        uint256 settlementPriceX18;
        /// @notice Timestamp when final settlement was first enabled (lock start).
        uint256 lockedAt;
    }

    /// @notice EIP-712 limit order. `margin` is collateral to bring for newly opened size (vault auto-tops up).
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
