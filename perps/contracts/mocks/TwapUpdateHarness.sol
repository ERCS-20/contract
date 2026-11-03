// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleSampler} from "../interfaces/IOracleSampler.sol";

/// @dev Calls `update` twice in one transaction so both see the same `block.timestamp`.
contract TwapUpdateHarness {
    function updateTwice(address oracle, uint256 marketId, address ercs20)
        external
        returns (bool first, bool second)
    {
        first = IOracleSampler(oracle).update(marketId, ercs20);
        second = IOracleSampler(oracle).update(marketId, ercs20);
    }

    function update(address oracle, uint256 marketId, address ercs20) external returns (bool) {
        return IOracleSampler(oracle).update(marketId, ercs20);
    }
}
