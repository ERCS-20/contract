// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPerpsOracle} from "../interfaces/IPerpsOracle.sol";
import {IOracleSampler} from "../interfaces/IOracleSampler.sol";
import {IErcs20Reserves} from "../interfaces/IErcs20Reserves.sol";

/// @title Ercs20TwapOracle
/// @notice Multi-market mark price = TWAP of each market's ERCS20 spot mid over `window`.
/// @dev Samples via `update(marketId, ercs20)` from PerpsExchange. Spot address is not stored here.
contract Ercs20TwapOracle is Ownable, IPerpsOracle, IOracleSampler {
    uint256 public constant BASE = 1e18;
    uint256 internal constant CARDINALITY = 32;
    uint256 public constant WINDOW = 15 minutes;
    uint256 public constant MIN_SAMPLE_INTERVAL = 30;

    struct Observation {
        uint32 timestamp;
        uint224 priceCumulative;
    }

    struct MarketState {
        uint256 priceCumulative;
        uint256 lastMidX18;
        uint256 lastSampleAt;
        uint8 observationIndex;
        uint8 observationCount;
        Observation[CARDINALITY] observations;
    }

    address public immutable exchange;
    /// @notice TWAP window (default 15 minutes).
    uint256 public immutable window;
    /// @notice Minimum seconds between samples (default 30).
    uint256 public immutable minSampleInterval;

    mapping(uint256 => MarketState) internal _markets;

    event MarkSampled(
        uint256 indexed marketId, uint256 spotX18, uint256 priceCumulative, uint256 timestamp
    );

    error NotExchange();
    error ZeroAddress();
    error NotReady();

    modifier onlyExchange() {
        if (msg.sender != exchange) revert NotExchange();
        _;
    }

    constructor(address exchange_) Ownable(msg.sender) {
        if (exchange_ == address(0)) revert ZeroAddress();
        exchange = exchange_;
        window = WINDOW;
        minSampleInterval = MIN_SAMPLE_INTERVAL;
    }

    function lastMidX18(uint256 marketId) external view returns (uint256) {
        return _markets[marketId].lastMidX18;
    }

    function lastSampleAt(uint256 marketId) external view returns (uint256) {
        return _markets[marketId].lastSampleAt;
    }

    /// @inheritdoc IOracleSampler
    function update(uint256 marketId, address ercs20) external onlyExchange returns (bool updated) {
        if (ercs20 == address(0)) revert ZeroAddress();
        MarketState storage m = _markets[marketId];
        if (m.lastSampleAt != 0 && block.timestamp < m.lastSampleAt + minSampleInterval) {
            return false;
        }

        uint256 spotX18 = _spotMid(ercs20);
        uint32 now32 = uint32(block.timestamp);

        if (m.lastSampleAt != 0) {
            uint256 dt = block.timestamp - m.lastSampleAt;
            m.priceCumulative += m.lastMidX18 * dt;
        }

        m.lastMidX18 = spotX18;
        m.lastSampleAt = block.timestamp;
        _writeObservation(m, now32, uint224(m.priceCumulative));

        emit MarkSampled(marketId, spotX18, m.priceCumulative, block.timestamp);
        return true;
    }

    /// @inheritdoc IPerpsOracle
    function getPrice(uint256 marketId) external view returns (uint256 priceX18) {
        MarketState storage m = _markets[marketId];
        if (m.observationCount == 0 || m.lastSampleAt == 0) revert NotReady();

        uint256 nowTs = block.timestamp;
        uint256 virtCum = m.priceCumulative + m.lastMidX18 * (nowTs - m.lastSampleAt);

        uint256 target = nowTs > window ? nowTs - window : 0;
        (uint32 obsTime, uint224 obsCum) = _observe(m, target);
        uint256 dt = nowTs - uint256(obsTime);
        if (dt == 0) return m.lastMidX18;
        return (virtCum - uint256(obsCum)) / dt;
    }

    function _spotMid(address ercs20_) private view returns (uint256) {
        (uint256 tokenReserve, uint256 quoteReserve) = IErcs20Reserves(ercs20_).getReserves();
        return (quoteReserve * BASE) / tokenReserve;
    }

    function _writeObservation(MarketState storage m, uint32 timestamp, uint224 cumulative) private {
        uint8 index = m.observationIndex;
        m.observations[index] = Observation({timestamp: timestamp, priceCumulative: cumulative});
        unchecked {
            m.observationIndex = uint8((uint256(index) + 1) % CARDINALITY);
            if (m.observationCount < CARDINALITY) {
                ++m.observationCount;
            }
        }
    }

    function _observe(MarketState storage m, uint256 target) private view returns (uint32, uint224) {
        uint8 count = m.observationCount;
        uint8 index = m.observationIndex;

        for (uint256 i; i < count;) {
            uint8 j;
            unchecked {
                j = uint8((uint256(index) + CARDINALITY - 1 - i) % CARDINALITY);
            }
            Observation memory obs = m.observations[j];
            if (uint256(obs.timestamp) <= target) {
                return (obs.timestamp, obs.priceCumulative);
            }
            unchecked {
                ++i;
            }
        }

        uint8 oldest = m.observationCount == CARDINALITY ? m.observationIndex : 0;
        Observation memory o = m.observations[oldest];
        return (o.timestamp, o.priceCumulative);
    }
}
