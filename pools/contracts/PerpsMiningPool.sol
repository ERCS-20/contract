// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RewardBucket} from "./libraries/RewardBucket.sol";

interface IPerpsFeeVault {
    function claimFees(uint256 amount) external;
    function protocolFees() external view returns (uint256);
}

/// @title PerpsMiningPool
/// @notice Stake one ERCS20 (OBX) and mine native USDC fees held by the perps vault.
/// @dev This contract must be the vault's `claimFeeDAO`. Same split as the spot pool:
///      a claim pulls the user's gross share, pays half, and keeps half for `withdrawer`.
///      Nothing is pulled before a user claims. Mining is always enabled.
contract PerpsMiningPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakeToken;
    IPerpsFeeVault public immutable vault;

    address public operator;
    address public withdrawer;
    /// @notice Set when the pool is abandoned. Stake, unstake, and claim stop. Users call `withdrawStake`.
    bool public paused;
    /// @notice System half already pulled into this contract.
    uint256 public systemNative;

    /// @notice Sentinel for native USDC. There is no ERC20 contract for this reward.
    address public constant REWARD_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    string public constant REWARD_SYMBOL = "USDC";
    string public constant REWARD_NAME = "USD Coin";
    uint8 public constant REWARD_DECIMALS = 18;

    RewardBucket.Bucket internal _bucket;

    event PoolCreated(
        address indexed pool,
        address indexed rewardToken,
        string symbol,
        string name,
        uint8 decimals,
        uint256 vaultFees
    );
    event OperatorSet(address indexed operator);
    event WithdrawerSet(address indexed withdrawer);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Staked(address indexed user, uint256 amount, uint256 userHalf);
    event Unstaked(address indexed user, uint256 amount, uint256 userHalf);
    event Claimed(address indexed user, uint256 userHalf);
    event StakeWithdrawn(address indexed user, uint256 amount);
    event SystemWithdrawn(address indexed to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotOperator();
    error NotWithdrawer();
    error PayFailed();
    error StakeToken();
    error IsPaused();
    error NotPaused();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyWithdrawer() {
        if (msg.sender != withdrawer) revert NotWithdrawer();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert NotPaused();
        _;
    }

    constructor(address stakeToken_, address vault_) Ownable(msg.sender) {
        if (stakeToken_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        stakeToken = IERC20(stakeToken_);
        vault = IPerpsFeeVault(vault_);
        _bucket.enabled = true;
        emit PoolCreated(address(this), REWARD_TOKEN, REWARD_SYMBOL, REWARD_NAME, REWARD_DECIMALS, vault.protocolFees());
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setWithdrawer(address withdrawer_) external onlyOwner {
        if (withdrawer_ == address(0)) revert ZeroAddress();
        withdrawer = withdrawer_;
        emit WithdrawerSet(withdrawer_);
    }

    function pause() external onlyOperator {
        if (paused) revert IsPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOperator {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    function totalStaked() external view returns (uint256) {
        return _bucket.totalStaked;
    }

    function stakedOf(address user) external view returns (uint256) {
        return _bucket.users[user].staked;
    }

    /// @notice Full perps vault fee balance.
    function rewardBalance() external view returns (uint256) {
        return vault.protocolFees();
    }

    /// @notice User-half rewards currently claimable.
    function earned(address user) external view returns (uint256) {
        return RewardBucket.earned(_bucket, user, vault.protocolFees());
    }

    function stake(uint256 amount) external whenNotPaused nonReentrant {
        uint256 userHalf = RewardBucket.stake(_bucket, msg.sender, amount, vault.protocolFees());
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        _payReward(userHalf);
        emit Staked(msg.sender, amount, userHalf);
    }

    function unstake(uint256 amount) external whenNotPaused nonReentrant {
        uint256 userHalf = RewardBucket.unstake(_bucket, msg.sender, amount, vault.protocolFees());
        stakeToken.safeTransfer(msg.sender, amount);
        _payReward(userHalf);
        emit Unstaked(msg.sender, amount, userHalf);
    }

    function claim() external whenNotPaused nonReentrant {
        _payReward(RewardBucket.harvest(_bucket, msg.sender, vault.protocolFees()));
    }

    /// @notice Return this user's staked OBX after the pool is paused.
    /// @dev Zeroes only that user's record so it cannot be taken twice. Rewards and bucket totals stay untouched.
    function withdrawStake() external whenPaused nonReentrant {
        uint256 amount = RewardBucket.withdrawStake(_bucket, msg.sender);
        if (amount != 0) stakeToken.safeTransfer(msg.sender, amount);
        emit StakeWithdrawn(msg.sender, amount);
    }

    /// @notice Withdraw system half already left in this contract by user claims.
    function withdrawSystem(uint256 amount) external onlyWithdrawer nonReentrant {
        systemNative -= amount;
        _payNative(msg.sender, amount);
        emit SystemWithdrawn(msg.sender, amount);
    }

    /// @notice Send an ERC20 that was transferred here by mistake. Cannot take the stake token.
    function rescue(address token, address to, uint256 amount) external onlyWithdrawer nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(stakeToken)) revert StakeToken();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @dev Accept native USDC forwarded by the vault.
    receive() external payable {
        if (msg.sender != address(vault)) revert PayFailed();
    }

    function _payReward(uint256 userHalf) private {
        if (userHalf == 0) return;
        vault.claimFees(userHalf * 2);
        systemNative += userHalf;
        _payNative(msg.sender, userHalf);
        emit Claimed(msg.sender, userHalf);
    }

    function _payNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayFailed();
    }
}
