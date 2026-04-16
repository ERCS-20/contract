# ERCS20 Smart Contracts · Liquidity Sovereignty Protocol

## One-line pitch

**Liquidity Sovereignty** is a smart-contract-native paradigm for equity-style financing and trading: **no zero-cost “founder stock.”** Anyone—including the founding team—who wants stock tokens from the pool must supply stablecoins (or an equivalent quote asset on-chain) under fixed rules. **Trading fees from secondary-market activity can accrue to the company (or a protocol treasury)** so ongoing liquidity becomes withdrawable revenue—**liquidity as income.**

This repository is a reference implementation of that paradigm: **Equity Request for Comments - Stock (20)** (**ERCS20**)—tokenized equity-like assets with an embedded **constant-product AMM** (Uniswap V2–style) for pricing and swaps.

---

## What ERCS-20 is designed to fix

ERCS-20 is not “yet another token.” It is a **tokenized stock primitive** that tries to solve several structural problems seen in common AMM pairs and orderbook listings:

1. **Bootstrapping a Uniswap pair requires real capital (initial price = locked cash)**  
   In a typical Uniswap-style launch, the initial price is set by depositing *real* quote liquidity into the pool—and that capital is effectively locked as liquidity. ERCS-20 introduces the idea of **virtual / accounting-based initial reserves** to anchor an initial price without forcing the issuer to permanently park that cash in a removable LP position.  
   The intended outcome is that the company can deploy capital more efficiently (e.g., into operations or even buying stock through the same on-chain mechanism), while still starting from a deterministic opening price.

2. **Approval phishing / allowance fraud on “buy” flows**  
   Many ERC20 purchase flows require users to `approve()` a spender, which is a common phishing vector. ERCS-20 is designed around a **no-allowance trading path**:
   - **Buy**: deposit the quote asset into the contract (native quote in this implementation), receive tokens.
   - **Sell**: send tokens into the contract (or call `sell()`), receive the quote asset out.
   This “transfer-in to trade” pattern reduces reliance on third-party allowances and helps mitigate approval-based scams at the UX layer.

3. **Liquidity removal rug-risk and “token goes to zero because liquidity disappears”**  
   In many AMMs, LPs can remove liquidity, and in many orderbooks there may be no market-making depth. Both can lead to catastrophic slippage and “effectively zero” price outcomes for holders. ERCS-20 aims to avoid that class of failure by making liquidity **contract-custodied**: the token inventory is minted to the contract at deployment, and there is **no LP position to withdraw** in the usual sense.  
   Users can only obtain tokens from the pool by depositing the quote asset according to the AMM curve, which is intended to keep pricing tied to an on-chain reserve system rather than removable third-party liquidity.

4. **Secondary-market trading generates revenue for venues, not for the issuer**  
   In traditional listings, most trading fees go to exchanges and intermediaries. ERCS-20 is designed so that a portion of each trade’s value (a protocol fee) can be accumulated and **withdrawn to a company/treasury-controlled address**, improving the issuer’s cash flow and long-term incentives (e.g., funding R&D and operations).  
   (In this repo’s current implementation, the output-side fee is ≈ **0.2% (1/500)**; see source.)

5. **Non-dilutive “re-financing” via preselling future fee revenue rights**  
   Instead of raising again through new-share issuance (dilution), the protocol narrative is to raise capital by **preselling rights to future trading-fee cash flows**. Existing holders keep their ownership percentages; new capital gains long-duration, fee-linked cash-flow exposure.  
   (This repo ships the fee accrual and withdrawal primitives; the presale/distribution layer is a product/extension module.)

## Design rationale

ERCS-20 combines a **tokenized stock primitive** with an AMM-style market and a fee-capture mechanism to realign incentives between issuers, traders, and long-term holders.

### 1) Liquidity sovereignty (why the market lives in the contract)

The core idea is to keep **pricing and fee capture** inside an on-chain rule set, rather than outsourcing value to third-party venues:

