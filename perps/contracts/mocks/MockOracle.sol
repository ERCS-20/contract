// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPerpsOracle} from "../interfaces/IPerpsOracle.sol";

contract MockOracle is IPerpsOracle {
    mapping(uint256 => uint256) public prices;

    function setPrice(uint256 marketId, uint256 priceX18) external {
        prices[marketId] = priceX18;
    }

    function getPrice(uint256 marketId) external view returns (uint256) {
        return prices[marketId];
    }
}
