// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpsTypes} from "./PerpsTypes.sol";

/// @notice dYdX-style balance math: trades swap margin ↔ position at fill price.
library PerpsMath {
    error InvalidPrice();
    error AmountZero();

    /// @notice Mark-to-market equity ≈ margin + position * mark / 1e18.
    function equity(int256 margin, int256 position, uint256 markPriceX18) internal pure returns (int256) {
        if (position == 0) return margin;
        if (markPriceX18 == 0) revert InvalidPrice();
        return margin + (position * int256(markPriceX18)) / int256(PerpsTypes.BASE);
    }

    function systemEquity(uint256 systemCash, int256 systemPosition, uint256 markPriceX18)
        internal
        pure
        returns (int256)
    {
        return equity(int256(systemCash), systemPosition, markPriceX18);
    }

    /// @notice Apply a bilateral fill (taker perspective `takerIsBuy`).
    function applyTrade(
        PerpsTypes.Balance memory taker,
        PerpsTypes.Balance memory maker,
        uint256 amount,
        uint256 priceX18,
        bool takerIsBuy
    ) internal pure returns (PerpsTypes.Balance memory newTaker, PerpsTypes.Balance memory newMaker) {
        int256 posAmt = int256(amount);
        int256 quoteAmt = int256((amount * priceX18) / PerpsTypes.BASE);

        if (takerIsBuy) {
            newTaker.position = taker.position + posAmt;
            newTaker.margin = taker.margin - quoteAmt;
            newMaker.position = maker.position - posAmt;
            newMaker.margin = maker.margin + quoteAmt;
        } else {
            newTaker.position = taker.position - posAmt;
            newTaker.margin = taker.margin + quoteAmt;
            newMaker.position = maker.position + posAmt;
            newMaker.margin = maker.margin - quoteAmt;
        }
    }

    /// @notice Proportional margin for this fill: order.margin * fillAmount / order.amount.
    function fillMargin(uint256 orderMargin, uint256 orderAmount, uint256 fillAmount)
        internal
        pure
        returns (uint256)
    {
        return (orderMargin * fillAmount) / orderAmount;
    }
}
