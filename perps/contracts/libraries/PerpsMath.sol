// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpsTypes} from "./PerpsTypes.sol";

/// @notice Position / PnL helpers for perps settlement.
library PerpsMath {
    using PerpsTypes for *;

    error InvalidPrice();
    error AmountZero();

    /// @notice Unrealized PnL of a position at `markPriceX18` (quote token units, signed).
    function unrealizedPnl(PerpsTypes.Position memory pos, uint256 markPriceX18)
        internal
        pure
        returns (int256)
    {
        if (pos.size == 0) return 0;
        if (markPriceX18 == 0 || pos.entryPriceX18 == 0) revert InvalidPrice();

        // pnl = size * (mark - entry) / 1e18
        int256 priceDelta = int256(markPriceX18) - int256(pos.entryPriceX18);
        return (pos.size * priceDelta) / int256(PerpsTypes.BASE);
    }

    /// @notice System equity = cash + unrealized PnL of system inventory.
    function systemEquity(uint256 systemCash, PerpsTypes.Position memory systemPos, uint256 markPriceX18)
        internal
        pure
        returns (int256)
    {
        return int256(systemCash) + unrealizedPnl(systemPos, markPriceX18);
    }

    /// @notice Apply a fill to a position. `signedAmount` > 0 = buy base, < 0 = sell base.
    /// @return newPos Updated position.
    /// @return realizedPnl Quote PnL realized on the closed portion (positive = profit).
    function applyFill(PerpsTypes.Position memory pos, int256 signedAmount, uint256 priceX18)
        internal
        pure
        returns (PerpsTypes.Position memory newPos, int256 realizedPnl)
    {
        if (signedAmount == 0) revert AmountZero();
        if (priceX18 == 0) revert InvalidPrice();

        if (pos.size == 0) {
            newPos.size = signedAmount;
            newPos.entryPriceX18 = priceX18;
            return (newPos, 0);
        }

        // Same direction or flat→open: weighted average entry.
        bool sameSign = (pos.size > 0 && signedAmount > 0) || (pos.size < 0 && signedAmount < 0);
        if (sameSign) {
            uint256 oldAbs = _abs(pos.size);
            uint256 addAbs = _abs(signedAmount);
            newPos.size = pos.size + signedAmount;
            newPos.entryPriceX18 = (pos.entryPriceX18 * oldAbs + priceX18 * addAbs) / (oldAbs + addAbs);
            return (newPos, 0);
        }

        // Opposite direction: close then maybe flip.
        uint256 posAbs = _abs(pos.size);
        uint256 fillAbs = _abs(signedAmount);

        if (fillAbs <= posAbs) {
            realizedPnl = _closePnl(pos.size, pos.entryPriceX18, signedAmount, priceX18);
            newPos.size = pos.size + signedAmount;
            newPos.entryPriceX18 = newPos.size == 0 ? 0 : pos.entryPriceX18;
            return (newPos, realizedPnl);
        }

        // Close all then open residual opposite.
        int256 closeAmount = -pos.size;
        realizedPnl = _closePnl(pos.size, pos.entryPriceX18, closeAmount, priceX18);
        int256 residual = signedAmount - closeAmount;
        newPos.size = residual;
        newPos.entryPriceX18 = priceX18;
        return (newPos, realizedPnl);
    }

    /// @notice Merge liquidated inventory into system position without adjusting cash.
    /// @dev Opposite sides net by size; residual keeps the larger side's entry price.
    function mergePositions(PerpsTypes.Position memory into, PerpsTypes.Position memory from)
        internal
        pure
        returns (PerpsTypes.Position memory out)
    {
        if (from.size == 0) return into;
        if (into.size == 0) return from;

        bool sameSign = (into.size > 0 && from.size > 0) || (into.size < 0 && from.size < 0);
        if (sameSign) {
            uint256 a = _abs(into.size);
            uint256 b = _abs(from.size);
            out.size = into.size + from.size;
            out.entryPriceX18 = (into.entryPriceX18 * a + from.entryPriceX18 * b) / (a + b);
            return out;
        }

        int256 net = into.size + from.size;
        if (net == 0) return PerpsTypes.Position(0, 0);
        out.size = net;
        out.entryPriceX18 = _abs(into.size) >= _abs(from.size) ? into.entryPriceX18 : from.entryPriceX18;
        return out;
    }

    function _closePnl(int256 /* size */, uint256 entryPriceX18, int256 signedClose, uint256 exitPriceX18)
        private
        pure
        returns (int256)
    {
        // Closed base has opposite sign of signedClose relative to reducing size.
        // realized = -signedClose * (exit - entry) / 1e18  when signedClose reduces long (signedClose < 0)
        // For long size>0, closing sell signedClose<0: pnl = (-signedClose) * (exit-entry)/1e18
        // General: pnl = (-signedClose) * (exit - entry) / 1e18 works for both sides when signedClose opposes size.
        int256 priceDelta = int256(exitPriceX18) - int256(entryPriceX18);
        return (-signedClose * priceDelta) / int256(PerpsTypes.BASE);
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }
}
