import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { Address, WalletClient } from "viem";

import { deployPerpsSystem, fundAndDeposit } from "./helpers/fixture.js";
import { signPerpsOrder, signPerpsWithdraw } from "./helpers/eip712.js";

const COL = 10n ** 18n;

async function settleOne(
  ctx: Awaited<ReturnType<typeof deployPerpsSystem>>,
  exchangeAsOp: { write: { settleTrades: (args: any) => Promise<unknown> } },
  maker: WalletClient,
  taker: WalletClient,
  amount: bigint,
  orderMargin: bigint,
  makerNonce: bigint,
  takerNonce: bigint,
) {
  const { chainId, exchange, MARKET_ID, PRICE } = ctx;
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const makerAddr = maker.account!.address as Address;
  const takerAddr = taker.account!.address as Address;

  const makerOrder = {
    trader: makerAddr,
    marketId: MARKET_ID,
    amount,
    margin: orderMargin,
    priceX18: PRICE,
    isBuy: false,
    nonce: makerNonce,
    expiry,
  };
  const takerOrder = {
    trader: takerAddr,
    marketId: MARKET_ID,
    amount,
    margin: orderMargin,
    priceX18: PRICE,
    isBuy: true,
    nonce: takerNonce,
    expiry,
  };

  const makerSig = await signPerpsOrder(maker, chainId, exchange.address, makerOrder);
  const takerSig = await signPerpsOrder(taker, chainId, exchange.address, takerOrder);

  await exchangeAsOp.write.settleTrades([
    [
      {
        takerOrder,
        takerSignature: takerSig,
        makerOrders: [makerOrder],
        makerSignatures: [makerSig],
        fulfillments: [{ amount, priceX18: PRICE }],
      },
    ],
  ]);
}

describe("GlobalPerpsVault", async function () {
  it("deposit and withdrawDAO-authorized withdraw", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, chainId, maker, withdrawDao, vault } = ctx;

    const amount = 1_000n * COL;
    await fundAndDeposit(ctx, maker, amount);

    const sig = await signPerpsWithdraw(withdrawDao, chainId, vault.address, {
      user: maker.account.address,
      orderId: 1n,
      amount: 400n * COL,
    });

    const vaultAsMaker = await viem.getContractAt("GlobalPerpsVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    const nativeBefore = await publicClient.getBalance({ address: maker.account.address });
    const txHash = await vaultAsMaker.write.withdraw([1n, 400n * COL, sig]);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    const nativeAfter = await publicClient.getBalance({ address: maker.account.address });
    const gasCost = receipt.gasUsed * (receipt.effectiveGasPrice ?? 0n);

    assert.equal(await vault.read.balances([maker.account.address]), 600n * COL);
    assert.equal(nativeAfter + gasCost - nativeBefore, 400n * COL);
  });

  it("forcedWithdrawal reverts while user has open position", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, seed, exchange, vault, MARKET_ID, PRICE } =
      ctx;

    // Notional = 1 * 100 = 100; lock 200 each so post-trade margin stays positive.
    const orderMargin = 200n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);
    await fundAndDeposit(ctx, seed, 50n * COL);

    const exchangeAsSeed = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: seed },
    });
    await exchangeAsSeed.write.seedSystem([MARKET_ID, 50n * COL]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, 1n * COL, orderMargin, 1n, 1n);

    const vaultAsMaker = await viem.getContractAt("GlobalPerpsVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    await viem.assertions.revertWithCustomError(
      vaultAsMaker.write.forcedWithdrawal(),
      vault,
      "HasOpenPosition",
    );
  });
});

describe("PerpsExchange", async function () {
  it("settleTrades opens opposite positions with Balance margin", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, seed, exchange, vault, MARKET_ID, PRICE } =
      ctx;

    const amount = 2n * COL;
    const orderMargin = 300n * COL; // notional 200
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);
    await fundAndDeposit(ctx, seed, 50n * COL);

    const exchangeAsSeed = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: seed },
    });
    await exchangeAsSeed.write.seedSystem([MARKET_ID, 50n * COL]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    const makerBal = await exchange.read.getBalance([maker.account.address, MARKET_ID]);
    const takerBal = await exchange.read.getBalance([taker.account.address, MARKET_ID]);
    // taker buy: pos +2, margin = 300 - 200 = 100; maker sell: pos -2, margin = 300 + 200 = 500
    assert.equal(takerBal[1], amount);
    assert.equal(takerBal[0], 100n * COL);
    assert.equal(makerBal[1], -amount);
    assert.equal(makerBal[0], 500n * COL);
    // locked from vault free
    assert.equal(await vault.read.balances([taker.account.address]), 500n * COL - orderMargin);
    assert.equal(await vault.read.balances([maker.account.address]), 500n * COL - orderMargin);
  });

  it("liquidate moves position into system account and seizes margin", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, seed, exchange, vault, MARKET_ID } = ctx;

    const amount = 1n * COL;
    const orderMargin = 200n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);
    await fundAndDeposit(ctx, seed, 50n * COL);

    const exchangeAsSeed = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: seed },
    });
    await exchangeAsSeed.write.seedSystem([MARKET_ID, 50n * COL]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    // taker margin after buy = 200 - 100 = 100
    await exchangeAsOp.write.liquidate([MARKET_ID, taker.account.address]);

    const takerBal = await exchange.read.getBalance([taker.account.address, MARKET_ID]);
    assert.equal(takerBal[0], 0n);
    assert.equal(takerBal[1], 0n);

    const sys = await exchange.read.getSystemAccount([MARKET_ID]);
    assert.equal(sys[1], amount);
    assert.equal(sys[0], 50n * COL + 100n * COL);
    assert.equal(await exchange.read.hasOpenPosition([taker.account.address]), false);
  });

  it("executeAdl runs when system equity is at or below threshold", async function () {
    const ctx = await deployPerpsSystem();
    const {
      viem,
      publicClient,
      maker,
      taker,
      operator,
      seed,
      exchange,
      oracle,
      MARKET_ID,
      ADL_THRESHOLD,
    } = ctx;

    const amount = 1n * COL;
    const orderMargin = 50n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);
    const seedAmt = ADL_THRESHOLD;
    await fundAndDeposit(ctx, seed, seedAmt);

    const exchangeAsSeed = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: seed },
    });
    await exchangeAsSeed.write.seedSystem([MARKET_ID, seedAmt]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    // Liquidate maker (short, margin≈150) into S; mark↑ → short inventory hurts S equity.
    await exchangeAsOp.write.liquidate([MARKET_ID, maker.account.address]);
    await oracle.write.setPrice([MARKET_ID, 200n * COL]);

    assert.equal(await exchange.read.isAdlTriggered([MARKET_ID]), true);

    // Taker is long; ADL sell (userIsBuy=false) closes long vs S.
    await exchangeAsOp.write.executeAdl([MARKET_ID, taker.account.address, amount, false]);

    const takerBal = await exchange.read.getBalance([taker.account.address, MARKET_ID]);
    assert.equal(takerBal[1], 0n);
  });
});
