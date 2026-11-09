// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RewardBucket} from "./libraries/RewardBucket.sol";

interface ISpotFeeVault {
    function claimFees(address token, uint256 amount) external;
    function tokenFees(address token) external view returns (uint256);
    function wusdc() external view returns (address);
}

/// @title SpotMiningPool
/// @notice Stake one ERCS20 (OBX) per reward token and mine that token's spot vault fees.
/// @dev This contract must be the vault's `claimFeeDAO`. Fees stay in the vault until a user
///      claims. A claim pulls that user's gross share, pays the user half, and keeps half for
///      `withdrawer`. WUSDC fees arrive as native USDC. Mining can be toggled per reward token:
///      while off, new fees are not credited, and rewards already credited stay claimable.
contract SpotMiningPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakeToken;
    ISpotFeeVault public immutable vault;
    /// @notice WUSDC reward claims are paid out as native USDC.
    address public immutable wusdc;

    address public operator;
    address public withdrawer;

    /// @notice System half already pulled into this contract, keyed by reward token. WUSDC uses `systemNative`.
    mapping(address => uint256) public systemReserve;
    uint256 public systemNative;

    mapping(address => RewardBucket.Bucket) internal _buckets;

    event OperatorSet(address indexed operator);
    event WithdrawerSet(address indexed withdrawer);
    event MiningEnabledSet(address indexed rewardToken, bool enabled);
    event Staked(address indexed user, address indexed rewardToken, uint256 amount, uint256 userHalf);
    event Unstaked(address indexed user, address indexed rewardToken, uint256 amount, uint256 userHalf);
    event Claimed(address indexed user, address indexed rewardToken, uint256 userHalf);
    event SystemWithdrawn(address indexed to, address indexed rewardToken, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotOperator();
    error NotWithdrawer();
    error PayFailed();
    error StakeToken();
    error ExcessRescue();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyWithdrawer() {
        if (msg.sender != withdrawer) revert NotWithdrawer();
        _;
    }

    constructor(address stakeToken_, address vault_) Ownable(msg.sender) {
        if (stakeToken_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        stakeToken = IERC20(stakeToken_);
        vault = ISpotFeeVault(vault_);
        wusdc = vault.wusdc();
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

    /// @notice Turn mining on or off for `rewardToken`. Staking is allowed either way.
    /// @dev Enabling credits fees already sitting in the vault to current stakers.
    function setMiningEnabled(address rewardToken, bool enabled) external onlyOperator {
        RewardBucket.setEnabled(_buckets[rewardToken], enabled, vault.tokenFees(rewardToken));
        emit MiningEnabledSet(rewardToken, enabled);
    }

    function miningEnabled(address rewardToken) external view returns (bool) {
        return _buckets[rewardToken].enabled;
    }

    function totalStaked(address rewardToken) external view returns (uint256) {
        return _buckets[rewardToken].totalStaked;
    }

    function stakedOf(address user, address rewardToken) external view returns (uint256) {
        return _buckets[rewardToken].users[user].staked;
    }

    /// @notice Full vault fee balance for `rewardToken`, or 0 while mining is off.
    function rewardBalance(address rewardToken) external view returns (uint256) {
        if (!_buckets[rewardToken].enabled) return 0;
        return vault.tokenFees(rewardToken);
    }

    /// @notice User-half rewards currently claimable. Still readable while mining is off.
    function earned(address user, address rewardToken) external view returns (uint256) {
        return RewardBucket.earned(_buckets[rewardToken], user, vault.tokenFees(rewardToken));
    }

    function stake(address rewardToken, uint256 amount) external nonReentrant {
        uint256 userHalf = RewardBucket.stake(_buckets[rewardToken], msg.sender, amount, vault.tokenFees(rewardToken));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        _payReward(rewardToken, userHalf);
        emit Staked(msg.sender, rewardToken, amount, userHalf);
    }

    function unstake(address rewardToken, uint256 amount) external nonReentrant {
        uint256 userHalf = RewardBucket.unstake(_buckets[rewardToken], msg.sender, amount, vault.tokenFees(rewardToken));
        stakeToken.safeTransfer(msg.sender, amount);
        _payReward(rewardToken, userHalf);
        emit Unstaked(msg.sender, rewardToken, amount, userHalf);
    }

    function claim(address rewardToken) external nonReentrant {
        uint256 userHalf = RewardBucket.harvest(_buckets[rewardToken], msg.sender, vault.tokenFees(rewardToken));
        _payReward(rewardToken, userHalf);
    }

    /// @notice Withdraw system half already left in this contract by user claims.
    /// @dev Pass `wusdc` to withdraw the native USDC collected from WUSDC fees.
    function withdrawSystem(address rewardToken, uint256 amount) external onlyWithdrawer nonReentrant {
        if (wusdc != address(0) && rewardToken == wusdc) {
            systemNative -= amount;
            _payNative(msg.sender, amount);
        } else {
            systemReserve[rewardToken] -= amount;
            IERC20(rewardToken).safeTransfer(msg.sender, amount);
        }
        emit SystemWithdrawn(msg.sender, rewardToken, amount);
    }

    /// @notice Send an ERC20 that was transferred here by mistake.
    /// @dev Cannot take the stake token, or the system half already tracked in `systemReserve`.
    function rescue(address token, address to, uint256 amount) external onlyWithdrawer nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(stakeToken)) revert StakeToken();
        uint256 surplus = IERC20(token).balanceOf(address(this)) - systemReserve[token];
        if (amount > surplus) revert ExcessRescue();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @dev Accept native USDC forwarded by the vault when WUSDC fees are claimed.
    receive() external payable {
        if (msg.sender != address(vault)) revert PayFailed();
    }

    function _payReward(address rewardToken, uint256 userHalf) private {
        if (userHalf == 0) return;
        _pullAndPay(rewardToken, userHalf);
        emit Claimed(msg.sender, rewardToken, userHalf);
    }

    function _pullAndPay(address rewardToken, uint256 userHalf) private {
        vault.claimFees(rewardToken, userHalf * 2);
        if (wusdc != address(0) && rewardToken == wusdc) {
            systemNative += userHalf;
            _payNative(msg.sender, userHalf);
        } else {
            systemReserve[rewardToken] += userHalf;
            IERC20(rewardToken).safeTransfer(msg.sender, userHalf);
        }
    }

    function _payNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayFailed();
    }
}
