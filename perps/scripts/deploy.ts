import { network } from "hardhat";
import { parseEther } from "viem";

/**
 * Deploy PerpsExchange + GlobalPerpsVault + oracles + PerpsPairFactory and wire roles.
 *
 * Usage:
 *   npx hardhat run scripts/deploy.ts --network hardhatMainnet
 */
async function main() {
  const { viem } = await network.getOrCreate();
  const publicClient = await viem.getPublicClient();
  const [deployer] = await viem.getWalletClients();

  const ercs20Factory = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
  const orbix = "0xCafac3dD18aC6c6e92c921884f9E4176737C052c";

  const dao = deployer.account.address;
  const withdrawDao = "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720";
  const operator = "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f";
  const liquidator = "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955";
  const fee = parseEther("1000");

  const exchange = await viem.deployContract("PerpsExchange", []);
  console.log("PerpsExchange:", exchange.address);

  const vault = await viem.deployContract("GlobalPerpsVault", [exchange.address]);
  console.log("GlobalPerpsVault:", vault.address);

  await exchange.write.setDAO([dao, true]);
  const exchangeAsDao = await viem.getContractAt("PerpsExchange", exchange.address, {
    client: { public: publicClient, wallet: deployer },
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
  // await vault.write.setPauseDAO([]);
  // await vault.write.setClaimFeeDAO([]);

  await pairFactory.write.setInsuranceAccount([liquidator]);
  console.log("Roles wired (DAO / operator / liquidator / insurance)");
  await pairFactory.write.setFee([fee]);

  const openingTime = BigInt(Math.floor(Date.now() / 1000));
  await pairFactory.write.create([orbix, openingTime], { value: fee });
  console.log(
    "PerpsPairFactory.create(orbix) applied, fee:",
    fee.toString(),
    "openingTime:",
    openingTime.toString(),
  );
  console.log("Deployer:", deployer.account.address);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
