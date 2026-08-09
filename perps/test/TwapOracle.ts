import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

const COL = 10n ** 18n;
const MARKET_ID = 1n;

describe("Ercs20TwapOracle", async function () {
  async function deploy() {
    const { viem, networkHelpers } = await network.connect();
    const publicClient = await viem.getPublicClient();
    const [, exchange] = await viem.getWalletClients();

    const spot = await viem.deployContract("MockErcs20Reserves", []);
    await spot.write.setReserves([1n * COL, 100n * COL]); // mid = 100

    const oracle = await viem.deployContract("Ercs20TwapOracle", [
      exchange.account.address,
      15n * 60n,
      30n,
    ]);

    const oracleAsExchange = await viem.getContractAt("Ercs20TwapOracle", oracle.address, {
      client: { public: publicClient, wallet: exchange },
    });

    return { viem, networkHelpers, publicClient, exchange, spot, oracle, oracleAsExchange };
  }

  it("after first sample, mark equals spot mid", async function () {
    const { oracle, oracleAsExchange, spot } = await deploy();
    await oracleAsExchange.write.update([MARKET_ID, spot.address]);
    assert.equal(await oracle.read.getPrice([MARKET_ID]), 100n * COL);
  });

  it("respects 30s sample interval", async function () {
    const { networkHelpers, oracle, oracleAsExchange, spot } = await deploy();
    await oracleAsExchange.write.update([MARKET_ID, spot.address]);

    await spot.write.setReserves([1n * COL, 200n * COL]);
    await oracleAsExchange.write.update([MARKET_ID, spot.address]); // too soon
    assert.equal(await oracle.read.lastMidX18([MARKET_ID]), 100n * COL);

    await networkHelpers.time.increase(30);
    await oracleAsExchange.write.update([MARKET_ID, spot.address]);
    assert.equal(await oracle.read.lastMidX18([MARKET_ID]), 200n * COL);
  });

  it("TWAP blends old and new mids over time", async function () {
    const { networkHelpers, oracle, oracleAsExchange, spot } = await deploy();
    await oracleAsExchange.write.update([MARKET_ID, spot.address]);

    await networkHelpers.time.increase(30);
    await spot.write.setReserves([1n * COL, 200n * COL]);
    await oracleAsExchange.write.update([MARKET_ID, spot.address]);

    await networkHelpers.time.increase(30);
    const mark = await oracle.read.getPrice([MARKET_ID]);
    assert.ok(mark > 100n * COL);
    assert.ok(mark < 200n * COL);
  });

  it("rejects non-exchange caller", async function () {
    const { viem, oracle, spot } = await deploy();
    await viem.assertions.revertWithCustomError(
      oracle.write.update([MARKET_ID, spot.address]),
      oracle,
      "NotExchange",
    );
  });
});
