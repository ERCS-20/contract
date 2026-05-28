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

  const ercs20Factory = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
  const orbix = "0xCafac3dD18aC6c6e92c921884f9E4176737C052c";

  const weth9 = await viem.deployContract("WETH9", []);
  console.log("WETH9 (vault weth9 stand-in):", weth9.address);

  const exchange = await viem.deployContract("SpotExchange");
  console.log("SpotExchange:", exchange.address);
  await exchange.write.addDAO(["0x70997970C51812dc3A010C7d01b50e0d17dc79C8"]);

  const vault = await viem.deployContract("GlobalSpotVault", [weth9.address, exchange.address]);
  console.log("GlobalSpotVault:", vault.address);

  await exchange.write.setVault([vault.address]);
  console.log("SpotExchange.setVault applied");

  const pairFactory = await viem.deployContract("SpotPairFactory", [ercs20Factory, vault.address]);
  await pairFactory.write.setPairDAO(["0x70997970C51812dc3A010C7d01b50e0d17dc79C8"]);
  console.log("SpotPairFactory:", pairFactory.address);

  await vault.write.setTokenWhitelistDAO([pairFactory.address]);
  await vault.write.setWithdrawDAO(["0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"]);

  await pairFactory.write.create([orbix]);

  
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
