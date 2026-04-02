import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import type { TransactionReceipt } from "ethers";

const totalSupply = ethers.parseUnits("100000000000", 18);
const usdcAmount = ethers.parseUnits("10000000", 18);

const pairCreatedIface = new ethers.Interface([
    "event PairCreated(address indexed,address indexed,address,uint256)",
]);

/** Parses `PairCreated` from `factory.create` receipt (emitted in ERCS20 constructor). */
function getPairCreatedFromReceipt(receipt: TransactionReceipt): { tokenAddress: string; index: bigint } {
    for (const log of receipt.logs) {
        try {
            const parsed = pairCreatedIface.parseLog({
                topics: log.topics as string[],
                data: log.data,
            });
            if (parsed !== null && parsed.name === "PairCreated") {
                const r = parsed.args;
                const indexArg = r[r.length - 1];
                return { tokenAddress: log.address, index: BigInt(String(indexArg)) };
            }
        } catch {
            /* not PairCreated */
        }
    }
    throw new Error("PairCreated log not found");
}

describe("ERCS20Factory", function () {
    async function createFixture() {
        const [deployer, tokenOwner, other] = await ethers.getSigners();
        const factory = await ethers.deployContract("ERCS20Factory", []);
        return { deployer, tokenOwner, other, factory };
    }

    it("deploys with deployer as owner", async function () {
        const { deployer, factory } = await loadFixture(createFixture);
        expect(await factory.owner()).to.equal(deployer.address);
        expect(await factory.index()).to.equal(0n);
    });

    it("create deploys ERCS20, registers it, assigns index, transfers ownership", async function () {
        const { deployer, tokenOwner, factory } = await loadFixture(createFixture);

        const tokenName = "Equity Alpha";
        const tokenSymbol = "EQA";

        const tx = await factory.create(tokenName, tokenSymbol, totalSupply, usdcAmount, tokenOwner.address);
        const receipt = await tx.wait();
        expect(receipt).to.not.be.null;

        const { tokenAddress, index } = getPairCreatedFromReceipt(receipt!);
        expect(index).to.equal(0n);

        const token = await ethers.getContractAt("ERCS20", tokenAddress);

        expect(await token.name()).to.equal(tokenName);
        expect(await token.symbol()).to.equal(tokenSymbol);
        expect(await token.totalSupply()).to.equal(totalSupply);
        expect(await token.ercs20Amount()).to.equal(totalSupply);
        expect(await token.usdcSeedAmount()).to.equal(usdcAmount);
        expect(await token.owner()).to.equal(tokenOwner.address);
        expect(await factory.ercs20s(tokenAddress)).to.equal(true);
        expect(await factory.symbols(tokenSymbol)).to.equal(true);
        expect(await factory.index()).to.equal(1n);
    });

    it("increments index across multiple creates", async function () {
        const { tokenOwner, factory } = await loadFixture(createFixture);

        const tx0 = await factory.create("A", "SYM_A", totalSupply, usdcAmount, tokenOwner.address);
        const r0 = await tx0.wait();
        expect(r0).to.not.be.null;
        const { tokenAddress: addr0, index: i0 } = getPairCreatedFromReceipt(r0!);
        expect(i0).to.equal(0n);

        const tx1 = await factory.create("B", "SYM_B", totalSupply, usdcAmount, tokenOwner.address);
        const r1 = await tx1.wait();
        expect(r1).to.not.be.null;
        const { tokenAddress: addr1, index: i1 } = getPairCreatedFromReceipt(r1!);
        expect(i1).to.equal(1n);

        expect(addr0).to.not.equal(addr1);
        expect(await factory.index()).to.equal(2n);
    });

    it("reverts create when symbol already exists", async function () {
        const { tokenOwner, factory } = await loadFixture(createFixture);

        await factory.create("One", "DUP", totalSupply, usdcAmount, tokenOwner.address);

        await expect(
            factory.create("Two", "DUP", totalSupply, usdcAmount, tokenOwner.address)
        ).to.be.revertedWith("ERCS20Factory: SYMBOL_EXISTS");
    });

    it("pause blocks create; unpause allows create", async function () {
        const { tokenOwner, other, factory } = await loadFixture(createFixture);

        await expect(factory.connect(other).pause()).to.be.revertedWith("Ownable: caller is not the owner");

        await factory.pause();
        await expect(
            factory.create("P", "SYM_P", totalSupply, usdcAmount, tokenOwner.address)
        ).to.be.revertedWith("Pausable: paused");

        await expect(factory.connect(other).unpause()).to.be.revertedWith("Ownable: caller is not the owner");

        await factory.unpause();
        await factory.create("P", "SYM_P", totalSupply, usdcAmount, tokenOwner.address);
        expect(await factory.symbols("SYM_P")).to.equal(true);
    });

    it("second pause or unpause when not applicable reverts", async function () {
        const { factory } = await loadFixture(createFixture);

        await factory.pause();
        await expect(factory.pause()).to.be.revertedWith("Pausable: paused");

        await factory.unpause();
        await expect(factory.unpause()).to.be.revertedWith("Pausable: not paused");
    });

    it("safeTransferETH moves native balance (owner only)", async function () {
        const { deployer, other, factory } = await loadFixture(createFixture);

        await expect(factory.connect(other).safeTransferETH(deployer.address, 1n)).to.be.revertedWith(
            "Ownable: caller is not the owner"
        );

        const amount = ethers.parseEther("1");
        // Factory has no receive/fallback; fund via Hardhat RPC for this test.
        await ethers.provider.send("hardhat_setBalance", [await factory.getAddress(), ethers.toQuantity(amount)]);

        const before = await ethers.provider.getBalance(deployer.address);
        const tx = await factory.safeTransferETH(deployer.address, amount);
        const receipt = await tx.wait();
        expect(receipt).to.not.be.null;
        const gasPrice = receipt!.gasPrice ?? (receipt as { effectiveGasPrice?: bigint }).effectiveGasPrice ?? 0n;
        const gas = receipt!.gasUsed * gasPrice;
        const after = await ethers.provider.getBalance(deployer.address);
        expect(after - before + gas).to.equal(amount);
    });

    it("safeTransfer moves ERC20 held by factory (owner only)", async function () {
        const { deployer, other, factory } = await loadFixture(createFixture);

        const mock = await ethers.deployContract("MockERC20", []);

        await mock.transfer(factory, 1000n);
        expect(await mock.balanceOf(factory)).to.equal(1000n);

        const deployerMockBefore = await mock.balanceOf(deployer.address);

        await expect(factory.connect(other).safeTransfer(mock, deployer.address, 100n)).to.be.revertedWith(
            "Ownable: caller is not the owner"
        );

        await factory.safeTransfer(mock, deployer.address, 400n);
        expect(await mock.balanceOf(factory)).to.equal(600n);
        expect(await mock.balanceOf(deployer.address)).to.equal(deployerMockBefore + 400n);
    });
});
