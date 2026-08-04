// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IPerpsOracle} from "./interfaces/IPerpsOracle.sol";
import {PerpsTypes} from "./libraries/PerpsTypes.sol";
import {PerpsMath} from "./libraries/PerpsMath.sol";
import {GlobalPerpsVault} from "./GlobalPerpsVault.sol";

/// @title PerpsExchange
/// @notice Multi-market perpetual settlement with dYdX-style Balance{margin, position}.
/// @dev GlobalPerpsVault holds shared free USDC. Per-market Balance is funded from the vault
///      (order.margin on fill, or addMargin). Trades move margin↔position between Balances.
///      Flat accounts return remaining margin to the vault.
contract PerpsExchange is Ownable, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    GlobalPerpsVault public vault;
    address public pauseDAO;

    /// @notice Binance USDT-M VIP0-style fees on notional: maker 0.02%, taker 0.05%.
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAKER_FEE_NUMERATOR = 2;
    uint256 public constant TAKER_FEE_NUMERATOR = 5;

    mapping(address => bool) public isOperator;
    mapping(uint256 => PerpsTypes.Market) public markets;
    mapping(address => mapping(uint256 => PerpsTypes.Balance)) public balances;

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,uint256 marketId,uint256 amount,uint256 margin,uint256 priceX18,bool isBuy,uint256 nonce,uint256 expiry)"
    );

    mapping(bytes32 => uint256) public filledAmount;

    event VaultSet(address indexed vault);
    event PauseDAOSet(address indexed dao);
    event OperatorSet(address indexed account, bool allowed);
    event MarketCreated(uint256 indexed marketId, address oracle, uint256 adlEquityThreshold);
    event MarketPaused(uint256 indexed marketId, bool paused);
    event AdlThresholdSet(uint256 indexed marketId, uint256 threshold);
    event OracleSet(uint256 indexed marketId, address oracle);
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
    event MarginRemoved(address indexed user, uint256 indexed marketId, uint256 amount);
    event Liquidated(
        uint256 indexed marketId, address indexed user, int256 position, uint256 marginSeized, uint256 markPriceX18
    );
    event AdlExecuted(
        uint256 indexed marketId, address indexed user, int256 closedSize, uint256 priceX18
    );
    event SystemSeeded(uint256 indexed marketId, uint256 amount);

    error InvalidAddress();
    error NotOperator();
    error NotPauseDAO();
    error MarketExists();
    error MarketNotFound();
    error MarketIsPaused();
    error VaultAlreadySet();
    error ZeroAmount();
    error OrderExpired();
    error OrderOverfilled();
    error InvalidSignature();
    error AdlNotTriggered();
    error NothingToLiquidate();
    error InvalidFill();
    error PriceInvalid();
    error OrderMismatch();
    error InsufficientMargin();

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier onlyPauseDAO() {
        if (msg.sender != pauseDAO) revert NotPauseDAO();
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

    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert InvalidAddress();
        if (address(vault) != address(0)) revert VaultAlreadySet();
        vault = GlobalPerpsVault(vault_);
        emit VaultSet(vault_);
    }

    function setPauseDAO(address dao) external onlyOwner {
        if (dao == address(0)) revert InvalidAddress();
        pauseDAO = dao;
        emit PauseDAOSet(dao);
    }

    function setOperator(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isOperator[account] = allowed;
        emit OperatorSet(account, allowed);
    }

    function pause() external onlyPauseDAO {
        _pause();
    }

    function unpause() external onlyPauseDAO {
        _unpause();
    }

    function createMarket(uint256 marketId, address oracle, uint256 adlEquityThreshold) external onlyOwner {
        if (oracle == address(0)) revert InvalidAddress();
        if (markets[marketId].exists) revert MarketExists();
        markets[marketId] = PerpsTypes.Market({
            exists: true,
            paused: false,
            oracle: oracle,
            adlEquityThreshold: adlEquityThreshold,
            systemPosition: 0
        });
        emit MarketCreated(marketId, oracle, adlEquityThreshold);
    }

    function setMarketPaused(uint256 marketId, bool paused_) external onlyOwner {
        _requireMarket(marketId);
        markets[marketId].paused = paused_;
        emit MarketPaused(marketId, paused_);
    }

    function setAdlEquityThreshold(uint256 marketId, uint256 threshold) external onlyOwner {
        _requireMarket(marketId);
        markets[marketId].adlEquityThreshold = threshold;
        emit AdlThresholdSet(marketId, threshold);
    }

    function setOracle(uint256 marketId, address oracle) external onlyOwner {
        if (oracle == address(0)) revert InvalidAddress();
        _requireMarket(marketId);
        markets[marketId].oracle = oracle;
        emit OracleSet(marketId, oracle);
    }

    function seedSystem(uint256 marketId, uint256 amount) external {
        _requireMarket(marketId);
        if (amount == 0) revert ZeroAmount();
        vault.transferUserToSystem(msg.sender, marketId, amount);
        emit SystemSeeded(marketId, amount);
    }

    /// @notice Move free vault collateral into this market's Balance.margin.
    function addMargin(uint256 marketId, uint256 amount) external whenNotPaused nonReentrant {
        _requireMarket(marketId);
        if (amount == 0) revert ZeroAmount();
        vault.adjustUserBalance(msg.sender, -int256(amount));
        _creditMargin(msg.sender, marketId, int256(amount));
        emit MarginAdded(msg.sender, marketId, amount);
    }

    /// @notice Move Balance.margin back to free vault collateral.
    /// @dev v0: allowed whenever remaining margin stays non-negative (no full maintenance check yet).
    function removeMargin(uint256 marketId, uint256 amount) external whenNotPaused nonReentrant {
        _requireMarket(marketId);
        if (amount == 0) revert ZeroAmount();
        PerpsTypes.Balance storage b = balances[msg.sender][marketId];
        if (b.margin < int256(amount)) revert InsufficientMargin();
        b.margin -= int256(amount);
        vault.adjustUserBalance(msg.sender, int256(amount));
        emit MarginRemoved(msg.sender, marketId, amount);
    }

    function settleTrades(PerpsTypes.TradeSettlement[] calldata settlements)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        uint256 length = settlements.length;
        for (uint256 i; i < length;) {
            _settleTrades(settlements[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Liquidate user into S: seize Balance.margin into system cash, merge position into S.
    function liquidate(uint256 marketId, address user)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        PerpsTypes.Market storage m = _market(marketId);
        if (m.paused) revert MarketIsPaused();

        PerpsTypes.Balance memory userBal = balances[user][marketId];
        if (userBal.position == 0) revert NothingToLiquidate();

        uint256 mark = IPerpsOracle(m.oracle).getPrice(marketId);
        uint256 seized;
        if (userBal.margin > 0) {
            seized = uint256(userBal.margin);
            vault.creditSystem(marketId, seized);
        }
        m.systemPosition += userBal.position;
        _clearBalance(user, marketId);

        emit Liquidated(marketId, user, userBal.position, seized, mark);
    }

    /// @notice ADL: force trade user against S inventory at mark when S equity ≤ threshold.
    function executeAdl(uint256 marketId, address user, uint256 amount, bool userIsBuy)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        PerpsTypes.Market storage m = _market(marketId);
        if (m.paused) revert MarketIsPaused();

        uint256 mark = IPerpsOracle(m.oracle).getPrice(marketId);
        uint256 systemCash = vault.systemBalances(marketId);
        if (PerpsMath.systemEquity(systemCash, m.systemPosition, mark) > int256(m.adlEquityThreshold)) {
            revert AdlNotTriggered();
        }

        PerpsTypes.Balance memory userBal = balances[user][marketId];
        if (userBal.position == 0) revert NothingToLiquidate();

        PerpsTypes.Balance memory sysBal =
            PerpsTypes.Balance({margin: int256(systemCash), position: m.systemPosition});

        // User is taker vs system as maker.
        (PerpsTypes.Balance memory newUser, PerpsTypes.Balance memory newSys) =
            PerpsMath.applyTrade(userBal, sysBal, amount, mark, userIsBuy);

        _setBalance(user, marketId, newUser);
        _syncSystem(marketId, newSys);
        _tryReturnMarginToVault(user, marketId);

        emit AdlExecuted(marketId, user, userIsBuy ? int256(amount) : -int256(amount), mark);
    }

    function getBalance(address user, uint256 marketId)
        external
        view
        returns (int256 margin, int256 position)
    {
        PerpsTypes.Balance memory b = balances[user][marketId];
        return (b.margin, b.position);
    }

    function getSystemAccount(uint256 marketId)
        external
        view
        returns (uint256 systemCash, int256 position, int256 equity_)
    {
        PerpsTypes.Market storage m = _market(marketId);
        uint256 mark = IPerpsOracle(m.oracle).getPrice(marketId);
        systemCash = vault.systemBalances(marketId);
        return (systemCash, m.systemPosition, PerpsMath.systemEquity(systemCash, m.systemPosition, mark));
    }

    function isAdlTriggered(uint256 marketId) external view returns (bool) {
        PerpsTypes.Market storage m = _market(marketId);
        uint256 mark = IPerpsOracle(m.oracle).getPrice(marketId);
        return PerpsMath.systemEquity(vault.systemBalances(marketId), m.systemPosition, mark)
            <= int256(m.adlEquityThreshold);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _settleTrades(PerpsTypes.TradeSettlement calldata s) private {
        uint256 length = s.makerOrders.length;
        if (length == 0 || length != s.makerSignatures.length || length != s.fulfillments.length) {
            revert InvalidFill();
        }

        PerpsTypes.Order calldata takerOrder = s.takerOrder;
        PerpsTypes.Market storage m = _market(takerOrder.marketId);
        if (m.paused) revert MarketIsPaused();

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

            _consumeFill(makerOrder, s.makerSignatures[i], fill.amount);
            takerFilled += fill.amount;

            uint256 marketId = takerOrder.marketId;
            uint256 makerMargin = _lockFillMargin(makerOrder, fill.amount);
            uint256 takerMargin = _lockFillMargin(takerOrder, fill.amount);

            PerpsTypes.Balance memory makerBal = balances[makerOrder.trader][marketId];
            PerpsTypes.Balance memory takerBal = balances[takerOrder.trader][marketId];

            (PerpsTypes.Balance memory newTaker, PerpsTypes.Balance memory newMaker) =
                PerpsMath.applyTrade(takerBal, makerBal, fill.amount, fill.priceX18, takerOrder.isBuy);

            _setBalance(makerOrder.trader, marketId, newMaker);
            _setBalance(takerOrder.trader, marketId, newTaker);
            _tryReturnMarginToVault(makerOrder.trader, marketId);
            _tryReturnMarginToVault(takerOrder.trader, marketId);

            uint256 notional = (fill.amount * fill.priceX18) / PerpsTypes.BASE;
            uint256 makerFee = (notional * MAKER_FEE_NUMERATOR) / FEE_DENOMINATOR;
            uint256 takerFee = (notional * TAKER_FEE_NUMERATOR) / FEE_DENOMINATOR;
            vault.collectTradeFees(makerOrder.trader, makerFee, takerOrder.trader, takerFee);

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

    function _lockFillMargin(PerpsTypes.Order calldata order, uint256 fillAmount)
        private
        returns (uint256 toLock)
    {
        toLock = PerpsMath.fillMargin(order.margin, order.amount, fillAmount);
        if (toLock == 0) return toLock;
        vault.adjustUserBalance(order.trader, -int256(toLock));
        _creditMargin(order.trader, order.marketId, int256(toLock));
    }

    function _creditMargin(address user, uint256 marketId, int256 amount) private {
        balances[user][marketId].margin += amount;
    }

    /// @dev If position is flat and margin > 0, return margin to free vault balance.
    function _tryReturnMarginToVault(address user, uint256 marketId) private {
        PerpsTypes.Balance storage b = balances[user][marketId];
        if (b.position != 0 || b.margin <= 0) return;
        uint256 amount = uint256(b.margin);
        b.margin = 0;
        vault.adjustUserBalance(user, int256(amount));
    }

    function _syncSystem(uint256 marketId, PerpsTypes.Balance memory sys) private {
        PerpsTypes.Market storage m = markets[marketId];
        m.systemPosition = sys.position;
        uint256 cash = vault.systemBalances(marketId);
        if (sys.margin >= 0) {
            uint256 target = uint256(sys.margin);
            if (target > cash) vault.creditSystem(marketId, target - cash);
            else if (target < cash) vault.debitSystem(marketId, cash - target);
        } else {
            // Underwater system: zero cash for v0.
            if (cash > 0) vault.debitSystem(marketId, cash);
        }
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
        if (digest.recover(signature) != order.trader) revert InvalidSignature();
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
