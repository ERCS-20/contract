// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PerpsTypes} from "./libraries/PerpsTypes.sol";

interface IERCS20Factory {
    function ercs20s(address token) external view returns (bool);
}

interface IERCS20 {
    function owner() external view returns (address);
    function usdcSeedAmount() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IPerpsExchange {
    function createMarket(uint256 marketId, uint256 adlEquityThreshold, uint256 minCollateralX18) external;
    function seedInsuranceMargin(uint256 marketId, address account) external payable;
}

interface IErcs20Binder {
    function setErcs20(uint256 marketId, address ercs20) external;
}

/// @title PerpsPairFactory
/// @notice Creates perps markets for ERCS20 underlyings and binds TWAP / funding oracles.
/// @dev
/// - Public `create(baseToken)` for ERCS20 token owners (verified via ERCS20Factory).
/// - pairDAO-only `create(baseToken, adlEquityThreshold, minCollateralX18)` with custom params.
/// - Default ADL threshold is `fee / 2` (half of listing-fee insurance seed).
/// - Listing `fee` is forwarded to PerpsExchange.seedInsuranceMargin for `insuranceAccount`.
/// - This contract must be `factory` on PerpsExchange, Ercs20TwapOracle, and Ercs20FundingOracle.
contract PerpsPairFactory is Ownable {
    IERCS20Factory public immutable ercs20Factory;
    IPerpsExchange public immutable exchange;
    IErcs20Binder public immutable twapOracle;
    IErcs20Binder public immutable fundingOracle;

    address public pairDAO;
    /// @notice Cold liquidator account that receives listing-fee insurance margin.
    address public insuranceAccount;
    /// @notice Number of markets created; next id is the current value (ids start at 0).
    uint256 public marketCount;
    /// @notice ERCS20 => perps marketId.
    mapping(address => uint256) public marketIdOf;
    /// @notice marketId => ERCS20
    mapping(uint256 => address) public ercs20Of;
    /// @notice Whether an ERCS20 already has a perps market (needed because marketId 0 is valid).
    mapping(address => bool) public isMarket;

    uint256 public defaultMinCollateralX18;
    /// @notice Native listing fee required by `create` (`msg.value` must equal `fee`). Default 1000e18.
    uint256 public fee;

    /// @notice 0.5% liquidation fee (absolute, 1e18 = 100%).
    uint256 public constant LIQUIDATION_FEE_X18 = 0.005e18;
    /// @notice 0.05% taker fee (matches PerpsExchange TAKER_FEE 5/10_000).
    uint256 public constant TAKER_FEE_X18 = 0.0005e18;
    /// @notice Default min collateralization: 100% + liq fee + taker fee = 100.55%.
    uint256 public constant DEFAULT_MIN_COLLATERAL_X18 = PerpsTypes.BASE + LIQUIDATION_FEE_X18 + TAKER_FEE_X18;
    uint256 public constant DEFAULT_FEE = 1000e18;

    event PerpsMarketCreated(
        address indexed ercs20, uint256 indexed marketId, uint256 adlEquityThreshold, uint256 minCollateralX18
    );
    event PairDAOSet(address indexed pairDAO);
    event PairDAORemoved(address indexed pairDAO);
    event InsuranceAccountSet(address indexed insuranceAccount);
    event DefaultMinCollateralSet(uint256 minCollateralX18);
    event FeeSet(uint256 fee);

    uint256 private constant OPENING_PRICE_SCALE = 1e18;
    uint256 private constant MAX_OPENING_PRICE = 1e16;

    error NotERCS20();
    error NotTokenOwner();
    error NotPairDAO();
    error MarketAlreadyExists();
    error InvalidAddress();
    error InvalidOpeningPrice();
    error OpeningPriceDecimalsTooHigh();
    error OpeningPriceTooHigh();
    error InvalidMinCollateral();
    error IncorrectFee();
    error InsuranceAccountNotSet();

    modifier onlyPairDAO() {
        if (msg.sender != pairDAO) revert NotPairDAO();
        _;
    }

    constructor(address ercs20Factory_, address exchange_, address twapOracle_, address fundingOracle_)
        Ownable(msg.sender)
    {
        if (ercs20Factory_ == address(0) || exchange_ == address(0) || twapOracle_ == address(0) || fundingOracle_ == address(0)) {
            revert InvalidAddress();
        }

        ercs20Factory = IERCS20Factory(ercs20Factory_);
        exchange = IPerpsExchange(exchange_);
        twapOracle = IErcs20Binder(twapOracle_);
        fundingOracle = IErcs20Binder(fundingOracle_);
        defaultMinCollateralX18 = DEFAULT_MIN_COLLATERAL_X18;
        fee = DEFAULT_FEE;
    }

    function setPairDAO(address pairDAO_) external onlyOwner {
        if (pairDAO_ == address(0)) revert InvalidAddress();
        pairDAO = pairDAO_;
        emit PairDAOSet(pairDAO_);
    }

    function removePairDAO(address) external onlyOwner {
        address previous = pairDAO;
        pairDAO = address(0);
        emit PairDAORemoved(previous);
    }

    function setInsuranceAccount(address insuranceAccount_) external onlyOwner {
        if (insuranceAccount_ == address(0)) revert InvalidAddress();
        insuranceAccount = insuranceAccount_;
        emit InsuranceAccountSet(insuranceAccount_);
    }

    function setDefaultMinCollateral(uint256 minCollateralX18_) external onlyOwner {
        if (minCollateralX18_ < PerpsTypes.BASE) revert InvalidMinCollateral();
        defaultMinCollateralX18 = minCollateralX18_;
        emit DefaultMinCollateralSet(minCollateralX18_);
    }

    /// @notice Sets the native listing fee for `create`.
    function setFee(uint256 fee_) external onlyOwner {
        fee = fee_;
        emit FeeSet(fee_);
    }

    /// @notice Creates a perps market for an ERCS20 owned by the caller.
    /// @dev ADL threshold defaults to `fee / 2`.
    function create(address baseToken) external payable {
        if (msg.value != fee) revert IncorrectFee();
        if (baseToken == address(0)) revert InvalidAddress();
        if (!ercs20Factory.ercs20s(baseToken)) revert NotERCS20();
        if (IERCS20(baseToken).owner() != msg.sender) revert NotTokenOwner();
        _validateErcs20OpeningPrice(baseToken);
        _createMarket(baseToken, fee / 2, defaultMinCollateralX18);
    }

    /// @notice Creates a perps market with custom risk params. DAO only.
    function create(address baseToken, uint256 adlEquityThreshold, uint256 minCollateralX18)
        external
        payable
        onlyPairDAO
    {
        if (msg.value < fee) revert IncorrectFee();
        if (baseToken == address(0)) revert InvalidAddress();
        if (minCollateralX18 < PerpsTypes.BASE) revert InvalidMinCollateral();
        _createMarket(baseToken, adlEquityThreshold, minCollateralX18);
    }

    function _createMarket(address baseToken, uint256 adlEquityThreshold, uint256 minCollateralX18) internal {
        if (isMarket[baseToken]) revert MarketAlreadyExists();
        address insurance = insuranceAccount;
        if (fee > 0 && insurance == address(0)) revert InsuranceAccountNotSet();

        uint256 marketId = marketCount++;

        twapOracle.setErcs20(marketId, baseToken);
        fundingOracle.setErcs20(marketId, baseToken);
        exchange.createMarket(marketId, adlEquityThreshold, minCollateralX18);

        if (fee > 0) {
            exchange.seedInsuranceMargin{value: fee}(marketId, insurance);
        }

        isMarket[baseToken] = true;
        marketIdOf[baseToken] = marketId;
        ercs20Of[marketId] = baseToken;

        emit PerpsMarketCreated(baseToken, marketId, adlEquityThreshold, minCollateralX18);
    }

    /// @dev Opening price = `usdcSeedAmount / totalSupply` (18-decimal fixed point) must be in (0, 1e16].
    function _validateErcs20OpeningPrice(address baseToken) internal view {
        IERCS20 ercs20 = IERCS20(baseToken);
        uint256 usdcSeed = ercs20.usdcSeedAmount();
        uint256 supply = ercs20.totalSupply();
        if (supply == 0 || usdcSeed == 0) return;

        uint256 scaled = Math.mulDiv(usdcSeed, OPENING_PRICE_SCALE, supply);
        if (scaled == 0) revert OpeningPriceDecimalsTooHigh();
        if (scaled > MAX_OPENING_PRICE) revert OpeningPriceTooHigh();
    }
}
