// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GlobalPerpsVault
/// @notice Shared Perps custody for ARC native USDC (not an ERC20 / not WUSDC).
/// @dev One free-collateral balance per user (cross-wallet UX). Positions live per marketId on the
///      exchange; open/close PnL credits/debits this shared balance. System cash remains per-market.
contract GlobalPerpsVault is Ownable, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    address public exchange;
    address public withdrawDAO;
    address public pauseDAO;
    address public claimFeeDAO;

    struct PendingExchangeUpdate {
        address pendingExchange;
        uint256 exchangeActionTimestamp;
    }

    PendingExchangeUpdate public pendingExchangeUpdate;

    /// @notice Shared free collateral per user (all markets).
    mapping(address => uint256) public balances;
    mapping(uint256 => uint256) public systemBalances;
    mapping(address => mapping(uint256 => bool)) public usedWithdrawOrder;
    mapping(address => uint256) public forcedWithdrawalRequestedAt;
    /// @notice Accumulated protocol trading fees (native USDC).
    uint256 public protocolFees;

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address user,uint256 orderId,uint256 amount)");

    event WithdrawDAOSet(address indexed dao);
    event PauseDAOSet(address indexed dao);
    event ClaimFeeDAOSet(address indexed dao);
    event ExchangeUpdateProposed(address indexed proposedExchange, uint256 executableAt);
    event ExchangeUpdated(address indexed previousExchange, address indexed newExchange);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 orderId);
    event ForcedWithdrawalRequested(address indexed user);
    event ForcedWithdrawalExecuted(address indexed user, uint256 amount);
    event SystemSeeded(uint256 indexed marketId, address indexed from, uint256 amount);
    event SystemWithdrawn(uint256 indexed marketId, address indexed to, uint256 amount);
    event SystemCredited(uint256 indexed marketId, uint256 amount);
    event SystemDebited(uint256 indexed marketId, uint256 amount);
    event UserBalanceAdjusted(address indexed user, int256 delta);
    event FeesClaimed(address indexed to, uint256 amount);

    error NotExchange();
    error NotWithdrawDAO();
    error NotPauseDAO();
    error NotClaimFeeDAO();
    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientSystemBalance();
    error WithdrawOrderAlreadyUsed();
    error ForcedWithdrawalTooEarly();
    error NoPendingExchangeUpdate();
    error ExchangeUpdateTooEarly();
    error ZeroAmount();
    error PayoutFailed();

    modifier onlyExchange() {
        if (msg.sender != exchange) revert NotExchange();
        _;
    }

    modifier onlyPauseDAO() {
        if (msg.sender != pauseDAO) revert NotPauseDAO();
        _;
    }

    modifier onlyClaimFeeDAO() {
        if (msg.sender != claimFeeDAO) revert NotClaimFeeDAO();
        _;
    }

    constructor(address _exchange) Ownable(msg.sender) {
        if (_exchange == address(0)) revert InvalidAddress();
        exchange = _exchange;

        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GlobalPerpsVault")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    function setWithdrawDAO(address dao) external onlyOwner {
        if (dao == address(0)) revert InvalidAddress();
        withdrawDAO = dao;
        emit WithdrawDAOSet(dao);
    }

    function setPauseDAO(address dao) external onlyOwner {
        if (dao == address(0)) revert InvalidAddress();
        pauseDAO = dao;
        emit PauseDAOSet(dao);
    }

    function setClaimFeeDAO(address dao) external onlyOwner {
        if (dao == address(0)) revert InvalidAddress();
        claimFeeDAO = dao;
        emit ClaimFeeDAOSet(dao);
    }

    function proposeExchangeUpdate(address newExchange) external onlyOwner {
        if (newExchange == address(0)) revert InvalidAddress();
        uint256 executableAt = block.timestamp + 7 days;
        pendingExchangeUpdate =
            PendingExchangeUpdate({pendingExchange: newExchange, exchangeActionTimestamp: executableAt});
        emit ExchangeUpdateProposed(newExchange, executableAt);
    }

    function applyExchangeUpdate() external onlyOwner {
        PendingExchangeUpdate memory p = pendingExchangeUpdate;
        if (p.pendingExchange == address(0)) revert NoPendingExchangeUpdate();
        if (block.timestamp < p.exchangeActionTimestamp) revert ExchangeUpdateTooEarly();

        address previous = exchange;
        exchange = p.pendingExchange;
        pendingExchangeUpdate = PendingExchangeUpdate(address(0), 0);
        emit ExchangeUpdated(previous, exchange);
    }

    function pause() external onlyPauseDAO {
        _pause();
    }

    function unpause() external onlyPauseDAO {
        _unpause();
    }

    /// @notice Deposit ARC native USDC into the caller's shared free collateral.
    function deposit() external payable whenNotPaused {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 orderId, uint256 amount, bytes calldata signature) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (usedWithdrawOrder[msg.sender][orderId]) revert WithdrawOrderAlreadyUsed();
        if (balances[msg.sender] < amount) revert InsufficientBalance();

        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, msg.sender, orderId, amount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (digest.recover(signature) != withdrawDAO) revert NotWithdrawDAO();

        usedWithdrawOrder[msg.sender][orderId] = true;
        balances[msg.sender] -= amount;
        _payout(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, orderId);
    }

    /// @notice Request or execute forced withdrawal of full free balance after 7 days.
    /// @dev Only free vault balance; locked per-market margin is unaffected.
    function forcedWithdrawal() external nonReentrant {
        uint256 requestedAt = forcedWithdrawalRequestedAt[msg.sender];
        if (requestedAt == 0) {
            forcedWithdrawalRequestedAt[msg.sender] = block.timestamp;
            emit ForcedWithdrawalRequested(msg.sender);
            return;
        }

        if (block.timestamp < requestedAt + 7 days) revert ForcedWithdrawalTooEarly();

        uint256 amount = balances[msg.sender];
        forcedWithdrawalRequestedAt[msg.sender] = 0;
        if (amount == 0) return;

        balances[msg.sender] = 0;
        _payout(msg.sender, amount);
        emit ForcedWithdrawalExecuted(msg.sender, amount);
    }

    /// @notice Seed per-market system cash from the caller's free collateral.
    function seedSystem(uint256 marketId, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balances[msg.sender] < amount) revert InsufficientBalance();
        balances[msg.sender] -= amount;
        systemBalances[marketId] += amount;
        emit SystemSeeded(marketId, msg.sender, amount);
    }

    /// @notice Withdraw per-market system cash (e.g. after a market is delisted).
    function withdrawSystem(uint256 marketId, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        if (systemBalances[marketId] < amount) revert InsufficientSystemBalance();
        systemBalances[marketId] -= amount;
        _payout(to, amount);
        emit SystemWithdrawn(marketId, to, amount);
    }

    /// @notice Credit system cash without debiting a user (e.g. liquidation seize of Balance.margin).
    function creditSystem(uint256 marketId, uint256 amount) external onlyExchange {
        if (amount == 0) return;
        systemBalances[marketId] += amount;
        emit SystemCredited(marketId, amount);
    }

    /// @notice Debit system cash (ADL / sync).
    function debitSystem(uint256 marketId, uint256 amount) external onlyExchange {
        if (amount == 0) return;
        if (systemBalances[marketId] < amount) revert InsufficientSystemBalance();
        systemBalances[marketId] -= amount;
        emit SystemDebited(marketId, amount);
    }

    /// @notice Adjust user shared free balance by signed delta.
    function adjustUserBalance(address user, int256 delta) external onlyExchange {
        if (delta > 0) {
            balances[user] += uint256(delta);
        } else {
            uint256 amt = uint256(-delta);
            if (balances[user] < amt) revert InsufficientBalance();
            balances[user] -= amt;
        }
        emit UserBalanceAdjusted(user, delta);
    }

    /// @notice Debit maker/taker free balances into the protocol fee pool in one call.
    function collectTradeFees(address maker, uint256 makerFee, address taker, uint256 takerFee)
        external
        onlyExchange
    {
        if (balances[maker] < makerFee) revert InsufficientBalance();
        balances[maker] -= makerFee;
        if (balances[taker] < takerFee) revert InsufficientBalance();
        balances[taker] -= takerFee;

        protocolFees += (makerFee + takerFee);
    }

    /// @notice Claim accumulated protocol fees to `claimFeeDAO`.
    function claimFees() external onlyClaimFeeDAO nonReentrant {
        uint256 amount = protocolFees;
        if (amount == 0) return;
        protocolFees = 0;
        _payout(msg.sender, amount);
        emit FeesClaimed(msg.sender, amount);
    }

    function _payout(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayoutFailed();
    }
}
