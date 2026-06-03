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

const ORBIX_ADDRESS = (process.env.ORBIX_ADDRESS ??
  "0xCafac3dD18aC6c6e92c921884f9E4176737C052c") as `0x${string}`;
const VAULT_ADDRESS = (process.env.VAULT_ADDRESS ??
  "0x0165878a594ca255338adfa4d48449f69242eb8f") as `0x${string}`;

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [wallet] = await viem.getWalletClients();

  const usdcBuyAmount = parseEther("100");
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const amountInMin = 0n;

  const orbix = await viem.getContractAt(
    "contracts/test/IERCS20.sol:IERCS20",
    ORBIX_ADDRESS,
    { client: { public: publicClient, wallet } },
  );
  const vault = await viem.getContractAt("GlobalSpotVault", VAULT_ADDRESS, {
    client: { public: publicClient, wallet },
  });

  const balanceBefore = await orbix.read.balanceOf([wallet.account.address]);

  console.log("Buying OBX with native USDC:", usdcBuyAmount.toString());
  const buyHash = await orbix.write.buy([amountInMin, deadline], { value: usdcBuyAmount });
  console.log("buy tx:", buyHash);

  const balanceAfterBuy = await orbix.read.balanceOf([wallet.account.address]);
  const bought = balanceAfterBuy - balanceBefore;
  console.log("OBX received from buy:", bought.toString());

  const depositAmount = balanceAfterBuy-balanceBefore;

  console.log("Approving vault for OBX:", depositAmount.toString());
  const approveHash = await orbix.write.approve([VAULT_ADDRESS, maxUint256]);
  console.log("approve tx:", approveHash);

  console.log("Depositing OBX into vault:", depositAmount.toString());
  const depositHash = await vault.write.deposit([ORBIX_ADDRESS, depositAmount]);
  console.log("deposit tx:", depositHash);

  const vaultBalance = await vault.read.balances([wallet.account.address, ORBIX_ADDRESS]);
  console.log("Vault OBX balance:", vaultBalance.toString());

  const depositUSDCTx = await vault.write.depositUSDC({ value: parseEther("100") });
  console.log("depositUSDC tx:", depositUSDCTx);

}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
