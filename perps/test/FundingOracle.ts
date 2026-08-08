import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

const COL = 10n ** 18n;
const MAX_8H = (COL * 75n) / 10_000n; // 0.75%
const EIGHT_HOURS = 8n * 3600n;
const MARKET_ID = 1n;

describe("Ercs20FundingOracle", async function () {
  async function deploy() {
    const { viem, networkHelpers } = await network.connect();
    const publicClient = await viem.getPublicClient();
    const [deployer, exchange] = await viem.getWalletClients();

    const spot = await viem.deployContract("MockErcs20Reserves", []);
    await spot.write.setReserves([1n * COL, 100n * COL]);

    const funder = await viem.deployContract("Ercs20FundingOracle", [
      exchange.account.address,
      5n * 60n,
    ]);
    await funder.write.setFactory([deployer.account.address]);
    await funder.write.setErcs20([MARKET_ID, spot.address]);

    const funderAsExchange = await viem.getContractAt("Ercs20FundingOracle", funder.address, {
      client: { public: publicClient, wallet: exchange },
    });

    return { viem, networkHelpers, publicClient, deployer, exchange, spot, funder, funderAsExchange };
  }

  it("samples premium from last vs spot and clamps to 0.75%/8h", async function () {
    const { funder, funderAsExchange } = await deploy();

    await funderAsExchange.write.update([MARKET_ID, 110n * COL]);
    const ratePerSec = MAX_8H / EIGHT_HOURS;
    const m = await funder.read.markets([MARKET_ID]);
    assert.equal(m[1], true); // isPositive
    assert.equal(m[2], ratePerSec);

    const [positive, value] = await funder.read.getFunding([MARKET_ID, EIGHT_HOURS]);
    assert.equal(positive, true);
    assert.equal(value, ratePerSec * EIGHT_HOURS);
  });

  it("negative premium: shorts pay longs", async function () {
    const { funder, funderAsExchange } = await deploy();

    await funderAsExchange.write.update([MARKET_ID, 90n * COL]);
    const m = await funder.read.markets([MARKET_ID]);
    assert.equal(m[1], false);
    assert.equal(m[2], MAX_8H / EIGHT_HOURS);
  });

  it("respects 5 minute sample interval", async function () {
    const { networkHelpers, funder, funderAsExchange } = await deploy();

    await funderAsExchange.write.update([MARKET_ID, 101n * COL]);
    await funderAsExchange.write.update([MARKET_ID, 120n * COL]);
    assert.equal((await funder.read.markets([MARKET_ID]))[2], MAX_8H / EIGHT_HOURS);

    await networkHelpers.time.increase(5 * 60);
    await funderAsExchange.write.update([MARKET_ID, 100n * COL]);
    assert.equal((await funder.read.markets([MARKET_ID]))[2], 0n);
  });

  it("rejects non-exchange caller", async function () {
    const { viem, funder } = await deploy();
    await viem.assertions.revertWithCustomError(
      funder.write.update([MARKET_ID, 100n * COL]),
      funder,
      "NotExchange",
    );
  });
});
