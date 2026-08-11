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
  const [deployer] = await viem.getWalletClients();

  const ercs20Factory = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
  const orbix = "0xCafac3dD18aC6c6e92c921884f9E4176737C052c";

  const dao = deployer.account.address;
  const withdrawDao = "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720";
  const operator = "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f";
  const liquidator = "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955";

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

  const fee = await pairFactory.read.fee();
  await pairFactory.write.create([orbix], { value: fee });
  console.log("PerpsPairFactory.create(orbix) applied, fee:", fee.toString());
  console.log("Deployer:", deployer.account.address);

  // PerpsExchange: 0xa51c1fc2f0d1a1b8494ed1fe312d7c3a78ed91c0
  // GlobalPerpsVault: 0x0dcd1bf9a1b36ce34237eeafef220932846bcd82
  // PerpsExchange.setVault applied
  // Ercs20TwapOracle: 0x959922be3caee4b8cd9a407cc3ac1c251c2007b1
  // Ercs20FundingOracle: 0x9a9f2ccfde556a7e9ff0848998aa4a0cfd8863ae
  // PerpsExchange oracle/funder set
  // PerpsPairFactory: 0xc6e7df5e7b4f2a278906862b61205850344d4e7d
  // Roles wired (DAO / operator / liquidator / insurance)
  // PerpsPairFactory.create(orbix) applied, fee: 1000000000000000000000
  // Deployer: 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
