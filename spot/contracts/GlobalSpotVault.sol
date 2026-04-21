// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal interface for WETH-style wrapped tokens (e.g. WUSDC).
interface IWrappedNativeLike {
    function withdraw(uint256 amount) external;
}

/// @title GlobalSpotVault
/// @notice Shared vault that custodies user assets and protocol fees for the Spot Orderbook.
/// @dev
/// - Holds user balances for whitelisted ERC20-like tokens (including WUSDC).
/// - Only the SpotExchange contract is allowed to perform internal transfers between users.
/// - Withdrawals are authorized off-chain by `withdrawDAO` using EIP-712 signatures.
/// - Fee claims are triggered and received by `claimFeeDAO`.
contract GlobalSpotVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    /// @notice Address of the SpotExchange contract allowed to call `internalTransfer`.
    address public immutable exchange;

    /// @notice Address of the wrapped USDC token implementing WETH-style deposit/withdraw.
    address public immutable wusdc;

    /// @notice Address whose EIP-712 signatures authorize withdrawals.
    address public withdrawDAO;

    /// @notice Address allowed to call and receive payout from `claimFees`.
    address public claimFeeDAO;

    /// @notice Address that governs the token whitelist.
    address public tokenWhitelistDAO;

    /// @notice Mapping of token => whether it is allowed to be deposited.
    mapping(address => bool) public isAllowedToken;

    /// @notice Per-user-per-token balances held by the vault.
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice Accumulated protocol fees per token.
    mapping(address => uint256) public tokenFees;

    /// @notice Tracks used withdrawal orderIds per user to prevent replay.
    mapping(address => mapping(uint256 => bool)) public usedWithdrawOrder;

    /// @notice Pending forced-withdrawal timestamp per user per token.
    /// 0 means no active forced-withdrawal request.
    mapping(address => mapping(address => uint256)) public forcedWithdrawalRequestedAt;

    /// @notice Emitted when the whitelist DAO is updated.
    event TokenWhitelistDAOSet(address indexed dao);

    /// @notice Emitted when the withdraw DAO is updated.
    event WithdrawDAOSet(address indexed dao);

    /// @notice Emitted when the claim-fee DAO is updated.
    event ClaimFeeDAOSet(address indexed dao);

    /// @notice Emitted when a token is added to the whitelist.
    event AllowedTokenAdded(address indexed token);

    /// @notice Emitted when a token is removed from the whitelist.
    event AllowedTokenRemoved(address indexed token);

    /// @notice Emitted when a user deposits tokens.
    event Deposited(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a user withdraws tokens.
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 orderId);

    /// @notice Emitted when a forced withdrawal is requested.
    event ForcedWithdrawalRequested(address indexed user, address indexed token);

    /// @notice Emitted when a forced withdrawal is executed.
    event ForcedWithdrawalExecuted(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when an internal transfer is executed.
    event InternalTransfer(
        address indexed from,
        address indexed to,
        address indexed token,
        uint256 amount,
        uint256 fee
    );

    error NotExchange();
    error NotTokenWhitelistDAO();
    error NotWithdrawDAO();
    error NotClaimFeeDAO();
    error TokenNotAllowed();
    error InvalidAddress();
    error InsufficientBalance();
    error WithdrawOrderAlreadyUsed();
    error NoForcedWithdrawalRecord();
    error ForcedWithdrawalTooEarly();
    error PayoutFailed();

    modifier onlyExchange() {
        if (msg.sender != exchange) revert NotExchange();
        _;
    }

    modifier onlyTokenWhitelistDAO() {
        if (msg.sender != tokenWhitelistDAO) revert NotTokenWhitelistDAO();
        _;
    }

    modifier onlyClaimFeeDAO() {
        if (msg.sender != claimFeeDAO) revert NotClaimFeeDAO();
        _;
    }

    /// @notice EIP-712 domain separator used for withdrawal signatures.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Typehash for the EIP-712 Withdraw struct.
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256("Withdraw(uint256 orderId,address token,uint256 amount)");

    /// @param _wusdc Address of the WUSDC token (must be non-zero).
    /// @param _exchange Address of the SpotExchange contract (must be non-zero).
    /// @dev The owner is set to the deployer (`msg.sender`). The exchange address is fixed
    ///      at construction time and cannot be changed afterwards.
    constructor(address _wusdc, address _exchange) Ownable(msg.sender) {
        if (_wusdc == address(0) || _exchange == address(0)) revert InvalidAddress();
        wusdc = _wusdc;
        exchange = _exchange;

        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GlobalSpotVault")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    /// @notice Sets the DAO address used for withdrawal EIP-712 signatures.
    function setWithdrawDAO(address dao) external onlyOwner {
        if (dao == address(0)) revert InvalidAddress();
        withdrawDAO = dao;
        emit WithdrawDAOSet(dao);
    }

    /// @notice Sets the DAO address allowed to call `claimFees`.
    function setClaimFeeDAO(address dao) external onlyOwner {
        if (dao == address(0)) revert InvalidAddress();
        claimFeeDAO = dao;
        emit ClaimFeeDAOSet(dao);
    }

    /// @notice Sets the DAO address that manages the token whitelist.
    function setTokenWhitelistDAO(address dao) external onlyOwner {
        if (dao == address(0)) revert InvalidAddress();
        tokenWhitelistDAO = dao;
        emit TokenWhitelistDAOSet(dao);
    }

    /// @notice Adds a token to the deposit whitelist.
    function addAllowedToken(address token) external onlyTokenWhitelistDAO {
        if (token == address(0)) revert InvalidAddress();
        isAllowedToken[token] = true;
        emit AllowedTokenAdded(token);
    }

    /// @notice Removes a token from the deposit whitelist.
    function removeAllowedToken(address token) external onlyTokenWhitelistDAO {
        isAllowedToken[token] = false;
        emit AllowedTokenRemoved(token);
    }

    /// @notice Deposits tokens into the vault, increasing the caller's balance.
    /// @dev For USDC, the frontend should wrap to WUSDC before calling this function.
    function deposit(address token, uint256 amount) external {
        if (!isAllowedToken[token]) revert TokenNotAllowed();
        if (amount == 0) return;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender][token] += amount;

        emit Deposited(msg.sender, token, amount);
    }

    /// @notice Withdraws tokens from the vault using an off-chain EIP-712 authorization.
    /// @dev
    /// - The message being signed has business fields (orderId, amount) combined with the
    ///   EIP-712 domain in `DOMAIN_SEPARATOR`.
    /// - The signature MUST be produced by `withdrawDAO`.
    /// - Funds are always transferred to `msg.sender`.
    function withdraw(
        uint256 orderId,
        address token,
        uint256 amount,
        bytes calldata signature
    ) external nonReentrant {
        if (usedWithdrawOrder[msg.sender][orderId]) revert WithdrawOrderAlreadyUsed();
        if (balances[msg.sender][token] < amount) revert InsufficientBalance();

        // Verify EIP-712 signature from `withdrawDAO` authorizing this withdrawal.
        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, orderId, token, amount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        address recovered = digest.recover(signature);
        if (recovered != withdrawDAO) revert NotWithdrawDAO();

        usedWithdrawOrder[msg.sender][orderId] = true;
        balances[msg.sender][token] -= amount;

        _payout(token, msg.sender, amount);

        emit Withdrawn(msg.sender, token, amount, orderId);
    }

    /// @notice Starts or completes a forced-withdrawal flow.
    /// @dev First call records only timestamp; a later call after 7 days withdraws full balance.
    function forcedWithdrawal(address token) external nonReentrant {
        uint256 requestedAt = forcedWithdrawalRequestedAt[msg.sender][token];

        if (requestedAt == 0) {
            // First request: record timestamp.
            forcedWithdrawalRequestedAt[msg.sender][token] = block.timestamp;
            emit ForcedWithdrawalRequested(msg.sender, token);
        } else {
            if (block.timestamp < requestedAt + 7 days) {
                revert ForcedWithdrawalTooEarly();
            }
            uint256 withdrawAmount = balances[msg.sender][token];
            if (withdrawAmount == 0) revert InsufficientBalance();
            forcedWithdrawalRequestedAt[msg.sender][token] = 0;
            balances[msg.sender][token] -= withdrawAmount;

            _payout(token, msg.sender, withdrawAmount);

            emit ForcedWithdrawalExecuted(msg.sender, token, withdrawAmount);
        }
    }

    /// @notice Internal transfer used by the SpotExchange for settlement.
    /// @param from The address to debit.
    /// @param to The address to credit.
    /// @param token The token being moved.
    /// @param amount The amount transferred from `from` to `to`.
    /// @param fee The fee amount transferred from `from` into the protocol fee pool.
    function internalTransfer(
        address from,
        address to,
        address token,
        uint256 amount,
        uint256 fee
    ) external onlyExchange {
        uint256 total = amount + fee;
        if (balances[from][token] < total) revert InsufficientBalance();

        balances[from][token] -= total;
        balances[to][token] += amount;
        tokenFees[token] += fee;

        emit InternalTransfer(from, to, token, amount, fee);
    }

    /// @notice Claims accumulated protocol fees for a given token to `claimFeeDAO`.
    /// @dev Callable only by `claimFeeDAO` (configured by `owner` via `setClaimFeeDAO`).
    function claimFees(address token) external onlyClaimFeeDAO nonReentrant {
        uint256 amount = tokenFees[token];
        if (amount == 0) return;
        tokenFees[token] = 0;
        _payout(token, msg.sender, amount);
    }

    /// @dev Pays out `amount` of `token` to `to`.
    /// - For WUSDC: unwrap via WETH-style `withdraw(amount)` and forward the resulting native value.
    /// - For ERC20: transfer token directly.
    function _payout(address token, address to, uint256 amount) internal {
        if (token == wusdc) {
            // Unwrap to the chain's native asset (ARC native is USDC per spec) and forward to receiver.
            IWrappedNativeLike(token).withdraw(amount);
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert PayoutFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Accept native asset payouts from WUSDC unwraps.
    receive() external payable {}
}

