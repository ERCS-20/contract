import { network } from "hardhat";
import { maxUint256, parseEther } from "viem";

/**
 * Buy OBX via ERCS20 `buy`, approve GlobalSpotVault, then deposit OBX.
 *
 * Usage:
 *   npx hardhat run scripts/deposit.ts --network local_host
 *
 * Optional env:
 *   ORBIX_ADDRESS   - ERCS20 token (default: local deploy address)
 *   VAULT_ADDRESS   - GlobalSpotVault
 *   USDC_BUY_AMOUNT - native USDC sent to `buy` (default: "10")
 *   DEPOSIT_AMOUNT  - OBX to deposit; if unset, deposits full wallet OBX balance after buy
 */

const VAULT_ADDRESS = (process.env.VAULT_ADDRESS ??
  "0x0165878a594ca255338adfa4d48449f69242eb8f") as `0x${string}`;

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [wallet] = await viem.getWalletClients();

  const signature = "0x1ae7cc8f07eb54b8900181e2d1a1541993dc1cc18d6cee9dced0857f384401010c14f739e84f465c9c0e6b89970084bf11174a9a6fa8c65fa54b5a1aa208bbf61c";
  const orderId = 7644886991963684865n;
  const token = "0xcafac3dd18ac6c6e92c921884f9e4176737c052c";
  const amount = 10000000000000000000n;

  const vault = await viem.getContractAt("GlobalSpotVault", VAULT_ADDRESS, {
    client: { public: publicClient, wallet },
  });
  await vault.write.withdraw([orderId, token, amount, signature]);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
