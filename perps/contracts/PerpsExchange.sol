// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IPerpsOracle} from "./interfaces/IPerpsOracle.sol";
import {IFundingOracle} from "./interfaces/IFundingOracle.sol";
import {IOracleSampler} from "./interfaces/IOracleSampler.sol";
import {PerpsTypes} from "./libraries/PerpsTypes.sol";
import {PerpsMath} from "./libraries/PerpsMath.sol";
import {GlobalPerpsVault} from "./GlobalPerpsVault.sol";

/// @title PerpsExchange
/// @notice Multi-market perpetual settlement with signed Balance{margin, position}.
/// @dev GlobalPerpsVault holds shared free USDC. Per-market Balance is funded from the vault
///      (order.margin on fill, or addMargin). Trades move margin↔position between Balances.
///      Flat accounts return remaining margin to the vault. Funding uses a continuous per-market
///      index with lazy settlement into Balance.margin. Liquidations merge into approved liquidators.
contract PerpsExchange is Ownable, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    GlobalPerpsVault public vault;
    address public factory;
    /// @notice Shared mark oracle for all markets (e.g. Ercs20TwapOracle).
    address public oracle;
    /// @notice Shared funding oracle for all markets; address(0) disables funding.
    address public funder;

    /// @notice Binance USDT-M VIP0-style fees on notional: maker 0.02%, taker 0.05%.
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAKER_FEE_NUMERATOR = 2;
    uint256 public constant TAKER_FEE_NUMERATOR = 5;
    /// @notice After final settlement is enabled, users have this long to self-withdraw before DAO may reclaim the pot.
    uint256 public constant FINAL_SETTLEMENT_LOCK = 300 days;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,uint256 marketId,uint256 amount,uint256 margin,uint256 priceX18,bool isBuy,uint256 nonce,uint256 expiry)"
    );

    /// @notice Protocol DAOs authorized for admin configuration (vault, oracles, pause, etc.).
    mapping(address => bool) public dao;
    mapping(address => bool) public isOperator;
    /// @notice Global liquidator allowlist (same L set for all markets).
    mapping(address => bool) public isLiquidator;
    /// @notice Session signers: trader => signer => allowed to sign Order for trader.
    mapping(address => mapping(address => bool)) public isSigner;
    mapping(uint256 => PerpsTypes.Market) public markets;
    /// @notice Final settlement config per market (only read after enable).
    mapping(uint256 => PerpsTypes.MarketSettlement) public marketSettlements;
    mapping(address => mapping(uint256 => PerpsTypes.Balance)) public balances;
    mapping(bytes32 => uint256) public filledAmount;
    /// @notice Per-market continuous funding index.
    mapping(uint256 => PerpsTypes.FundingIndex) public fundingIndex;
    /// @notice Last settled funding index per account.
    mapping(address => mapping(uint256 => PerpsTypes.FundingIndex)) public localFundingIndex;

    event VaultSet(address indexed vault);
    event DAOSet(address indexed account, bool allowed);
    event FactorySet(address indexed factory);
    event OperatorSet(address indexed account, bool allowed);
    event LiquidatorSet(address indexed account, bool allowed);
    event SignerSet(address indexed trader, address indexed signer, bool allowed);
    event InsuranceSeeded(uint256 indexed marketId, address indexed account, uint256 amount);
    event MarketCreated(
        uint256 indexed marketId, address indexed ercs20, uint256 adlEquityThreshold, uint256 minCollateralX18
    );
    event MarketPaused(uint256 indexed marketId, bool paused);
    event AdlThresholdSet(uint256 indexed marketId, uint256 threshold);
    event OracleSet(address indexed oracle);
    event FunderSet(address indexed funder);
    event FundingIndexUpdated(uint256 indexed marketId, int256 value, uint256 timestamp);
    event FundingSettled(address indexed account, uint256 indexed marketId, int256 marginDelta);
    event FundingSampled(uint256 indexed marketId, uint256 lastPriceX18, bool updated);
    event MarkSampled(uint256 indexed marketId, bool updated);
    event TradeSettled(
        uint256 indexed marketId,
        address indexed maker,
        address indexed taker,
        uint256 amount,
        uint256 priceX18,
        bool takerIsBuy,
        uint256 makerMargin,
        uint256 takerMargin,
        uint256 makerFee,
        uint256 takerFee
    );
    event MarginAdded(address indexed user, uint256 indexed marketId, uint256 amount);
    event Liquidated(
        uint256 indexed marketId,
        address indexed user,
        address indexed liquidator,
        int256 position,
        int256 marginSeized,
        uint256 markPriceX18
    );
    event AdlExecuted(
        uint256 indexed marketId,
        address indexed user,
        address indexed liquidator,
        int256 closedSize,
        uint256 priceX18
    );
    event FinalSettlementEnabled(uint256 indexed marketId, uint256 settlementPriceX18, uint256 lockedAt);
    event FinalSettlementWithdrawn(address indexed user, uint256 indexed marketId, uint256 amount);
    event FinalSettlementPotReclaimed(uint256 indexed marketId, address indexed to, uint256 amount);

    error NotOperator();
    error NotDAO();
    error NotFactory();
    error NotFactoryOrLiquidator();
    error ZeroAddress();
    error MarketExists();
    error MarketNotFound();
    error MarketIsPaused();
    error FinalSettlementNotEnabled();
    error FinalSettlementLockActive();
    error ZeroAmount();
    error OrderExpired();
    error OrderOverfilled();
    error InvalidSignature();
    error AdlNotTriggered();
    error NothingToLiquidate();
    error InvalidFill();
    error PriceInvalid();
    error OrderMismatch();
    error NotLiquidatable();
    error InvalidMinCollateral();
    error CannotLiquidateNegativeAccount();
    error NotLiquidator();
    error LiquidatorCannotTake();
    error FunderNotSet();
    error NoLastPrice();

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier onlyDAO() {
        if (!dao[msg.sender]) revert NotDAO();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor() Ownable(msg.sender) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PerpsExchange")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    /// @notice Grant or revoke DAO admin rights. Owner only.
    function setDAO(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        dao[account] = allowed;
        emit DAOSet(account, allowed);
    }

    function setVault(address vault_) external onlyDAO {
        vault = GlobalPerpsVault(vault_);
        emit VaultSet(vault_);
    }

    function setOperator(address account, bool allowed) external onlyDAO {
        isOperator[account] = allowed;
        emit OperatorSet(account, allowed);
    }

    function setLiquidator(address account, bool allowed) external onlyDAO {
        isLiquidator[account] = allowed;
        emit LiquidatorSet(account, allowed);
    }

    /// @notice Authorize `signer` to EIP-712-sign Orders where `trader == msg.sender`.
    function setSigner(address signer, bool allowed) external {
        if (signer == address(0)) revert ZeroAddress();
        isSigner[msg.sender][signer] = allowed;
        emit SignerSet(msg.sender, signer, allowed);
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function createMarket(uint256 marketId, address ercs20, uint256 adlEquityThreshold, uint256 minCollateralX18)
        external
        onlyFactory
    {
        if (ercs20 == address(0)) revert ZeroAddress();
        if (markets[marketId].exists) revert MarketExists();
        if (minCollateralX18 < PerpsTypes.BASE) revert InvalidMinCollateral();
        markets[marketId] = PerpsTypes.Market({
            ercs20: ercs20,
            exists: true,
            paused: false,
            adlEquityThreshold: adlEquityThreshold,
            minCollateralX18: minCollateralX18,
            lastPriceX18: 0
        });
        fundingIndex[marketId] = PerpsTypes.FundingIndex({timestamp: block.timestamp, value: 0});
        emit MarketCreated(marketId, ercs20, adlEquityThreshold, minCollateralX18);
    }

    /// @notice Enable or update final settlement at an off-chain-chosen `settlementPriceX18`.
    /// @dev Only flips storage + pause — no funding/oracle — so enable cannot get stuck.
    ///      Owner may call again to correct the price; `lockedAt` is set only on first enable.
    function enableFinalSettlement(uint256 marketId, uint256 settlementPriceX18) external onlyOwner {
        if (settlementPriceX18 == 0) revert PriceInvalid();

        _market(marketId).paused = true;
        PerpsTypes.MarketSettlement storage s = marketSettlements[marketId];
        if (!s.enabled) {
            s.enabled = true;
            s.lockedAt = block.timestamp;
        }
        s.settlementPriceX18 = settlementPriceX18;
        emit FinalSettlementEnabled(marketId, settlementPriceX18, s.lockedAt);
    }

    /// @notice Close caller's Balance at settlement price; positive equity → vault free.
    /// @dev Underwater (equity ≤ 0): wipe Balance, no payout. Pot must cover solvent payouts
    ///      (flat book ⇒ choose price / clear underwater off-chain so Σ max(equity,0) ≤ pot).
    function withdrawFinalSettlement(uint256 marketId) external nonReentrant {
        PerpsTypes.MarketSettlement storage s = marketSettlements[marketId];
        if (!s.enabled) revert FinalSettlementNotEnabled();

        PerpsTypes.Balance memory userBal = balances[msg.sender][marketId];
        if (userBal.margin == 0 && userBal.position == 0) revert ZeroAmount();

        int256 eq = PerpsMath.equity(userBal.margin, userBal.position, s.settlementPriceX18);
        _clearBalance(msg.sender, marketId);

        uint256 payout;
        if (eq > 0) {
            payout = uint256(eq);
            vault.adjustUserBalance(msg.sender, marketId, eq);
        }

        emit FinalSettlementWithdrawn(msg.sender, marketId, payout);
    }

    /// @notice After `FINAL_SETTLEMENT_LOCK`, DAO moves the entire leftover market pot to its vault free balance.
    function reclaimFinalSettlementPot(uint256 marketId) external onlyDAO nonReentrant {
        PerpsTypes.MarketSettlement storage s = marketSettlements[marketId];
        if (!s.enabled) revert FinalSettlementNotEnabled();
        if (block.timestamp < s.lockedAt + FINAL_SETTLEMENT_LOCK) revert FinalSettlementLockActive();

        uint256 amount = vault.marketPots(marketId);
        if (amount == 0) revert ZeroAmount();

        vault.adjustUserBalance(msg.sender, marketId, int256(amount));
        emit FinalSettlementPotReclaimed(marketId, msg.sender, amount);
    }

    /// @notice Deposit native USDC into a liquidator's market Balance.margin.
    /// @dev Callable by `factory` (any liquidator `account`) or by a liquidator funding themselves.
    function seedInsuranceMargin(uint256 marketId, address account) external payable {
        if (msg.sender != factory && !isLiquidator[msg.sender]) revert NotFactoryOrLiquidator();
        if (!isLiquidator[account]) revert NotLiquidator();
        if (msg.sender != factory && account != msg.sender) revert NotLiquidator();

        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();
        _requireMarket(marketId);

        vault.depositFor{value: amount}(account);
        vault.adjustUserBalance(account, marketId, -int256(amount));
        _creditMargin(account, marketId, int256(amount));

        emit MarginAdded(account, marketId, amount);
        emit InsuranceSeeded(marketId, account, amount);
    }

    function setMinCollateral(uint256 marketId, uint256 minCollateralX18) external onlyDAO {
        _requireMarket(marketId);
        if (minCollateralX18 < PerpsTypes.BASE) revert InvalidMinCollateral();
        markets[marketId].minCollateralX18 = minCollateralX18;
    }

    function setMarketPaused(uint256 marketId, bool paused_) external onlyDAO {
        _requireMarket(marketId);
        markets[marketId].paused = paused_;
        emit MarketPaused(marketId, paused_);
    }

    function setAdlEquityThreshold(uint256 marketId, uint256 threshold) external onlyDAO {
        _requireMarket(marketId);
        markets[marketId].adlEquityThreshold = threshold;
        emit AdlThresholdSet(marketId, threshold);
    }

    function setOracle(address oracle_) external onlyDAO {
        oracle = oracle_;
        emit OracleSet(oracle_);
    }

    function setFunder(address funder_) external onlyDAO {
        funder = funder_;
        emit FunderSet(funder_);
    }

    /// @notice Advance market funding index and settle funding for `account` into Balance.margin.
    function settleFunding(address account, uint256 marketId) external {
        PerpsTypes.Market storage m = _market(marketId);
        if (m.paused) revert MarketIsPaused();
        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(account, marketId, index);
    }

    /// @notice Accrue funding index with the cached rate, then resample rate from `lastPriceX18`.
    /// @dev onlyOperator: avoids flash-loan spot + public sample. Use when idle (no trades).
    function updateFunding(uint256 marketId) external onlyOperator {
        PerpsTypes.Market storage m = _market(marketId);
        if (m.lastPriceX18 == 0) revert NoLastPrice();

        // Apply existing cached rate to elapsed time before taking a new sample.
        _advanceFundingIndex(marketId);
        _sampleFunding(marketId, m);
    }

    /// @notice Sample mark oracle (TWAP cumulative) when idle. no-op if oracle has no sampler.
    function updateMark(uint256 marketId) external onlyOperator {
        _requireMarket(marketId);
        _sampleMark(marketId);
    }

    /// @notice Move free vault collateral into this market's Balance.margin.
    function addMargin(uint256 marketId, uint256 amount) external nonReentrant {
        PerpsTypes.Market storage m = _market(marketId);
        if (m.paused) revert MarketIsPaused();
        if (amount == 0) revert ZeroAmount();
        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(msg.sender, marketId, index);
        vault.adjustUserBalance(msg.sender, marketId, -int256(amount));
        _creditMargin(msg.sender, marketId, int256(amount));
        emit MarginAdded(msg.sender, marketId, amount);
    }

    /// @dev Prefer one market per call. `lastPrice` / funding sample use the last settlement's last fill.
    function settleTrades(PerpsTypes.TradeSettlement[] calldata settlements) external onlyOperator {
        uint256 length = settlements.length;
        for (uint256 i; i < length;) {
            _settleTrades(settlements[i]);
            unchecked {
                ++i;
            }
        }

        if (length == 0) return;

        PerpsTypes.TradeSettlement calldata last = settlements[length - 1];
        uint256 fillLen = last.fulfillments.length;
        if (fillLen == 0) return;

        uint256 marketId = last.takerOrder.marketId;
        PerpsTypes.Market storage m = markets[marketId];
        m.lastPriceX18 = last.fulfillments[fillLen - 1].priceX18;
        _sampleFunding(marketId, m);
        _sampleMark(marketId);
    }

    /// @notice Liquidate user into `liquidator`: merge full Balance (margin + position, signed).
    /// @dev Reverts if L mark equity would be negative after the merge (fund L first).
    function liquidate(uint256 marketId, address user, address liquidator) external onlyOperator  {
        if (!isLiquidator[liquidator]) revert NotLiquidator();
        PerpsTypes.Market storage m = _market(marketId);

        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(user, marketId, index);
        _settleAccountFunding(liquidator, marketId, index);

        PerpsTypes.Balance memory userBal = balances[user][marketId];
        if (userBal.position == 0) revert NothingToLiquidate();
        uint256 mark = IPerpsOracle(oracle).getPrice(marketId);

        // Cannot liquidate when margin and position are both negative.
        if (userBal.margin < 0 && userBal.position < 0) revert CannotLiquidateNegativeAccount();
        if (PerpsMath.isCollateralized(userBal.margin, userBal.position, mark, m.minCollateralX18)) {
            revert NotLiquidatable();
        }

        PerpsTypes.Balance memory liqBal = balances[liquidator][marketId];
        liqBal.margin += userBal.margin;
        liqBal.position += userBal.position;

        if (PerpsMath.equity(liqBal.margin, liqBal.position, mark) < 0) {
            revert LiquidatorCannotTake();
        }

        _setBalance(liquidator, marketId, liqBal);
        _clearBalance(user, marketId);

        emit Liquidated(marketId, user, liquidator, userBal.position, userBal.margin, mark);
    }

    /// @notice ADL: force trade user against liquidator at mark when L margin ≤ threshold.
    function executeAdl(
        uint256 marketId,
        address user,
        address liquidator,
        uint256 amount,
        bool userIsBuy
    ) external onlyOperator {
        if (amount == 0) revert ZeroAmount();
        if (!isLiquidator[liquidator]) revert NotLiquidator();

        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(user, marketId, index);
        _settleAccountFunding(liquidator, marketId, index);

        if (!_isAdlTriggered(marketId, liquidator)) revert AdlNotTriggered();

        PerpsTypes.Balance memory userBal = balances[user][marketId];
        if (userBal.position == 0) revert NothingToLiquidate();

        uint256 mark = IPerpsOracle(oracle).getPrice(marketId);
        PerpsTypes.Balance memory liqBal = balances[liquidator][marketId];

        // User is taker vs liquidator as maker.
        (PerpsTypes.Balance memory newUser, PerpsTypes.Balance memory newLiq) =
            PerpsMath.applyTrade(userBal, liqBal, amount, mark, userIsBuy);

        _setBalance(user, marketId, newUser);
        _setBalance(liquidator, marketId, newLiq);
        _tryReturnMarginToVault(user, marketId);
        _tryReturnMarginToVault(liquidator, marketId);

        emit AdlExecuted(marketId, user, liquidator, userIsBuy ? int256(amount) : -int256(amount), mark);
    }

    function isAdlTriggered(uint256 marketId, address liquidator) external view returns (bool) {
        _requireMarket(marketId);
        if (!isLiquidator[liquidator]) return false;
        return _isAdlTriggered(marketId, liquidator);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _isAdlTriggered(uint256 marketId, address liquidator) private view returns (bool) {
        return balances[liquidator][marketId].margin <= int256(markets[marketId].adlEquityThreshold);
    }

    function _settleTrades(PerpsTypes.TradeSettlement calldata s) private {
        uint256 length = s.makerOrders.length;
        if (length == 0 || length != s.makerSignatures.length || length != s.fulfillments.length) {
            revert InvalidFill();
        }

        PerpsTypes.Order calldata takerOrder = s.takerOrder;
        uint256 marketId = takerOrder.marketId;

        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(takerOrder.trader, marketId, index);

        bytes32 takerHash = _verifyOrder(takerOrder, s.takerSignature);
        uint256 takerFilled = filledAmount[takerHash];

        for (uint256 i; i < length;) {
            PerpsTypes.Order calldata makerOrder = s.makerOrders[i];
            PerpsTypes.Fulfillment calldata fill = s.fulfillments[i];

            if (fill.amount == 0 || fill.priceX18 == 0) revert InvalidFill();
            if (makerOrder.marketId != takerOrder.marketId) revert OrderMismatch();
            if (makerOrder.isBuy == takerOrder.isBuy) revert OrderMismatch();

            _requireLimitPrice(makerOrder, fill.priceX18);
            _requireLimitPrice(takerOrder, fill.priceX18);

            _settleAccountFunding(makerOrder.trader, marketId, index);

            _consumeFill(makerOrder, s.makerSignatures[i], fill.amount);
            takerFilled += fill.amount;

            (uint256 makerMargin, uint256 makerFee) =
                _lockFillMarginAndFee(makerOrder, fill.amount, fill.priceX18, false);
            (uint256 takerMargin, uint256 takerFee) =
                _lockFillMarginAndFee(takerOrder, fill.amount, fill.priceX18, true);

            PerpsTypes.Balance memory makerBal = balances[makerOrder.trader][marketId];
            PerpsTypes.Balance memory takerBal = balances[takerOrder.trader][marketId];

            (PerpsTypes.Balance memory newTaker, PerpsTypes.Balance memory newMaker) =
                PerpsMath.applyTrade(takerBal, makerBal, fill.amount, fill.priceX18, takerOrder.isBuy);

            _setBalance(makerOrder.trader, marketId, newMaker);
            _setBalance(takerOrder.trader, marketId, newTaker);
            _tryReturnMarginToVault(makerOrder.trader, marketId);
            _tryReturnMarginToVault(takerOrder.trader, marketId);

            emit TradeSettled(
                marketId,
                makerOrder.trader,
                takerOrder.trader,
                fill.amount,
                fill.priceX18,
                takerOrder.isBuy,
                makerMargin,
                takerMargin,
                makerFee,
                takerFee
            );

            unchecked {
                ++i;
            }
        }

        if (takerFilled > takerOrder.amount) revert OrderOverfilled();
        filledAmount[takerHash] = takerFilled;
    }

    function _sampleFunding(uint256 marketId, PerpsTypes.Market storage m) private {
        if (funder == address(0) || m.lastPriceX18 == 0) return;
        bool updated = IFundingOracle(funder).update(marketId, m.lastPriceX18, m.ercs20);
        emit FundingSampled(marketId, m.lastPriceX18, updated);
    }

    /// @dev Optional sampler (TWAP). MockOracle without `update` is ignored via try/catch.
    function _sampleMark(uint256 marketId) private {
        address oracle_ = oracle;
        if (oracle_ == address(0)) return;
        address ercs20 = markets[marketId].ercs20;
        try IOracleSampler(oracle_).update(marketId, ercs20) returns (bool updated) {
            emit MarkSampled(marketId, updated);
        } catch {}
    }

    /// @dev Advance continuous funding index: Δindex += ±(unitlessFunding * mark / 1e18).
    function _advanceFundingIndex(uint256 marketId) private returns (PerpsTypes.FundingIndex memory index) {
        index = fundingIndex[marketId];

        if (index.timestamp == 0) {
            index.timestamp = block.timestamp;
            fundingIndex[marketId] = index;
            return index;
        }

        uint256 timeDelta = block.timestamp - index.timestamp;
        if (timeDelta == 0) return index;

        if (funder != address(0)) {
            uint256 mark = IPerpsOracle(oracle).getPrice(marketId);
            (bool positive, uint256 unitless) = IFundingOracle(funder).getFunding(marketId, timeDelta);
            int256 delta = int256((unitless * mark) / PerpsTypes.BASE);
            if (!positive) delta = -delta;
            index.value += delta;
        }

        index.timestamp = block.timestamp;
        fundingIndex[marketId] = index;
        emit FundingIndexUpdated(marketId, index.value, index.timestamp);
    }

    function _settleAccountFunding(address account, uint256 marketId, PerpsTypes.FundingIndex memory globalIndex)
        private
    {
        PerpsTypes.FundingIndex storage local = localFundingIndex[account][marketId];
        if (local.timestamp == globalIndex.timestamp) return;

        int256 indexDelta = globalIndex.value - local.value;
        local.timestamp = globalIndex.timestamp;
        local.value = globalIndex.value;

        PerpsTypes.Balance storage b = balances[account][marketId];
        if (b.position == 0 || indexDelta == 0) return;

        int256 marginDelta = PerpsMath.fundingMarginDelta(indexDelta, b.position);
        b.margin += marginDelta;
        emit FundingSettled(account, marketId, marginDelta);
    }

    /// @dev Lock fill collateral + trading fee from vault free.
    ///      Only collateral is credited to Balance.margin; fee goes to protocolFees.
    function _lockFillMarginAndFee(
        PerpsTypes.Order calldata order,
        uint256 fillAmount,
        uint256 fillPriceX18,
        bool isTaker
    ) private returns (uint256 toLock, uint256 fee) {
        toLock = PerpsMath.fillMargin(order.margin, order.amount, fillAmount);
        uint256 notional = (fillAmount * fillPriceX18) / PerpsTypes.BASE;
        fee = isTaker
            ? (notional * TAKER_FEE_NUMERATOR) / FEE_DENOMINATOR
            : (notional * MAKER_FEE_NUMERATOR) / FEE_DENOMINATOR;

        vault.debitFreeForFill(order.trader, order.marketId, toLock, fee);
        _creditMargin(order.trader, order.marketId, int256(toLock));
    }

    function _creditMargin(address user, uint256 marketId, int256 amount) private {
        balances[user][marketId].margin += amount;
    }

    /// @dev If position is flat and margin > 0, return margin to free vault balance.
    /// @dev Liquidators keep margin parked for subsequent liquidations.
    function _tryReturnMarginToVault(address user, uint256 marketId) private {
        if (isLiquidator[user]) return;
        PerpsTypes.Balance storage b = balances[user][marketId];
        if (b.position != 0 || b.margin <= 0) return;
        uint256 amount = uint256(b.margin);
        b.margin = 0;
        vault.adjustUserBalance(user, marketId, int256(amount));
    }

    function _verifyOrder(PerpsTypes.Order calldata order, bytes calldata signature)
        private
        view
        returns (bytes32 orderHash)
    {
        if (block.timestamp > order.expiry) revert OrderExpired();
        if (order.amount == 0) revert ZeroAmount();
        orderHash = _hashOrder(order);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, orderHash));
        address recovered = digest.recover(signature);
        if (recovered != order.trader && !isSigner[order.trader][recovered]) revert InvalidSignature();
    }

    function _consumeFill(PerpsTypes.Order calldata order, bytes calldata signature, uint256 fillAmount) private {
        bytes32 orderHash = _verifyOrder(order, signature);
        uint256 newFilled = filledAmount[orderHash] + fillAmount;
        if (newFilled > order.amount) revert OrderOverfilled();
        filledAmount[orderHash] = newFilled;
    }

    function _requireLimitPrice(PerpsTypes.Order calldata order, uint256 fillPriceX18) private pure {
        if (order.isBuy) {
            if (fillPriceX18 > order.priceX18) revert PriceInvalid();
        } else if (fillPriceX18 < order.priceX18) {
            revert PriceInvalid();
        }
    }

    function _hashOrder(PerpsTypes.Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.trader,
                order.marketId,
                order.amount,
                order.margin,
                order.priceX18,
                order.isBuy,
                order.nonce,
                order.expiry
            )
        );
    }

    function _setBalance(address user, uint256 marketId, PerpsTypes.Balance memory newBal) private {
        PerpsTypes.Balance storage cur = balances[user][marketId];
        cur.margin = newBal.margin;
        cur.position = newBal.position;
    }

    function _clearBalance(address user, uint256 marketId) private {
        _setBalance(user, marketId, PerpsTypes.Balance(0, 0));
    }

    function _requireMarket(uint256 marketId) private view {
        if (!markets[marketId].exists) revert MarketNotFound();
    }

    function _market(uint256 marketId) private view returns (PerpsTypes.Market storage m) {
        m = markets[marketId];
        if (!m.exists) revert MarketNotFound();
    }
}
