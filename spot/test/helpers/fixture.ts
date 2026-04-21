import { network } from "hardhat";

/** Must match SpotExchange EIP-712 domain constants. */
export const SPOT_EIP712_NAME = "SpotExchange";
export const SPOT_EIP712_VERSION = "1";

export async function deploySpotSystem() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [
    deployer,
    whitelistDao,
    withdrawDao,
    maker,
    taker,
    relayer,
    claimFeeDao,
  ] = await viem.getWalletClients();

  const tokenA = await viem.deployContract("MockERC20", ["TokenA", "TKA"]);
  const tokenB = await viem.deployContract("MockERC20", ["TokenB", "TKB"]);
  const wusdc = await viem.deployContract("MockWUSDC", []);

  const exchange = await viem.deployContract("SpotExchange");

  const vault = await viem.deployContract("GlobalSpotVault", [
    wusdc.address,
    exchange.address,
  ]);

  await exchange.write.setVault([vault.address]);
  await vault.write.setTokenWhitelistDAO([whitelistDao.account.address]);
  await vault.write.setWithdrawDAO([withdrawDao.account.address]);
  await vault.write.setClaimFeeDAO([claimFeeDao.account.address]);

  const vaultAsWhitelist = await viem.getContractAt("GlobalSpotVault", vault.address, {
    client: { public: publicClient, wallet: whitelistDao },
  });
  await vaultAsWhitelist.write.addAllowedToken([tokenA.address]);
  await vaultAsWhitelist.write.addAllowedToken([tokenB.address]);
  await vaultAsWhitelist.write.addAllowedToken([wusdc.address]);

  await exchange.write.addDAO([relayer.account.address]);

  const chainId = await publicClient.getChainId();

  return {
    viem,
    publicClient,
    chainId,
    deployer,
    whitelistDao,
    withdrawDao,
    claimFeeDao,
    maker,
    taker,
    relayer,
    tokenA,
    tokenB,
    wusdc,
    exchange,
    vault,
  };
}
