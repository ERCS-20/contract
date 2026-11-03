// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IFundingOracle} from "../interfaces/IFundingOracle.sol";
import {IErcs20Reserves} from "../interfaces/IErcs20Reserves.sol";

/// @title Ercs20FundingOracle
/// @notice Multi-market funding oracle: last vs ERCS20 spot mid, per-market cached rate.
/// @dev
///  premiumX18 = (last − spot) / spot
///  rate1h     = clamp(premium, ±0.75% / 8)
///  rate/sec   = |rate1h| / 1 hour
///  Spot `ercs20` is passed by PerpsExchange each `update` (not stored here).
contract Ercs20FundingOracle is Ownable, IFundingOracle {
    uint256 public constant BASE = 1e18;
    uint256 public constant ONE_HOUR = 1 hours;
    /// @notice Max absolute funding over a 1-hour window: 0.75% / 8.
    uint256 public constant MAX_ABS_RATE_1H_X18 = ((BASE * 75) / 10_000) / 8;
    uint256 public constant MIN_SAMPLE_INTERVAL = 1 hours;

    struct MarketState {
        bool isPositive;
        uint256 ratePerSecondX18;
        uint256 lastSampleAt;
    }

    address public immutable exchange;
    /// @notice Minimum seconds between successful samples (default 1 hour).
    uint256 public immutable minSampleInterval;

    mapping(uint256 => MarketState) public markets;

    event FundingRateSampled(uint256 indexed marketId, bool positive, uint256 ratePerSecondX18, uint256 timestamp);

    error NotExchange();
    error ZeroAddress();
    error InvalidPrice();

    modifier onlyExchange() {
        if (msg.sender != exchange) revert NotExchange();
        _;
    }

    constructor(address exchange_) Ownable(msg.sender) {
        if (exchange_ == address(0)) revert ZeroAddress();
        exchange = exchange_;
        minSampleInterval = MIN_SAMPLE_INTERVAL;
    }

    /// @inheritdoc IFundingOracle
    function update(uint256 marketId, uint256 lastPriceX18, address ercs20)
        external
        onlyExchange
        returns (bool updated)
    {
        MarketState storage m = markets[marketId];
        if (m.lastSampleAt != 0 && block.timestamp < m.lastSampleAt + minSampleInterval) {
            return false;
        }

        (uint256 tokenReserve, uint256 quoteReserve) = IErcs20Reserves(ercs20).getReserves();
        uint256 spotX18 = (quoteReserve * BASE) / tokenReserve;

        int256 premiumX18 = ((int256(lastPriceX18) - int256(spotX18)) * int256(BASE)) / int256(spotX18);

        int256 max1h = int256(MAX_ABS_RATE_1H_X18);
        if (premiumX18 > max1h) premiumX18 = max1h;
        else if (premiumX18 < -max1h) premiumX18 = -max1h;

        bool positive = premiumX18 >= 0;
        uint256 abs1h = positive ? uint256(premiumX18) : uint256(-premiumX18);
        uint256 ratePerSec = abs1h / ONE_HOUR;

        m.isPositive = positive;
        m.ratePerSecondX18 = ratePerSec;
        m.lastSampleAt = block.timestamp;

        emit FundingRateSampled(marketId, positive, ratePerSec, block.timestamp);
        return true;
    }

    /// @inheritdoc IFundingOracle
    function getFunding(uint256 marketId, uint256 timeDelta) external view returns (bool, uint256) {
        MarketState storage m = markets[marketId];
        return (m.isPositive, m.ratePerSecondX18 * timeDelta);
    }
}
