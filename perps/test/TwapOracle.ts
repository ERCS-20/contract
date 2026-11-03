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

    const oracle = await viem.deployContract("Ercs20TwapOracle", [exchange.account.address]);

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

  it("respects 1s sample interval", async function () {
    const { viem, networkHelpers, spot } = await deploy();
    const harness = await viem.deployContract("TwapUpdateHarness", []);
    const oracle = await viem.deployContract("Ercs20TwapOracle", [harness.address]);

    const simulated = await harness.simulate.updateTwice([oracle.address, MARKET_ID, spot.address]);
    assert.equal(simulated.result[0], true);
    assert.equal(simulated.result[1], false);
    await harness.write.updateTwice([oracle.address, MARKET_ID, spot.address]);
    assert.equal(await oracle.read.lastMidX18([MARKET_ID]), 100n * COL);

    const sampledAt = await oracle.read.lastSampleAt([MARKET_ID]);
    await networkHelpers.time.setNextBlockTimestamp(sampledAt + 1n);
    await spot.write.setReserves([1n * COL, 200n * COL]);
    await networkHelpers.time.setNextBlockTimestamp(sampledAt + 2n);
    await harness.write.update([oracle.address, MARKET_ID, spot.address]);
    assert.equal(await oracle.read.lastMidX18([MARKET_ID]), 200n * COL);
  });

  it("TWAP is settled in update and stays put until the next sample", async function () {
    const { networkHelpers, publicClient, oracle, oracleAsExchange, spot } = await deploy();
    const t = (await publicClient.getBlock()).timestamp + 100n;

    await networkHelpers.time.setNextBlockTimestamp(t);
    await oracleAsExchange.write.update([MARKET_ID, spot.address]);

    await networkHelpers.time.setNextBlockTimestamp(t + 1n);
    await spot.write.setReserves([1n * COL, 200n * COL]);

    await networkHelpers.time.setNextBlockTimestamp(t + 2n);
    await oracleAsExchange.write.update([MARKET_ID, spot.address]);

    await networkHelpers.time.setNextBlockTimestamp(t + 4n);
    await oracleAsExchange.write.update([MARKET_ID, spot.address]);

    const mark = await oracle.read.getPrice([MARKET_ID]);
    // 2s at 100 then 2s at 200 → 150. Time after this sample does not move the stored mark.
    assert.equal(mark, 150n * COL);

    await networkHelpers.time.setNextBlockTimestamp(t + 20n);
    await networkHelpers.mine();
    assert.equal(await oracle.read.getPrice([MARKET_ID]), mark);
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
