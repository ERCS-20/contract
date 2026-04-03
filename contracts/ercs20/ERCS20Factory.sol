// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import "./ERCS20.sol";

/// @title ERCS20Factory
/// @notice Factory contract for deploying and tracking ERCS20 (Equity Request for Comments - Stock 20) instances.
/// @dev
/// - Owner can pause/unpause new deployments.
/// - Each deployment increments `index` and records the new token address.
/// - Includes owner-only rescue functions for native quote asset and ERC20 held by this factory.
contract ERCS20Factory is Pausable, Ownable {

    /// @notice Sequential id assigned to each newly created ERCS20 contract.
    uint256 public index;
    /// @notice Registry of contracts created by this factory.
    mapping(address => bool) public ercs20s;
    /// @notice Registry of symbols used by this factory.
    mapping(string => bool) public symbols;

    /// @notice Emitted when a new ERCS20 token contract is created.
    /// @param ercs20 The ERCS20 token address.
    /// @param index Sequential index assigned by the factory/creator.
    event Create(address indexed ercs20, uint256 index);

    /// @notice Deploys a new ERCS20 token contract and transfers its ownership.
    /// @param name ERC20 name for the new token.
    /// @param symbol ERC20 symbol for the new token.
    /// @param totalSupply Initial token supply minted to the ERCS20 contract itself.
    /// @param usdcAmount Initial quote-side reserve seed (USDC-chain native asset side in implementation).
    /// @param newOwner Address that receives ownership of the new ERCS20 contract.
    function create(string memory name, string memory symbol, uint256 totalSupply, uint256 usdcAmount, address newOwner) external whenNotPaused {

        require(!symbols[symbol], "ERCS20Factory: SYMBOL_EXISTS");
        symbols[symbol] = true;

        ERCS20 ercs20 = new ERCS20(name, symbol, totalSupply, usdcAmount, index++);
        ercs20.transferOwnership(newOwner);
        ercs20.setWithdrawAddr(newOwner);
        ercs20s[address(ercs20)] = true;

        emit Create(address(ercs20), index-1);
    }

    /// @notice Pauses factory creation operations.
    /// @dev Only callable by owner while not paused.
    function pause() external virtual whenNotPaused onlyOwner {
        _pause();
    }

    /// @notice Unpauses factory creation operations.
    /// @dev Only callable by owner while paused.
    function unpause() external virtual whenPaused onlyOwner {
        _unpause();
    }

    /// @notice Transfers native quote asset held by this factory.
    /// @dev Owner-only rescue/administrative function.
    /// @param to Recipient address.
    /// @param amount Amount of native quote asset to transfer.
    function safeTransferETH(address to, uint256 amount) external onlyOwner {
        TransferHelper.safeTransferETH(to, amount);
    }

    /// @notice Transfers ERC20 tokens held by this factory.
    /// @dev Owner-only rescue/administrative function.
    /// @param token ERC20 token address.
    /// @param to Recipient address.
    /// @param amount Amount of tokens to transfer.
    function safeTransfer(address token, address to, uint256 amount) external onlyOwner {
        TransferHelper.safeTransfer(token, to, amount);
    }

}