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
///      when an open posts order.margin. Trades move margin↔position
///      between Balances; fees debit Balance.margin into protocolFees. Flat accounts return
///      remaining margin to the vault. Funding uses a continuous per-market
///      index with lazy settlement into Balance.margin. Liquidations merge into approved liquidators.
contract PerpsExchange is Ownable, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    /// @notice Fees on notional: maker 0.02%, taker 0.05%.
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAKER_FEE_NUMERATOR = 2;
    uint256 public constant TAKER_FEE_NUMERATOR = 5;
    /// @notice Added to `minCollateralX18` when checking a liquidation. 0.02e18 = 2%.
    uint256 public constant LIQUIDATION_PENALTY_X18 = 0.02e18;
    /// @notice After final settlement is enabled, users have this long to self-withdraw before DAO may reclaim the pot.
    uint256 public constant FINAL_SETTLEMENT_LOCK = 300 days;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,uint256 marketId,uint256 amount,uint256 margin,uint256 priceX18,bool isBuy,uint256 nonce,uint256 expiry)"
    );

    GlobalPerpsVault public vault;
    address public factory;
    /// @notice Shared mark oracle for all markets (e.g. Ercs20TwapOracle). Required before createMarket.
    address public oracle;
    /// @notice Shared funding oracle for all markets. Required before createMarket; cannot be cleared.
    address public funder;

    /// @notice Protocol DAOs authorized for admin configuration (vault, oracles, pause, etc.).
    mapping(address => bool) public dao;
    mapping(address => bool) public isOperator;
    /// @notice May liquidate and run ADL. Separate from `isOperator`, which only settles trades and samples oracles.
    mapping(address => bool) public isRiskOperator;
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
    event RiskOperatorSet(address indexed account, bool allowed);
    event LiquidatorSet(address indexed account, bool allowed);
    event SignerSet(address indexed trader, address indexed signer, bool allowed);
    event MarketCreated(uint256 indexed marketId, address indexed ercs20, uint256 adlEquityThreshold, uint256 minCollateralX18);
    event MarketPaused(uint256 indexed marketId, bool paused);
    event AdlThresholdSet(uint256 indexed marketId, uint256 threshold);
    event MinCollateralSet(uint256 indexed marketId, uint256 minCollateralX18);
    event OracleSet(address indexed oracle);
    event FunderSet(address indexed funder);
    event FundingIndexUpdated(uint256 indexed marketId, int256 value, uint256 timestamp);
    event FundingSettled(address indexed account, uint256 indexed marketId, int256 marginDelta, uint256 startTimestamp, uint256 endTimestamp, int256 value);
    /// @notice `makerIsBuy` is the maker side; the taker takes the opposite side.
    ///         `makerMarginIn` / `takerMarginIn` = collateral pulled this fill (0 on pure reduce).
    event TradeSettled(uint256 indexed marketId, address indexed maker, address indexed taker, uint256 amount, uint256 priceX18, bool makerIsBuy, uint256 makerMarginIn, uint256 takerMarginIn, uint256 makerFee, uint256 takerFee);
    event MarginAdded(address indexed account, uint256 indexed marketId, uint256 amount);
    event MarginWithdraw(address indexed account, uint256 indexed marketId, uint256 amount);
    event MarginSettled(address indexed account, uint256 indexed marketId, uint256 amount);
    event Liquidated(uint256 indexed marketId, address indexed account, address indexed liquidator, int256 positionDelta, int256 marginDelta, bytes32 tradeHash, uint256 tradePriceX18, uint256 markPriceX18);
    /// @dev `positionDelta` / `marginDelta` apply to the liquidator. The account's trade deltas are the negation.
    event AdlExecuted(uint256 indexed marketId, address indexed account, address indexed liquidator, int256 positionDelta, int256 marginDelta, uint256 priceX18, uint256 markPriceX18);
    event FinalSettlementEnabled(uint256 indexed marketId, uint256 settlementPriceX18, uint256 lockedAt);
    event FinalSettlementWithdrawn(address indexed account, uint256 indexed marketId, uint256 amount);
    event FinalSettlementPotReclaimed(uint256 indexed marketId, address indexed to, uint256 amount);

    error NotOperator();
    error NotRiskOperator();
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
    error AdlExceedsPosition();
    error AdlEquityExceeded();
    error NothingToLiquidate();
    error InvalidFill();
    error PriceInvalid();
    error OrderMismatch();
    error InvalidMinCollateral();
    error NotLiquidator();
    error NoLastPrice();
    error NoPosition();
    error InsufficientMargin();

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier onlyRiskOperator() {
        if (!isRiskOperator[msg.sender]) revert NotRiskOperator();
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

    /// @notice Grant or revoke the right to liquidate and execute ADL.
    function setRiskOperator(address account, bool allowed) external onlyDAO {
        isRiskOperator[account] = allowed;
        emit RiskOperatorSet(account, allowed);
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
        if (ercs20 == address(0) || oracle == address(0) || funder == address(0)) revert ZeroAddress();
        if (markets[marketId].exists) revert MarketExists();
        if (minCollateralX18 < PerpsTypes.ONE_X18) revert InvalidMinCollateral();
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

    /// @notice Remaining native USDC in this market's vault pot (readable anytime; reclaim only after lock).
    function remainingFinalSettlementPot(uint256 marketId) external view returns (uint256) {
        return vault.marketPots(marketId);
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
    }

    function setMinCollateral(uint256 marketId, uint256 minCollateralX18) external onlyDAO {
        _requireMarket(marketId);
        if (minCollateralX18 < PerpsTypes.ONE_X18) revert InvalidMinCollateral();
        markets[marketId].minCollateralX18 = minCollateralX18;
        emit MinCollateralSet(marketId, minCollateralX18);
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
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(oracle_);
    }

    function setFunder(address funder_) external onlyDAO {
        if (funder_ == address(0)) revert ZeroAddress();
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

    /// @notice Sample mark oracle (TWAP cumulative) when idle.
    function updateMark(uint256 marketId) external onlyOperator {
        _requireMarket(marketId);
        _sampleMark(marketId);
    }

    /// @notice Move free vault collateral into this market's Balance.margin. Requires an open position.
    function addMargin(uint256 marketId, uint256 amount) external nonReentrant {
        PerpsTypes.Market storage m = _market(marketId);
        if (m.paused) revert MarketIsPaused();
        if (amount == 0) revert ZeroAmount();
        if (balances[msg.sender][marketId].position == 0) revert NoPosition();
        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(msg.sender, marketId, index);
        vault.adjustUserBalance(msg.sender, marketId, -int256(amount));
        _creditMargin(msg.sender, marketId, int256(amount));
        emit MarginAdded(msg.sender, marketId, amount);
    }

    /// @notice Move market Balance.margin back to vault free.
    /// @dev Funding is settled first. If a position remains, it must stay collateralized at mark.
    function withdrawMargin(uint256 marketId, uint256 amount) external nonReentrant {
        PerpsTypes.Market storage m = _market(marketId);
        if (m.paused) revert MarketIsPaused();

        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(msg.sender, marketId, index);

        PerpsTypes.Balance storage b = balances[msg.sender][marketId];
        if (b.margin < int256(amount)) revert InsufficientMargin();
        b.margin -= int256(amount);
        if (b.position != 0) {
            uint256 mark = IPerpsOracle(oracle).getPrice(marketId);
            if (!PerpsMath.isCollateralized(b.margin, b.position, mark, m.minCollateralX18)) {
                revert InsufficientMargin();
            }
        }

        vault.adjustUserBalance(msg.sender, marketId, int256(amount));
        emit MarginWithdraw(msg.sender, marketId, amount);
    }

    /// @dev Caller must group by `marketId` (backend sorts fills by pairId). Each contiguous
    ///      run samples mark once before fills and funding once after that run's last fill.
    function settleTrades(PerpsTypes.TradeSettlement[] calldata settlements) external onlyOperator {
        uint256 length = settlements.length;
        if (length == 0) return;

        uint256 runMarketId = settlements[0].takerOrder.marketId;
        _sampleMark(runMarketId);

        for (uint256 i; i < length;) {
            uint256 marketId = settlements[i].takerOrder.marketId;
            if (marketId != runMarketId) {
                _sampleFunding(runMarketId, markets[runMarketId]);
                runMarketId = marketId;
                _sampleMark(runMarketId);
            }
            _settleTrades(settlements[i]);
            unchecked {
                ++i;
            }
        }
        _sampleFunding(runMarketId, markets[runMarketId]);
    }

    /// @notice Liquidate each account into its liquidator. Each row carries its own market and trade.
    /// @dev Eligibility uses that row's mark and `minCollateralX18 + 2%`. A still-collateralized account is skipped.
    ///      Applied in order. Post-merge equity may be negative.
    function liquidate(PerpsTypes.Liquidation[] calldata liquidations) external onlyRiskOperator {
        uint256 length = liquidations.length;
        for (uint256 i; i < length;) {
            _liquidate(liquidations[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice ADL one market: force-close each account against `liquidator` at `priceX18`.
    /// @dev One mark and one trigger check for the batch. Afterwards L's mark equity must be <= 1.1x the ADL threshold.
    function executeAdl(uint256 marketId, address liquidator, uint256 priceX18, PerpsTypes.AdlExecution[] calldata executions) external onlyRiskOperator {
        if (priceX18 == 0) revert PriceInvalid();
        if (!isLiquidator[liquidator]) revert NotLiquidator();
        uint256 length = executions.length;
        if (length == 0) return;

        _requireMarket(marketId);
        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(liquidator, marketId, index);
        uint256 mark = IPerpsOracle(oracle).getPrice(marketId);
        if (!_isAdlTriggered(marketId, liquidator, mark)) revert AdlNotTriggered();

        for (uint256 i; i < length;) {
            _executeAdl(marketId, executions[i], liquidator, priceX18, mark, index);
            unchecked {
                ++i;
            }
        }

        uint256 cap = markets[marketId].adlEquityThreshold * 11 / 10;
        PerpsTypes.Balance storage b = balances[liquidator][marketId];
        if (PerpsMath.equity(b.margin, b.position, mark) > int256(cap)) revert AdlEquityExceeded();
    }

    function isAdlTriggered(uint256 marketId, address liquidator) external view returns (bool) {
        _requireMarket(marketId);
        if (!isLiquidator[liquidator]) return false;
        return _isAdlTriggered(marketId, liquidator, IPerpsOracle(oracle).getPrice(marketId));
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _liquidate(PerpsTypes.Liquidation calldata liquidation) private {
        uint256 marketId = liquidation.marketId;
        address account = liquidation.account;
        address liquidator = liquidation.liquidator;
        bytes32 tradeHash = liquidation.tradeHash;
        uint256 tradePriceX18 = liquidation.tradePriceX18;

        if (!isLiquidator[liquidator]) revert NotLiquidator();
        if (tradePriceX18 == 0) revert PriceInvalid();
        PerpsTypes.Market storage m = _market(marketId);

        PerpsTypes.FundingIndex memory index = _advanceFundingIndex(marketId);
        _settleAccountFunding(account, marketId, index);
        _settleAccountFunding(liquidator, marketId, index);

        PerpsTypes.Balance memory userBal = balances[account][marketId];
        if (userBal.position == 0) revert NothingToLiquidate();
        uint256 mark = IPerpsOracle(oracle).getPrice(marketId);
        if (PerpsMath.isCollateralized(userBal.margin, userBal.position, mark, m.minCollateralX18 + LIQUIDATION_PENALTY_X18)) {
            return;
        }

        // Clear first, then credit storage. Same address reads the cleared slot and adds the saved balance back.
        _clearBalance(account, marketId);
        PerpsTypes.Balance storage liqBal = balances[liquidator][marketId];
        liqBal.margin += userBal.margin;
        liqBal.position += userBal.position;

        emit Liquidated(marketId, account, liquidator, userBal.position, userBal.margin, tradeHash, tradePriceX18, mark);
    }

    function _executeAdl(
        uint256 marketId,
        PerpsTypes.AdlExecution calldata execution,
        address liquidator,
        uint256 priceX18,
        uint256 mark,
        PerpsTypes.FundingIndex memory index
    ) private {
        address account = execution.account;
        uint256 amount = execution.amount;

        _settleAccountFunding(account, marketId, index);

        PerpsTypes.Balance storage userBal = balances[account][marketId];
        if (userBal.position == 0) revert NothingToLiquidate();
        // Close only: a short buys, a long sells. A larger fill would open the other side.
        bool userIsBuy = userBal.position < 0;
        uint256 closable = userIsBuy ? uint256(-userBal.position) : uint256(userBal.position);
        if (amount > closable) revert AdlExceedsPosition();

        // User side first. Liquidator then reads storage, so one address nets instead of the second write clobbering the first.
        int256 posAmt = int256(amount);
        int256 quoteAmt = int256((amount * priceX18) / PerpsTypes.ONE_X18);
        int256 userPosDelta = userIsBuy ? posAmt : -posAmt;
        int256 userMarginDelta = userIsBuy ? -quoteAmt : quoteAmt;
        userBal.position += userPosDelta;
        userBal.margin += userMarginDelta;

        PerpsTypes.Balance storage liqBal = balances[liquidator][marketId];
        liqBal.position -= userPosDelta;
        liqBal.margin -= userMarginDelta;
        emit AdlExecuted(marketId, account, liquidator, -userPosDelta, -userMarginDelta, priceX18, mark);

        _tryReturnMarginToVault(account, marketId);
    }

    function _isAdlTriggered(uint256 marketId, address liquidator, uint256 mark) private view returns (bool) {
        PerpsTypes.Balance storage b = balances[liquidator][marketId];
        return PerpsMath.equity(b.margin, b.position, mark) < int256(markets[marketId].adlEquityThreshold);
    }

    function _settleTrades(PerpsTypes.TradeSettlement calldata s) private {
        uint256 length = s.makerOrders.length;
        if (length == 0 || length != s.makerSignatures.length || length != s.fulfillments.length) {
            revert InvalidFill();
        }

        uint256 marketId = s.takerOrder.marketId;
        _settleAccountFunding(s.takerOrder.trader, marketId, _advanceFundingIndex(marketId));

        bytes32 takerHash = _verifyOrder(s.takerOrder, s.takerSignature);
        uint256 takerFilled = filledAmount[takerHash];

        for (uint256 i; i < length;) {
            takerFilled += _settleFill(s.takerOrder, s.makerOrders[i], s.makerSignatures[i], s.fulfillments[i]);
            unchecked {
                ++i;
            }
        }

        if (takerFilled > s.takerOrder.amount) revert OrderOverfilled();
        filledAmount[takerHash] = takerFilled;
        markets[marketId].lastPriceX18 = s.fulfillments[length - 1].priceX18;
    }

    function _settleFill(
        PerpsTypes.Order calldata takerOrder,
        PerpsTypes.Order calldata makerOrder,
        bytes calldata makerSignature,
        PerpsTypes.Fulfillment calldata fill
    ) private returns (uint256) {
        if (fill.amount == 0 || fill.priceX18 == 0) revert InvalidFill();
        if (makerOrder.marketId != takerOrder.marketId) revert OrderMismatch();
        if (makerOrder.isBuy == takerOrder.isBuy) revert OrderMismatch();

        _requireLimitPrice(makerOrder, fill.priceX18);
        _requireLimitPrice(takerOrder, fill.priceX18);

        uint256 marketId = takerOrder.marketId;
        _settleAccountFunding(makerOrder.trader, marketId, fundingIndex[marketId]);
        _consumeFill(makerOrder, makerSignature, fill.amount);

        (uint256 makerMarginIn, bool makerOpened) = _prepareSide(makerOrder, fill.amount);
        (uint256 takerMarginIn, bool takerOpened) = _prepareSide(takerOrder, fill.amount);

        // Storage in-place, maker then taker. Same trader aliases one slot so self-trades net
        // correctly (memory copies + double _setBalance would let the second write clobber the first).
        // Both opening checks above read position before either write.
        uint256 makerFee = _applyFillSide(makerOrder.trader, marketId, fill.amount, fill.priceX18, makerOrder.isBuy, makerMarginIn, false);
        uint256 takerFee = _applyFillSide(takerOrder.trader, marketId, fill.amount, fill.priceX18, takerOrder.isBuy, takerMarginIn, true);
        if (makerOrder.trader == takerOrder.trader) {
            if (makerOpened || takerOpened) {
                _requireOpenedCollateral(makerOrder.trader, marketId, fill.priceX18);
            }
        } else {
            if (makerOpened) _requireOpenedCollateral(makerOrder.trader, marketId, fill.priceX18);
            if (takerOpened) _requireOpenedCollateral(takerOrder.trader, marketId, fill.priceX18);
        }
        vault.collectProtocolFee(marketId, makerFee + takerFee);

        emit TradeSettled(
            marketId,
            makerOrder.trader,
            takerOrder.trader,
            fill.amount,
            fill.priceX18,
            makerOrder.isBuy,
            makerMarginIn,
            takerMarginIn,
            makerFee,
            takerFee
        );

        _tryReturnMarginToVault(makerOrder.trader, marketId);
        _tryReturnMarginToVault(takerOrder.trader, marketId);
        return fill.amount;
    }

    function _sampleFunding(uint256 marketId, PerpsTypes.Market storage m) private {
        if (m.lastPriceX18 == 0) return;
        IFundingOracle(funder).update(marketId, m.lastPriceX18, m.ercs20);
    }

    /// @dev TWAP sampler. Oracle must implement `IOracleSampler.update`.
    function _sampleMark(uint256 marketId) private {
        IOracleSampler(oracle).update(marketId, markets[marketId].ercs20);
    }

    /// @dev Advance continuous funding index: Δindex += ±(unitlessFunding * mark / 1e18).
    function _advanceFundingIndex(uint256 marketId) private returns (PerpsTypes.FundingIndex memory index) {
        index = fundingIndex[marketId];

        // Bootstrap only: seed timestamp with value still 0. No funding accrued, so no FundingIndexUpdated.
        // Normal markets are initialized in createMarket; this branch is a defensive fallback.
        if (index.timestamp == 0) {
            index.timestamp = block.timestamp;
            fundingIndex[marketId] = index;
            return index;
        }

        uint256 timeDelta = block.timestamp - index.timestamp;
        if (timeDelta == 0) return index;

        uint256 mark = IPerpsOracle(oracle).getPrice(marketId);
        (bool positive, uint256 unitless) = IFundingOracle(funder).getFunding(marketId, timeDelta);
        int256 delta = int256((unitless * mark) / PerpsTypes.ONE_X18);
        if (!positive) delta = -delta;
        index.value += delta;

        index.timestamp = block.timestamp;
        fundingIndex[marketId] = index;
        emit FundingIndexUpdated(marketId, index.value, index.timestamp);
    }

    function _settleAccountFunding(address account, uint256 marketId, PerpsTypes.FundingIndex memory globalIndex)
        private
        returns (int256 marginDelta)
    {
        PerpsTypes.FundingIndex storage local = localFundingIndex[account][marketId];
        if (local.timestamp == globalIndex.timestamp) return 0;

        uint256 localTimestamp = local.timestamp;

        int256 indexDelta = globalIndex.value - local.value;
        local.timestamp = globalIndex.timestamp;
        local.value = globalIndex.value;

        PerpsTypes.Balance storage b = balances[account][marketId];
        if (b.position != 0 && indexDelta != 0) {
            marginDelta = PerpsMath.fundingMarginDelta(indexDelta, b.position);
            b.margin += marginDelta;
        }

        if (marginDelta != 0) {
            emit FundingSettled(account, marketId, marginDelta, localTimestamp, globalIndex.timestamp, globalIndex.value);
        }
    }

    /// @dev Credit `marginIn`, apply fill delta, debit the trading fee on one side.
    ///      Fee is taken from the same quote booked on this fill: maker 0.02%, taker 0.05%.
    ///      Uses storage so a maker==taker self-trade aliases and nets instead of clobbering via memory copies.
    /// @return fee Trading fee charged on this side.
    function _applyFillSide(
        address account,
        uint256 marketId,
        uint256 amount,
        uint256 priceX18,
        bool isBuy,
        uint256 marginIn,
        bool isTaker
    ) private returns (uint256 fee) {
        PerpsTypes.Balance storage bal = balances[account][marketId];
        bal.margin += int256(marginIn);

        int256 posAmt = int256(amount);
        uint256 quote = (amount * priceX18) / PerpsTypes.ONE_X18;
        int256 quoteAmt = int256(quote);
        if (isBuy) {
            bal.position += posAmt;
            bal.margin -= quoteAmt;
        } else {
            bal.position -= posAmt;
            bal.margin += quoteAmt;
        }

        fee = isTaker
            ? (quote * TAKER_FEE_NUMERATOR) / FEE_DENOMINATOR
            : (quote * MAKER_FEE_NUMERATOR) / FEE_DENOMINATOR;
        bal.margin -= int256(fee);
    }

    /// @dev Opening/increasing size pulls proportional `order.margin` from vault free (pot only).
    ///      Balance.margin is credited later in the same settle writeback as the fill.
    ///      Pure reduce pulls nothing (fee is debited from existing margin in `_applyFillSide`).
    ///      Call both sides before either apply: opening size is the pre-trade position.
    ///      After the fill, an opening side must have margin >= 0 and be collateralized at the fill price.
    /// @return want Collateral pulled this fill (`0` on pure reduce).
    /// @return opened True when this fill increases exposure.
    function _prepareSide(PerpsTypes.Order calldata order, uint256 fillAmount)
        private
        returns (uint256 want, bool opened)
    {
        PerpsTypes.Balance storage b = balances[order.trader][order.marketId];
        uint256 opening = _openingSize(order.isBuy, b.position, fillAmount);
        if (opening == 0) return (0, false);

        want = PerpsMath.fillMargin(order.margin, order.amount, opening);
        if (want != 0) vault.adjustUserBalance(order.trader, order.marketId, -int256(want));
        opened = true;
    }

    /// @dev New exposure must be backed at the fill price. A non-negative margin means the quote
    ///      moved to the counterparty was pulled into the pot. Shorts also need `minCollateralX18`.
    function _requireOpenedCollateral(address account, uint256 marketId, uint256 fillPriceX18) private view {
        PerpsTypes.Balance storage b = balances[account][marketId];
        if (b.position == 0) return;
        if (b.margin < 0) revert InsufficientMargin();
        if (!PerpsMath.isCollateralized(b.margin, b.position, fillPriceX18, markets[marketId].minCollateralX18)) {
            revert InsufficientMargin();
        }
    }

    /// @dev Size of `fillAmount` that increases exposure (not closing existing opposite position).
    function _openingSize(bool isBuy, int256 position, uint256 fillAmount) private pure returns (uint256) {
        if (isBuy) {
            if (position >= 0) return fillAmount;
            uint256 short = uint256(-position);
            return fillAmount > short ? fillAmount - short : 0;
        }
        if (position <= 0) return fillAmount;
        uint256 long_ = uint256(position);
        return fillAmount > long_ ? fillAmount - long_ : 0;
    }

    function _creditMargin(address account, uint256 marketId, int256 amount) private {
        balances[account][marketId].margin += amount;
    }

    /// @dev If position is flat and margin > 0, return margin to free vault balance.
    ///      Flat with margin < 0 is insolvent — revert instead of leaving a stranded debit.
    /// @dev Liquidators keep margin parked for subsequent liquidations.
    function _tryReturnMarginToVault(address account, uint256 marketId) private {
        if (isLiquidator[account]) return;
        PerpsTypes.Balance storage b = balances[account][marketId];
        if (b.position != 0) return;
        if (b.margin < 0) revert InsufficientMargin();
        if (b.margin == 0) return;
        int256 amount = b.margin;
        b.margin = 0;
        vault.adjustUserBalance(account, marketId, amount);
        emit MarginSettled(account, marketId, uint256(amount));
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

    function _setBalance(address account, uint256 marketId, PerpsTypes.Balance memory newBal) private {
        PerpsTypes.Balance storage cur = balances[account][marketId];
        cur.margin = newBal.margin;
        cur.position = newBal.position;
    }

    function _clearBalance(address account, uint256 marketId) private {
        _setBalance(account, marketId, PerpsTypes.Balance(0, 0));
    }

    function _requireMarket(uint256 marketId) private view {
        if (!markets[marketId].exists) revert MarketNotFound();
    }

    function _market(uint256 marketId) private view returns (PerpsTypes.Market storage m) {
        m = markets[marketId];
        if (!m.exists) revert MarketNotFound();
    }
}
