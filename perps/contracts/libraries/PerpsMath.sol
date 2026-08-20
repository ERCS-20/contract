// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpsTypes} from "./PerpsTypes.sol";

/// @notice Perpetual balance math: trades swap margin ↔ position at fill price.
library PerpsMath {
    error InvalidPrice();
    error AmountZero();

    /// @notice Mark-to-market equity ≈ margin + position * mark / 1e18.
    function equity(int256 margin, int256 position, uint256 markPriceX18) internal pure returns (int256) {
        return margin + (position * int256(markPriceX18)) / int256(PerpsTypes.ONE_X18);
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
        int256 quoteAmt = int256((amount * priceX18) / PerpsTypes.ONE_X18);

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

    /// @notice Split margin/position into positive and negative value at `priceX18`.
    /// @dev Margin leg is scaled by an extra 1e18 so it shares units with `position * price`.
    function getPositiveAndNegativeValue(int256 margin, int256 position, uint256 priceX18)
        internal
        pure
        returns (uint256 positive, uint256 negative)
    {
        if (margin > 0) {
            positive = uint256(margin) * PerpsTypes.ONE_X18;
        } else if (margin < 0) {
            negative = uint256(-margin) * PerpsTypes.ONE_X18;
        }

        if (position > 0) {
            positive += uint256(position) * priceX18;
        } else if (position < 0) {
            negative += uint256(-position) * priceX18;
        }
    }

    /// @notice True if collateralization ratio >= minCollateralX18 / 1e18.
    function isCollateralized(int256 margin, int256 position, uint256 priceX18, uint256 minCollateralX18)
        internal
        pure
        returns (bool)
    {
        (uint256 positive, uint256 negative) = getPositiveAndNegativeValue(margin, position, priceX18);
        return positive * PerpsTypes.ONE_X18 >= negative * minCollateralX18;
    }

    /// @notice Margin delta from funding: `-(indexDelta * position) / 1e18`.
    /// @dev Index up + long => debit; index up + short => credit.
    function fundingMarginDelta(int256 indexDelta, int256 position) internal pure returns (int256) {
        if (indexDelta == 0 || position == 0) return 0;
        return -((indexDelta * position) / int256(PerpsTypes.ONE_X18));
    }
}
