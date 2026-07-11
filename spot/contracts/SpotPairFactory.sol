// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IERCS20Factory {
    function ercs20s(address token) external view returns (bool);
}

interface IGlobalSpotVault {
    function addAllowedToken(address token) external;
    function wusdc() external view returns (address);
}

interface IERCS20 {
    function owner() external view returns (address);
    function usdcSeedAmount() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title SpotPairFactory
/// @notice Registers spot trading pairs and whitelists tokens on GlobalSpotVault.
/// @dev
/// - Public `create(baseToken)` registers ERCS20 / WUSDC pairs verified via ERCS20Factory.
/// - pairDAO-only `create(baseToken, quoteToken)` registers arbitrary pairs.
/// - This contract must be configured as `tokenWhitelistDAO` on GlobalSpotVault.
contract SpotPairFactory is Ownable {
    IERCS20Factory public immutable ercs20Factory;
    IGlobalSpotVault public immutable vault;

    address public pairDAO;
    uint256 public pairCount;
    mapping(bytes32 => bool) public spotPairs;

    /// @notice Emitted when a new spot pair is registered.
    event SpotPairCreated(address indexed baseToken, address indexed quoteToken, uint256 indexed pairIndex);

    /// @notice Emitted when the DAO address is updated.
    event PairDAOSet(address indexed pairDAO);

    /// @notice Emitted when the DAO address is removed.
    event PairDAORemoved(address indexed pairDAO);

    uint256 private constant OPENING_PRICE_SCALE = 1e18;
    uint256 private constant MAX_OPENING_PRICE = 1e16;

    error NotERCS20();
    /// @dev Only the ERCS20 token owner may call single-argument `create`.
    error NotTokenOwner();
    error NotPairDAO();
    error PairAlreadyExists();
    error InvalidAddress();
    error WusdcMismatch();
    error InvalidOpeningPrice();
    error OpeningPriceDecimalsTooHigh();
    error OpeningPriceTooHigh();

    modifier onlyPairDAO() {
        if (msg.sender != pairDAO) revert NotPairDAO();
        _;
    }


    /// @notice Constructor.
    /// @param ercs20Factory_ Address of the ERCS20Factory contract.
    /// @param vault_ Address of the GlobalSpotVault contract.
    /// @dev The owner is set to the deployer (`msg.sender`).  
    constructor(address ercs20Factory_, address vault_) Ownable(msg.sender) {
        if (ercs20Factory_ == address(0) || vault_ == address(0)) {
            revert InvalidAddress();
        }
        ercs20Factory = IERCS20Factory(ercs20Factory_);
        vault = IGlobalSpotVault(vault_);
    }

    /// @notice Sets the DAO address allowed to call two-argument `create`.
    function setPairDAO(address pairDAO_) external onlyOwner {
        if (pairDAO_ == address(0)) revert InvalidAddress();
        pairDAO = pairDAO_; 
        emit PairDAOSet(pairDAO_);
    }
    
    /// @notice Removes the DAO address allowed to call two-argument `create`.
    function removePairDAO(address pairDAO_) external onlyOwner {
        if (pairDAO_ == address(0)) revert InvalidAddress();
        pairDAO = address(0);
        emit PairDAORemoved(pairDAO_);
    }

    /// @notice Registers an ERCS20 token for spot trading against WUSDC.
    /// @param baseToken ERCS20 token address created by ERCS20Factory.
    function create(address baseToken) external {
        if (baseToken == address(0)) revert InvalidAddress();
        if (!ercs20Factory.ercs20s(baseToken)) revert NotERCS20();
        if (IERCS20(baseToken).owner() != msg.sender) revert NotTokenOwner();
        _validateErcs20OpeningPrice(baseToken);
        _registerPair(baseToken, vault.wusdc());
    }

    /// @notice Registers a spot pair with an arbitrary quote token. DAO only.
    function create(address baseToken, address quoteToken) external onlyPairDAO {
        if (baseToken == address(0) || quoteToken == address(0)) revert InvalidAddress();
        _registerPair(baseToken, quoteToken);
    }

    /// @notice Checks if a spot pair exists.
    /// @param baseToken The base token address.
    /// @param quoteToken The quote token address.
    /// @return True if the pair exists, false otherwise.
    function isPair(address baseToken, address quoteToken) external view returns (bool) {
        return spotPairs[_pairKey(baseToken, quoteToken)];
    }

    /// @notice Computes the key for a spot pair.
    /// @param baseToken The base token address.
    /// @param quoteToken The quote token address.
    /// @return The key for the spot pair.
    function _pairKey(address baseToken, address quoteToken) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseToken, quoteToken));
    }

    /// @notice Registers a spot pair.
    /// @param baseToken The base token address.
    /// @param quoteToken The quote token address.
    /// @dev Adds the base and quote tokens to the vault's allowed tokens and sets the pair as created.
    function _registerPair(address baseToken, address quoteToken) internal {
        bytes32 key = _pairKey(baseToken, quoteToken);
        if (spotPairs[key]) revert PairAlreadyExists();

        vault.addAllowedToken(baseToken);
        vault.addAllowedToken(quoteToken);

        spotPairs[key] = true;
        emit SpotPairCreated(baseToken, quoteToken, pairCount++);
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
