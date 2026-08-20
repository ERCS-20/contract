// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPerpsOracle} from "../interfaces/IPerpsOracle.sol";
import {IOracleSampler} from "../interfaces/IOracleSampler.sol";

contract MockOracle is IPerpsOracle, IOracleSampler {
    mapping(uint256 => uint256) public prices;

    function setPrice(uint256 marketId, uint256 priceX18) external {
        prices[marketId] = priceX18;
    }

    function getPrice(uint256 marketId) external view returns (uint256) {
        return prices[marketId];
    }

    /// @dev No-op sampler for tests; mark price is set via `setPrice`.
    function update(uint256, address) external pure returns (bool updated) {
        return false;
    }
}
