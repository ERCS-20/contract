## Spot Orderbook Protocol – Requirements & Design v3.0

This repository contains the smart-contract implementation of a Spot Orderbook protocol, built with Hardhat 3, Solidity, and TypeScript (`node:test` + viem).

### 1. System Architecture

- **GlobalSpotVault (GSV)**: Shared asset vault. Custodies all user tokens and protocol fees.
- **SpotExchange (SE)**: Matching engine. Verifies EIP‑712 orders from both sides, performs matching & fee calculation, and instructs GSV to move balances.

### 2. Contracts

#### 2.1 Responsibilities

##### 2.1.1 GlobalSpotVault (GSV)

- Custodies **ERCS‑20** tokens and **USDC** for users, maintaining on‑vault balances (consistent with or derivable from on‑chain balances).
- **Constructor**: Sets the SpotExchange (SE) contract address.
- **WUSDC handling**:  
  - Depositing native USDC: convert to WUSDC.  
  - Withdrawing WUSDC: convert back to native USDC.  
  - Claiming fees in WUSDC: convert to native USDC before sending out.  
  - The contract is deployed on the ARC chain where the native token is USDC.  
  - GSV stores a single `wusdc` token address and uses standard WETH‑style `deposit` / `withdraw` methods for wrapping/unwrapping.
- **Token whitelist governance**: Maintains an `isAllowedTokens` whitelist.
- **tokenWhitelistDAO**: Only `tokenWhitelistDAO` can manage the token whitelist; `setTokenWhitelistDAO` is `onlyOwner`.
- **withdrawDAO**: The address that signs withdrawal approvals. The EIP‑712 withdrawal signature must be produced by `withdrawDAO`.
- **Deposit**:  
  - Accepts assets from users and credits their vault balance.  
  - Only tokens in the **ERCS‑20 whitelist** are allowed to be deposited; non‑whitelisted tokens MUST revert.
- **Withdrawal**:  
  - User submits a withdrawal request to the backend.  
  - Backend verifies off‑chain, signs a withdrawal approval, and returns the signature to the user.  
  - User calls the vault with the signature to withdraw.  
  - `orderId` for a given user MUST be unique; upon successful withdrawal, this `orderId` is recorded as used.  
  - Funds MUST always be transferred only to `msg.sender` (the caller of the withdrawal).
- **Internal transfers**:  
  - Only SE can call `internalTransfer`.  
  - Used to move balances between users and between users and the fee account, according to the matching engine’s settlement instructions.
- **Fee accounting**:  
  - Trading fees are accumulated in `mapping(address => uint256) public tokenFees`.  
  - **Owner** can claim accumulated fees for a specific `token` to the owner.
- **Forced withdrawals**:  
  - On first forced‑withdrawal request, if the user has no existing record for that token, record only `requestedAt` (current block timestamp).  
  - On subsequent calls, if `block.timestamp >= requestedAt + 7 days`, the user can withdraw the **entire current vault balance** of that token and the record is cleared.  
  - After the first forced‑withdrawal request, all outstanding orders for this user are canceled off‑chain, and the user is no longer allowed to place new orders (enforced off‑chain).

##### 2.1.2 SpotExchange (SE)

- **Key whitelist governance**:  
  - Maintains an `AllowedKeys` set.  
  - Only addresses in `AllowedKeys` are allowed to call `settleTrades`.  
  - `addDAO` and `removeDAO` are `onlyOwner`.
- **Trade settlement**:
  - Verify one EIP‑712 signature for each side (Maker, Taker), ensuring the order content matches the signer.
  - Check `expiry` for each order to ensure it has not expired.
  - For the **last Maker order**, verify price compatibility:  
    `actualTakeAmount * makerOrder.makerAmount >= actualMakerAmount * makerOrder.takerAmount`.
  - For the **Taker order**, compute:  
    - `actualTakerAmount = sum(fulfillments[i].takerAmount)`  
    - `actualMakerAmount = sum(fulfillments[i].makerAmount)`  
    - Verify: `actualTakerAmount * takerOrder.makerAmount >= actualMakerAmount * takerOrder.takerAmount`.
  - Compute the EIP‑712 order hash for each order:  
    `hash = keccak256(SpotOrder EIP‑712 encoding)`.
  - For each order hash, read existing filled amount and ensure this settlement does not exceed `makerAmount`.  
    - `filledAmount[hash] += makerAmount` (measured in `makerAmount` units).
  - Compute Maker and Taker fees as specified in the fee logic; fees are deducted from the **token each side receives**.
  - Call GSV to perform the four‑legged settlement transfer:  
    - Maker → Taker, Taker → Maker, and both sides → fee account (via `internalTransfer`).

#### 2.2 Contract Interfaces

##### 2.2.1 GlobalSpotVault.sol

| Function | Description |
|---------|-------------|
| `deposit(address token, uint256 amount)` | User (or authorized party) deposits assets into the vault and increases their balance. Reverts if `token` is not whitelisted. |
| `withdraw(uint256 orderId, address token, uint256 amount)` | Withdraws assets from the vault and decreases the caller’s balance, using a valid EIP‑712 signature from `withdrawDAO`. Records `orderId` as used. |
| `forcedWithdrawal(address token)` | Forced withdrawal flow as described above; first call records timestamp, later call after 7 days releases the user’s full current balance for that token and clears the record. |
| `internalTransfer(address from, address to, address token, uint256 amount, uint256 fee)` | Only SE may call. Moves `amount` of `token` from `from` to `to`, and additionally moves `fee` of `token` from `from` into `tokenFees[token]`. |
| `claimFees(address token)` | Only **Owner**. Transfers accumulated `tokenFees[token]` to the owner. |
| `addAllowedToken(address addr)` | Only `tokenWhitelistDAO`. Adds a token to the deposit whitelist. |
| `removeAllowedToken(address addr)` | Only `tokenWhitelistDAO`. Removes a token from the whitelist. |
| `setTokenWhitelistDAO(address addr)` | Only **Owner**. Sets the token whitelist DAO address. |
| `setWithdrawDAO(address addr)` | Only **Owner**. Sets the `withdrawDAO` address used to verify withdrawal signatures. |

