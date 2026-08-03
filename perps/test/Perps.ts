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
    priceX18: PRICE,
    isBuy: false,
    nonce: makerNonce,
    expiry,
  };
  const takerOrder = {
    trader: takerAddr,
    marketId: MARKET_ID,
    amount,
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
        marketId: MARKET_ID,
        maker: makerAddr,
        taker: takerAddr,
        amount,
        priceX18: PRICE,
        takerIsBuy: true,
      },
    ],
    [
      {
        makerOrder,
        takerOrder,
        makerSig,
        takerSig,
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
    const { viem, publicClient, maker, taker, operator, seed, exchange, vault, MARKET_ID } = ctx;

    await fundAndDeposit(ctx, maker, 100n * COL);
    await fundAndDeposit(ctx, taker, 100n * COL);
    await fundAndDeposit(ctx, seed, 50n * COL);

    const exchangeAsSeed = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: seed },
    });
    await exchangeAsSeed.write.seedSystem([MARKET_ID, 50n * COL]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, 1n * COL, 1n, 1n);

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
  it("settleTrades opens opposite positions", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, seed, exchange, MARKET_ID, PRICE } = ctx;

    await fundAndDeposit(ctx, maker, 100n * COL);
    await fundAndDeposit(ctx, taker, 100n * COL);
    await fundAndDeposit(ctx, seed, 50n * COL);

    const exchangeAsSeed = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: seed },
    });
    await exchangeAsSeed.write.seedSystem([MARKET_ID, 50n * COL]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });

    const amount = 2n * COL;
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, 1n, 1n);

    const makerPos = await exchange.read.getPosition([maker.account.address, MARKET_ID]);
    const takerPos = await exchange.read.getPosition([taker.account.address, MARKET_ID]);
    assert.equal(makerPos[0], -amount);
    assert.equal(takerPos[0], amount);
    assert.equal(makerPos[1], PRICE);
    assert.equal(takerPos[1], PRICE);
  });

  it("liquidate moves position into system account and seizes margin", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, seed, exchange, vault, MARKET_ID } = ctx;

    await fundAndDeposit(ctx, maker, 100n * COL);
    await fundAndDeposit(ctx, taker, 100n * COL);
    await fundAndDeposit(ctx, seed, 50n * COL);

    const exchangeAsSeed = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: seed },
    });
    await exchangeAsSeed.write.seedSystem([MARKET_ID, 50n * COL]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });

    const amount = 1n * COL;
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, 1n, 1n);

    const seize = 20n * COL;
    await exchangeAsOp.write.liquidate([MARKET_ID, taker.account.address, seize]);

    const takerPos = await exchange.read.getPosition([taker.account.address, MARKET_ID]);
    assert.equal(takerPos[0], 0n);

    const sys = await exchange.read.getSystemAccount([MARKET_ID]);
    assert.equal(sys[1], amount);
    assert.equal(sys[0], 50n * COL + seize);
    assert.equal(await vault.read.balances([taker.account.address]), 100n * COL - seize);
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
      vault,
      MARKET_ID,
      ADL_THRESHOLD,
    } = ctx;

    await fundAndDeposit(ctx, maker, 100n * COL);
    await fundAndDeposit(ctx, taker, 100n * COL);
    const seedAmt = ADL_THRESHOLD + 10n * COL;
    await fundAndDeposit(ctx, seed, seedAmt);

    const exchangeAsSeed = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: seed },
    });
    await exchangeAsSeed.write.seedSystem([MARKET_ID, seedAmt]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });

    const amount = 1n * COL;
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, 1n, 1n);

    await exchangeAsOp.write.liquidate([MARKET_ID, maker.account.address, 0n]);
    await oracle.write.setPrice([MARKET_ID, 200n * COL]);

    assert.equal(await exchange.read.isAdlTriggered([MARKET_ID]), true);

    const takerBalBefore = await vault.read.balances([taker.account.address]);
    const sysBefore = await exchange.read.getSystemAccount([MARKET_ID]);
    await exchangeAsOp.write.executeAdl([MARKET_ID, taker.account.address, -amount]);

    const takerPos = await exchange.read.getPosition([taker.account.address, MARKET_ID]);
    assert.equal(takerPos[0], 0n);
    const takerBalAfter = await vault.read.balances([taker.account.address]);
    // Full mark PnL would be +100, but S only has seedAmt cash → haircut to available cash.
    assert.equal(takerBalAfter - takerBalBefore, sysBefore[0]);

    const sys = await exchange.read.getSystemAccount([MARKET_ID]);
    assert.equal(sys[1], 0n);
    assert.equal(sys[0], 0n);
  });
});
