// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library PerpsTypes {
    uint256 internal constant BASE = 1e18;

    /// @dev Per-market position. Positive size = long, negative = short.
    struct Position {
        int256 size;
        uint256 entryPriceX18;
    }

    struct Market {
        bool exists;
        bool paused;
        address oracle;
        /// @notice Fixed ADL equity threshold (absolute USDC units, same decimals as collateral).
        uint256 adlEquityThreshold;
        /// @notice System inventory position. Cash lives only in `GlobalPerpsVault.systemBalances`.
        Position systemPosition;
    }

    /// @notice EIP-712 limit order. `amount` is total size; fills accumulate against it.
    struct Order {
        address trader;
        uint256 marketId;
        uint256 amount;
        uint256 priceX18;
        bool isBuy;
        uint256 nonce;
        uint256 expiry;
    }

    struct TradeFill {
        uint256 marketId;
        address maker;
        address taker;
        /// @notice Absolute base size filled in this settlement.
        uint256 amount;
        /// @notice Execution price, 1e18 quote per base.
        uint256 priceX18;
        /// @notice True if taker is buying (increasing long / decreasing short).
        bool takerIsBuy;
    }

    /// @notice Maker + taker signed limit orders authorizing a fill.
    struct FillAuth {
        Order makerOrder;
        Order takerOrder;
        bytes makerSig;
        bytes takerSig;
    }
}
