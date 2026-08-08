// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IFundingOracle} from "../interfaces/IFundingOracle.sol";
import {IErcs20Reserves} from "../interfaces/IErcs20Reserves.sol";

/// @title Ercs20FundingOracle
/// @notice Multi-market funding oracle: last vs ERCS20 spot mid, per-market cached rate.
/// @dev
///  premiumX18 = (last − spot) / spot
///  rate8h     = clamp(premium, ±0.75%)
///  rate/sec   = |rate8h| / 8 hours
///  Bind spot via `setErcs20` (`onlyFactory`). Only `exchange` may `update`.
contract Ercs20FundingOracle is Ownable, IFundingOracle {
    uint256 public constant BASE = 1e18;
    uint256 public constant EIGHT_HOURS = 8 hours;
    /// @notice Max absolute funding over an 8-hour window: 0.75%.
    uint256 public constant MAX_ABS_RATE_8H_X18 = (BASE * 75) / 10_000;

    struct MarketState {
        address ercs20;
        bool isPositive;
        uint256 ratePerSecondX18;
        uint256 lastSampleAt;
    }

    address public immutable exchange;
    address public factory;
    /// @notice Minimum seconds between successful samples (default 5 minutes).
    uint256 public immutable minSampleInterval;

    mapping(uint256 => MarketState) public markets;

    event FactorySet(address indexed factory);
    event Ercs20Set(uint256 indexed marketId, address indexed ercs20);
    event FundingRateSampled(
        uint256 indexed marketId,
        uint256 lastPriceX18,
        uint256 spotX18,
        int256 premiumX18,
        bool positive,
        uint256 ratePerSecondX18
    );

    error NotExchange();
    error NotFactory();
    error ZeroAddress();
    error InvalidPrice();
    error MarketNotBound();

    modifier onlyExchange() {
        if (msg.sender != exchange) revert NotExchange();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(address exchange_, uint256 minSampleInterval_) Ownable(msg.sender) {
        if (exchange_ == address(0)) revert ZeroAddress();
        exchange = exchange_;
        minSampleInterval = minSampleInterval_ == 0 ? 5 minutes : minSampleInterval_;
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @notice Bind or update the ERCS20 spot pool for a perps `marketId`.
    function setErcs20(uint256 marketId, address ercs20_) external onlyFactory {
        if (ercs20_ == address(0)) revert ZeroAddress();
        markets[marketId].ercs20 = ercs20_;
        emit Ercs20Set(marketId, ercs20_);
    }

    /// @inheritdoc IFundingOracle
    function update(uint256 marketId, uint256 lastPriceX18) external onlyExchange returns (bool updated) {
        if (lastPriceX18 == 0) revert InvalidPrice();

        MarketState storage m = markets[marketId];
        if (m.ercs20 == address(0)) revert MarketNotBound();
        if (m.lastSampleAt != 0 && block.timestamp < m.lastSampleAt + minSampleInterval) {
            return false;
        }

        (uint256 tokenReserve, uint256 quoteReserve) = IErcs20Reserves(m.ercs20).getReserves();
        uint256 spotX18 = (quoteReserve * BASE) / tokenReserve;

        int256 premiumX18 = ((int256(lastPriceX18) - int256(spotX18)) * int256(BASE)) / int256(spotX18);

        int256 max8h = int256(MAX_ABS_RATE_8H_X18);
        if (premiumX18 > max8h) premiumX18 = max8h;
        else if (premiumX18 < -max8h) premiumX18 = -max8h;

        bool positive = premiumX18 >= 0;
        uint256 abs8h = positive ? uint256(premiumX18) : uint256(-premiumX18);
        uint256 ratePerSec = abs8h / EIGHT_HOURS;

        m.isPositive = positive;
        m.ratePerSecondX18 = ratePerSec;
        m.lastSampleAt = block.timestamp;

        emit FundingRateSampled(marketId, lastPriceX18, spotX18, premiumX18, positive, ratePerSec);
        return true;
    }

    /// @inheritdoc IFundingOracle
    function getFunding(uint256 marketId, uint256 timeDelta) external view returns (bool, uint256) {
        MarketState storage m = markets[marketId];
        return (m.isPositive, m.ratePerSecondX18 * timeDelta);
    }
}
