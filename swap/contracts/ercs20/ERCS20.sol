// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import "./IERCS20.sol";


/// @title ERCS20 (Equity Request for Comments - Stock 20)
/// @notice Implementation of the ERCS20 stock token standard with built-in AMM-style USDC pricing.
/// @dev
/// - The contract mints the full token supply to itself as initial liquidity.
/// - `ercs20Amount` and `usdAmount` are internal reserve trackers used for pricing.
/// - Buy flow: user sends USDC-chain native quote asset via `buy` (or plain transfer to `receive`) and gets tokens.
/// - Sell flow: user transfers tokens to this contract (directly or via `sell`) and receives USDC-chain native quote asset.
/// - A fee is taken from output amount on each swap and can be withdrawn by `withdrawAddr`.
contract ERCS20 is Ownable, ReentrancyGuard, IERCS20, ERC20 {
    /// @notice Tracked token reserve used by pricing formula (token side of the pool).
    uint256 public ercs20Amount;

    /// @notice Initial quote-side seed amount configured at deployment (USDC-chain native asset).
    uint256 public usdcSeedAmount;
    /// @notice Tracked quote reserve used by pricing formula (USDC-chain native asset side).
    uint256 public usdAmount;

    /// @notice Address allowed to withdraw accumulated protocol fees.
    address public withdrawAddr;
    
    /// @param _name ERC20 token name.
    /// @param _symbol ERC20 token symbol.
    /// @param totalSupply Initial token supply minted to this contract.
    /// @param _usdcAmount Initial quote-side reserve used as pricing seed.
    /// @param index External index emitted in `PairCreated` for factory-level tracking.
    constructor(string memory _name, string memory _symbol, uint256 totalSupply, uint256 _usdcAmount, uint256 index) ERC20(_name, _symbol) {
        ercs20Amount = totalSupply;
        
        usdcSeedAmount = _usdcAmount;
        usdAmount = _usdcAmount;

        _mint(address(this), totalSupply);

        emit PairCreated(address(this), address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF), address(this), index);
        emit Sync(uint112(totalSupply), uint112(_usdcAmount));
    }

    /// @notice Sets the fee-withdrawal address.
    /// @dev Owner-only; zero address is not allowed.
    /// @param _withdrawAddr Address authorized to call `withdrawFee`.
    function setWithdrawAddr(address _withdrawAddr) external onlyOwner {
        require(_withdrawAddr != address(0), "ERCS20: WITHDRAW_ADDR_ERROR");
        withdrawAddr = _withdrawAddr;
    }

    /// @dev
    /// Overrides ERC20 transfer hook to handle sell behavior:
    /// when tokens are transferred to this contract, it treats the transfer as a sell swap
    /// and sends quote-asset output to the seller.
    function _transfer(address from, address to, uint256 amount) internal virtual override nonReentrant {

        super._transfer(from, to, amount);

        if(to == address(this)) {
            (uint256 amountOut, uint256 fee) = getAmountOut(amount, false);

            ercs20Amount += amount;
            usdAmount -= (amountOut+fee);

            emit Sync(uint112(ercs20Amount), uint112(usdAmount));
            emit Swap(from, amount, 0, 0, amountOut, from);

            TransferHelper.safeTransferETH(from, amountOut);
        }
    }

    /// @notice Returns the current tracked reserves used for swap pricing.
    /// @return tokenReserve Current token reserve (`ercs20Amount`).
    /// @return quoteReserve Current quote reserve (`usdAmount`).
    function getReserves() external view virtual override returns(uint256, uint256) {
        return (ercs20Amount, usdAmount);
    }

    /// @notice Calculates output amount and fee for a buy or sell.
    /// @param amount Input amount (quote asset for buy, token amount for sell).
    /// @param isBuy True for buy quote (quote -> token), false for sell quote (token -> quote).
    /// @return amountOut Net output amount after fee.
    /// @return fee Fee amount (1/500 ~= 0.2%) deducted from output.
    function getAmountOut(uint256 amount, bool isBuy) public virtual view returns (uint256, uint256) {
        uint256 amountOut;
        if (isBuy) {
            amountOut = (amount * ercs20Amount) / (usdAmount + amount);
        } else {
            amountOut = (amount * usdAmount) / (ercs20Amount + amount);
        }

        uint256 fee = amountOut/500;
        amountOut -= fee;

        return(amountOut, fee);
    }

    /// @dev `deadline == type(uint256).max` skips the time bound (used by `receive`).
    function _requireDeadline(uint256 deadline) private view {
        if (deadline != type(uint256).max) {
            require(block.timestamp <= deadline, "ERCS20: EXPIRED");
        }
    }

    /// @notice Buys tokens with quote asset on the USDC chain.
    /// @param amountInMin Minimum acceptable token output (slippage protection).
    /// @param deadline Latest valid block timestamp for this transaction (`type(uint256).max` = no check).
    function buy(uint256 amountInMin, uint256 deadline) public payable virtual override {
        _requireDeadline(deadline);
        require(msg.value > 0, "ERCS20: AMOUNT_IN_ERROR");

        (uint256 amountOut, uint256 fee) = getAmountOut(msg.value, true);

        require(amountOut >= amountInMin, "ERCS20: INSUFFICIENT_OUTPUT_AMOUNT");

        ercs20Amount -= (amountOut+fee);
        usdAmount += msg.value;

        emit Sync(uint112(ercs20Amount), uint112(usdAmount));
        emit Swap(_msgSender(), 0, msg.value, amountOut, 0, _msgSender());

        super._transfer(address(this), _msgSender(), amountOut);
    }

    /// @notice Convenience entrypoint to buy tokens by sending native quote asset directly.
    /// @dev No deadline enforcement; prefer `buy` with an explicit `deadline` for mempool safety.
    receive() external payable {
        buy(0, type(uint256).max);
    }

    /// @notice Sells tokens for quote asset by transferring tokens to this contract.
    /// @dev `_transfer` executes the pricing and native quote payout when `to == address(this)`.
    /// @param amountOut Token amount to sell.
    /// @param amountInMin Minimum acceptable quote asset received (slippage protection).
    /// @param deadline Latest valid block timestamp for this transaction (`type(uint256).max` = no check).
    function sell(uint256 amountOut, uint256 amountInMin, uint256 deadline) external virtual override {
        _requireDeadline(deadline);
        uint256 balance = _msgSender().balance;

        _transfer(_msgSender(), address(this), amountOut);

        uint256 amountIn = _msgSender().balance - balance;

        require(amountIn >= amountInMin, "ERCS20: INSUFFICIENT_OUTPUT_AMOUNT");
    }

    /// @notice Withdraws accumulated protocol fees (quote asset and token-side dust).
    /// @dev Callable only by `withdrawAddr`.
    function withdrawFee() external {
        require(withdrawAddr != address(0), "ERCS20: WITHDRAW_ADDR_ERROR");

        TransferHelper.safeTransferETH(withdrawAddr, (address(this).balance+usdcSeedAmount-usdAmount));

        TransferHelper.safeTransfer(address(this), withdrawAddr, (balanceOf(address(this))-ercs20Amount));
    }

    /// @notice Rescue function for non-ERCS20 tokens held by this contract.
    /// @dev Owner-only and explicitly disallows transferring this token itself.
    function safeTransfer(address token, address to, uint256 value) external onlyOwner {
        require(token != address(this), "ERCS20: TOKEN_ERROR");
        TransferHelper.safeTransfer(token, to, value);
    }

}