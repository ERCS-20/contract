import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

const name = "ERCS20";
const symbol = "ERCS20";
const totalSupply = ethers.parseUnits("100000000000", 18);
const usdcAmount =  ethers.parseUnits("10000000", 18);

/** Mirrors `ERCS20.getAmountOut` (gross then fee = gross/500, net = gross - fee). */
function expectedGetAmountOut(
    amount: bigint,
    isBuy: boolean,
    ercs20Reserve: bigint,
    usdReserve: bigint
): [bigint, bigint] {
    const gross = isBuy
        ? (amount * ercs20Reserve) / (usdReserve + amount)
        : (amount * usdReserve) / (ercs20Reserve + amount);
    const fee = gross / 500n;
    return [gross - fee, fee];
}

/** Valid swap deadline: current block time + buffer (seconds). */
async function futureDeadline(offsetSec: bigint = 3600n): Promise<bigint> {
    return BigInt(await time.latest()) + offsetSec;
}

describe("ERCS20", function() {

    async function createFixture() {

        const ercs20 = await ethers.deployContract("ERCS20", [name, symbol, totalSupply, usdcAmount]);
    
        return {ercs20};
    }

    it("constructor", async function() {
        const [deployer] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);

        expect(await ercs20.name()).to.equals(name);
        expect(await ercs20.symbol()).to.equals(symbol);
        expect(await ercs20.ercs20Amount()).to.equals(totalSupply);
        expect(await ercs20.usdcSeedAmount()).to.equals(usdcAmount);
        expect(await ercs20.usdAmount()).to.equals(usdcAmount);
        
        expect(await ercs20.balanceOf(ercs20)).to.equals(totalSupply);
        expect(await ercs20.totalSupply()).to.equals(totalSupply);

        expect(await ercs20.owner()).to.equals(deployer);
    });

    describe("setWithdrawAddr", function() {
        it("owner sets a non-zero withdraw address", async function() {
            const [deployer, addr] = await ethers.getSigners();
            const {ercs20} = await loadFixture(createFixture);

            await ercs20.setWithdrawAddr(addr.address);
            expect(await ercs20.withdrawAddr()).to.equal(addr.address);
        });

        it("reverts when setting zero address", async function() {
            const {ercs20} = await loadFixture(createFixture);

            await expect(ercs20.setWithdrawAddr(ethers.ZeroAddress)).to.be.revertedWith(
                "ERCS20: WITHDRAW_ADDR_ERROR"
            );
        });

        it("non-owner cannot set withdraw address", async function() {
            const [, other] = await ethers.getSigners();
            const {ercs20} = await loadFixture(createFixture);

            await expect(ercs20.connect(other).setWithdrawAddr(other.address)).to.be.revertedWith(
                "Ownable: caller is not the owner"
            );
        });

        it("owner can replace withdraw address", async function() {
            const [, first, second] = await ethers.getSigners();
            const {ercs20} = await loadFixture(createFixture);

            await ercs20.setWithdrawAddr(first.address);
            expect(await ercs20.withdrawAddr()).to.equal(first.address);

            await ercs20.setWithdrawAddr(second.address);
            expect(await ercs20.withdrawAddr()).to.equal(second.address);
        });
    });

    it("sell path _transfer rejects reentrancy (native callback)", async function() {
        const [deployer] = await ethers.getSigners();
        const {ercs20} = await loadFixture(createFixture);

        const [x, y] = await ercs20.getReserves();
        const quoteIn = ethers.parseUnits("1", 18);
        const buyExpected = expectedGetAmountOut(quoteIn, true, x, y);
        await ercs20.connect(deployer).buy(buyExpected[0], await futureDeadline(), { value: quoteIn });

        const Attacker = await ethers.getContractFactory("ERCS20SellReentrant");
        const attacker = await Attacker.deploy(ercs20);

        const bought = buyExpected[0];
        const half = bought / 2n;
        await ercs20.connect(deployer).transfer(attacker, bought);

        const reservesBefore = await ercs20.getReserves();

        // Nested sell in `receive` hits `nonReentrant` on `_transfer`. The outer `safeTransferETH`
        // then sees a failed callback and reverts with TransferHelper's "STE" (not the inner reason).
        await expect(attacker.attack(half, half)).to.be.revertedWith("STE");

        expect(await ercs20.balanceOf(attacker)).to.equals(bought);
        const reservesAfter = await ercs20.getReserves();
        expect(reservesAfter[0]).to.equals(reservesBefore[0]);
        expect(reservesAfter[1]).to.equals(reservesBefore[1]);
    });

    it("getReserves", async function() {

        const {ercs20} = await loadFixture(createFixture);

        const data = await ercs20.getReserves();
        expect(data[0]).to.equals(totalSupply);
        expect(data[1]).to.equals(usdcAmount);

    });

    describe("getAmountOut", function() {
        it("returns (0, 0) for zero amount (buy and sell)", async function() {
            const {ercs20} = await loadFixture(createFixture);
            expect(await ercs20.getAmountOut(0n, true)).to.deep.equal([0n, 0n]);
            expect(await ercs20.getAmountOut(0n, false)).to.deep.equal([0n, 0n]);
        });

        it("matches local formula for 1 wei (buy and sell)", async function() {
            const {ercs20} = await loadFixture(createFixture);
            const [x, y] = await ercs20.getReserves();
            const one = 1n;

            const buyExpected = expectedGetAmountOut(one, true, x, y);
            const buyActual = await ercs20.getAmountOut(one, true);
            expect(buyActual[0]).to.equal(buyExpected[0]);
            expect(buyActual[1]).to.equal(buyExpected[1]);

            const sellExpected = expectedGetAmountOut(one, false, x, y);
            const sellActual = await ercs20.getAmountOut(one, false);
            expect(sellActual[0]).to.equal(sellExpected[0]);
            expect(sellActual[1]).to.equal(sellExpected[1]);
        });

        it("matches local formula for 1e18 quote in (buy) and 1e18 token in (sell)", async function() {
            const {ercs20} = await loadFixture(createFixture);
            const [x, y] = await ercs20.getReserves();
            const amount = ethers.parseUnits("1", 18);

            const buyExpected = expectedGetAmountOut(amount, true, x, y);
            const buyActual = await ercs20.getAmountOut(amount, true);
            expect(buyActual[0]).to.equal(buyExpected[0]);
            expect(buyActual[1]).to.equal(buyExpected[1]);

            const sellExpected = expectedGetAmountOut(amount, false, x, y);
            const sellActual = await ercs20.getAmountOut(amount, false);
            expect(sellActual[0]).to.equal(sellExpected[0]);
            expect(sellActual[1]).to.equal(sellExpected[1]);
        });

        it("uses updated reserves after a buy", async function() {
            const {ercs20} = await loadFixture(createFixture);
            const amountIn = ethers.parseUnits("1", 18);

            await ercs20.buy(await ercs20.getAmountOut(amountIn, true).then((r) => r[0]), await futureDeadline(), {
                value: amountIn,
            });

            const [x, y] = await ercs20.getReserves();
            const probe = ethers.parseUnits("1", 17);
            const expected = expectedGetAmountOut(probe, true, x, y);
            const actual = await ercs20.getAmountOut(probe, true);
            expect(actual[0]).to.equal(expected[0]);
            expect(actual[1]).to.equal(expected[1]);
        });
    });

    it("transfer usdc to the contract", async function() {
        const [deployer] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);

        const usdcSeedAmount = await ercs20.usdcSeedAmount();

        const tokenBalance = await ercs20.balanceOf(deployer);
        const ethBalance = await ethers.provider.getBalance(deployer);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);

        const tx = await deployer.sendTransaction({
            to: ercs20,
            value: ethers.parseUnits("1", 18)
        });
        const txReceipt = await tx.wait();
        expect(txReceipt).to.not.be.null;
        const gasFee = txReceipt!.gasUsed * txReceipt!.gasPrice!;

        const buyExpected = expectedGetAmountOut(amount, true, x, y);

        // user's balance
        expect(await ercs20.balanceOf(deployer)).to.equals(tokenBalance+buyExpected[0]);
        expect(await ethers.provider.getBalance(deployer)).to.equals(ethBalance-amount-gasFee);

        // contract's balance
        expect(await ercs20.balanceOf(ercs20)).to.equals(x-buyExpected[0]);
        expect(await ethers.provider.getBalance(ercs20)).to.equals(y+amount-usdcSeedAmount);

        // contract's reserves
        const data = await ercs20.getReserves();
        expect(data[0]).to.equals(x-buyExpected[0]-buyExpected[1]);
        expect(data[1]).to.equals(y+amount);

        // buy-side token fee
        expect(await ercs20.balanceOf(ercs20)).to.equals(data[0]+buyExpected[1]);
    });

    it("transfer ercs20 to the contract", async function() {
        const [deployer] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);

        const usdcSeedAmount = await ercs20.usdcSeedAmount();

        const tokenBalance0 = await ercs20.balanceOf(deployer);
        const ethBalance0 = await ethers.provider.getBalance(deployer);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);

        const tx1 = await deployer.sendTransaction({
            to: ercs20,
            value: amount,
        });
        const receipt1 = await tx1.wait();
        expect(receipt1).to.not.be.null;
        const gasFee1 = receipt1!.gasUsed * receipt1!.gasPrice!;

        const buyExpected = expectedGetAmountOut(amount, true, x, y);
        const sellAmount = buyExpected[0];

        // after buy (same relations as "transfer usdc to the contract")
        expect(await ercs20.balanceOf(deployer)).to.equals(tokenBalance0 + buyExpected[0]);
        expect(await ethers.provider.getBalance(deployer)).to.equals(ethBalance0 - amount - gasFee1);

        expect(await ercs20.balanceOf(ercs20)).to.equals(x - buyExpected[0]);
        expect(await ethers.provider.getBalance(ercs20)).to.equals(y + amount - usdcSeedAmount);

        let data = await ercs20.getReserves();
        expect(data[0]).to.equals(x - buyExpected[0] - buyExpected[1]);
        expect(data[1]).to.equals(y + amount);
        expect(await ercs20.balanceOf(ercs20)).to.equals(data[0] + buyExpected[1]);

        // sell: transfer bought tokens back to the contract
        const tokenBalance1 = await ercs20.balanceOf(deployer);
        const ethBalance1 = await ethers.provider.getBalance(deployer);

        const [x1, y1] = data;
        const sellExpected = expectedGetAmountOut(sellAmount, false, x1, y1);

        const tx2 = await ercs20.transfer(ercs20, sellAmount);
        const receipt2 = await tx2.wait();
        expect(receipt2).to.not.be.null;
        const gasFee2 = receipt2!.gasUsed * receipt2!.gasPrice!;

        // user's balance
        expect(await ercs20.balanceOf(deployer)).to.equals(tokenBalance1 - sellAmount);
        expect(await ethers.provider.getBalance(deployer)).to.equals(ethBalance1 + sellExpected[0] - gasFee2);

        // contract's balance
        expect(await ercs20.balanceOf(ercs20)).to.equals(x);
        expect(await ethers.provider.getBalance(ercs20)).to.equals(
            y + amount - usdcSeedAmount - sellExpected[0]
        );

        // contract's reserves
        data = await ercs20.getReserves();
        expect(data[0]).to.equals(x1 + sellAmount);
        expect(data[1]).to.equals(y1 - sellExpected[0] - sellExpected[1]);

        // buy-side token fee 
        expect(await ercs20.balanceOf(ercs20)).to.equals(data[0] + buyExpected[1]);
        // sell-side usdc fee
        expect(await ethers.provider.getBalance(ercs20)).to.equals(data[1] - usdcSeedAmount + sellExpected[1]);
    });

    it("buy", async function() {
        const [deployer] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);

        const usdcSeedAmountFromContract = await ercs20.usdcSeedAmount();

        const tokenBalance = await ercs20.balanceOf(deployer);
        const ethBalance = await ethers.provider.getBalance(deployer);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);
        const buyExpected = expectedGetAmountOut(amount, true, x, y);

        const tx = await ercs20.buy(buyExpected[0], await futureDeadline(), { value: amount });
        const txReceipt = await tx.wait();
        expect(txReceipt).to.not.be.null;
        const gasFee = txReceipt!.gasUsed * txReceipt!.gasPrice!;

        // user's balance
        expect(await ercs20.balanceOf(deployer)).to.equals(tokenBalance + buyExpected[0]);
        expect(await ethers.provider.getBalance(deployer)).to.equals(ethBalance - amount - gasFee);

        // contract's balance
        expect(await ercs20.balanceOf(ercs20)).to.equals(x - buyExpected[0]);
        expect(await ethers.provider.getBalance(ercs20)).to.equals(y + amount - usdcSeedAmountFromContract);

        // contract's reserves
        const data = await ercs20.getReserves();
        expect(data[0]).to.equals(x - buyExpected[0] - buyExpected[1]);
        expect(data[1]).to.equals(y + amount);

        // buy-side token fee
        expect(await ercs20.balanceOf(ercs20)).to.equals(data[0] + buyExpected[1]);
    });

    it("sell", async function() {
        const [deployer] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);

        const usdcSeedAmountFromContract = await ercs20.usdcSeedAmount();

        const tokenBalance0 = await ercs20.balanceOf(deployer);
        const ethBalance0 = await ethers.provider.getBalance(deployer);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);

        const tx1 = await deployer.sendTransaction({
            to: ercs20,
            value: amount,
        });
        const receipt1 = await tx1.wait();
        expect(receipt1).to.not.be.null;
        const gasFee1 = receipt1!.gasUsed * receipt1!.gasPrice!;

        const buyExpected = expectedGetAmountOut(amount, true, x, y);
        const sellAmount = buyExpected[0];

        expect(await ercs20.balanceOf(deployer)).to.equals(tokenBalance0 + buyExpected[0]);
        expect(await ethers.provider.getBalance(deployer)).to.equals(ethBalance0 - amount - gasFee1);

        let data = await ercs20.getReserves();
        const [x1, y1] = data;

        const tokenBalance1 = await ercs20.balanceOf(deployer);
        const ethBalance1 = await ethers.provider.getBalance(deployer);

        const sellExpected = expectedGetAmountOut(sellAmount, false, x1, y1);

        const tx2 = await ercs20.sell(sellAmount, sellExpected[0], await futureDeadline());
        const receipt2 = await tx2.wait();
        expect(receipt2).to.not.be.null;
        const gasFee2 = receipt2!.gasUsed * receipt2!.gasPrice!;

        // user's balance
        expect(await ercs20.balanceOf(deployer)).to.equals(tokenBalance1 - sellAmount);
        expect(await ethers.provider.getBalance(deployer)).to.equals(ethBalance1 + sellExpected[0] - gasFee2);

        // contract's balance
        expect(await ercs20.balanceOf(ercs20)).to.equals(x);
        expect(await ethers.provider.getBalance(ercs20)).to.equals(
            y + amount - usdcSeedAmountFromContract - sellExpected[0]
        );

        // contract's reserves
        data = await ercs20.getReserves();
        expect(data[0]).to.equals(x1 + sellAmount);
        expect(data[1]).to.equals(y1 - sellExpected[0] - sellExpected[1]);

        // buy-side token fee
        expect(await ercs20.balanceOf(ercs20)).to.equals(data[0] + buyExpected[1]);
        // sell-side quote fee (native) stays in contract vs tracked reserve
        expect(await ethers.provider.getBalance(ercs20)).to.equals(
            data[1] - usdcSeedAmountFromContract + sellExpected[1]
        );
    });

    it("buy log", async function() {
        const [deployer] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);
        const buyExpected = expectedGetAmountOut(amount, true, x, y);

        await expect(ercs20.buy(buyExpected[0], await futureDeadline(), { value: amount }))
            .to.emit(ercs20, "Sync")
            .withArgs(x - buyExpected[0] - buyExpected[1], y + amount)
            .to.emit(ercs20, "Swap")
            .withArgs(deployer, 0, amount, buyExpected[0], 0, deployer);
    });

    it("sell log", async function() {
        const [deployer] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);
        const buyExpected = expectedGetAmountOut(amount, true, x, y);

        await expect(ercs20.buy(buyExpected[0], await futureDeadline(), { value: amount }))
            .to.emit(ercs20, "Sync")
            .withArgs(x - buyExpected[0] - buyExpected[1], y + amount)
            .to.emit(ercs20, "Swap")
            .withArgs(deployer, 0, amount, buyExpected[0], 0, deployer);

        const [x1, y1] = await ercs20.getReserves();
        const sellAmount = buyExpected[0];
        const sellExpected = expectedGetAmountOut(sellAmount, false, x1, y1);

        await expect(ercs20.sell(sellAmount, sellExpected[0], await futureDeadline()))
            .to.emit(ercs20, "Sync")
            .withArgs(x1 + sellAmount, y1 - sellExpected[0] - sellExpected[1])
            .to.emit(ercs20, "Swap")
            .withArgs(deployer, sellAmount, 0, 0, sellExpected[0], deployer);
    });

    it("buy amountInMin", async function() {
        const {ercs20} = await loadFixture(createFixture);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);
        const buyExpected = expectedGetAmountOut(amount, true, x, y);

        await expect(
            ercs20.buy(buyExpected[0] + 1n, await futureDeadline(), { value: amount })
        ).to.be.revertedWith(/ERCS20: INSUFFICIENT_OUTPUT_AMOUNT/);

        await ercs20.buy(buyExpected[0], await futureDeadline(), { value: amount });
    });

    it("sell amountInMin", async function() {
        const {ercs20} = await loadFixture(createFixture);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);
        const buyExpected = expectedGetAmountOut(amount, true, x, y);
        await ercs20.buy(buyExpected[0], await futureDeadline(), { value: amount });

        const [x1, y1] = await ercs20.getReserves();
        const sellAmount = buyExpected[0];
        const sellExpected = expectedGetAmountOut(sellAmount, false, x1, y1);

        await expect(ercs20.sell(sellAmount, sellExpected[0] + 1n, await futureDeadline())).to.be.revertedWith(
            /ERCS20: INSUFFICIENT_OUTPUT_AMOUNT/
        );

        await ercs20.sell(sellAmount, sellExpected[0], await futureDeadline());
    });

    describe("deadline", function () {
        it("reverts buy when deadline is in the past", async function () {
            const { ercs20 } = await loadFixture(createFixture);
            const [x, y] = await ercs20.getReserves();
            const amount = ethers.parseUnits("1", 18);
            const buyExpected = expectedGetAmountOut(amount, true, x, y);
            const past = BigInt(await time.latest()) - 1n;

            await expect(
                ercs20.buy(buyExpected[0], past, { value: amount })
            ).to.be.revertedWith("ERCS20: EXPIRED");
        });

        it("reverts buy when block time passes deadline", async function () {
            const { ercs20 } = await loadFixture(createFixture);
            const [x, y] = await ercs20.getReserves();
            const amount = ethers.parseUnits("1", 18);
            const buyExpected = expectedGetAmountOut(amount, true, x, y);
            const dl = BigInt(await time.latest()) + 10n;
            await time.increase(20n);

            await expect(
                ercs20.buy(buyExpected[0], dl, { value: amount })
            ).to.be.revertedWith("ERCS20: EXPIRED");
        });

        it("reverts sell when deadline is in the past", async function () {
            const [deployer] = await ethers.getSigners();
            const { ercs20 } = await loadFixture(createFixture);
            const [x, y] = await ercs20.getReserves();
            const amount = ethers.parseUnits("1", 18);
            const buyExpected = expectedGetAmountOut(amount, true, x, y);
            await ercs20.buy(buyExpected[0], await futureDeadline(), { value: amount });

            const [x1, y1] = await ercs20.getReserves();
            const sellAmount = buyExpected[0];
            const sellExpected = expectedGetAmountOut(sellAmount, false, x1, y1);
            const past = BigInt(await time.latest()) - 1n;

            await expect(ercs20.sell(sellAmount, sellExpected[0], past)).to.be.revertedWith(
                "ERCS20: EXPIRED"
            );
        });

        it("reverts sell when block time passes deadline", async function () {
            const { ercs20 } = await loadFixture(createFixture);
            const [x, y] = await ercs20.getReserves();
            const amount = ethers.parseUnits("1", 18);
            const buyExpected = expectedGetAmountOut(amount, true, x, y);
            await ercs20.buy(buyExpected[0], await futureDeadline(), { value: amount });

            const [x1, y1] = await ercs20.getReserves();
            const sellAmount = buyExpected[0];
            const sellExpected = expectedGetAmountOut(sellAmount, false, x1, y1);
            const dl = BigInt(await time.latest()) + 10n;
            await time.increase(20n);

            await expect(ercs20.sell(sellAmount, sellExpected[0], dl)).to.be.revertedWith(
                "ERCS20: EXPIRED"
            );
        });

        it("allows buy and sell with type(uint256).max deadline (no time bound)", async function () {
            const [deployer] = await ethers.getSigners();
            const { ercs20 } = await loadFixture(createFixture);
            const maxDl = ethers.MaxUint256;
            const [x, y] = await ercs20.getReserves();
            const amount = ethers.parseUnits("1", 18);
            const buyExpected = expectedGetAmountOut(amount, true, x, y);

            await time.increase(100_000n);
            await ercs20.buy(buyExpected[0], maxDl, { value: amount });
            expect(await ercs20.balanceOf(deployer)).to.equal(buyExpected[0]);

            await time.increase(100_000n);
            const [x1, y1] = await ercs20.getReserves();
            const sellAmount = buyExpected[0];
            const sellExpected = expectedGetAmountOut(sellAmount, false, x1, y1);
            await ercs20.sell(sellAmount, sellExpected[0], maxDl);

            expect(await ercs20.balanceOf(deployer)).to.equal(0n);
        });
    });

    it("withdrawFee", async function() {
        const [deployer, feeCollector] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);

        const [x, y] = await ercs20.getReserves();
        const amount = ethers.parseUnits("1", 18);
        const buyExpected = expectedGetAmountOut(amount, true, x, y);
        await ercs20.buy(buyExpected[0], await futureDeadline(), { value: amount });

        const [x1, y1] = await ercs20.getReserves();
        const sellAmount = buyExpected[0];
        const sellExpected = expectedGetAmountOut(sellAmount, false, x1, y1);
        await ercs20.sell(sellAmount, sellExpected[0], await futureDeadline());

        const recipientEthBefore = await ethers.provider.getBalance(feeCollector);
        const recipientTokenBefore = await ercs20.balanceOf(feeCollector);
        const data = await ercs20.getReserves();

        await expect(ercs20.withdrawFee()).to.be.revertedWith(
            "ERCS20: WITHDRAW_ADDR_ERROR"
        );

        await ercs20.setWithdrawAddr(feeCollector);

        await ercs20.withdrawFee();

        expect(await ercs20.balanceOf(feeCollector)).to.equals(recipientTokenBefore + buyExpected[1]);
        expect(await ethers.provider.getBalance(feeCollector)).to.equals(recipientEthBefore + sellExpected[1]);

        const dataAfter = await ercs20.getReserves();
        expect(dataAfter[0]).to.equals(data[0]);
        expect(dataAfter[1]).to.equals(data[1]);
    });

    it("safeTransfer", async function() {
        const [deployer, test001] = await ethers.getSigners();

        const {ercs20} = await loadFixture(createFixture);
        const mock = await ethers.deployContract("MockERC20", []);

        const test001MockBalance = await mock.balanceOf(test001);

        await mock.transfer(ercs20, 100n);
        expect(await mock.balanceOf(ercs20)).to.equals(100n);

        await expect(ercs20.safeTransfer(ercs20, test001, 100)).to.be.revertedWith(
            /ERCS20: TOKEN_ERROR/
        );
        await expect(ercs20.connect(test001).safeTransfer(mock, test001, 100)).to.be.revertedWith(
            /Ownable: caller is not the owner/
        );

        await ercs20.safeTransfer(mock, test001, 100);

        expect(await mock.balanceOf(ercs20)).to.equals(0n);
        expect(await mock.balanceOf(test001)).to.equals(test001MockBalance + 100n);
    });

});