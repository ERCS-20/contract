import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

const COL = 10n ** 18n;
/** 100% + 0.5% liq fee + 0.05% taker fee */
const DEFAULT_MIN_COLLATERAL = COL + 5n * 10n ** 15n + 5n * 10n ** 14n;
const DEFAULT_FEE = 1000n * 10n ** 18n;
const DEFAULT_ADL = DEFAULT_FEE / 2n;

describe("PerpsPairFactory", async function () {
  async function deploy() {
    const { viem, networkHelpers } = await network.connect();
    const publicClient = await viem.getPublicClient();
    const [deployer, tokenOwner, other, liquidator] = await viem.getWalletClients();

    const exchange = await viem.deployContract("PerpsExchange", []);
    const vault = await viem.deployContract("GlobalPerpsVault", [exchange.address]);
    await exchange.write.setDAO([deployer.account.address, true]);
    await exchange.write.setVault([vault.address]);

    const twap = await viem.deployContract("Ercs20TwapOracle", [exchange.address]);
    const funder = await viem.deployContract("Ercs20FundingOracle", [exchange.address]);
    await exchange.write.setOracle([twap.address]);
    await exchange.write.setFunder([funder.address]);

    const mockErcs20Factory = await viem.deployContract("MockERCS20Factory", []);
    const pairFactory = await viem.deployContract("PerpsPairFactory", [
      mockErcs20Factory.address,
      exchange.address,
    ]);

    await exchange.write.setFactory([pairFactory.address]);
    await exchange.write.setLiquidator([liquidator.account.address, true]);
    await pairFactory.write.setInsuranceAccount([liquidator.account.address]);

    return {
      viem,
      networkHelpers,
      publicClient,
      deployer,
      tokenOwner,
      other,
      liquidator,
      exchange,
      vault,
      twap,
      funder,
      mockErcs20Factory,
      pairFactory,
    };
  }

  async function registerToken(
    viem: Awaited<ReturnType<typeof deploy>>["viem"],
    mockFactory: Awaited<ReturnType<typeof deploy>>["mockErcs20Factory"],
    owner: Awaited<ReturnType<typeof deploy>>["tokenOwner"],
    usdcSeed = 1n * 10n ** 15n,
    totalSupply = 1n * COL,
  ) {
    const token = await viem.deployContract("MockERCS20WithSeed", [usdcSeed, totalSupply], {
      client: { wallet: owner },
    });
    await mockFactory.write.setERCS20([token.address, true]);
    return token;
  }

  it("defaults fee to 1000e18", async function () {
    const { pairFactory } = await deploy();
    assert.equal(await pairFactory.read.fee(), DEFAULT_FEE);
  });

  it("token owner create seeds insurance margin to liquidator", async function () {
    const {
      viem,
      publicClient,
      tokenOwner,
      liquidator,
      exchange,
      vault,
      twap,
      funder,
      mockErcs20Factory,
      pairFactory,
    } = await deploy();
    const token = await registerToken(viem, mockErcs20Factory, tokenOwner);

    const factoryAsOwner = await viem.getContractAt("PerpsPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: tokenOwner },
    });
    await factoryAsOwner.write.create([token.address], { value: DEFAULT_FEE });

    assert.equal(await pairFactory.read.marketCount(), 1n);
    assert.equal(await pairFactory.read.marketIdOf([token.address]), 0n);
    assert.equal(await pairFactory.read.isMarket([token.address]), true);
    assert.equal(await publicClient.getBalance({ address: pairFactory.address }), 0n);
    assert.equal(await vault.read.balances([liquidator.account.address]), 0n);

    const liqBal = await exchange.read.balances([liquidator.account.address, 0n]);
    assert.equal(liqBal[0], DEFAULT_FEE);
    assert.equal(liqBal[1], 0n);

    const market = await exchange.read.markets([0n]);
    assert.equal(market[0].toLowerCase(), token.address.toLowerCase()); // ercs20
    assert.equal(market[1], true); // exists
    assert.equal(market[2], false); // paused
    assert.equal(market[3], DEFAULT_ADL); // adlEquityThreshold = fee / 2
    assert.equal(market[4], DEFAULT_MIN_COLLATERAL);
    const settlement = await exchange.read.marketSettlements([0n]);
    assert.equal(settlement[0], false); // enabled
    assert.equal(await pairFactory.read.defaultMinCollateralX18(), DEFAULT_MIN_COLLATERAL);
    assert.equal((await exchange.read.oracle()).toLowerCase(), twap.address.toLowerCase());
    assert.equal((await exchange.read.funder()).toLowerCase(), funder.address.toLowerCase());
  });

  it("reverts when listing fee is wrong", async function () {
    const { viem, publicClient, tokenOwner, mockErcs20Factory, pairFactory } = await deploy();
    const token = await registerToken(viem, mockErcs20Factory, tokenOwner);

    const factoryAsOwner = await viem.getContractAt("PerpsPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: tokenOwner },
    });
    await viem.assertions.revertWithCustomError(
      factoryAsOwner.write.create([token.address], { value: 0n }),
      pairFactory,
      "IncorrectFee",
    );
  });

  it("reverts when insurance account unset", async function () {
    const { viem } = await network.connect();
    const publicClient = await viem.getPublicClient();
    const [deployer, tokenOwner, , liquidator] = await viem.getWalletClients();

    const exchange = await viem.deployContract("PerpsExchange", []);
    const vault = await viem.deployContract("GlobalPerpsVault", [exchange.address]);
    await exchange.write.setDAO([deployer.account.address, true]);
    await exchange.write.setVault([vault.address]);
    const mockErcs20Factory = await viem.deployContract("MockERCS20Factory", []);
    const pairFactory = await viem.deployContract("PerpsPairFactory", [
      mockErcs20Factory.address,
      exchange.address,
    ]);
    await exchange.write.setFactory([pairFactory.address]);
    await exchange.write.setLiquidator([liquidator.account.address, true]);

    const token = await viem.deployContract("MockERCS20WithSeed", [1n * 10n ** 15n, 1n * COL], {
      client: { wallet: tokenOwner },
    });
    await mockErcs20Factory.write.setERCS20([token.address, true]);

    const factoryAsOwner = await viem.getContractAt("PerpsPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: tokenOwner },
    });
    await viem.assertions.revertWithCustomError(
      factoryAsOwner.write.create([token.address], { value: DEFAULT_FEE }),
      pairFactory,
      "InsuranceAccountNotSet",
    );
  });

  it("reverts when caller is not token owner", async function () {
    const { viem, publicClient, tokenOwner, other, mockErcs20Factory, pairFactory } = await deploy();
    const token = await registerToken(viem, mockErcs20Factory, tokenOwner);

    const factoryAsOther = await viem.getContractAt("PerpsPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: other },
    });
    await viem.assertions.revertWithCustomError(
      factoryAsOther.write.create([token.address], { value: DEFAULT_FEE }),
      pairFactory,
      "NotTokenOwner",
    );
  });

  it("reverts on duplicate market", async function () {
    const { viem, publicClient, tokenOwner, mockErcs20Factory, pairFactory } = await deploy();
    const token = await registerToken(viem, mockErcs20Factory, tokenOwner);

    const factoryAsOwner = await viem.getContractAt("PerpsPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: tokenOwner },
    });
    await factoryAsOwner.write.create([token.address], { value: DEFAULT_FEE });
    await viem.assertions.revertWithCustomError(
      factoryAsOwner.write.create([token.address], { value: DEFAULT_FEE }),
      pairFactory,
      "MarketAlreadyExists",
    );
  });
});
