// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library PerpsTypes {
    uint256 internal constant BASE = 1e18;

    /// @dev Per-market account (dYdX-style). Margin/position are signed.
    struct Balance {
        int256 margin;
        int256 position;
    }

    struct Market {
        bool exists;
        bool paused;
        address oracle;
        /// @notice Fixed ADL equity threshold (absolute USDC units).
        uint256 adlEquityThreshold;
        /// @notice System inventory size. System cash lives in `GlobalPerpsVault.systemBalances`.
        int256 systemPosition;
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
