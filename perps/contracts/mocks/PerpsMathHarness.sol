// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpsTypes} from "../libraries/PerpsTypes.sol";
import {PerpsMath} from "../libraries/PerpsMath.sol";

contract PerpsMathHarness {
    function equity(int256 margin, int256 position, uint256 markPriceX18) external pure returns (int256) {
        return PerpsMath.equity(margin, position, markPriceX18);
    }

    function applyTrade(
        int256 takerMargin,
        int256 takerPosition,
        int256 makerMargin,
        int256 makerPosition,
        uint256 amount,
        uint256 priceX18,
        bool takerIsBuy
    )
        external
        pure
        returns (int256 newTakerMargin, int256 newTakerPosition, int256 newMakerMargin, int256 newMakerPosition)
    {
        PerpsTypes.Balance memory taker = PerpsTypes.Balance(takerMargin, takerPosition);
        PerpsTypes.Balance memory maker = PerpsTypes.Balance(makerMargin, makerPosition);
        (PerpsTypes.Balance memory nt, PerpsTypes.Balance memory nm) =
            PerpsMath.applyTrade(taker, maker, amount, priceX18, takerIsBuy);
        return (nt.margin, nt.position, nm.margin, nm.position);
    }

    function fillMargin(uint256 orderMargin, uint256 orderAmount, uint256 fillAmount)
        external
        pure
        returns (uint256)
    {
        return PerpsMath.fillMargin(orderMargin, orderAmount, fillAmount);
    }

    function isCollateralized(
        int256 margin,
        int256 position,
        uint256 priceX18,
        uint256 minCollateralX18
    ) external pure returns (bool) {
        return PerpsMath.isCollateralized(margin, position, priceX18, minCollateralX18);
    }

    function fundingMarginDelta(int256 indexDelta, int256 position) external pure returns (int256) {
        return PerpsMath.fundingMarginDelta(indexDelta, position);
    }
}
