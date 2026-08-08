import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { Address, WalletClient } from "viem";

import { deployPerpsSystem, fundAndDeposit, fundDepositAndAddMargin } from "./helpers/fixture.js";
import { signPerpsOrder, signPerpsWithdraw } from "./helpers/eip712.js";

const COL = 10n ** 18n;
/** Binance USDT-M VIP0: maker 0.02%, taker 0.05% on notional. */
const MAKER_FEE_BPS = 2n;
const TAKER_FEE_BPS = 5n;
const FEE_DENOM = 10_000n;

function tradeFees(amount: bigint, priceX18: bigint) {
  const notional = (amount * priceX18) / COL;
  return {
    notional,
    makerFee: (notional * MAKER_FEE_BPS) / FEE_DENOM,
    takerFee: (notional * TAKER_FEE_BPS) / FEE_DENOM,
  };
}

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

  it("forcedWithdrawal can request while user has open position", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, exchange, vault, MARKET_ID } = ctx;

    const orderMargin = 200n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, 1n * COL, orderMargin, 1n, 1n);

    const vaultAsMaker = await viem.getContractAt("GlobalPerpsVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    await vaultAsMaker.write.forcedWithdrawal();
    const requestedAt = await vault.read.forcedWithdrawalRequestedAt([maker.account.address]);
    assert.notEqual(requestedAt, 0n);
  });
});

