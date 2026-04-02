# ERCS20 Smart Contracts · Liquidity Sovereignty Protocol

## One-line pitch

**Liquidity Sovereignty** is a smart-contract-native paradigm for equity-style financing and trading: **no zero-cost “founder stock.”** Anyone—including the founding team—who wants stock tokens from the pool must supply stablecoins (or an equivalent quote asset on-chain) under fixed rules. **Trading fees from secondary-market activity can accrue to the company (or a protocol treasury)** so ongoing liquidity becomes withdrawable revenue—**liquidity as income.**

This repository is a reference implementation of that paradigm: **Equity Request for Comments - Stock (20)** (**ERCS20**)—tokenized equity-like assets with an embedded **constant-product AMM** (Uniswap V2–style) for pricing and swaps.

---

## Design rationale

### Non-dilutive financing: presale of fee revenue rights (product narrative)

For large capital needs, instead of the classic path **new issuance → dilution of existing holders**, you can prioritize **non-dilutive** instruments:

- **Existing shareholders**: voting power and ownership percentages can stay unchanged across a new funding round.  
- **New investors**: they need not (or may not) buy new shares directly; they can **subscribe to rights over future trading-fee cash flows** (revenue rights, dividend-like rights, or legally wrapped equivalents), gaining **long-dated exposure** tied to secondary-market activity.  
- **The company**: receives capital upfront or in tranches while assigning part of future **fee income from liquidity** to new capital—a **“cash today, repaid by tomorrow’s trading revenue”** structure.

> **Relation to this codebase:** that **fee-revenue presale** layer is **product and legal structuring** (e.g. separate revenue-rights tokens, trusts/SPVs, off-chain agreements). The **`ERCS20` contracts here mainly implement “stock token + AMM + fee accrual and withdrawal.”** Splitting, preselling, and distributing revenue rights can be built in upper layers or follow-on modules.

### Pain points of traditional equity financing

1. **Cheap founder stock and misaligned incentives**  
   Founders and early holders often hold large stakes at very low cost. After listing, without strong constraints they may sell into strength and exit, sometimes harming long-term holders; the operating company may still capture little from day-to-day secondary trading.

2. **Liquidity value flows to intermediaries**  
   Active trading reflects consensus, but fees and market-making economics often accrue to exchanges and middlemen, weakening the issuer’s incentive to protect valuation and liquidity quality.

3. **Market cap vs. cash flow**  
   Funding is concentrated in IPOs and follow-ons; rising share prices do not automatically become usable corporate cash—**“high market cap, thin wallet.”**

### Tokenized stock + AMM: technical base for liquidity sovereignty

Here **liquidity sovereignty** means keeping **pricing and fee capture** as much as possible **inside the issuer’s rule set**, not fully leaking to third-party venues. Smart contracts bind the **stock token** and the **liquidity pool** under one math and permission model:

1. **Fixed supply, initially custodied by the contract**  
   Total supply is set at deployment; tokens can be minted entirely to the contract as inventory. Float is released through the AMM **without ad-hoc dilutive mints** (large raises can use parallel tools such as **fee-revenue presales**, above).

2. **Uniswap V2–style constant-product pricing**  
   Reserves follow \(x \times y = k\) between the **stock token** and a **quote asset** (e.g. USDC or the chain’s native quote), enabling continuous prices without a central limit order book.

3. **Opening price from initial reserves**  
   Initial stock-side and quote-side reserve parameters set the starting exchange rate. Example: if reserves imply **1M tokens** vs **1M USDC**, the implied spot is about **1 USDC per token** (actual values follow constructor parameters on-chain).

4. **No zero-cost founder shares: everyone swaps in stablecoins under the same curve**  
   Under a **“full float in the pool”** design, **founders and early insiders who want tokens from the pool must still deposit quote assets and trade the curve**, like everyone else—reducing **“free founder stock + secondary dump”** dynamics.

5. **Fees to the company (or treasury): liquidity as income**  
   Swaps can charge a fee on the output side and route it to a configurable address (here, e.g. **`withdrawAddr`** / **`withdrawFee`**), tying **secondary-market activity to withdrawable cash** (exact fee rate: see source).

### Conceptual comparison

| Dimension | Traditional equities | Liquidity sovereignty / this model |
|-----------|----------------------|-------------------------------------|
| Large raises vs. dilution | Often new issuance; dilutes incumbents | Can stay **non-dilutive** via **presales of future fee revenue rights** (product design) |
| New investor returns | Mostly price + dividend policy | Can link to **long-horizon trading-fee cash flows** (needs a dedicated rights vehicle) |
| Issuer benefit from secondary trading | Usually none directly | Fees can **accrue to issuer/treasury by rule** (this repo: accrual + withdrawal path) |
| Early stock acquisition | Often very low subscription/strike cost | **Must swap quote into the AMM**—no privileged zero-cost pool |
| Where liquidity value goes | Mostly venues and intermediaries | Can **stay with protocol and issuer** (liquidity sovereignty) |

### Summary

- **For the company:** raise large checks **without necessarily diluting legacy holders** (fee-revenue presales, etc.) while making **trading fees** a plannable revenue line (**liquidity as income**).  
- **For existing holders:** ownership can remain stable; new capital is served by **future liquidity revenue rights**.  
- **For new investors:** exposure to **fee-linked cash flows** tied to secondary activity (legal form depends on jurisdiction).  
- **For the ecosystem:** pricing and value distribution are constrained by **public on-chain rules**, reducing opaque misalignment.

This fits innovative fundraising and on-chain equity expression; **a full on-chain presale module for revenue rights can ship as a later iteration.**

> The table is **economic / product** framing only. Rights, compliance, and disclosure must be validated for each jurisdiction. This repo is a **smart-contract reference**, not legal or investment advice.

## Project roadmap (two phases) — enabling liquidity expansion

In its current form, the ERCS20 pool is initialized with a fixed inventory on-chain. Because it does not continuously replenish liquidity like a mature venue, prices can become highly volatile under thin-liquidity conditions or during large trades.

## Orbix & OXD (note / risk disclosure)

- **Exchange**: `Orbix` (website: `orbix.exchange`) is the planned decentralized exchange for expanding liquidity in the ERCS-20 ecosystem. Its goal is to provide deeper market depth and to serve as the execution layer for spot markets, derivatives, and incentive mechanisms over time.
- **Protocol token**: `Orbix DAO` (symbol: `OXD`) is the **first token** introduced for the ERCS-20 ecosystem. It is intended for exchange-stage staking/mining programs, fee distribution, and broader ecosystem incentives (final mechanics depend on the production release).
- **Experimental positioning**: Orbix and OXD form an **ERCS-20 experimental sandbox** to validate the feasibility and boundaries of “liquidity sovereignty,” fee recapture, and the non-dilutive financing narrative under real market conditions.
- **High-risk disclaimer**: This project is under active development and experimentation. Smart-contract risk, mechanism/design risk, liquidity risk, and severe price volatility may occur. Please do your own research and understand the rules and risks before participating. **Participate cautiously and within your means.** Nothing in this repository constitutes investment advice.

To address this critical weakness, the project evolves from a single AMM pool into a full decentralized exchange system designed to provide persistent liquidity and deeper market depth.

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
