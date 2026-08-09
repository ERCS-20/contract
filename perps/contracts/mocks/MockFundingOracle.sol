// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundingOracle} from "../interfaces/IFundingOracle.sol";

/// @dev Test funder: `ratePerSecondX18` is unitless per-second funding (1e18).
contract MockFundingOracle is IFundingOracle {
    bool public isPositive = true;
    uint256 public ratePerSecondX18;
    uint256 public lastPriceX18;
    uint256 public lastMarketId;
    uint256 public updateCount;

    function setRate(bool positive, uint256 ratePerSecondX18_) external {
        isPositive = positive;
        ratePerSecondX18 = ratePerSecondX18_;
    }

    function update(uint256 marketId, uint256 lastPriceX18_, address) external returns (bool updated) {
        lastMarketId = marketId;
        lastPriceX18 = lastPriceX18_;
        unchecked {
            ++updateCount;
        }
        return true;
    }

    function getFunding(uint256, uint256 timeDelta) external view returns (bool, uint256) {
        return (isPositive, ratePerSecondX18 * timeDelta);
    }
}
