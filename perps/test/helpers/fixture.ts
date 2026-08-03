import { network } from "hardhat";

export const MARKET_ID = 1n;
/** Mark / fill price: 100 quote per base, 1e18 fixed-point. */
export const PRICE = 100n * 10n ** 18n;
/** Fixed ADL equity threshold in collateral units (ARC native USDC = 18 decimals). */
export const ADL_THRESHOLD = 50n * 10n ** 18n;

export async function deployPerpsSystem() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [deployer, withdrawDao, pauseDao, operator, maker, taker, seed] =
    await viem.getWalletClients();

  const oracle = await viem.deployContract("MockOracle", []);

  const exchange = await viem.deployContract("PerpsExchange", []);
  const vault = await viem.deployContract("GlobalPerpsVault", [exchange.address]);

  await exchange.write.setVault([vault.address]);
  await exchange.write.setPauseDAO([pauseDao.account.address]);
  await vault.write.setWithdrawDAO([withdrawDao.account.address]);
  await vault.write.setPauseDAO([pauseDao.account.address]);
  await exchange.write.setOperator([operator.account.address, true]);

  await oracle.write.setPrice([MARKET_ID, PRICE]);
  await exchange.write.createMarket([MARKET_ID, oracle.address, ADL_THRESHOLD]);

  const chainId = await publicClient.getChainId();

  return {
    viem,
    publicClient,
    chainId,
    deployer,
    withdrawDao,
    pauseDao,
    operator,
    maker,
    taker,
    seed,
    oracle,
    exchange,
    vault,
    MARKET_ID,
    PRICE,
    ADL_THRESHOLD,
  };
}

export async function fundAndDeposit(
  ctx: Awaited<ReturnType<typeof deployPerpsSystem>>,
  wallet: { account: { address: `0x${string}` } },
  amount: bigint,
) {
  const { viem, publicClient, vault } = ctx;
  const vaultAsUser = await viem.getContractAt("GlobalPerpsVault", vault.address, {
    client: { public: publicClient, wallet },
  });
  await vaultAsUser.write.deposit({ value: amount });
}
