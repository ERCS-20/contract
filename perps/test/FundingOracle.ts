import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

const COL = 10n ** 18n;
const MAX_1H = (COL * 75n) / 10_000n / 8n; // 0.75% / 8 per hour
const ONE_HOUR = 3600n;
const MARKET_ID = 1n;

describe("Ercs20FundingOracle", async function () {
  async function deploy() {
    const { viem, networkHelpers } = await network.connect();
    const publicClient = await viem.getPublicClient();
    const [, exchange] = await viem.getWalletClients();

    const spot = await viem.deployContract("MockErcs20Reserves", []);
    await spot.write.setReserves([1n * COL, 100n * COL]);

    const funder = await viem.deployContract("Ercs20FundingOracle", [exchange.account.address]);

    const funderAsExchange = await viem.getContractAt("Ercs20FundingOracle", funder.address, {
      client: { public: publicClient, wallet: exchange },
    });

    return { viem, networkHelpers, publicClient, exchange, spot, funder, funderAsExchange };
  }

  it("samples premium from last vs spot and clamps to 0.75%/8 per hour", async function () {
    const { funder, funderAsExchange, spot } = await deploy();

    await funderAsExchange.write.update([MARKET_ID, 110n * COL, spot.address]);
    const ratePerSec = MAX_1H / ONE_HOUR;
    const m = await funder.read.markets([MARKET_ID]);
    assert.equal(m[0], true); // isPositive
    assert.equal(m[1], ratePerSec);

    const [positive, value] = await funder.read.getFunding([MARKET_ID, ONE_HOUR]);
    assert.equal(positive, true);
    assert.equal(value, ratePerSec * ONE_HOUR);
  });

  it("negative premium: shorts pay longs", async function () {
    const { funder, funderAsExchange, spot } = await deploy();

    await funderAsExchange.write.update([MARKET_ID, 90n * COL, spot.address]);
    const m = await funder.read.markets([MARKET_ID]);
    assert.equal(m[0], false);
    assert.equal(m[1], MAX_1H / ONE_HOUR);
  });

  it("respects 1 hour sample interval", async function () {
    const { networkHelpers, funder, funderAsExchange, spot } = await deploy();

    await funderAsExchange.write.update([MARKET_ID, 101n * COL, spot.address]);
    await funderAsExchange.write.update([MARKET_ID, 120n * COL, spot.address]);
    assert.equal((await funder.read.markets([MARKET_ID]))[1], MAX_1H / ONE_HOUR);

    await networkHelpers.time.increase(60 * 60);
    await funderAsExchange.write.update([MARKET_ID, 100n * COL, spot.address]);
    assert.equal((await funder.read.markets([MARKET_ID]))[1], 0n);
  });

  it("rejects non-exchange caller", async function () {
    const { viem, funder, spot } = await deploy();
    await viem.assertions.revertWithCustomError(
      funder.write.update([MARKET_ID, 100n * COL, spot.address]),
      funder,
      "NotExchange",
    );
  });
});