describe("PerpsExchange", async function () {
  it("settleTrades opens opposite positions with Balance margin", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, exchange, vault, MARKET_ID, PRICE } = ctx;

    const amount = 2n * COL;
    const orderMargin = 300n * COL; // notional 200
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);

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
    const { makerFee, takerFee } = tradeFees(amount, PRICE);
    // locked margin + trading fee from vault free
    assert.equal(
      await vault.read.balances([taker.account.address]),
      500n * COL - orderMargin - takerFee,
    );
    assert.equal(
      await vault.read.balances([maker.account.address]),
      500n * COL - orderMargin - makerFee,
    );
    assert.equal(await vault.read.protocolFees(), makerFee + takerFee);
  });

  it("liquidate reverts when account is still collateralized", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, liquidator, exchange, MARKET_ID } = ctx;

    const amount = 1n * COL;
    const orderMargin = 200n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    await viem.assertions.revertWithCustomError(
      exchangeAsOp.write.liquidate([
        MARKET_ID,
        taker.account.address,
        liquidator.account.address,
        0n,
      ]),
      exchange,
      "NotLiquidatable",
    );
  });

  it("liquidate moves undercollateralized position into liquidator", async function () {
    const ctx = await deployPerpsSystem();
    const {
      viem,
      publicClient,
      maker,
      taker,
      operator,
      liquidator,
      exchange,
      oracle,
      MARKET_ID,
      ADL_THRESHOLD,
    } = ctx;

    // High leverage long: lock 50, buy 1 @ 100 → margin=-50, pos=+1
    const amount = 1n * COL;
    const orderMargin = 50n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);
    await fundDepositAndAddMargin(ctx, liquidator, ADL_THRESHOLD);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    // Drop mark so long is undercollateralized.
    await oracle.write.setPrice([MARKET_ID, 50n * COL]);
    await exchangeAsOp.write.liquidate([
      MARKET_ID,
      taker.account.address,
      liquidator.account.address,
      0n,
    ]);

    const takerBal = await exchange.read.getBalance([taker.account.address, MARKET_ID]);
    assert.equal(takerBal[0], 0n);
    assert.equal(takerBal[1], 0n);

    const liqBal = await exchange.read.getBalance([liquidator.account.address, MARKET_ID]);
    // negative margin wiped; L keeps its buffer margin and absorbs position
    assert.equal(liqBal[0], ADL_THRESHOLD);
    assert.equal(liqBal[1], amount);
  });

  it("liquidate marginTopUp pulls from liquidator vault free balance", async function () {
    const ctx = await deployPerpsSystem();
    const {
      viem,
      publicClient,
      maker,
      taker,
      operator,
      liquidator,
      exchange,
      vault,
      oracle,
      MARKET_ID,
      ADL_THRESHOLD,
    } = ctx;

    const amount = 1n * COL;
    const orderMargin = 50n * COL;
    const topUp = 100n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);
    // Locked buffer + free balance for top-up.
    await fundDepositAndAddMargin(ctx, liquidator, ADL_THRESHOLD);
    await fundAndDeposit(ctx, liquidator, topUp);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    await oracle.write.setPrice([MARKET_ID, 50n * COL]);
    await exchangeAsOp.write.liquidate([
      MARKET_ID,
      taker.account.address,
      liquidator.account.address,
      topUp,
    ]);

    const liqBal = await exchange.read.getBalance([liquidator.account.address, MARKET_ID]);
    assert.equal(liqBal[0], ADL_THRESHOLD + topUp);
    assert.equal(liqBal[1], amount);
    assert.equal(await vault.read.balances([liquidator.account.address]), 0n);
    assert.equal(
      await exchange.read.isAdlTriggered([MARKET_ID, liquidator.account.address]),
      false,
    );
  });

  it("executeAdl runs when liquidator margin is at or below threshold", async function () {
    const ctx = await deployPerpsSystem();
    const {
      viem,
      publicClient,
      maker,
      taker,
      operator,
      liquidator,
      exchange,
      oracle,
      MARKET_ID,
      ADL_THRESHOLD,
    } = ctx;

    const amount = 1n * COL;
    const orderMargin = 50n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);
    // L margin == threshold so ADL is already armed; liquidating underwater long keeps margin.
    await fundDepositAndAddMargin(ctx, liquidator, ADL_THRESHOLD);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    // Drop mark so long is undercollateralized, then liquidate into L.
    await oracle.write.setPrice([MARKET_ID, 50n * COL]);
    await exchangeAsOp.write.liquidate([
      MARKET_ID,
      taker.account.address,
      liquidator.account.address,
      0n,
    ]);

    assert.equal(
      await exchange.read.isAdlTriggered([MARKET_ID, liquidator.account.address]),
      true,
    );

    // Maker is short; ADL buy (userIsBuy=true) closes short vs L long.
    await exchangeAsOp.write.executeAdl([
      MARKET_ID,
      maker.account.address,
      liquidator.account.address,
      amount,
      true,
    ]);

    const makerBal = await exchange.read.getBalance([maker.account.address, MARKET_ID]);
    assert.equal(makerBal[1], 0n);

    const liqBal = await exchange.read.getBalance([liquidator.account.address, MARKET_ID]);
    assert.equal(liqBal[1], 0n);
  });

  it("funding: positive rate debits longs and credits shorts over time", async function () {
    const ctx = await deployPerpsSystem();
    const {
      viem,
      networkHelpers,
      publicClient,
      maker,
      taker,
      operator,
      funder,
      exchange,
      MARKET_ID,
    } = ctx;

    const amount = 1n * COL;
    const orderMargin = 200n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    // ratePerSecond = 1e12; index accumulates unitless * mark / 1e18
    await funder.write.setRate([true, 10n ** 12n]);
    await networkHelpers.time.increase(1000);

    await exchange.write.settleFunding([taker.account.address, MARKET_ID]);
    const takerIndex = await exchange.read.fundingIndex([MARKET_ID]);
    const takerBal = await exchange.read.getBalance([taker.account.address, MARKET_ID]);
    // long pays: margin -= indexValue (position = 1e18)
    assert.equal(takerBal[0], 100n * COL - takerIndex[1]);

    await exchange.write.settleFunding([maker.account.address, MARKET_ID]);
    const makerIndex = await exchange.read.fundingIndex([MARKET_ID]);
    const makerBal = await exchange.read.getBalance([maker.account.address, MARKET_ID]);
    // After open @100 lock 200: taker margin=100, maker=300
    assert.equal(makerBal[0], 300n * COL + makerIndex[1]);
  });

  it("settleTrades updates lastPrice; updateFunding samples funder", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, funder, exchange, MARKET_ID, PRICE } =
      ctx;

    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, 1n * COL, 200n * COL, 1n, 1n);

    assert.equal(await exchange.read.getLastPrice([MARKET_ID]), PRICE);
    assert.equal(await funder.read.lastPriceX18(), PRICE);
    assert.equal(await funder.read.updateCount(), 1n);

    await exchangeAsOp.write.updateFunding([MARKET_ID]);
    assert.equal(await funder.read.updateCount(), 2n);
  });
});
