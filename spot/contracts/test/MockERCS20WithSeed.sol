// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev ERCS20-like token for SpotPairFactory opening-price tests.
contract MockERCS20WithSeed is Ownable {
    uint256 public usdcSeedAmount;
    uint256 public totalSupply;

    constructor(uint256 usdcSeedAmount_, uint256 totalSupply_) Ownable(msg.sender) {
        usdcSeedAmount = usdcSeedAmount_;
        totalSupply = totalSupply_;
    }
}
