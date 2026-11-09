// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-reward-token stake accounting. The caller pays the returned user-half immediately.
/// @dev User half is `vaultIncrease / 2`, credited to current stakers. The other half stays
///      in the vault until this user is paid, then the caller pulls both halves.
library RewardBucket {
    uint256 internal constant ONE = 1e18;

    struct UserInfo {
        uint256 staked;
        uint256 debt;
    }

    struct Bucket {
        bool enabled;
        uint256 accPerShare;
        uint256 totalStaked;
        /// @notice User-half already assigned to stakers and not yet paid. Still sitting in the vault.
        uint256 allocated;
        mapping(address => UserInfo) users;
    }

    function setEnabled(Bucket storage b, bool enabled, uint256 vaultFees) internal {
        if (!enabled) {
            // Book fees already visible while mining was on, then stop new credits.
            sync(b, vaultFees);
            b.enabled = false;
            return;
        }
        b.enabled = true;
        sync(b, vaultFees);
    }

    /// @notice Fold newly observed vault fees into this bucket. Disabled buckets ignore new fees.
    function sync(Bucket storage b, uint256 vaultFees) internal {
        if (!b.enabled) return;
        if (b.totalStaked == 0) return;
        uint256 known = b.allocated * 2;
        if (vaultFees <= known) return;
        uint256 userHalf = (vaultFees - known) / 2;
        if (userHalf == 0) return;
        _credit(b, userHalf);
    }

    /// @notice Add `amount` and return the user-half that must be paid now.
    /// @dev Fees that arrived while nobody was staked stay unaccounted and are paid on a later action.
    function stake(Bucket storage b, address account, uint256 amount, uint256 vaultFees) internal returns (uint256 payout) {
        sync(b, vaultFees);
        payout = _take(b, account);
        UserInfo storage u = b.users[account];
        u.staked += amount;
        b.totalStaked += amount;
        u.debt = u.staked * b.accPerShare / ONE;
    }

    /// @notice Remove `amount` and return the user-half that must be paid now.
    function unstake(Bucket storage b, address account, uint256 amount, uint256 vaultFees) internal returns (uint256 payout) {
        sync(b, vaultFees);
        payout = _take(b, account);
        UserInfo storage u = b.users[account];
        u.staked -= amount;
        b.totalStaked -= amount;
        u.debt = u.staked * b.accPerShare / ONE;
    }

    /// @notice Return the user-half that must be paid now, without changing the stake.
    function harvest(Bucket storage b, address account, uint256 vaultFees) internal returns (uint256 payout) {
        sync(b, vaultFees);
        payout = _take(b, account);
    }

    function earned(Bucket storage b, address account, uint256 vaultFees) internal view returns (uint256) {
        UserInfo storage u = b.users[account];
        uint256 acc = b.accPerShare;
        if (b.enabled && b.totalStaked != 0) {
            uint256 known = b.allocated * 2;
            if (vaultFees > known) {
                acc += ((vaultFees - known) / 2) * ONE / b.totalStaked;
            }
        }
        return u.staked * acc / ONE - u.debt;
    }

    function _credit(Bucket storage b, uint256 userHalf) private {
        uint256 share = userHalf * ONE / b.totalStaked;
        if (share == 0) return;
        b.accPerShare += share;
        // Rounding dust stays out of `allocated`, so the next sync picks it up with new fees.
        b.allocated += share * b.totalStaked / ONE;
    }

    /// @dev Move this user's unpaid user-half out of `allocated` and bring `debt` up to date.
    function _take(Bucket storage b, address account) private returns (uint256 delta) {
        UserInfo storage u = b.users[account];
        uint256 accrued = u.staked * b.accPerShare / ONE;
        delta = accrued - u.debt;
        u.debt = accrued;
        if (delta != 0) b.allocated -= delta;
    }
}
