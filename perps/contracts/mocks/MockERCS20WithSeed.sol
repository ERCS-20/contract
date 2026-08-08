// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev ERCS20-like token for PerpsPairFactory / oracle binding tests.
contract MockERCS20WithSeed is Ownable {
    uint256 public usdcSeedAmount;
    uint256 public totalSupply;
    uint256 public tokenReserve;
    uint256 public quoteReserve;

    constructor(uint256 usdcSeedAmount_, uint256 totalSupply_) Ownable(msg.sender) {
        usdcSeedAmount = usdcSeedAmount_;
        totalSupply = totalSupply_;
        tokenReserve = totalSupply_;
        quoteReserve = usdcSeedAmount_;
    }

    function setReserves(uint256 tokenReserve_, uint256 quoteReserve_) external {
        tokenReserve = tokenReserve_;
        quoteReserve = quoteReserve_;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (tokenReserve, quoteReserve);
    }
}
