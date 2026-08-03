// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPerpsPositionView} from "./interfaces/IPerpsPositionView.sol";

/// @title GlobalPerpsVault
/// @notice Shared Perps custody for ARC native USDC (not an ERC20 / not WUSDC).
/// @dev User and per-market system balances are ledger entries over the contract's native balance.
///      Settlement between accounts is accounting-only; only deposit/withdraw move native USDC.
contract GlobalPerpsVault is Ownable, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    address public exchange;
    address public withdrawDAO;
    address public pauseDAO;

    struct PendingExchangeUpdate {
        address pendingExchange;
        uint256 exchangeActionTimestamp;
    }

    PendingExchangeUpdate public pendingExchangeUpdate;

    mapping(address => uint256) public balances;
    mapping(uint256 => uint256) public systemBalances;
    mapping(address => mapping(uint256 => bool)) public usedWithdrawOrder;
    mapping(address => uint256) public forcedWithdrawalRequestedAt;

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address user,uint256 orderId,uint256 amount)");

    event WithdrawDAOSet(address indexed dao);
    event PauseDAOSet(address indexed dao);
    event ExchangeUpdateProposed(address indexed proposedExchange, uint256 executableAt);
    event ExchangeUpdated(address indexed previousExchange, address indexed newExchange);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 orderId);
    event ForcedWithdrawalRequested(address indexed user);
    event ForcedWithdrawalExecuted(address indexed user, uint256 amount);
    event SystemCredited(uint256 indexed marketId, uint256 amount);
    event SystemDebited(uint256 indexed marketId, uint256 amount);
    event UserBalanceAdjusted(address indexed user, int256 delta);

    error NotExchange();
    error NotWithdrawDAO();
    error NotPauseDAO();
    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientSystemBalance();
    error WithdrawOrderAlreadyUsed();
    error ForcedWithdrawalTooEarly();
    error HasOpenPosition();
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

    /// @notice Deposit ARC native USDC; credits the caller's free collateral.
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
    /// @dev Reverts if the user still has an open perps position.
    function forcedWithdrawal() external nonReentrant {
        if (IPerpsPositionView(exchange).hasOpenPosition(msg.sender)) revert HasOpenPosition();

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

    /// @notice Move user free collateral into per-market system cash (e.g. liquidation seize).
    function transferUserToSystem(address user, uint256 marketId, uint256 amount) external onlyExchange {
        if (amount == 0) return;
        if (balances[user] < amount) revert InsufficientBalance();
        balances[user] -= amount;
        systemBalances[marketId] += amount;
        emit SystemCredited(marketId, amount);
    }

    /// @notice Pay user from per-market system cash (e.g. profitable close).
    function transferSystemToUser(address user, uint256 marketId, uint256 amount) external onlyExchange {
        if (amount == 0) return;
        if (systemBalances[marketId] < amount) revert InsufficientSystemBalance();
        systemBalances[marketId] -= amount;
        balances[user] += amount;
        emit SystemDebited(marketId, amount);
    }

    /// @notice Credit system cash without debiting a user (paired with user loss accounting).
    function creditSystem(uint256 marketId, uint256 amount) external onlyExchange {
        if (amount == 0) return;
        systemBalances[marketId] += amount;
        emit SystemCredited(marketId, amount);
    }

    /// @notice Adjust user free balance by signed delta (loss debit / residual credit).
    function adjustUserBalance(address user, int256 delta) external onlyExchange {
        if (delta == 0) return;
        if (delta > 0) {
            balances[user] += uint256(delta);
        } else {
            uint256 amt = uint256(-delta);
            if (balances[user] < amt) revert InsufficientBalance();
            balances[user] -= amt;
        }
        emit UserBalanceAdjusted(user, delta);
    }

    function _payout(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayoutFailed();
    }
}
