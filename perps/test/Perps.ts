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

    const makerBal = await exchange.read.balances([maker.account.address, MARKET_ID]);
    const takerBal = await exchange.read.balances([taker.account.address, MARKET_ID]);
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

  it("session signer can sign orders for trader", async function () {
    const ctx = await deployPerpsSystem();
    const {
      viem,
      publicClient,
      chainId,
      deployer,
      maker,
      taker,
      operator,
      exchange,
      MARKET_ID,
      PRICE,
    } = ctx;

    const amount = 1n * COL;
    const orderMargin = 200n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);

    const exchangeAsMaker = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: maker },
    });
    await exchangeAsMaker.write.setSigner([deployer.account.address, true]);

    const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const makerOrder = {
      trader: maker.account.address as Address,
      marketId: MARKET_ID,
      amount,
      margin: orderMargin,
      priceX18: PRICE,
      isBuy: false,
      nonce: 1n,
      expiry,
    };
    const takerOrder = {
      trader: taker.account.address as Address,
      marketId: MARKET_ID,
      amount,
      margin: orderMargin,
      priceX18: PRICE,
      isBuy: true,
      nonce: 1n,
      expiry,
    };

    // Hot session key signs for cold trader; taker still self-signs.
    const makerSig = await signPerpsOrder(deployer, chainId, exchange.address, makerOrder);
    const takerSig = await signPerpsOrder(taker, chainId, exchange.address, takerOrder);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
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

    const makerBal = await exchange.read.balances([maker.account.address, MARKET_ID]);
    assert.equal(makerBal[1], -amount);
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
    ]);

    const takerBal = await exchange.read.balances([taker.account.address, MARKET_ID]);
    assert.equal(takerBal[0], 0n);
    assert.equal(takerBal[1], 0n);

    const liqBal = await exchange.read.balances([liquidator.account.address, MARKET_ID]);
    // L absorbs signed margin (-50) and position (+1)
    assert.equal(liqBal[0], ADL_THRESHOLD - 50n * COL);
    assert.equal(liqBal[1], amount);
  });

  it("liquidator margin stays parked after ADL", async function () {
    const ctx = await deployPerpsSystem();
    const {
      viem,
      publicClient,
      dao,
      maker,
      taker,
      operator,
      liquidator,
      exchange,
      vault,
      oracle,
      MARKET_ID,
    } = ctx;

    const amount = 1n * COL;
    const orderMargin = 50n * COL;
    const adlThreshold = 200n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);
    // After absorb user -50: margin == threshold (ADL armed); ADL quote 50 leaves parked remainder.
    await fundDepositAndAddMargin(ctx, liquidator, adlThreshold + 50n * COL);

    const exchangeAsDao = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: dao },
    });
    await exchangeAsDao.write.setAdlEquityThreshold([MARKET_ID, adlThreshold]);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    await oracle.write.setPrice([MARKET_ID, 50n * COL]);
    await exchangeAsOp.write.liquidate([
      MARKET_ID,
      taker.account.address,
      liquidator.account.address,
    ]);

    const vaultBefore = await vault.read.balances([liquidator.account.address]);
    // ADL closes L inventory; margin must remain parked (not auto-returned to vault).
    await exchangeAsOp.write.executeAdl([
      MARKET_ID,
      maker.account.address,
      liquidator.account.address,
      amount,
      true,
    ]);
    const liqBal = await exchange.read.balances([liquidator.account.address, MARKET_ID]);
    assert.equal(liqBal[1], 0n);
    assert.ok(liqBal[0] > 0n);
    assert.equal(await vault.read.balances([liquidator.account.address]), vaultBefore);
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
    // After absorbing user margin=-50, L.margin == threshold ⇒ ADL armed.
    await fundDepositAndAddMargin(ctx, liquidator, ADL_THRESHOLD + 50n * COL);

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

    const makerBal = await exchange.read.balances([maker.account.address, MARKET_ID]);
    assert.equal(makerBal[1], 0n);

    const liqBal = await exchange.read.balances([liquidator.account.address, MARKET_ID]);
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
    const takerBal = await exchange.read.balances([taker.account.address, MARKET_ID]);
    // long pays: margin -= indexValue (position = 1e18)
    assert.equal(takerBal[0], 100n * COL - takerIndex[1]);

    await exchange.write.settleFunding([maker.account.address, MARKET_ID]);
    const makerIndex = await exchange.read.fundingIndex([MARKET_ID]);
    const makerBal = await exchange.read.balances([maker.account.address, MARKET_ID]);
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

    const [, , , , , lastPriceX18] = await exchange.read.markets([MARKET_ID]);
    assert.equal(lastPriceX18, PRICE);
    assert.equal(await funder.read.lastPriceX18(), PRICE);
    assert.equal(await funder.read.updateCount(), 1n);

    await exchangeAsOp.write.updateFunding([MARKET_ID]);
    assert.equal(await funder.read.updateCount(), 2n);
  });

  it("final settlement: users withdraw equity at settlement price", async function () {
    const ctx = await deployPerpsSystem();
    const {
      viem,
      publicClient,
      deployer,
      maker,
      taker,
      operator,
      exchange,
      vault,
      MARKET_ID,
    } = ctx;

    const amount = 2n * COL;
    const orderMargin = 300n * COL;
    await fundAndDeposit(ctx, maker, 500n * COL);
    await fundAndDeposit(ctx, taker, 500n * COL);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, orderMargin, 1n, 1n);

    // Higher settle price: long gains, short loses — both still solvent.
    const settlePrice = 110n * COL;
    await exchange.write.enableFinalSettlement([MARKET_ID, settlePrice]);

    const market = await exchange.read.markets([MARKET_ID]);
    assert.equal(market[2], true); // paused
    const settlement = await exchange.read.marketSettlements([MARKET_ID]);
    assert.equal(settlement[0], true); // enabled
    assert.equal(settlement[1], settlePrice); // settlementPriceX18
    assert.ok(settlement[2] > 0n); // lockedAt

    const exchangeAsTaker = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: taker },
    });
    await viem.assertions.revertWithCustomError(
      exchangeAsTaker.write.addMargin([MARKET_ID, 1n]),
      exchange,
      "MarketIsPaused",
    );

    // Taker long: margin=100 pos=+2 @ 110 → equity=320
    const vaultBeforeTaker = await vault.read.balances([taker.account.address]);
    await exchangeAsTaker.write.withdrawFinalSettlement([MARKET_ID]);
    assert.equal(
      await vault.read.balances([taker.account.address]),
      vaultBeforeTaker + 320n * COL,
    );
    const takerBal = await exchange.read.balances([taker.account.address, MARKET_ID]);
    assert.equal(takerBal[0], 0n);
    assert.equal(takerBal[1], 0n);

    // Maker short: margin=500 pos=-2 @ 110 → equity=280
    const vaultBeforeMaker = await vault.read.balances([maker.account.address]);
    const exchangeAsMaker = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: maker },
    });
    await exchangeAsMaker.write.withdrawFinalSettlement([MARKET_ID]);
    assert.equal(
      await vault.read.balances([maker.account.address]),
      vaultBeforeMaker + 280n * COL,
    );

    // Owner can correct settlement price if mis-set; lockedAt stays from first enable.
    const correctedPrice = 105n * COL;
    const lockedAt = settlement[2];
    await exchange.write.enableFinalSettlement([MARKET_ID, correctedPrice], {
      account: deployer.account,
    });
    const resettled = await exchange.read.marketSettlements([MARKET_ID]);
    assert.equal(resettled[1], correctedPrice);
    assert.equal(resettled[2], lockedAt);
  });

  it("final settlement: underwater account withdraws with no payout", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, maker, taker, operator, exchange, vault, MARKET_ID } = ctx;

    // Maker short 1 @ 100 with thin margin → margin=150, pos=-1 after fill.
    const amount = 1n * COL;
    await fundAndDeposit(ctx, maker, 200n * COL);
    await fundAndDeposit(ctx, taker, 200n * COL);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, 50n * COL, 1n, 1n);

    // Settle at 200: maker equity = 150 - 200 = -50 < 0.
    await exchange.write.enableFinalSettlement([MARKET_ID, 200n * COL]);

    const vaultBeforeMaker = await vault.read.balances([maker.account.address]);
    const exchangeAsMaker = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: maker },
    });
    await exchangeAsMaker.write.withdrawFinalSettlement([MARKET_ID]);

    assert.equal(await vault.read.balances([maker.account.address]), vaultBeforeMaker);
    const makerBal = await exchange.read.balances([maker.account.address, MARKET_ID]);
    assert.equal(makerBal[0], 0n);
    assert.equal(makerBal[1], 0n);
  });

  it("final settlement: after 300d lock DAO reclaims leftover market pot", async function () {
    const ctx = await deployPerpsSystem();
    const { viem, publicClient, networkHelpers, maker, taker, operator, dao, exchange, vault, MARKET_ID } =
      ctx;

    const amount = 1n * COL;
    await fundAndDeposit(ctx, maker, 200n * COL);
    await fundAndDeposit(ctx, taker, 200n * COL);

    const exchangeAsOp = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: operator },
    });
    await settleOne(ctx, exchangeAsOp, maker, taker, amount, 50n * COL, 1n, 1n);

    // Underwater wipe leaves stranded USDC in the market pot.
    await exchange.write.enableFinalSettlement([MARKET_ID, 200n * COL]);
    const exchangeAsMaker = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: maker },
    });
    await exchangeAsMaker.write.withdrawFinalSettlement([MARKET_ID]);

    const leftover = await exchange.read.remainingFinalSettlementPot([MARKET_ID]);
    assert.ok(leftover > 0n);
    assert.equal(leftover, await vault.read.marketPots([MARKET_ID]));

    const exchangeAsDao = await viem.getContractAt("PerpsExchange", exchange.address, {
      client: { public: publicClient, wallet: dao },
    });
    await viem.assertions.revertWithCustomError(
      exchangeAsDao.write.reclaimFinalSettlementPot([MARKET_ID]),
      exchange,
      "FinalSettlementLockActive",
    );

    await networkHelpers.time.increase(300 * 24 * 60 * 60);

    const daoFreeBefore = await vault.read.balances([dao.account.address]);
    await exchangeAsDao.write.reclaimFinalSettlementPot([MARKET_ID]);
    assert.equal(await vault.read.marketPots([MARKET_ID]), 0n);
    assert.equal(await vault.read.balances([dao.account.address]), daoFreeBefore + leftover);
    assert.equal(await exchange.read.remainingFinalSettlementPot([MARKET_ID]), 0n);
  });
});
