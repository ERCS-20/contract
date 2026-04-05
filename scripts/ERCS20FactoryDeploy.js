const { ethers } = require("hardhat");

const pairCreatedIface = new ethers.Interface([
    "event PairCreated(address indexed,address indexed,address,uint256)",
]);

function getPairCreatedFromReceipt(receipt) {
    for (const log of receipt.logs) {
        try {
            const parsed = pairCreatedIface.parseLog({
                topics: log.topics,
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

async function main() {
    const [deployer] = await ethers.getSigners();

    const factory = await ethers.deployContract("ERCS20Factory");
    const factoryAddr = await factory.getAddress();
    console.log("factoryAddr:"+factoryAddr);

    const totalSupply = ethers.parseUnits("100000000000", 18);
    const usdcAmount =  ethers.parseUnits("10000000", 18);

    const tx = await factory.create("Orbix DAO", "OXD", totalSupply, usdcAmount, deployer.address);
    const receipt = await tx.wait();
    console.log("receipt:", receipt);
    const { tokenAddress, index } = getPairCreatedFromReceipt(receipt);
    console.log("tokenAddress:", tokenAddress);
    console.log("index:", index);
}

main();
