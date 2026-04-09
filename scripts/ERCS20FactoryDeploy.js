const { ethers } = require("hardhat");

const createIface = new ethers.Interface([
    "event Create(address indexed ercs20, uint256 index)",
]);

function getCreateFromReceipt(receipt) {
    for (const log of receipt.logs) {
        try {
            const parsed = createIface.parseLog({
                topics: log.topics,
                data: log.data,
            });
            if (parsed !== null && parsed.name === "Create") {
                const { ercs20, index } = parsed.args;
                return {
                    tokenAddress: ercs20,
                    index: BigInt(String(index)),
                };
            }
        } catch {
            /* not Create */
        }
    }
    throw new Error("Create log not found");
}

async function main() {
    const [deployer] = await ethers.getSigners();

    const factory = await ethers.deployContract("ERCS20Factory");
    const factoryAddr = await factory.getAddress();
    console.log("factoryAddr:"+factoryAddr);

    const totalSupply = ethers.parseUnits("100000000000", 18);
    const usdcAmount =  ethers.parseUnits("10000000", 18);

    const tx = await factory.create("Orbix DAO", "OBX", totalSupply, usdcAmount, deployer.address);
    const receipt = await tx.wait();
    console.log("receipt:", receipt);
    const { tokenAddress, index } = getCreateFromReceipt(receipt);
    console.log("tokenAddress:", tokenAddress);
    console.log("index:", index);
}

main();
