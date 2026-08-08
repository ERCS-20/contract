import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

const COL = 10n ** 18n;
const MAX_8H = (COL * 75n) / 10_000n; // 0.75%
const EIGHT_HOURS = 8n * 3600n;

describe("Ercs20FundingOracle", async function () {
  async function deploy() {
    const { viem, networkHelpers } = await network.connect();
    const publicClient = await viem.getPublicClient();
    const [deployer, exchange] = await viem.getWalletClients();

    const spot = await viem.deployContract("MockErcs20Reserves", []);
    // spot mid = 100
    await spot.write.setReserves([1n * COL, 100n * COL]);

    const funder = await viem.deployContract("Ercs20FundingOracle", [
      exchange.account.address,
      spot.address,
      5n * 60n,
    ]);

    const funderAsExchange = await viem.getContractAt("Ercs20FundingOracle", funder.address, {
      client: { public: publicClient, wallet: exchange },
    });

    return { viem, networkHelpers, publicClient, deployer, exchange, spot, funder, funderAsExchange };
  }

  it("samples premium from last vs spot and clamps to 0.75%/8h", async function () {
    const { funder, funderAsExchange } = await deploy();

    // last = 110 → premium 10%, clamps to 0.75%
    await funderAsExchange.write.update([110n * COL]);
    assert.equal(await funder.read.isPositive(), true);

    const ratePerSec = MAX_8H / EIGHT_HOURS;
    assert.equal(await funder.read.ratePerSecondX18(), ratePerSec);

    const [positive, value] = await funder.read.getFunding([EIGHT_HOURS]);
    assert.equal(positive, true);
    // integer division: ratePerSec * 8h ≤ MAX_8H
    assert.equal(value, ratePerSec * EIGHT_HOURS);
  });

  it("negative premium: shorts pay longs", async function () {
    const { funder, funderAsExchange } = await deploy();

    await funderAsExchange.write.update([90n * COL]);
    assert.equal(await funder.read.isPositive(), false);
    assert.equal(await funder.read.ratePerSecondX18(), MAX_8H / EIGHT_HOURS);
  });

  it("respects 5 minute sample interval", async function () {
    const { networkHelpers, funder, funderAsExchange } = await deploy();

    const ok1 = await funderAsExchange.write.update([101n * COL]);
    await networkHelpers.mine(); // ensure tx mined before reading
    assert.equal(await funder.read.lastSampleAt() > 0n, true);

    // immediate second sample should no-op
    await funderAsExchange.write.update([120n * COL]);
    // rate still from first sample (premium ~1% → clamp 0.75%)
    const rateAfter = await funder.read.ratePerSecondX18();
    assert.equal(rateAfter, MAX_8H / EIGHT_HOURS);

    await networkHelpers.time.increase(5 * 60);
    await funderAsExchange.write.update([100n * COL]); // premium 0
    assert.equal(await funder.read.ratePerSecondX18(), 0n);
    void ok1;
  });

  it("rejects non-exchange caller", async function () {
    const { viem, funder } = await deploy();
    await viem.assertions.revertWithCustomError(funder.write.update([100n * COL]), funder, "NotExchange");
  });
});
