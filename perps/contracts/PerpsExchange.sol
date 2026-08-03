// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IPerpsOracle} from "./interfaces/IPerpsOracle.sol";
import {IPerpsPositionView} from "./interfaces/IPerpsPositionView.sol";
import {PerpsTypes} from "./libraries/PerpsTypes.sol";
import {PerpsMath} from "./libraries/PerpsMath.sol";
import {GlobalPerpsVault} from "./GlobalPerpsVault.sol";

/// @title PerpsExchange
/// @notice Multi-market perpetual settlement: operator-submitted fills, system account S,
///         liquidation into S, and ADL against S when equity hits a fixed threshold.
contract PerpsExchange is Ownable, Pausable, ReentrancyGuard, IPerpsPositionView {
    using ECDSA for bytes32;
    using PerpsMath for PerpsTypes.Position;

    GlobalPerpsVault public vault;
    address public pauseDAO;

    mapping(address => bool) public isOperator;
    mapping(uint256 => PerpsTypes.Market) public markets;
    mapping(address => mapping(uint256 => PerpsTypes.Position)) public positions;
    /// @dev Number of markets with non-zero size for `hasOpenPosition` fast path.
    mapping(address => uint256) public openMarketCount;

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,uint256 marketId,uint256 amount,uint256 priceX18,bool isBuy,uint256 nonce,uint256 expiry)"
    );

    /// @notice Cumulative filled base amount per EIP-712 order hash (Spot / dYdX style).
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
        bool takerIsBuy
    );
    event Liquidated(
        uint256 indexed marketId, address indexed user, int256 size, uint256 marginSeized, uint256 markPriceX18
    );
    event AdlExecuted(
        uint256 indexed marketId, address indexed user, int256 closedSize, uint256 priceX18, int256 realizedPnl
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
    error InsufficientSystemCash();
    error AdlNotTriggered();
    error NothingToLiquidate();
    error InvalidFill();
    error PriceInvalid();
    error OrderMismatch();

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
            systemPosition: PerpsTypes.Position(0, 0)
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

    /// @notice Donate caller's free collateral into this market's system account S.
    function seedSystem(uint256 marketId, uint256 amount) external {
        _requireMarket(marketId);
        if (amount == 0) revert ZeroAmount();
        vault.transferUserToSystem(msg.sender, marketId, amount);
        emit SystemSeeded(marketId, amount);
    }

    /// @notice Operator-submitted fill batch. Each fill requires maker + taker EIP-712 order signatures.
    function settleTrades(PerpsTypes.TradeFill[] calldata fills, PerpsTypes.FillAuth[] calldata auths)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        uint256 n = fills.length;
        if (n == 0 || auths.length != n) revert InvalidFill();

        for (uint256 i = 0; i < n; i++) {
            _settleOne(fills[i], auths[i]);
        }
    }

    /// @notice Liquidate `user` into system account S. Seizes `marginToSeize` free collateral into S cash.
    /// @dev Does not verify user signature. Operator / AllowedKey only.
    function liquidate(uint256 marketId, address user, uint256 marginToSeize)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        PerpsTypes.Market storage m = _market(marketId);
        if (m.paused) revert MarketIsPaused();

        PerpsTypes.Position memory userPos = positions[user][marketId];
        if (userPos.size == 0) revert NothingToLiquidate();

        uint256 mark = IPerpsOracle(m.oracle).getPrice(marketId);

        if (marginToSeize > 0) {
            vault.transferUserToSystem(user, marketId, marginToSeize);
        }

        m.systemPosition = PerpsMath.mergePositions(m.systemPosition, userPos);
        _clearPosition(user, marketId);

        emit Liquidated(marketId, user, userPos.size, marginToSeize, mark);
    }

    /// @notice Force-close (part of) a winning position against S when S equity ≤ threshold.
    /// @param signedAmount Absolute trade from user perspective: positive = buy, negative = sell.
    ///        Must reduce user's position toward flat (ADL engine chooses opposite side of inventory).
    function executeAdl(uint256 marketId, address user, int256 signedAmount)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        if (signedAmount == 0) revert ZeroAmount();
        PerpsTypes.Market storage m = _market(marketId);
        if (m.paused) revert MarketIsPaused();

        uint256 mark = IPerpsOracle(m.oracle).getPrice(marketId);
        uint256 systemCash = vault.systemBalances(marketId);
        int256 equity = PerpsMath.systemEquity(systemCash, m.systemPosition, mark);
        if (equity > int256(m.adlEquityThreshold)) revert AdlNotTriggered();

        PerpsTypes.Position memory userPos = positions[user][marketId];
        if (userPos.size == 0) revert NothingToLiquidate();

        // User fill at mark; S takes the opposite. User PnL settles vs S cash (zero-sum for S).
        (PerpsTypes.Position memory newUserPos, int256 userPnl) = PerpsMath.applyFill(userPos, signedAmount, mark);
        (PerpsTypes.Position memory newSysPos,) = PerpsMath.applyFill(m.systemPosition, -signedAmount, mark);

        _settleUserPnl(user, marketId, userPnl, true);
        _setPosition(user, marketId, newUserPos);
        m.systemPosition = newSysPos;

        emit AdlExecuted(marketId, user, signedAmount, mark, userPnl);
    }

    function hasOpenPosition(address user) external view returns (bool) {
        return openMarketCount[user] > 0;
    }

    function getPosition(address user, uint256 marketId) external view returns (int256 size, uint256 entryPriceX18) {
        PerpsTypes.Position memory p = positions[user][marketId];
        return (p.size, p.entryPriceX18);
    }

    function getSystemAccount(uint256 marketId)
        external
        view
        returns (uint256 systemCash, int256 size, uint256 entryPriceX18, int256 equity)
    {
        PerpsTypes.Market storage m = _market(marketId);
        uint256 mark = IPerpsOracle(m.oracle).getPrice(marketId);
        systemCash = vault.systemBalances(marketId);
        return (
            systemCash,
            m.systemPosition.size,
            m.systemPosition.entryPriceX18,
            PerpsMath.systemEquity(systemCash, m.systemPosition, mark)
        );
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

    function _settleOne(PerpsTypes.TradeFill calldata fill, PerpsTypes.FillAuth calldata auth) private {
        PerpsTypes.Market storage m = _market(fill.marketId);
        if (m.paused) revert MarketIsPaused();
        if (fill.amount == 0 || fill.priceX18 == 0) revert InvalidFill();
        if (fill.maker == fill.taker) revert InvalidFill();

        _matchOrderToFill(auth.makerOrder, fill.maker, fill.marketId, !fill.takerIsBuy);
        _matchOrderToFill(auth.takerOrder, fill.taker, fill.marketId, fill.takerIsBuy);

        _fillOrder(auth.makerOrder, fill.amount, fill.priceX18, auth.makerSig);
        _fillOrder(auth.takerOrder, fill.amount, fill.priceX18, auth.takerSig);

        int256 takerSizeChange = fill.takerIsBuy ? int256(fill.amount) : -int256(fill.amount);
        int256 makerSizeChange = -takerSizeChange;

        (PerpsTypes.Position memory newMaker, int256 makerPnl) =
            PerpsMath.applyFill(positions[fill.maker][fill.marketId], makerSizeChange, fill.priceX18);
        (PerpsTypes.Position memory newTaker, int256 takerPnl) =
            PerpsMath.applyFill(positions[fill.taker][fill.marketId], takerSizeChange, fill.priceX18);

        _settleUserPnl(fill.maker, fill.marketId, makerPnl, false);
        _settleUserPnl(fill.taker, fill.marketId, takerPnl, false);

        _setPosition(fill.maker, fill.marketId, newMaker);
        _setPosition(fill.taker, fill.marketId, newTaker);

        emit TradeSettled(fill.marketId, fill.maker, fill.taker, fill.amount, fill.priceX18, fill.takerIsBuy);
    }

    /// @dev Profit paid from S cash; loss credited to S cash. If `allowHaircut`, profit is capped by available S cash.
    function _settleUserPnl(address user, uint256 marketId, int256 pnl, bool allowHaircut) private {
        if (pnl == 0) return;
        if (pnl > 0) {
            uint256 pay = uint256(pnl);
            uint256 cash = vault.systemBalances(marketId);
            if (cash < pay) {
                if (!allowHaircut) revert InsufficientSystemCash();
                pay = cash;
            }
            if (pay == 0) return;
            vault.transferSystemToUser(user, marketId, pay);
        } else {
            uint256 loss = uint256(-pnl);
            vault.adjustUserBalance(user, -int256(loss));
            vault.creditSystem(marketId, loss);
        }
    }

    function _matchOrderToFill(PerpsTypes.Order calldata order, address trader, uint256 marketId, bool isBuy)
        private
        pure
    {
        if (order.trader != trader || order.marketId != marketId || order.isBuy != isBuy) {
            revert OrderMismatch();
        }
    }

    /// @dev Verify EIP-712 signature, limit price, and accumulate fill against order hash.
    function _fillOrder(
        PerpsTypes.Order calldata order,
        uint256 fillAmount,
        uint256 fillPriceX18,
        bytes calldata signature
    ) private {
        if (block.timestamp > order.expiry) revert OrderExpired();
        if (order.amount == 0) revert ZeroAmount();

        // Buy limit: execution at or below limit. Sell limit: at or above.
        if (order.isBuy) {
            if (fillPriceX18 > order.priceX18) revert PriceInvalid();
        } else if (fillPriceX18 < order.priceX18) {
            revert PriceInvalid();
        }

        bytes32 orderHash = _hashOrder(order);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, orderHash));
        if (digest.recover(signature) != order.trader) revert InvalidSignature();

        uint256 newFilled = filledAmount[orderHash] + fillAmount;
        if (newFilled > order.amount) revert OrderOverfilled();
        filledAmount[orderHash] = newFilled;
    }

    function _hashOrder(PerpsTypes.Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.trader,
                order.marketId,
                order.amount,
                order.priceX18,
                order.isBuy,
                order.nonce,
                order.expiry
            )
        );
    }

    function _setPosition(address user, uint256 marketId, PerpsTypes.Position memory newPos) private {
        PerpsTypes.Position storage cur = positions[user][marketId];
        bool wasOpen = cur.size != 0;
        bool nowOpen = newPos.size != 0;
        cur.size = newPos.size;
        cur.entryPriceX18 = newPos.entryPriceX18;
        if (!wasOpen && nowOpen) openMarketCount[user] += 1;
        if (wasOpen && !nowOpen) openMarketCount[user] -= 1;
    }

    function _clearPosition(address user, uint256 marketId) private {
        _setPosition(user, marketId, PerpsTypes.Position(0, 0));
    }

    function _requireMarket(uint256 marketId) private view {
        if (!markets[marketId].exists) revert MarketNotFound();
    }

    function _market(uint256 marketId) private view returns (PerpsTypes.Market storage m) {
        m = markets[marketId];
        if (!m.exists) revert MarketNotFound();
    }
}
