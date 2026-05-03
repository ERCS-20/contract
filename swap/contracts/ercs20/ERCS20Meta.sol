// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title ERCS20Meta
/// @notice Single-call reader for ERCS20 token display fields and quote-side amounts (`ERCS20.sol`).
contract ERCS20Meta {

    function get(address token) external view returns (string memory name, string memory symbol, uint8 decimals, uint256 totalSupply,uint256 usdcSeedAmount) {
        IERCS20 ercs20 = IERCS20(token);

        name = ercs20.name(); 
        symbol = ercs20.symbol();
        decimals = ercs20.decimals();
        totalSupply = ercs20.totalSupply();
        usdcSeedAmount = ercs20.usdcSeedAmount();
    }
}

/// @notice Minimal surface for ERCS20 quote-side storage exposed as public getters.
interface IERCS20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function usdcSeedAmount() external view returns (uint256);
}
