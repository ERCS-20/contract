## Tech stack

- **Solidity** 0.8.18 (`viaIR`, optimizer enabled)  
- **Hardhat** + **@nomicfoundation/hardhat-toolbox**  
- **OpenZeppelin** (`Ownable`, `ERC20`, `Pausable`, `ReentrancyGuard`, etc.)  
- **Uniswap** `TransferHelper` (safe transfer helpers)

---

## Repository layout

```text
contracts/
  ercs20/
    ERCS20.sol          # Token + AMM swap and reserve logic
    ERCS20Factory.sol   # Deploy/register ERCS20; symbol uniqueness; pausable
    IERCS20.sol         # Events and interface
  test/
    MockERC20.sol       # Test ERC20
    ERCS20SellReentrant.sol  # Reentrancy test helper
test/
  token/ercs20/
    ERCS20.ts
    ERCS20Factory.ts
```

---

## Prerequisites

- Node.js (current LTS recommended)  
- npm or compatible package manager  

If you use the configured **`hardhat_local`** network (see `hardhat.config.ts`), add a root **`.env`** with `TEST0_PRIVATE_KEY` … `TEST10_PRIVATE_KEY` (never commit `.env`).

---

## Install & compile

```bash
npm install
npx hardhat compile
```

---

## Tests

```bash
npx hardhat test
# ERCS20 only
npx hardhat test test/token/ercs20/ERCS20.ts
# Factory only
npx hardhat test test/token/ercs20/ERCS20Factory.ts
```

Some factory tests use **`hardhat_setBalance`** to fund the factory with native balance (the factory has no `receive` / `fallback`).

---

## Vision vs. what this repo ships

| Narrative | In these contracts today |
|-----------|---------------------------|
| No zero-cost founder stock → swap quote via AMM | **Yes:** full initial supply in the pool; buy is `payable`; sell by transferring tokens to the contract. |
| Fees to company; liquidity as income | **Yes:** output-side fee + `withdrawAddr` / `withdrawFee` (call **`setWithdrawAddr`** first). |
| Non-dilutive financing + fee-revenue presale | **Product / extension:** needs revenue-rights tokens, sale/distribution contracts, or off-chain wrappers—not inside **`ERCS20.sol` alone**. |

- **ERCS20:** output-side fee ≈ **0.2% (1/500)**; the implementation uses the chain’s **native asset** as quote (often described as a USDC-native chain scenario in docs)—see source.  
- **ERCS20Factory:** `create` enforces unique `symbol`, increments `index`, transfers new token `owner`; `pause` / `unpause`; `safeTransferETH` / `safeTransfer` for owner recovery.

---

## License

Contract files are marked **SPDX-License-Identifier: MIT** in their headers.

---

## Disclaimer

Software is provided **“as is.”** It is not securities, investment, or legal advice. Perform your own security review, compliance work, and risk management before deployment or use.
