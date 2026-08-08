import { network } from "hardhat";

export const MARKET_ID = 1n;
/** Mark / fill price: 100 quote per base, 1e18 fixed-point. */
export const PRICE = 100n * 10n ** 18n;
/** Fixed ADL margin threshold in collateral units (ARC native USDC = 18 decimals). */
export const ADL_THRESHOLD = 50n * 10n ** 18n;
/** Min collateralization ratio: 110% = 1.1e18. */
export const MIN_COLLATERAL = 11n * 10n ** 17n;

export async function deployPerpsSystem() {
  const { viem, networkHelpers } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [deployer, withdrawDao, pauseDao, claimFeeDao, operator, maker, taker, liquidator] =
    await viem.getWalletClients();

  const oracle = await viem.deployContract("MockOracle", []);
  const funder = await viem.deployContract("MockFundingOracle", []);

  const exchange = await viem.deployContract("PerpsExchange", []);
  const vault = await viem.deployContract("GlobalPerpsVault", [exchange.address]);

  await exchange.write.setVault([vault.address]);
  await exchange.write.setPauseDAO([pauseDao.account.address]);
  await vault.write.setWithdrawDAO([withdrawDao.account.address]);
  await vault.write.setPauseDAO([pauseDao.account.address]);
  await vault.write.setClaimFeeDAO([claimFeeDao.account.address]);
  await exchange.write.setOperator([operator.account.address, true]);
  await exchange.write.setLiquidator([liquidator.account.address, true]);

  await oracle.write.setPrice([MARKET_ID, PRICE]);
  await exchange.write.createMarket([
    MARKET_ID,
    oracle.address,
    funder.address,
    ADL_THRESHOLD,
    MIN_COLLATERAL,
  ]);

  const chainId = await publicClient.getChainId();

  return {
    viem,
    networkHelpers,
    publicClient,
    chainId,
    deployer,
    withdrawDao,
    pauseDao,
    claimFeeDao,
    operator,
    maker,
    taker,
    liquidator,
    oracle,
    funder,
    exchange,
    vault,
    MARKET_ID,
    PRICE,
    ADL_THRESHOLD,
    MIN_COLLATERAL,
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

/** Deposit then lock `amount` into market Balance.margin for `wallet`. */
export async function fundDepositAndAddMargin(
  ctx: Awaited<ReturnType<typeof deployPerpsSystem>>,
  wallet: { account: { address: `0x${string}` } },
  amount: bigint,
) {
  const { viem, publicClient, exchange, MARKET_ID } = ctx;
  await fundAndDeposit(ctx, wallet, amount);
  const exchangeAsUser = await viem.getContractAt("PerpsExchange", exchange.address, {
    client: { public: publicClient, wallet },
  });
  await exchangeAsUser.write.addMargin([MARKET_ID, amount]);
}
