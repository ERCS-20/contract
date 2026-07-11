import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { encodePacked, keccak256 } from "viem";

import { deploySpotSystem } from "./helpers/fixture.js";

function pairKey(baseToken: `0x${string}`, quoteToken: `0x${string}`) {
  return keccak256(encodePacked(["address", "address"], [baseToken, quoteToken]));
}

describe("SpotPairFactory", async function () {
  async function deployPairFactory(options?: { wireVaultWhitelist?: boolean }) {
    const wireVaultWhitelist = options?.wireVaultWhitelist ?? true;
    const ctx = await deploySpotSystem();
    const { viem, publicClient, deployer, vault } = ctx;

    const mockFactory = await viem.deployContract("MockERCS20Factory", []);
    const pairFactory = await viem.deployContract("SpotPairFactory", [
      mockFactory.address,
      vault.address,
    ]);

    if (wireVaultWhitelist) {
      await vault.write.setTokenWhitelistDAO([pairFactory.address]);
    }

    return { ...ctx, mockFactory, pairFactory, publicClient, viem, deployer };
  }

  /** Default seed: scaled opening price = 1e15 (0.001 quote per token). */
  async function registerErcs20(
    viem: Awaited<ReturnType<typeof deploySpotSystem>>["viem"],
    mockFactory: Awaited<ReturnType<typeof deployPairFactory>>["mockFactory"],
    usdcSeed = 1n * 10n ** 15n,
    totalSupply = 1n * 10n ** 18n,
  ) {
    const token = await viem.deployContract("MockERCS20WithSeed", [usdcSeed, totalSupply]);
    await mockFactory.write.setERCS20([token.address, true]);
    return token;
  }

  it("constructor stores immutable dependencies", async function () {
    const { mockFactory, pairFactory, vault } = await deployPairFactory();

    assert.equal(
      (await pairFactory.read.ercs20Factory()).toLowerCase(),
      mockFactory.address.toLowerCase(),
    );
    assert.equal((await pairFactory.read.vault()).toLowerCase(), vault.address.toLowerCase());
    assert.equal(await pairFactory.read.pairCount(), 0n);
    assert.equal(await pairFactory.read.pairDAO(), "0x0000000000000000000000000000000000000000");
  });

  it("constructor reverts for zero ercs20Factory", async function () {
    const { viem, vault, pairFactory } = await deployPairFactory();

    await viem.assertions.revertWithCustomError(
      viem.deployContract("SpotPairFactory", [
        "0x0000000000000000000000000000000000000000",
        vault.address,
      ]),
      pairFactory,
      "InvalidAddress",
    );
  });

  it("constructor reverts for zero vault", async function () {
    const { viem, mockFactory, pairFactory } = await deployPairFactory();

    await viem.assertions.revertWithCustomError(
      viem.deployContract("SpotPairFactory", [
        mockFactory.address,
        "0x0000000000000000000000000000000000000000",
      ]),
      pairFactory,
      "InvalidAddress",
    );
  });

  it("setPairDAO sets dao and emits PairDAOSet", async function () {
    const { publicClient, pairFactory, taker } = await deployPairFactory();

    const fromBlock = await publicClient.getBlockNumber();
    await pairFactory.write.setPairDAO([taker.account.address]);

    assert.equal(
      (await pairFactory.read.pairDAO()).toLowerCase(),
      taker.account.address.toLowerCase(),
    );

    const events = await publicClient.getContractEvents({
      address: pairFactory.address,
      abi: pairFactory.abi,
      eventName: "PairDAOSet",
      fromBlock,
      strict: true,
    });
    assert.equal(events.length, 1);
    assert.equal(events[0].args.pairDAO.toLowerCase(), taker.account.address.toLowerCase());
  });

  it("setPairDAO reverts when caller is not owner", async function () {
    const { viem, publicClient, pairFactory, taker } = await deployPairFactory();

    const pairFactoryAsTaker = await viem.getContractAt("SpotPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: taker },
    });

    await viem.assertions.revertWithCustomError(
      pairFactoryAsTaker.write.setPairDAO([taker.account.address]),
      pairFactory,
      "OwnableUnauthorizedAccount",
    );
  });

  it("setPairDAO reverts for zero address", async function () {
    const { viem, pairFactory } = await deployPairFactory();

    await viem.assertions.revertWithCustomError(
      pairFactory.write.setPairDAO(["0x0000000000000000000000000000000000000000"]),
      pairFactory,
      "InvalidAddress",
    );
  });

  it("removePairDAO clears dao and emits PairDAORemoved", async function () {
    const { publicClient, pairFactory, taker } = await deployPairFactory();

    await pairFactory.write.setPairDAO([taker.account.address]);
    const fromBlock = await publicClient.getBlockNumber();
    await pairFactory.write.removePairDAO([taker.account.address]);

    assert.equal(await pairFactory.read.pairDAO(), "0x0000000000000000000000000000000000000000");

    const events = await publicClient.getContractEvents({
      address: pairFactory.address,
      abi: pairFactory.abi,
      eventName: "PairDAORemoved",
      fromBlock,
      strict: true,
    });
    assert.equal(events.length, 1);
    assert.equal(events[0].args.pairDAO.toLowerCase(), taker.account.address.toLowerCase());
  });

  it("removePairDAO reverts for zero address", async function () {
    const { viem, pairFactory } = await deployPairFactory();

    await viem.assertions.revertWithCustomError(
      pairFactory.write.removePairDAO(["0x0000000000000000000000000000000000000000"]),
      pairFactory,
      "InvalidAddress",
    );
  });

  it("removePairDAO reverts when caller is not owner", async function () {
    const { viem, publicClient, pairFactory, taker } = await deployPairFactory();

    await pairFactory.write.setPairDAO([taker.account.address]);

    const pairFactoryAsTaker = await viem.getContractAt("SpotPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: taker },
    });

    await viem.assertions.revertWithCustomError(
      pairFactoryAsTaker.write.removePairDAO([taker.account.address]),
      pairFactory,
      "OwnableUnauthorizedAccount",
    );
  });

  it("create(baseToken) whitelists ercs20 and emits SpotPairCreated", async function () {
    const { viem, publicClient, mockFactory, pairFactory, vault, wusdc } =
      await deployPairFactory();

    const ercs20 = await registerErcs20(viem, mockFactory);

    const fromBlock = await publicClient.getBlockNumber();
    await pairFactory.write.create([ercs20.address]);

    assert.equal(await pairFactory.read.isPair([ercs20.address, wusdc.address]), true);
    assert.equal(await pairFactory.read.spotPairs([pairKey(ercs20.address, wusdc.address)]), true);
    assert.equal(await pairFactory.read.pairCount(), 1n);
    assert.equal(await vault.read.isAllowedToken([ercs20.address]), true);

    const events = await publicClient.getContractEvents({
      address: pairFactory.address,
      abi: pairFactory.abi,
      eventName: "SpotPairCreated",
      fromBlock,
      strict: true,
    });
    assert.equal(events.length, 1);
    const evt = events[0].args;
    assert.equal(evt.baseToken.toLowerCase(), ercs20.address.toLowerCase());
    assert.equal(evt.quoteToken.toLowerCase(), wusdc.address.toLowerCase());
    assert.equal(evt.pairIndex, 0n);
  });

  it("create(baseToken) reverts when caller is not token owner", async function () {
    const { viem, publicClient, mockFactory, pairFactory, taker } = await deployPairFactory();

    const ercs20 = await registerErcs20(viem, mockFactory);
    const pairFactoryAsTaker = await viem.getContractAt("SpotPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: taker },
    });

    await viem.assertions.revertWithCustomError(
      pairFactoryAsTaker.write.create([ercs20.address]),
      pairFactory,
      "NotTokenOwner",
    );
  });

  it("create(baseToken) increments pairIndex across multiple pairs", async function () {
    const { viem, publicClient, mockFactory, pairFactory } = await deployPairFactory();

    const acme = await registerErcs20(viem, mockFactory);
    const beta = await registerErcs20(viem, mockFactory, 5n * 10n ** 15n, 1n * 10n ** 18n);

    const fromBlock = await publicClient.getBlockNumber();
    await pairFactory.write.create([acme.address]);
    await pairFactory.write.create([beta.address]);

    assert.equal(await pairFactory.read.pairCount(), 2n);

    const events = await publicClient.getContractEvents({
      address: pairFactory.address,
      abi: pairFactory.abi,
      eventName: "SpotPairCreated",
      fromBlock,
      strict: true,
    });
    assert.equal(events.length, 2);
    assert.equal(events[0].args.pairIndex, 0n);
    assert.equal(events[1].args.pairIndex, 1n);
  });

  it("create(baseToken) reverts for zero baseToken", async function () {
    const { viem, pairFactory } = await deployPairFactory();

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create(["0x0000000000000000000000000000000000000000"]),
      pairFactory,
      "InvalidAddress",
    );
  });

  it("create(baseToken) reverts when token is not registered in ERCS20Factory", async function () {
    const { viem, mockFactory, pairFactory } = await deployPairFactory();

    const ercs20 = await viem.deployContract("MockERC20", ["Fake", "FAKE"]);

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([ercs20.address]),
      pairFactory,
      "NotERCS20",
    );
    assert.equal(await mockFactory.read.ercs20s([ercs20.address]), false);
  });

  it("create(baseToken) reverts when pair already exists", async function () {
    const { viem, mockFactory, pairFactory } = await deployPairFactory();

    const ercs20 = await registerErcs20(viem, mockFactory);
    await pairFactory.write.create([ercs20.address]);

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([ercs20.address]),
      pairFactory,
      "PairAlreadyExists",
    );
  });

  it("create(baseToken) reverts when factory is not vault tokenWhitelistDAO", async function () {
    const { viem, mockFactory, pairFactory, vault } = await deployPairFactory({
      wireVaultWhitelist: false,
    });

    const ercs20 = await registerErcs20(viem, mockFactory);

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([ercs20.address]),
      vault,
      "NotTokenWhitelistDAO",
    );
  });

  it("pairDAO create registers custom quote pair", async function () {
    const { publicClient, pairFactory, vault, tokenA, tokenB, deployer } =
      await deployPairFactory();

    await pairFactory.write.setPairDAO([deployer.account.address]);

    const fromBlock = await publicClient.getBlockNumber();
    await pairFactory.write.create([tokenA.address, tokenB.address]);

    assert.equal(await pairFactory.read.isPair([tokenA.address, tokenB.address]), true);
    assert.equal(await pairFactory.read.spotPairs([pairKey(tokenA.address, tokenB.address)]), true);
    assert.equal(await vault.read.isAllowedToken([tokenA.address]), true);
    assert.equal(await vault.read.isAllowedToken([tokenB.address]), true);

    const events = await publicClient.getContractEvents({
      address: pairFactory.address,
      abi: pairFactory.abi,
      eventName: "SpotPairCreated",
      fromBlock,
      strict: true,
    });
    assert.equal(events.length, 1);
    assert.equal(events[0].args.baseToken.toLowerCase(), tokenA.address.toLowerCase());
    assert.equal(events[0].args.quoteToken.toLowerCase(), tokenB.address.toLowerCase());
    assert.equal(events[0].args.pairIndex, 0n);
  });

  it("pairDAO create treats base/quote direction as distinct pairs", async function () {
    const { pairFactory, tokenA, tokenB, deployer } = await deployPairFactory();

    await pairFactory.write.setPairDAO([deployer.account.address]);
    await pairFactory.write.create([tokenA.address, tokenB.address]);

    assert.equal(await pairFactory.read.isPair([tokenA.address, tokenB.address]), true);
    assert.equal(await pairFactory.read.isPair([tokenB.address, tokenA.address]), false);

    await pairFactory.write.create([tokenB.address, tokenA.address]);
    assert.equal(await pairFactory.read.isPair([tokenB.address, tokenA.address]), true);
    assert.equal(await pairFactory.read.pairCount(), 2n);
  });

  it("pairDAO create reverts when caller is not pairDAO", async function () {
    const { viem, publicClient, taker, pairFactory, tokenA, tokenB } =
      await deployPairFactory();

    const pairFactoryAsTaker = await viem.getContractAt("SpotPairFactory", pairFactory.address, {
      client: { public: publicClient, wallet: taker },
    });

    await viem.assertions.revertWithCustomError(
      pairFactoryAsTaker.write.create([tokenA.address, tokenB.address]),
      pairFactory,
      "NotPairDAO",
    );
  });

  it("pairDAO create reverts after pairDAO is removed", async function () {
    const { viem, pairFactory, tokenA, tokenB, deployer } = await deployPairFactory();

    await pairFactory.write.setPairDAO([deployer.account.address]);
    await pairFactory.write.removePairDAO([deployer.account.address]);

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([tokenA.address, tokenB.address]),
      pairFactory,
      "NotPairDAO",
    );
  });

  it("pairDAO create reverts for zero baseToken or quoteToken", async function () {
    const { viem, pairFactory, tokenA, deployer } = await deployPairFactory();

    await pairFactory.write.setPairDAO([deployer.account.address]);

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([
        "0x0000000000000000000000000000000000000000",
        tokenA.address,
      ]),
      pairFactory,
      "InvalidAddress",
    );

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([
        tokenA.address,
        "0x0000000000000000000000000000000000000000",
      ]),
      pairFactory,
      "InvalidAddress",
    );
  });

  it("pairDAO create reverts when pair already exists", async function () {
    const { viem, pairFactory, tokenA, tokenB, deployer } = await deployPairFactory();

    await pairFactory.write.setPairDAO([deployer.account.address]);
    await pairFactory.write.create([tokenA.address, tokenB.address]);

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([tokenA.address, tokenB.address]),
      pairFactory,
      "PairAlreadyExists",
    );
  });

  it("isPair returns false for unregistered pair", async function () {
    const { pairFactory, tokenA, tokenB } = await deployPairFactory();

    assert.equal(await pairFactory.read.isPair([tokenA.address, tokenB.address]), false);
  });

  it("create(baseToken) reverts when opening price exceeds 1e16", async function () {
    const { viem, mockFactory, pairFactory } = await deployPairFactory();

    const tooHigh = await registerErcs20(viem, mockFactory, 2n * 10n ** 16n, 1n * 10n ** 18n);
    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([tooHigh.address]),
      pairFactory,
      "OpeningPriceTooHigh",
    );
  });

  it("create(baseToken) accepts opening price exactly at 1e16", async function () {
    const { pairFactory, viem, mockFactory } = await deployPairFactory();

    const atMax = await registerErcs20(viem, mockFactory, 1n * 10n ** 16n, 1n * 10n ** 18n);
    await pairFactory.write.create([atMax.address]);
    assert.equal(await pairFactory.read.pairCount(), 1n);
  });

  it("create(baseToken) reverts when opening price is smaller than 1e-18", async function () {
    const { viem, mockFactory, pairFactory } = await deployPairFactory();

    const tooSmall = await registerErcs20(viem, mockFactory, 1n, 10n ** 19n);
    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([tooSmall.address]),
      pairFactory,
      "OpeningPriceDecimalsTooHigh",
    );
  });

  it("create(baseToken) allows zero totalSupply", async function () {
    const { pairFactory, viem, mockFactory, wusdc } = await deployPairFactory();

    const zeroSupply = await registerErcs20(viem, mockFactory, 1n, 0n);
    await pairFactory.write.create([zeroSupply.address]);
    assert.equal(await pairFactory.read.isPair([zeroSupply.address, wusdc.address]), true);
  });

  it("create(baseToken) allows zero usdcSeedAmount", async function () {
    const { pairFactory, viem, mockFactory, wusdc } = await deployPairFactory();

    const zeroSeed = await registerErcs20(viem, mockFactory, 0n, 1n * 10n ** 18n);
    await pairFactory.write.create([zeroSeed.address]);
    assert.equal(await pairFactory.read.isPair([zeroSeed.address, wusdc.address]), true);
  });

  it("pairDAO create does not validate opening price for ERCS20 base", async function () {
    const { viem, mockFactory, pairFactory, tokenB, deployer } = await deployPairFactory();

    const invalidForSingleCreate = await registerErcs20(
      viem,
      mockFactory,
      2n * 10n ** 16n,
      1n * 10n ** 18n,
    );

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([invalidForSingleCreate.address]),
      pairFactory,
      "OpeningPriceTooHigh",
    );

    await pairFactory.write.setPairDAO([deployer.account.address]);
    await pairFactory.write.create([invalidForSingleCreate.address, tokenB.address]);

    assert.equal(
      await pairFactory.read.isPair([invalidForSingleCreate.address, tokenB.address]),
      true,
    );
  });

  it("pairDAO create does not validate opening price even when quote is WUSDC", async function () {
    const { viem, mockFactory, pairFactory, wusdc, deployer } = await deployPairFactory();

    const tooHigh = await registerErcs20(viem, mockFactory, 2n * 10n ** 16n, 1n * 10n ** 18n);

    await viem.assertions.revertWithCustomError(
      pairFactory.write.create([tooHigh.address]),
      pairFactory,
      "OpeningPriceTooHigh",
    );

    await pairFactory.write.setPairDAO([deployer.account.address]);
    await pairFactory.write.create([tooHigh.address, wusdc.address]);

    assert.equal(await pairFactory.read.isPair([tooHigh.address, wusdc.address]), true);
  });

  it("pairDAO create skips opening price check for non-ERCS20 base", async function () {
    const { pairFactory, tokenA, tokenB, deployer } = await deployPairFactory();

    await pairFactory.write.setPairDAO([deployer.account.address]);
    await pairFactory.write.create([tokenA.address, tokenB.address]);
    assert.equal(await pairFactory.read.isPair([tokenA.address, tokenB.address]), true);
  });

  it("mixed create paths share the same pairCount sequence", async function () {
    const { viem, publicClient, mockFactory, pairFactory, tokenA, tokenB, deployer, wusdc } =
      await deployPairFactory();

    await pairFactory.write.setPairDAO([deployer.account.address]);

    const ercs20 = await registerErcs20(viem, mockFactory);
    const fromBlock = await publicClient.getBlockNumber();

    await pairFactory.write.create([ercs20.address]);
    await pairFactory.write.create([tokenA.address, tokenB.address]);

    assert.equal(await pairFactory.read.pairCount(), 2n);

    const events = await publicClient.getContractEvents({
      address: pairFactory.address,
      abi: pairFactory.abi,
      eventName: "SpotPairCreated",
      fromBlock,
      strict: true,
    });
    assert.equal(events.length, 2);
    assert.equal(events[0].args.baseToken.toLowerCase(), ercs20.address.toLowerCase());
    assert.equal(events[0].args.quoteToken.toLowerCase(), wusdc.address.toLowerCase());
    assert.equal(events[0].args.pairIndex, 0n);
    assert.equal(events[1].args.pairIndex, 1n);
  });
});
