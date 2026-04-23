// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IGlobalSpotVault {
    function internalTransfer(
        address from,
        address to,
        address token,
        uint256 amount,
        uint256 fee
    ) external;
}

/// @title SpotExchange
/// @notice Matching engine for the Spot Orderbook protocol.
/// @dev
/// - Verifies EIP-712 signatures for Maker and Taker orders.
/// - Enforces price constraints and tracks filled makerAmount per order hash.
/// - Calls GlobalSpotVault to move user balances and accumulate protocol fees.
contract SpotExchange is Ownable {
    using ECDSA for bytes32;

    /// @notice EIP-712 domain separator.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Typehash for the SpotOrder struct.
    bytes32 public constant SPOT_ORDER_TYPEHASH = keccak256("SpotOrder(address maker,address makerToken,address takerToken,uint256 makerAmount,uint256 takerAmount,uint256 expiry,uint256 salt)");

    /// @notice Fee rate constants: 0.2% = 20 / 10000.
    uint256 public constant FEE_NUMERATOR = 20;
    uint256 public constant FEE_DENOMINATOR = 10000;

    /// @notice GlobalSpotVault used for balance movements.
    /// @dev Set once by owner after deployment to avoid constructor circular dependency.
    IGlobalSpotVault public vault;

    /// @notice Addresses allowed to call `settleTrades`.
    mapping(address => bool) public allowedKeys;

    /// @notice Tracks cumulative filled makerAmount per order hash.
    mapping(bytes32 => uint256) public filledAmount;

    /// @notice Emitted when an address is added to allowedKeys.
    event DAOAdded(address indexed addr);

    /// @notice Emitted when an address is removed from allowedKeys.
    event DAORemoved(address indexed addr);

    /// @notice Emitted for each maker-taker fill in `settleTrades`.
    event TradeExecuted(
        address indexed maker,
        address indexed taker,
        bytes32 makerOrderHash,
        bytes32 takerOrderHash,
        address makerToken,
        address takerToken,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 makerFee,
        uint256 takerFee
    );

    /// @notice Emitted when the vault is set.  
    event VaultSet(address indexed vault);

    error NotAllowedKey();
    error OrderExpired();
    error MakerPriceInvalid();
    error TakerPriceInvalid();
    error MakerOverfilled();
    error TakerOverfilled();
    error TokenPairMismatch();
    error InvalidAddress();
    error VaultNotSet();
    error VaultAlreadySet();

    struct SpotOrder {
        address maker;
        address makerToken;
        address takerToken;
        uint256 makerAmount;
        uint256 takerAmount;
        uint256 expiry;
        uint256 salt;
    }

    struct Fulfillment {
        uint256 makerAmount;
        uint256 takerAmount;
    }

    modifier onlyAllowedKey() {
        if (!allowedKeys[msg.sender]) revert NotAllowedKey();
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
                keccak256(bytes("SpotExchange")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    /// @notice Sets the GlobalSpotVault address (one-time action).
    /// @dev Needed to avoid deployment-time circular dependency with the vault constructor.
    function setVault(address vault_) external onlyOwner {
        vault = IGlobalSpotVault(vault_);
        emit VaultSet(vault_);
    }

    /// @notice Adds an address to the set of allowedKeys.
    function addDAO(address addr) external onlyOwner {
        allowedKeys[addr] = true;
        emit DAOAdded(addr);
    }

    /// @notice Removes an address from the set of allowedKeys.
    function removeDAO(address addr) external onlyOwner {
        allowedKeys[addr] = false;
        emit DAORemoved(addr);
    }

    /// @notice Settles a batch of trades between one taker order and multiple maker orders.
    /// @dev
    /// - Verifies EIP-712 signatures for taker and each maker.
    /// - Enforces price constraints and non-overfilling per order hash.
    /// - Computes fees for both sides and calls the vault for transfers.
    function settleTrades(
        SpotOrder calldata takerOrder,
        bytes calldata takerSignature,
        SpotOrder[] calldata makerOrders,
        bytes[] calldata makerSignatures,
        Fulfillment[] calldata fulfillments
    ) external onlyAllowedKey {
        uint256 length = makerOrders.length;
        require(length == makerSignatures.length && length == fulfillments.length,"length mismatch");

        // Verify taker signature and expiry.
        _verifyOrder(takerOrder, takerSignature);

        // Sum actual maker/taker amounts for the taker-side price check.
        uint256 totalMakerAmount;
        uint256 totalTakerAmount;

        // Compute taker order hash.
        bytes32 takerHash = _hashOrder(takerOrder);

        for (uint256 i; i < length; ) {
            SpotOrder calldata makerOrder = makerOrders[i];
            Fulfillment calldata f = fulfillments[i];

            // Verify maker signature and expiry.
            _verifyOrder(makerOrder, makerSignatures[i]);

            // Verify token pair matches.
            if (makerOrder.makerToken != takerOrder.takerToken|| makerOrder.takerToken != takerOrder.makerToken) {
                revert TokenPairMismatch();
            }

            // Validate fill against remaining makerAmount.
            bytes32 makerHash = _hashOrder(makerOrder);
            uint256 prevFilled = filledAmount[makerHash];
            uint256 newFilled = prevFilled + f.makerAmount;
            if (newFilled > makerOrder.makerAmount) revert MakerOverfilled();
            filledAmount[makerHash] = newFilled;

            // Price constraint for this maker using its own fulfillment.
            if (f.takerAmount * makerOrder.makerAmount < f.makerAmount * makerOrder.takerAmount) {
                revert MakerPriceInvalid();
            }

            totalMakerAmount += f.makerAmount;
            totalTakerAmount += f.takerAmount;

            // Maker fee: on takerToken they receive.
            uint256 makerFee = (f.takerAmount * FEE_NUMERATOR) / FEE_DENOMINATOR;

            // Taker fee: on makerToken they receive.
            uint256 takerFee = (f.makerAmount * FEE_NUMERATOR) / FEE_DENOMINATOR;

            // Maker gives makerToken to taker.
            vault.internalTransfer(
                makerOrder.maker,
                takerOrder.maker,
                makerOrder.makerToken,
                f.makerAmount - takerFee,
                takerFee
            );

            // Taker gives takerToken to maker.
            vault.internalTransfer(
                takerOrder.maker,
                makerOrder.maker,
                takerOrder.makerToken,
                f.takerAmount - makerFee,
                makerFee
            );

            emit TradeExecuted(
                makerOrder.maker,
                takerOrder.maker,
                makerHash,
                takerHash,
                makerOrder.makerToken,
                takerOrder.makerToken,
                f.makerAmount,
                f.takerAmount,
                makerFee,
                takerFee
            );

            unchecked {
                ++i;
            }
        }

        // Verify taker order price constraint.
        uint256 prevTakerFilled = filledAmount[takerHash];
        uint256 newTakerFilled = prevTakerFilled + totalTakerAmount;
        if (newTakerFilled > takerOrder.makerAmount) revert TakerOverfilled();
        filledAmount[takerHash] = newTakerFilled;

        // Price constraint for taker order using aggregated actual amounts.
        if (totalMakerAmount * takerOrder.makerAmount < totalTakerAmount * takerOrder.takerAmount) {
            revert TakerPriceInvalid();
        }
    }

    /// @notice Computes the EIP-712 struct hash for a SpotOrder.
    function _hashOrder(SpotOrder calldata order) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    SPOT_ORDER_TYPEHASH,
                    order.maker,
                    order.makerToken,
                    order.takerToken,
                    order.makerAmount,
                    order.takerAmount,
                    order.expiry,
                    order.salt
                )
            );
    }

    /// @notice Verifies an order's signature and expiry.
    function _verifyOrder(SpotOrder calldata order, bytes calldata signature) internal view {
        if (block.timestamp > order.expiry) revert OrderExpired();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _hashOrder(order))
        );
        address recovered = digest.recover(signature);
        require(recovered == order.maker, "bad sig");
    }
}