- **Contract-custodied inventory**: total supply is minted to the contract at deployment, so there is no “LP position” that a third party can remove in the usual AMM sense.
- **Continuous pricing**: swaps follow a constant-product curve \(x \times y = k\) between the stock token and the quote asset (native quote in this implementation).
- **Fee recapture**: a portion of swap value is accumulated and can be withdrawn to an issuer/treasury-controlled address (see `withdrawAddr` / `withdrawFee`).

### 2) Non-dilutive financing narrative (preselling future fee revenue rights)

For large capital needs, the narrative is to avoid **new-share issuance → dilution** by raising capital via **preselling rights to future trading-fee cash flows**:

- incumbents keep ownership structure unchanged;
- new capital gains long-duration, fee-linked cash-flow exposure;
- the issuer converts future liquidity revenue into upfront funding.

> **Scope note:** this repo provides the fee accrual + withdrawal primitives. The presale/distribution instrument (revenue-rights token, sale contract, or legal wrapper) is an upper-layer module.

### 3) Why this differs from both AMM pairs and orderbooks

- Compared to typical AMM pairs: ERCS-20 aims to reduce “liquidity removal → collapse” failure modes by keeping inventory inside the contract.
- Compared to pure orderbooks: ERCS-20 provides an always-on pricing curve (though depth still depends on reserves and market participation).

> This section is economic/product framing only. Rights, compliance, and disclosure must be validated per jurisdiction. Nothing here is investment advice.

## Project roadmap (two phases) — enabling liquidity expansion

In its current form, the ERCS20 pool is initialized with a fixed inventory on-chain. Because it does not continuously replenish liquidity like a mature venue, prices can become highly volatile under thin-liquidity conditions or during large trades.

To address this critical weakness, the project evolves from a single AMM pool into a full decentralized exchange system designed to provide persistent liquidity and deeper market depth.

## Orbix & OXD (note / risk disclosure)

- **Exchange**: `Orbix` (website: `orbix.exchange`) is the planned decentralized exchange for expanding liquidity in the ERCS-20 ecosystem. Its goal is to provide deeper market depth and to serve as the execution layer for spot markets, derivatives, and incentive mechanisms over time.
- **Protocol token**: `Orbix DAO` (symbol: `OBX`) is the **first token** introduced for the ERCS-20 ecosystem. It is intended for exchange-stage staking/mining programs, fee distribution, and broader ecosystem incentives (final mechanics depend on the production release).
- **Experimental positioning**: Orbix and OXD form an **ERCS-20 experimental sandbox** to validate the feasibility and boundaries of “liquidity sovereignty,” fee recapture, and the non-dilutive financing narrative under real market conditions.
- **High-risk disclaimer**: This project is under active development and experimentation. Smart-contract risk, mechanism/design risk, liquidity risk, and severe price volatility may occur. Please do your own research and understand the rules and risks before participating. **Participate cautiously and within your means.** Nothing in this repository constitutes investment advice.

We ship in two phases:

1. **Phase 1: Uniswap-style exchange experience (UI first)**  
   Build a front-end and interactive swap page so users can exchange ERCS20 with the quote asset conveniently. This phase focuses on usability and trading-entry experience: users should not need to understand contract internals to trade reliably.

2. **Phase 2: dYdX-style decentralized exchange (spot + futures) + staking mining**  
   Deploy a more complete DEX:
   - Support **spot** and **futures** trading.  
   - Use a dYdX-like workflow of **off-chain signing + on-chain settlement** (orders are signed off-chain, then validated and settled on-chain).  
   - Add **staking & mining**: users stake a protocol token to participate in mining.  
   - **Fee distribution**: exchange fees are split into two portions—one for project/platform operations, and the other allocated to mining rewards via the staking platform.  

By starting with a practical trading entry and progressively upgrading into a liquidity-sustaining venue with derivatives and incentives, the community can begin using and validating early while forming a healthier liquidity and reward loop over time.

---

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