##### 2.2.2 SpotExchange.sol

| Function | Description |
|----------|-------------|
| `addDAO(address addr)` | Only **Owner**. Adds an address to `AllowedKeys`. |
| `removeDAO(address addr)` | Only **Owner**. Removes an address from `AllowedKeys`. |
| `settleTrades(SpotOrder calldata takerOrder, bytes calldata takerSignature, SpotOrder[] calldata makerOrders, bytes[] calldata makerSignatures, Fulfillment[] calldata fulfillments)` | Batch settlement entrypoint. Processes multiple matches in a single transaction. Must enforce `makerOrders.length == makerSignatures.length == fulfillments.length`. |

### 4. Technical Specification

#### 4.1 Permissions & Call Constraints

- **Vault authorization**: GSV only accepts `internalTransfer` calls from SE (e.g. via an `onlyExchange` modifier).
- **Signature verification**: SE MUST verify two EIP‑712 signatures per match (one Maker, one Taker) to ensure orders are authentic and unmodified.

#### 4.2 EIP‑712 Domain & Messages

**Domain fields (shared by all EIP‑712 messages in this protocol):**

- `string name` – DApp/protocol name (e.g. `"SpotOrderbook"`).
- `string version` – Protocol version (e.g. `"1"`).
- `uint256 chainId` – Chain ID (per EIP‑155, e.g. mainnet = 1) to prevent cross‑chain replay.
- `address verifyingContract` – The contract address performing signature verification (GSV for withdrawals, SE for orders), to prevent cross‑contract replay.
- `bytes32 salt` (optional) – Protocol‑level salt as a final anti‑collision measure.

**Order message (verified by SE):**

```solidity
struct SpotOrder {
    address maker;       // Signer address
    address makerToken;  // Token being sold
    address takerToken;  // Token being bought
    uint256 makerAmount; // Total amount of makerToken to sell
    uint256 takerAmount; // Total amount of takerToken to buy
    uint256 expiry;      // Expiry timestamp
    uint256 salt;        // Anti-collision nonce
}
```

**Withdrawal message (verified by GSV via withdrawDAO):**

Business fields:

- `uint256 orderId` – Business identifier, MUST be unique per user; used to prevent replay.
- `address token` – Token to withdraw; included in signature to prevent cross-token replay.
- `uint256 amount` – Amount to withdraw.

These fields are combined with the EIP‑712 domain described above. The signature MUST be produced by `withdrawDAO`; GSV enforces:

- `orderId` not used before, otherwise revert.
- Withdrawal amount transferred only to `msg.sender`.

#### 4.3 Settlement Fulfillment Structure

```solidity
struct Fulfillment {
    uint256 makerAmount; // Maker's actual amount of makerToken sold in this settlement
    uint256 takerAmount; // Maker's actual amount of takerToken received in this settlement
}
```

For each `makerOrders[i]`:

- Compute `orderHash = keccak256(SpotOrder EIP-712 encoding)`.
- Let `prevFilled = filledAmount[orderHash]` (measured in `makerAmount` units).
- Enforce `prevFilled + fulfillments[i].makerAmount <= makerOrders[i].makerAmount`, otherwise revert.
- Update `filledAmount[orderHash] = prevFilled + fulfillments[i].makerAmount`.

This allows multiple partial fills over time for the same order.

#### 4.4 Fee Logic

The protocol charges **both sides** (Maker and Taker) a fee on each trade, similar to Binance’s model.

**Fixed rates (current spec; implementation leaves room for different Maker/Taker rates):**

- Maker: `fee = amount * 20 / 10000` (0.2%)
- Taker: `fee = amount * 20 / 10000` (0.2%)

- Integer division is used (rounding down). Extremely small trades may result in `fee = 0`, which is acceptable.

**Deduction method:**

- For each side, the fee is deducted from the **token they receive** in the settlement:
  - Maker’s fee is deducted from the Maker’s received token (`takerToken`).
  - Taker’s fee is deducted from the Taker’s received token (`makerToken`).

#### 4.5 Safety & Performance

- **Conservation of assets**:  
  For every settlement, the total debits and credits across users plus fees MUST balance exactly.
- **Batch settlement**:  
  As per `settleTrades`, multiple matches are processed in a single transaction to amortize fixed gas costs (e.g. on L2). Implementation MUST ensure each per‑order settlement is independently correct and that failures revert the transaction according to the chosen policy (this spec assumes whole‑tx revert on any failure).
- **Non‑negative balances**:  
  Before any balance decrease, the contracts MUST enforce `require(balance >= amount)` (or equivalent checks) to prevent underflow or negative logical balances.

### 5. Local Development & Testing

```shell
npx hardhat test
npx hardhat test solidity
npx hardhat test nodejs
```

The `sepolia` network is configured in `hardhat.config.ts` using `SEPOLIA_RPC_URL` and `SEPOLIA_PRIVATE_KEY`.  
You can set `SEPOLIA_PRIVATE_KEY` via `npx hardhat keystore set SEPOLIA_PRIVATE_KEY` or as an environment variable.
