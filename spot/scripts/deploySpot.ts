import { network } from "hardhat";
import type { Address } from "viem";

/**
 * Deploy GlobalSpotVault + SpotExchange and wire `exchange.setVault`.
 *
 * - If `WUSDC_ADDRESS` is set, uses it as wrapped native / WUSDC stand-in (production-style).
 * - Otherwise deploys `WETH9` from `contracts/test/WETH9.sol` (local dev; WETH-style `deposit` / `withdraw`).
 *
 * Usage:
 *   npx hardhat run scripts/deploySpot.ts --network hardhatMainnet
 */
async function main() {
  const { viem } = await network.connect();

  const weth9 = await viem.deployContract("WETH9", []);
  console.log("WETH9 (vault weth9 stand-in):", weth9.address);

  const exchange = await viem.deployContract("SpotExchange");
  console.log("SpotExchange:", exchange.address);

  const vault = await viem.deployContract("GlobalSpotVault", [weth9.address, exchange.address]);
  console.log("GlobalSpotVault:", vault.address);

  await exchange.write.setVault([vault.address]);
  console.log("SpotExchange.setVault applied");

  const tx = await exchange.write.addDAO(["0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199"]);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
