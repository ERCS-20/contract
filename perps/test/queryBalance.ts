import { describe, it } from "node:test";
import type { Address } from "viem";
import { formatEther } from "viem";

import { network } from "hardhat";

/** Hardhat #9 / deploy.ts withdrawDao. */
const ACCOUNT = "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720" as Address;
const MARKET_ID = 0n;

/** Override with PERPS_EXCHANGE=0x... if redeployed. */
const EXCHANGE =
  (process.env.PERPS_EXCHANGE as Address | undefined) ??
  ("0xa51c1fc2f0d1a1b8494ed1fe312d7c3a78ed91c0" as Address);

/**
 * Read-only probe against a deployed PerpsExchange.
 *
 *   npx hardhat test test/queryBalance.ts --network local_host
 */
describe("queryBalance", async function () {
  it(`prints balances(${ACCOUNT}, marketId=${MARKET_ID})`, async function () {
    const { viem } = await network.getOrCreate();
    const exchange = await viem.getContractAt("PerpsExchange", EXCHANGE);

    const [margin, position] = await exchange.read.balances([ACCOUNT, MARKET_ID]);
    const [ercs20, exists, paused, , , lastPriceX18] = await exchange.read.markets([MARKET_ID]);
    const vaultAddr = await exchange.read.vault();
    const vault = await viem.getContractAt("GlobalPerpsVault", vaultAddr);
    const free = await vault.read.balances([ACCOUNT]);
    const [fundingTs, fundingValue] = await exchange.read.localFundingIndex([ACCOUNT, MARKET_ID]);

    console.log({
      exchange: EXCHANGE,
      account: ACCOUNT,
      marketId: MARKET_ID.toString(),
      market: { ercs20, exists, paused, lastPriceX18: lastPriceX18.toString() },
      balance: {
        margin: margin.toString(),
        marginEther: formatEther(margin),
        position: position.toString(),
        positionEther: formatEther(position),
      },
      vaultFree: {
        amount: free.toString(),
        ether: formatEther(free),
      },
      localFundingIndex: {
        timestamp: fundingTs.toString(),
        value: fundingValue.toString(),
      },
    });
  });
});
