import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

import { deploySpotSystem } from "./helpers/fixture.js";
import { signWithdraw } from "./helpers/eip712.js";

describe("GlobalSpotVault", async function () {
  it("reverts deposit when token is not whitelisted", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, tokenA, vault } = ctx;

    const tokenC = await viem.deployContract("MockERC20", ["TokenC", "TKC"]);
    await tokenC.write.mint([deployer.account.address, 1_000_000n * 10n ** 18n]);
    await tokenC.write.approve([vault.address, 1_000_000n * 10n ** 18n]);

    const vaultAsUser = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });

    await viem.assertions.revertWithCustomError(
      vaultAsUser.write.deposit([tokenC.address, 1000n]),
      vault,
      "TokenNotAllowed",
    );
  });

  it("deposit increases balance and pulls ERC20", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, tokenA, vault } = ctx;

    const amount = 50_000n * 10n ** 18n;
    await tokenA.write.mint([deployer.account.address, amount]);
    await tokenA.write.approve([vault.address, amount]);

    const vaultAsUser = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });
    await vaultAsUser.write.deposit([tokenA.address, amount]);

    const bal = await vault.read.balances([deployer.account.address, tokenA.address]);
    assert.equal(bal, amount);
    const vaultHeld = await tokenA.read.balanceOf([vault.address]);
    assert.equal(vaultHeld, amount);
  });

  it("withdraw succeeds with withdrawDAO signature and debits balance", async function () {
    const ctx = await deploySpotSystem();
    const {
      viem,
      publicClient,
      chainId,
      deployer,
      withdrawDao,
      tokenA,
      vault,
    } = ctx;

    const amount = 10_000n * 10n ** 18n;
    await tokenA.write.mint([deployer.account.address, amount * 2n]);
    await tokenA.write.approve([vault.address, amount * 2n]);

    const vaultAsUser = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });
    await vaultAsUser.write.deposit([tokenA.address, amount * 2n]);

    const sig = await signWithdraw(withdrawDao, chainId, vault.address, {
      user: deployer.account.address,
      orderId: 1n,
      token: tokenA.address,
      amount,
    });

    const userTokenBefore = await tokenA.read.balanceOf([deployer.account.address]);
    await vaultAsUser.write.withdraw([1n, tokenA.address, amount, sig]);
    const userTokenAfter = await tokenA.read.balanceOf([deployer.account.address]);

    const bal = await vault.read.balances([deployer.account.address, tokenA.address]);
    assert.equal(bal, amount);
    assert.equal(userTokenAfter - userTokenBefore, amount);
    const used = await vault.read.usedWithdrawOrder([deployer.account.address, 1n]);
    assert.equal(used, true);
  });

  it("withdraw reverts when reusing the same orderId", async function () {
    const ctx = await deploySpotSystem();
    const {
      viem,
      publicClient,
      chainId,
      deployer,
      withdrawDao,
      tokenA,
      vault,
    } = ctx;

    const amount = 5_000n * 10n ** 18n;
    await tokenA.write.mint([deployer.account.address, amount * 3n]);
    await tokenA.write.approve([vault.address, amount * 3n]);

    const vaultAsUser = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });
    await vaultAsUser.write.deposit([tokenA.address, amount * 3n]);

    const sig = await signWithdraw(withdrawDao, chainId, vault.address, {
      user: deployer.account.address,
      orderId: 42n,
      token: tokenA.address,
      amount,
    });
    await vaultAsUser.write.withdraw([42n, tokenA.address, amount, sig]);

    const sig2 = await signWithdraw(withdrawDao, chainId, vault.address, {
      user: deployer.account.address,
      orderId: 42n,
      token: tokenA.address,
      amount,
    });
    await viem.assertions.revertWithCustomError(
      vaultAsUser.write.withdraw([42n, tokenA.address, amount, sig2]),
      vault,
      "WithdrawOrderAlreadyUsed",
    );
  });

  it("withdraw reverts when signature is reused by another user", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, chainId, deployer, taker, withdrawDao, tokenA, vault } = ctx;

    const amount = 2_000n * 10n ** 18n;
    await tokenA.write.mint([deployer.account.address, amount]);
    await tokenA.write.mint([taker.account.address, amount]);
    await tokenA.write.approve([vault.address, amount], { account: deployer.account });
    await tokenA.write.approve([vault.address, amount], { account: taker.account });

    const vaultAsDeployer = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });
    const vaultAsTaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: taker },
    });
    await vaultAsDeployer.write.deposit([tokenA.address, amount]);
    await vaultAsTaker.write.deposit([tokenA.address, amount]);

    const sigForDeployer = await signWithdraw(withdrawDao, chainId, vault.address, {
      user: deployer.account.address,
      orderId: 77n,
      token: tokenA.address,
      amount,
    });

    await viem.assertions.revertWithCustomError(
      vaultAsTaker.write.withdraw([77n, tokenA.address, amount, sigForDeployer]),
      vault,
      "NotWithdrawDAO",
    );
  });

  it("internalTransfer is only callable by SpotExchange", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, maker, tokenA, vault } = ctx;

    await tokenA.write.mint([maker.account.address, 1000n]);
    await tokenA.write.approve([vault.address, 1000n], { account: maker.account });

    const vaultAsMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    await vaultAsMaker.write.deposit([tokenA.address, 1000n]);

    await viem.assertions.revertWithCustomError(
      vaultAsMaker.write.internalTransfer([
        maker.account.address,
        deployer.account.address,
        tokenA.address,
        100n,
        1n,
      ]),
      vault,
      "NotExchange",
    );
  });

  it("internalTransfer moves balances and records fees (via exchange)", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, maker, taker, tokenA, exchange, vault } =
      ctx;

    await tokenA.write.mint([maker.account.address, 10_000n]);
    await tokenA.write.approve([vault.address, 10_000n], { account: maker.account });
    const vaultAsMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    await vaultAsMaker.write.deposit([tokenA.address, 10_000n]);

    const testClient = await viem.getTestClient();
    await testClient.impersonateAccount({ address: exchange.address });
    await testClient.setBalance({ address: exchange.address, value: 10n ** 18n });

    const exchangeWallet = await viem.getWalletClient(exchange.address);
    const vaultImp = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: exchangeWallet },
    });

    await vaultImp.write.internalTransfer([
      maker.account.address,
      taker.account.address,
      tokenA.address,
      1000n,
      7n,
    ]);

    assert.equal(await vault.read.balances([maker.account.address, tokenA.address]), 8993n);
    assert.equal(await vault.read.balances([taker.account.address, tokenA.address]), 1000n);
    assert.equal(await vault.read.tokenFees([tokenA.address]), 7n);

    await testClient.stopImpersonatingAccount({ address: exchange.address });
  });

  it("claimFees pays accumulated fees to claimFeeDAO", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, claimFeeDao, maker, taker, tokenA, exchange, vault } =
      ctx;

    await tokenA.write.mint([maker.account.address, 10_000n]);
    await tokenA.write.approve([vault.address, 10_000n], { account: maker.account });
    const vaultAsMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    await vaultAsMaker.write.deposit([tokenA.address, 10_000n]);

    const testClient = await viem.getTestClient();
    await testClient.impersonateAccount({ address: exchange.address });
    await testClient.setBalance({ address: exchange.address, value: 10n ** 18n });

    const exchangeWallet = await viem.getWalletClient(exchange.address);
    const vaultImp = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: exchangeWallet },
    });
    await vaultImp.write.internalTransfer([
      maker.account.address,
      taker.account.address,
      tokenA.address,
      1000n,
      25n,
    ]);
    await testClient.stopImpersonatingAccount({ address: exchange.address });

    const claimFeeDaoBefore = await tokenA.read.balanceOf([claimFeeDao.account.address]);
    const vaultAsClaimFeeDao = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: claimFeeDao },
    });
    await vaultAsClaimFeeDao.write.claimFees([tokenA.address]);
    const claimFeeDaoAfter = await tokenA.read.balanceOf([claimFeeDao.account.address]);
    assert.equal(claimFeeDaoAfter - claimFeeDaoBefore, 25n);
    assert.equal(await vault.read.tokenFees([tokenA.address]), 0n);
  });

  it("claimFees reverts when caller is not claimFeeDAO", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, tokenA, vault } = ctx;

    const testClient = await viem.getTestClient();
    await testClient.impersonateAccount({ address: ctx.exchange.address });
    await testClient.setBalance({ address: ctx.exchange.address, value: 10n ** 18n });
    const exchangeWallet = await viem.getWalletClient(ctx.exchange.address);
    const vaultImp = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: exchangeWallet },
    });
    await tokenA.write.mint([deployer.account.address, 100n]);
    await tokenA.write.approve([vault.address, 100n]);
    const vaultAsDeployer = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });
    await vaultAsDeployer.write.deposit([tokenA.address, 100n]);
    await vaultImp.write.internalTransfer([
      deployer.account.address,
      deployer.account.address,
      tokenA.address,
      0n,
      10n,
    ]);
    await testClient.stopImpersonatingAccount({ address: ctx.exchange.address });

    await viem.assertions.revertWithCustomError(
      vault.write.claimFees([tokenA.address]),
      vault,
      "NotClaimFeeDAO",
    );
  });

  it("forcedWithdrawal completes after 7 days", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, tokenA, vault } = ctx;

    const amount = 3_000n;
    await tokenA.write.mint([deployer.account.address, amount]);
    await tokenA.write.approve([vault.address, amount]);
    const vaultAsUser = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });
    await vaultAsUser.write.deposit([tokenA.address, amount]);

    await vaultAsUser.write.forcedWithdrawal([tokenA.address]);

    await viem.assertions.revertWithCustomError(
      vaultAsUser.write.forcedWithdrawal([tokenA.address]),
      vault,
      "ForcedWithdrawalTooEarly",
    );

    const testClient = await viem.getTestClient();
    await testClient.increaseTime({ seconds: 7 * 24 * 60 * 60 + 1 });
    await testClient.mine({ blocks: 1 });

    const before = await tokenA.read.balanceOf([deployer.account.address]);
    await vaultAsUser.write.forcedWithdrawal([tokenA.address]);
    const after = await tokenA.read.balanceOf([deployer.account.address]);
    assert.equal(after - before, amount);
    assert.equal(await vault.read.balances([deployer.account.address, tokenA.address]), 0n);
  });

  it("WUSDC withdraw unwraps to native for the caller", async function () {
    const ctx = await deploySpotSystem();
    const {
      viem,
      publicClient,
      chainId,
      deployer,
      withdrawDao,
      wusdc,
      vault,
    } = ctx;

    const wrapAmount = 2n * 10n ** 18n;
    const wusdcAsUser = await viem.getContractAt("MockWUSDC", wusdc.address, {
      client: { public: publicClient, wallet: deployer },
    });
    await wusdcAsUser.write.deposit({ value: wrapAmount });

    await wusdc.write.approve([vault.address, wrapAmount]);
    const vaultAsUser = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });
    await vaultAsUser.write.deposit([wusdc.address, wrapAmount]);

    const sig = await signWithdraw(withdrawDao, chainId, vault.address, {
      user: deployer.account.address,
      orderId: 99n,
      token: wusdc.address,
      amount: wrapAmount,
    });

    const ethBefore = await publicClient.getBalance({ address: deployer.account.address });
    await vaultAsUser.write.withdraw([99n, wusdc.address, wrapAmount, sig]);
    const ethAfter = await publicClient.getBalance({ address: deployer.account.address });
    assert.ok(ethAfter > ethBefore);
  });

  it("paused vault blocks deposit", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, pauseDao, tokenA, vault } = ctx;

    await tokenA.write.mint([deployer.account.address, 1_000n]);
    await tokenA.write.approve([vault.address, 1_000n]);

    const vaultAsPauseDao = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: pauseDao },
    });
    await (vaultAsPauseDao.write as any).pause();

    const vaultAsUser = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: deployer },
    });
    await viem.assertions.revertWithCustomError(
      vaultAsUser.write.deposit([tokenA.address, 1_000n]),
      vault,
      "EnforcedPause",
    );
  });

  it("paused vault blocks internalTransfer", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, maker, taker, pauseDao, tokenA, exchange, vault } = ctx;

    await tokenA.write.mint([maker.account.address, 10_000n]);
    await tokenA.write.approve([vault.address, 10_000n], { account: maker.account });
    const vaultAsMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    await vaultAsMaker.write.deposit([tokenA.address, 10_000n]);

    const vaultAsPauseDao = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: pauseDao },
    });
    await (vaultAsPauseDao.write as any).pause();

    const testClient = await viem.getTestClient();
    await testClient.impersonateAccount({ address: exchange.address });
    await testClient.setBalance({ address: exchange.address, value: 10n ** 18n });
    const exchangeWallet = await viem.getWalletClient(exchange.address);
    const vaultImp = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: exchangeWallet },
    });
    await viem.assertions.revertWithCustomError(
      vaultImp.write.internalTransfer([
        maker.account.address,
        taker.account.address,
        tokenA.address,
        1_000n,
        10n,
      ]),
      vault,
      "EnforcedPause",
    );
    await testClient.stopImpersonatingAccount({ address: exchange.address });
  });

  it("applyExchangeUpdate reverts without pending proposal", async function () {
    const ctx = await deploySpotSystem();
    const { viem, vault } = ctx;

    await viem.assertions.revertWithCustomError(
      vault.write.applyExchangeUpdate(),
      vault,
      "NoPendingExchangeUpdate",
    );
  });

  it("applyExchangeUpdate reverts before 7-day delay", async function () {
    const ctx = await deploySpotSystem();
    const { viem, vault } = ctx;

    const exchange2 = await viem.deployContract("SpotExchange");
    await vault.write.proposeExchangeUpdate([exchange2.address]);

    await viem.assertions.revertWithCustomError(
      vault.write.applyExchangeUpdate(),
      vault,
      "ExchangeUpdateTooEarly",
    );
  });

  it("propose then apply after 7 days updates exchange", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, vault, exchange, maker, taker, tokenA } = ctx;

    const exchange2 = await viem.deployContract("SpotExchange");
    await exchange2.write.setVault([vault.address]);

    assert.equal(
      (await vault.read.exchange()).toLowerCase(),
      exchange.address.toLowerCase(),
    );
    await vault.write.proposeExchangeUpdate([exchange2.address]);

    const pending = await vault.read.pendingExchangeUpdate();
    const [pendingAddr, pendingAt] = pending as readonly [`0x${string}`, bigint];
    assert.equal(pendingAddr.toLowerCase(), exchange2.address.toLowerCase());
    assert.ok(pendingAt > 0n);

    const testClient = await viem.getTestClient();
    await testClient.increaseTime({ seconds: 7 * 24 * 60 * 60 + 1 });
    await testClient.mine({ blocks: 1 });

    await vault.write.applyExchangeUpdate();

    assert.equal((await vault.read.exchange()).toLowerCase(), exchange2.address.toLowerCase());
    const cleared = await vault.read.pendingExchangeUpdate();
    const [clearedAddr, clearedAt] = cleared as readonly [`0x${string}`, bigint];
    assert.equal(clearedAddr, "0x0000000000000000000000000000000000000000");
    assert.equal(clearedAt, 0n);

    await tokenA.write.mint([maker.account.address, 1000n]);
    await tokenA.write.approve([vault.address, 1000n], { account: maker.account });
    const vaultAsMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });
    await vaultAsMaker.write.deposit([tokenA.address, 1000n]);

    await testClient.impersonateAccount({ address: exchange.address });
    await testClient.setBalance({ address: exchange.address, value: 10n ** 18n });
    const oldExWallet = await viem.getWalletClient(exchange.address);
    const vaultOld = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: oldExWallet },
    });
    await viem.assertions.revertWithCustomError(
      vaultOld.write.internalTransfer([
        maker.account.address,
        taker.account.address,
        tokenA.address,
        100n,
        1n,
      ]),
      vault,
      "NotExchange",
    );
    await testClient.stopImpersonatingAccount({ address: exchange.address });

    await testClient.impersonateAccount({ address: exchange2.address });
    await testClient.setBalance({ address: exchange2.address, value: 10n ** 18n });
    const newExWallet = await viem.getWalletClient(exchange2.address);
    const vaultNew = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: newExWallet },
    });
    await vaultNew.write.internalTransfer([
      maker.account.address,
      taker.account.address,
      tokenA.address,
      100n,
      1n,
    ]);
    await testClient.stopImpersonatingAccount({ address: exchange2.address });
  });

  it("proposeExchangeUpdate reverts for zero address", async function () {
    const ctx = await deploySpotSystem();
    const { viem, vault } = ctx;

    await viem.assertions.revertWithCustomError(
      vault.write.proposeExchangeUpdate(["0x0000000000000000000000000000000000000000"]),
      vault,
      "InvalidAddress",
    );
  });

  it("proposeExchangeUpdate reverts when caller is not owner", async function () {
    const ctx = await deploySpotSystem();
    const { viem, publicClient, vault, maker } = ctx;

    const exchange2 = await viem.deployContract("SpotExchange");
    const vaultAsMaker = await viem.getContractAt("GlobalSpotVault", vault.address, {
      client: { public: publicClient, wallet: maker },
    });

    await viem.assertions.revertWithCustomError(
      vaultAsMaker.write.proposeExchangeUpdate([exchange2.address]),
      vault,
      "OwnableUnauthorizedAccount",
    );
  });
});
