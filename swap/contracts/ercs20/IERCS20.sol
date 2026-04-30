// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERCS20 (Equity Request for Comments - Stock 20)
/// @notice Interface for the ERCS20 stock token standard with AMM-style swap behavior.
interface IERCS20 is IERC20 {

    /// @notice Emitted when tracked reserves are updated.
    /// @param totalErcs20 Current token-side tracked reserve.
    /// @param totalUsdc Current quote-side tracked reserve.
    event Sync(uint112 totalErcs20, uint112 totalUsdc);

    /// @notice Emitted for swap executions.
    /// @param sender Address that initiates the swap.
    /// @param ercs20AmountIn Token amount sent in.
    /// @param usdcAmountIn Quote amount sent in (USDC-chain native asset in implementation).
    /// @param ercs20AmountOut Token amount sent out.
    /// @param usdcAmountOut Quote amount sent out (USDC-chain native asset in implementation).
    /// @param to Final recipient of output asset.
    event Swap(address indexed sender, uint256 ercs20AmountIn, uint256 usdcAmountIn, uint256 ercs20AmountOut, uint256 usdcAmountOut, address indexed to);

    /// @notice Returns current tracked reserves used by pricing logic.
    /// @return tokenReserve Token-side reserve.
    /// @return quoteReserve Quote-side reserve.
    function getReserves() external returns(uint256, uint256);
    
    /// @notice Buys ERCS20 tokens with quote asset (USDC-chain native asset in implementation).
    /// @param amountInMin Minimum acceptable token output.
    /// @param deadline Unix timestamp after which the call reverts; use `type(uint256).max` to disable.
    function buy(uint256 amountInMin, uint256 deadline) external payable;

    /// @notice Sells ERCS20 tokens for quote asset (USDC-chain native asset in implementation).
    /// @param amountOut Token amount to sell.
    /// @param amountInMin Minimum acceptable quote output.
    /// @param deadline Unix timestamp after which the call reverts; use `type(uint256).max` to disable.
    function sell(uint256 amountOut, uint256 amountInMin, uint256 deadline) external;
}