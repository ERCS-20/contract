import { network } from "hardhat";

/**
 * Deploy PerpsExchange + GlobalPerpsVault + oracles + PerpsPairFactory and wire roles.
 *
 * Usage:
 *   npx hardhat run scripts/deploy.ts --network hardhatMainnet
 */
async function main() {
  const { viem } = await network.getOrCreate();
  const publicClient = await viem.getPublicClient();
  const [deployer, daoWallet] = await viem.getWalletClients();

  const ercs20Factory = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
  const orbix = "0xCafac3dD18aC6c6e92c921884f9E4176737C052c";

  const withdrawDao = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";
  const operator = "0x90F79bf6EB2c4f870365E785982E1f101E93b906";
  const liquidator = "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65";

  const exchange = await viem.deployContract("PerpsExchange", []);
  console.log("PerpsExchange:", exchange.address);

  const vault = await viem.deployContract("GlobalPerpsVault", [exchange.address]);
  console.log("GlobalPerpsVault:", vault.address);

  await exchange.write.setDAO([daoWallet.account.address, true]);
  const exchangeAsDao = await viem.getContractAt("PerpsExchange", exchange.address, {
    client: { public: publicClient, wallet: daoWallet },
  });

  await exchangeAsDao.write.setVault([vault.address]);
  console.log("PerpsExchange.setVault applied");

  const twap = await viem.deployContract("Ercs20TwapOracle", [exchange.address]);
  console.log("Ercs20TwapOracle:", twap.address);

  const funder = await viem.deployContract("Ercs20FundingOracle", [exchange.address]);
  console.log("Ercs20FundingOracle:", funder.address);

  await exchangeAsDao.write.setOracle([twap.address]);
  await exchangeAsDao.write.setFunder([funder.address]);
  console.log("PerpsExchange oracle/funder set");

  const pairFactory = await viem.deployContract("PerpsPairFactory", [
    ercs20Factory,
    exchange.address,
  ]);
  console.log("PerpsPairFactory:", pairFactory.address);

  await exchange.write.setFactory([pairFactory.address]);
  await exchangeAsDao.write.setOperator([operator, true]);
  await exchangeAsDao.write.setLiquidator([liquidator, true]);

  await vault.write.setWithdrawDAO([withdrawDao]);
  await vault.write.setPauseDAO([daoWallet.account.address]);
  await vault.write.setClaimFeeDAO([daoWallet.account.address]);

  await pairFactory.write.setPairDAO([daoWallet.account.address]);
  await pairFactory.write.setInsuranceAccount([liquidator]);
  console.log("Roles wired (DAO / operator / liquidator / insurance)");

  const fee = await pairFactory.read.fee();
  await pairFactory.write.create([orbix], { value: fee });
  console.log("PerpsPairFactory.create(orbix) applied, fee:", fee.toString());
  console.log("Deployer:", deployer.account.address);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
