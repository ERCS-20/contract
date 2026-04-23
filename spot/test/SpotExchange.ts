import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { deploySpotSystem } from "./helpers/fixture.js";
import { hashSpotOrderStruct, signSpotOrder } from "./helpers/eip712.js";

describe("SpotExchange", async function () {
  it("settleTrades moves vault balances and accrues fees", async function () {
    const { viem, publicClient, chainId, maker, taker, relayer, tokenA, tokenB, exchange, vault } =
      await deploySpotSystem();

    const unit = 10n ** 18n;
    const makerAmt = 10_000n * unit;
    const takerAmt = 20_000n * unit;

    await tokenA.write.mint([maker.account.address, makerAmt * 2n]);
    await tokenB.write.mint([taker.account.address, takerAmt * 2n]);
    await tokenA.write.approve([vault.address, makerAmt * 2n], { account: maker.account });
    await tokenB.write.approve([vault.address, takerAmt * 2n], { account: taker.account });

    const vaultMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    const vaultTaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: taker },
    });
    await vaultMaker.write.deposit([tokenA.address, makerAmt * 2n]);
    await vaultTaker.write.deposit([tokenB.address, takerAmt * 2n]);

    const ts = await publicClient.getBlock().then((b) => b.timestamp);
    const expiry = ts + 86_400n;

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 1n,
    };
    const takerOrder = {
      maker: taker.account.address,
      makerToken: tokenB.address,
      takerToken: tokenA.address,
      makerAmount: takerAmt,
      takerAmount: makerAmt,
      expiry,
      salt: 2n,
    };

    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);

    const ex = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: relayer },
    });

    const makerFee = (takerAmt * 20n) / 10_000n;
    const takerFee = (makerAmt * 20n) / 10_000n;
    const typeHash = await exchange.read.SPOT_ORDER_TYPEHASH();
    const makerOrderHash = hashSpotOrderStruct(typeHash, makerOrder);
    const takerOrderHash = hashSpotOrderStruct(typeHash, takerOrder);
    const fromBlock = await publicClient.getBlockNumber();
    await ex.write.settleTrades([
      takerOrder,
      takerSig,
      [makerOrder],
      [makerSig],
      [{ makerAmount: makerAmt, takerAmount: takerAmt }],
    ]);
    const events = await publicClient.getContractEvents({
      address: exchange.address,
      abi: exchange.abi,
      eventName: "TradeExecuted",
      fromBlock,
      strict: true,
    });
    assert.equal(events.length, 1);
    const evt = events[0].args;
    assert.equal(evt.maker.toLowerCase(), maker.account.address.toLowerCase());
    assert.equal(evt.taker.toLowerCase(), taker.account.address.toLowerCase());
    assert.equal((evt as typeof evt & { makerOrderHash: `0x${string}` }).makerOrderHash, makerOrderHash);
    assert.equal((evt as typeof evt & { takerOrderHash: `0x${string}` }).takerOrderHash, takerOrderHash);
    assert.equal(evt.makerToken.toLowerCase(), tokenA.address.toLowerCase());
    assert.equal(evt.takerToken.toLowerCase(), tokenB.address.toLowerCase());
    assert.equal(evt.makerAmount, makerAmt);
    assert.equal(evt.takerAmount, takerAmt);
    assert.equal(evt.makerFee, makerFee);
    assert.equal(evt.takerFee, takerFee);

    assert.equal(await vault.read.balances([maker.account.address, tokenA.address]), makerAmt);
    assert.equal(
      await vault.read.balances([maker.account.address, tokenB.address]),
      takerAmt - makerFee,
    );
    assert.equal(
      await vault.read.balances([taker.account.address, tokenA.address]),
      makerAmt - takerFee,
    );
    assert.equal(await vault.read.balances([taker.account.address, tokenB.address]), takerAmt);
    assert.equal(await vault.read.tokenFees([tokenA.address]), takerFee);
    assert.equal(await vault.read.tokenFees([tokenB.address]), makerFee);
  });

  it("reverts settleTrades when caller is not an allowed key", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, chainId, maker, taker, tokenA, tokenB, exchange } = ctx;

    const unit = 10n ** 12n;
    const makerAmt = 100n * unit;
    const takerAmt = 200n * unit;
    const ts = await publicClient.getBlock().then((b) => b.timestamp);
    const expiry = ts + 3600n;

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 11n,
    };
    const takerOrder = {
      maker: taker.account.address,
      makerToken: tokenB.address,
      takerToken: tokenA.address,
      makerAmount: takerAmt,
      takerAmount: makerAmt,
      expiry,
      salt: 12n,
    };
    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);

    const exAsTaker = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: taker },
    });

    await viem.assertions.revertWithCustomError(
      exAsTaker.write.settleTrades([
        takerOrder,
        takerSig,
        [makerOrder],
        [makerSig],
        [{ makerAmount: makerAmt, takerAmount: takerAmt }],
      ]),
      exchange,
      "NotAllowedKey",
    );
  });

  it("reverts on expired order", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, chainId, maker, taker, relayer, tokenA, tokenB, exchange } = ctx;

    const makerAmt = 1000n;
    const takerAmt = 2000n;
    const expiry = 1n;

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 21n,
    };
    const takerOrder = {
      maker: taker.account.address,
      makerToken: tokenB.address,
      takerToken: tokenA.address,
      makerAmount: takerAmt,
      takerAmount: makerAmt,
      expiry,
      salt: 22n,
    };
    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);

    const ex = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: relayer },
    });

    await viem.assertions.revertWithCustomError(
      ex.write.settleTrades([
        takerOrder,
        takerSig,
        [makerOrder],
        [makerSig],
        [{ makerAmount: makerAmt, takerAmount: takerAmt }],
      ]),
      exchange,
      "OrderExpired",
    );
  });

  it("reverts MakerPriceInvalid when maker fulfillment violates limit price", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, chainId, maker, taker, relayer, tokenA, tokenB, exchange } = ctx;

    const makerAmt = 10_000n;
    const takerAmt = 20_000n;
    const ts = await publicClient.getBlock().then((b) => b.timestamp);
    const expiry = ts + 3600n;

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 31n,
    };
    const takerOrder = {
      maker: taker.account.address,
      makerToken: tokenB.address,
      takerToken: tokenA.address,
      makerAmount: takerAmt,
      takerAmount: makerAmt,
      expiry,
      salt: 32n,
    };
    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);

    const ex = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: relayer },
    });

    await viem.assertions.revertWithCustomError(
      ex.write.settleTrades([
        takerOrder,
        takerSig,
        [makerOrder],
        [makerSig],
        [{ makerAmount: makerAmt, takerAmount: takerAmt - 1n }],
      ]),
      exchange,
      "MakerPriceInvalid",
    );
  });

  it("reverts TakerPriceInvalid when aggregated fill violates taker limit", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, chainId, maker, taker, relayer, tokenA, tokenB, exchange, vault } = ctx;

    const makerAmt = 100n;
    const takerAmt = 150n;
    const ts = await publicClient.getBlock().then((b) => b.timestamp);
    const expiry = ts + 3600n;

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 41n,
    };
    const takerOrder = {
      maker: taker.account.address,
      makerToken: tokenB.address,
      takerToken: tokenA.address,
      makerAmount: takerAmt,
      takerAmount: makerAmt,
      expiry,
      salt: 42n,
    };

    await tokenA.write.mint([maker.account.address, makerAmt * 2n]);
    await tokenB.write.mint([taker.account.address, takerAmt * 2n]);
    await tokenA.write.approve([vault.address, makerAmt * 2n], { account: maker.account });
    await tokenB.write.approve([vault.address, takerAmt * 2n], { account: taker.account });

    const vaultMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    const vaultTaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: taker },
    });
    await vaultMaker.write.deposit([tokenA.address, makerAmt * 2n]);
    await vaultTaker.write.deposit([tokenB.address, takerAmt * 2n]);

    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);

    const ex = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: relayer },
    });

    await viem.assertions.revertWithCustomError(
      ex.write.settleTrades([
        takerOrder,
        takerSig,
        [makerOrder],
        [makerSig],
        [{ makerAmount: 99n, takerAmount: 149n }],
      ]),
      exchange,
      "TakerPriceInvalid",
    );
  });

  it("reverts when maker/taker token pairs do not match", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, chainId, maker, taker, relayer, tokenA, tokenB, exchange } = ctx;

    const makerAmt = 100n;
    const takerAmt = 200n;
    const ts = await publicClient.getBlock().then((b) => b.timestamp);
    const expiry = ts + 3600n;

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 43n,
    };
    const takerOrder = {
      maker: taker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: takerAmt,
      takerAmount: makerAmt,
      expiry,
      salt: 44n,
    };
    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);

    const ex = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: relayer },
    });

    await viem.assertions.revertWithCustomError(
      ex.write.settleTrades([
        takerOrder,
        takerSig,
        [makerOrder],
        [makerSig],
        [{ makerAmount: makerAmt, takerAmount: takerAmt }],
      ]),
      exchange,
      "TokenPairMismatch",
    );
  });

  it("reverts MakerOverfilled when cumulated fill exceeds maker order", async function () {
    const ctx = await deploySpotSystem();
    const {
      viem,
      publicClient,
      chainId,
      maker,
      taker,
      relayer,
      tokenA,
      tokenB,
      exchange,
      vault,
    } = ctx;

    const makerAmt = 10_000n;
    const takerAmt = 20_000n;
    const ts = await publicClient.getBlock().then((b) => b.timestamp);
    const expiry = ts + 3600n;

    await tokenA.write.mint([maker.account.address, makerAmt * 2n]);
    await tokenB.write.mint([taker.account.address, takerAmt * 4n]);
    await tokenA.write.approve([vault.address, makerAmt * 2n], { account: maker.account });
    await tokenB.write.approve([vault.address, takerAmt * 4n], { account: taker.account });
    const vaultMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    const vaultTaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: taker },
    });
    await vaultMaker.write.deposit([tokenA.address, makerAmt * 2n]);
    await vaultTaker.write.deposit([tokenB.address, takerAmt * 4n]);

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 51n,
    };
    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const ex = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: relayer },
    });

    const run = async (takerSalt: bigint, fillA: bigint, fillB: bigint) => {
      const takerOrder = {
        maker: taker.account.address,
        makerToken: tokenB.address,
        takerToken: tokenA.address,
        makerAmount: fillB,
        takerAmount: fillA,
        expiry,
        salt: takerSalt,
      };
      const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);
      await ex.write.settleTrades([
        takerOrder,
        takerSig,
        [makerOrder],
        [makerSig],
        [{ makerAmount: fillA, takerAmount: fillB }],
      ]);
    };

    await run(61n, 6000n, 12000n);
    await viem.assertions.revertWithCustomError(
      run(62n, 5000n, 10000n),
      exchange,
      "MakerOverfilled",
    );
  });

  it("reverts TakerOverfilled when fill exceeds taker makerAmount", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, chainId, maker, taker, relayer, tokenA, tokenB, exchange, vault } = ctx;

    const makerAmt = 10_000n;
    const takerAmt = 20_000n;
    const ts = await publicClient.getBlock().then((b) => b.timestamp);
    const expiry = ts + 3600n;

    await tokenA.write.mint([maker.account.address, makerAmt * 2n]);
    await tokenB.write.mint([taker.account.address, takerAmt * 2n]);
    await tokenA.write.approve([vault.address, makerAmt * 2n], { account: maker.account });
    await tokenB.write.approve([vault.address, takerAmt * 2n], { account: taker.account });
    const vaultMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    const vaultTaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: taker },
    });
    await vaultMaker.write.deposit([tokenA.address, makerAmt * 2n]);
    await vaultTaker.write.deposit([tokenB.address, takerAmt * 2n]);

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 81n,
    };
    const takerOrder = {
      maker: taker.account.address,
      makerToken: tokenB.address,
      takerToken: tokenA.address,
      makerAmount: 11_000n,
      takerAmount: 5_500n,
      expiry,
      salt: 82n,
    };
    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);

    const ex = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: relayer },
    });

    await viem.assertions.revertWithCustomError(
      ex.write.settleTrades([
        takerOrder,
        takerSig,
        [makerOrder],
        [makerSig],
        [{ makerAmount: 6000n, takerAmount: 12_000n }],
      ]),
      exchange,
      "TakerOverfilled",
    );
  });

  it("allows two partial fills against the same maker order", async function () {
    const ctx = await deploySpotSystem();
    const {
      viem,
      publicClient,
      chainId,
      maker,
      taker,
      relayer,
      tokenA,
      tokenB,
      exchange,
      vault,
    } = ctx;

    const makerAmt = 10_000n;
    const takerAmt = 20_000n;
    const ts = await publicClient.getBlock().then((b) => b.timestamp);
    const expiry = ts + 3600n;

    await tokenA.write.mint([maker.account.address, makerAmt * 2n]);
    await tokenB.write.mint([taker.account.address, takerAmt * 2n]);
    await tokenA.write.approve([vault.address, makerAmt * 2n], { account: maker.account });
    await tokenB.write.approve([vault.address, takerAmt * 2n], { account: taker.account });
    const vaultMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    const vaultTaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: taker },
    });
    await vaultMaker.write.deposit([tokenA.address, makerAmt * 2n]);
    await vaultTaker.write.deposit([tokenB.address, takerAmt * 2n]);

    const makerOrder = {
      maker: maker.account.address,
      makerToken: tokenA.address,
      takerToken: tokenB.address,
      makerAmount: makerAmt,
      takerAmount: takerAmt,
      expiry,
      salt: 71n,
    };
    const makerSig = await signSpotOrder(maker, chainId, exchange.address, makerOrder);
    const ex = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: relayer },
    });

    const settleHalf = async (salt: bigint) => {
      const halfA = makerAmt / 2n;
      const halfB = takerAmt / 2n;
      const takerOrder = {
        maker: taker.account.address,
        makerToken: tokenB.address,
        takerToken: tokenA.address,
        makerAmount: halfB,
        takerAmount: halfA,
        expiry,
        salt,
      };
      const takerSig = await signSpotOrder(taker, chainId, exchange.address, takerOrder);
      await ex.write.settleTrades([
        takerOrder,
        takerSig,
        [makerOrder],
        [makerSig],
        [{ makerAmount: halfA, takerAmount: halfB }],
      ]);
    };

    await settleHalf(81n);
    await settleHalf(82n);

    const typeHash = await exchange.read.SPOT_ORDER_TYPEHASH();
    const orderHash = hashSpotOrderStruct(typeHash, makerOrder);
    const filled = await exchange.read.filledAmount([orderHash]);
    assert.equal(filled, makerAmt);
  });

  it("only owner can setVault", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, taker, exchange, vault } = ctx;

    const exAsTaker = await viem.getContractAt("SpotExchange", exchange.address, {
      client: { public: publicClient, wallet: taker },
    });

    await viem.assertions.revertWithCustomError(
      exAsTaker.write.setVault([vault.address]),
      exchange,
      "OwnableUnauthorizedAccount",
    );
  });
});
