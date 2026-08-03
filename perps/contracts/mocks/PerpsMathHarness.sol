// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpsTypes} from "../libraries/PerpsTypes.sol";
import {PerpsMath} from "../libraries/PerpsMath.sol";

/// @dev Thin wrapper so Hardhat/forge tests can exercise PerpsMath.
contract PerpsMathHarness {
    function unrealizedPnl(int256 size, uint256 entryPriceX18, uint256 markPriceX18) external pure returns (int256) {
        return PerpsMath.unrealizedPnl(PerpsTypes.Position(size, entryPriceX18), markPriceX18);
    }

    function applyFill(int256 size, uint256 entryPriceX18, int256 signedAmount, uint256 priceX18)
        external
        pure
        returns (int256 newSize, uint256 newEntry, int256 realizedPnl)
    {
        (PerpsTypes.Position memory p, int256 pnl) =
            PerpsMath.applyFill(PerpsTypes.Position(size, entryPriceX18), signedAmount, priceX18);
        return (p.size, p.entryPriceX18, pnl);
    }

    function systemEquity(uint256 systemCash, int256 size, uint256 entryPriceX18, uint256 markPriceX18)
        external
        pure
        returns (int256)
    {
        return PerpsMath.systemEquity(systemCash, PerpsTypes.Position(size, entryPriceX18), markPriceX18);
    }
}
