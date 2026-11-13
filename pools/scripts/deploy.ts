import { network } from "hardhat";

const claimFeeDaoAbi = [
  {
    type: "function",
    name: "setClaimFeeDAO",
    stateMutability: "nonpayable",
    inputs: [{ name: "dao", type: "address" }],
    outputs: [],
  },
] as const;

/**
 * Deploy SpotMiningPool + PerpsMiningPool and set each vault's claimFeeDAO.
 *
 * Usage:
 *   npx hardhat run scripts/deploy.ts --network local_host
 */
async function main() {
  const { viem } = await network.getOrCreate();
  const [deployer] = await viem.getWalletClients();

  const stakeToken = "0xCafac3dD18aC6c6e92c921884f9E4176737C052c";
  const spotVault = "0x0165878a594ca255338adfa4d48449f69242eb8f";
  const perpsVault = "0x0dcd1bf9a1b36ce34237eeafef220932846bcd82";

  const operator = "0x90F79bf6EB2c4f870365E785982E1f101E93b906";
  const withdrawer = "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720";

  const spotPool = await viem.deployContract("SpotMiningPool", [stakeToken, spotVault]);
  console.log("SpotMiningPool:", spotPool.address);

  const perpsPool = await viem.deployContract("PerpsMiningPool", [stakeToken, perpsVault]);
  console.log("PerpsMiningPool:", perpsPool.address);

  await deployer.writeContract({
    address: spotVault,
    abi: claimFeeDaoAbi,
    functionName: "setClaimFeeDAO",
    args: [spotPool.address],
  });
  await deployer.writeContract({
    address: perpsVault,
    abi: claimFeeDaoAbi,
    functionName: "setClaimFeeDAO",
    args: [perpsPool.address],
  });
  console.log("claimFeeDAO set on both vaults");

  await spotPool.write.setOperator([operator]);
  await spotPool.write.setWithdrawer([withdrawer]);
  await perpsPool.write.setOperator([operator]);
  await perpsPool.write.setWithdrawer([withdrawer]);
  console.log("Roles wired (operator / withdrawer)");
  console.log("Deployer:", deployer.account.address);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
