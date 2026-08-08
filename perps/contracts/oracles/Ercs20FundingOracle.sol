// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundingOracle} from "../interfaces/IFundingOracle.sol";

/// @dev Minimal ERCS20 surface used for spot mid = quote / token.
interface IErcs20Reserves {
    function getReserves() external view returns (uint256 tokenReserve, uint256 quoteReserve);
}

/// @title Ercs20FundingOracle
/// @notice Samples funding from perp last vs ERCS20 spot mid; caches a per-second unitless rate.
/// @dev
///  premiumX18 = (last − spot) / spot
///  rate8h     = clamp(premium, ±0.75%)
///  rate/sec   = |rate8h| / 8 hours
///  Positive rate ⇒ longs pay shorts. Only `exchange` may call `update`.
contract Ercs20FundingOracle is IFundingOracle {
    uint256 public constant BASE = 1e18;
    uint256 public constant EIGHT_HOURS = 8 hours;
    /// @notice Max absolute funding over an 8-hour window: 0.75%.
    uint256 public constant MAX_ABS_RATE_8H_X18 = (BASE * 75) / 10_000;

    address public immutable exchange;
    address public immutable ercs20;
    /// @notice Minimum seconds between successful samples (default 5 minutes).
    uint256 public immutable minSampleInterval;

    bool public isPositive;
    uint256 public ratePerSecondX18;
    uint256 public lastSampleAt;

    event FundingRateSampled(
        uint256 lastPriceX18, uint256 spotX18, int256 premiumX18, bool positive, uint256 ratePerSecondX18
    );

    error NotExchange();
    error ZeroAddress();
    error InvalidPrice();

    modifier onlyExchange() {
        if (msg.sender != exchange) revert NotExchange();
        _;
    }

    constructor(address exchange_, address ercs20_, uint256 minSampleInterval_) {
        if (exchange_ == address(0) || ercs20_ == address(0)) revert ZeroAddress();
        exchange = exchange_;
        ercs20 = ercs20_;
        minSampleInterval = minSampleInterval_ == 0 ? 5 minutes : minSampleInterval_;
    }

    /// @inheritdoc IFundingOracle
    function update(uint256 lastPriceX18) external onlyExchange returns (bool updated) {
        if (lastPriceX18 == 0) revert InvalidPrice();
        if (lastSampleAt != 0 && block.timestamp < lastSampleAt + minSampleInterval) {
            return false;
        }

        (uint256 tokenReserve, uint256 quoteReserve) = IErcs20Reserves(ercs20).getReserves();

        uint256 spotX18 = (quoteReserve * BASE) / tokenReserve;

        int256 premiumX18 = ((int256(lastPriceX18) - int256(spotX18)) * int256(BASE)) / int256(spotX18);

        int256 max8h = int256(MAX_ABS_RATE_8H_X18);
        if (premiumX18 > max8h) premiumX18 = max8h;
        else if (premiumX18 < -max8h) premiumX18 = -max8h;

        bool positive = premiumX18 >= 0;
        uint256 abs8h = positive ? uint256(premiumX18) : uint256(-premiumX18);
        uint256 ratePerSec = abs8h / EIGHT_HOURS;

        isPositive = positive;
        ratePerSecondX18 = ratePerSec;
        lastSampleAt = block.timestamp;

        emit FundingRateSampled(lastPriceX18, spotX18, premiumX18, positive, ratePerSec);
        return true;
    }

    /// @inheritdoc IFundingOracle
    function getFunding(uint256 timeDelta) external view returns (bool, uint256) {
        return (isPositive, ratePerSecondX18 * timeDelta);
    }
}
