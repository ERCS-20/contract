const { ethers } = require("hardhat");

const name = "Orbix DAO";
const symbol = "OBX";
const totalSupply = ethers.parseUnits("100000000000", 18);
const usdcAmount = ethers.parseUnits("10000000", 18);

function pairCreatedFromReceipt(factory, receipt) {
  for (const log of receipt.logs) {
    try {
      const parsed = factory.interface.parseLog(log);
      if (parsed && parsed.name === "PairCreated") {
        return {
          ercs20: parsed.args.ercs20,
          usdc: parsed.args.usdc,
          pair: parsed.args.pair,
          index: parsed.args.index,
        };
      }
    } catch {
      /* unrelated log */
    }
  }
  throw new Error("PairCreated event not found in receipt");
}

async function main() {
  const [deployer] = await ethers.getSigners();

  const meta = await ethers.deployContract("ERCS20Meta");
  const metaAddr = await meta.getAddress();
  console.log("ERCS20Meta:", metaAddr);

  const factory = await ethers.deployContract("ERCS20Factory");
  const factoryAddr = await factory.getAddress();
  console.log("ERCS20Factory:", factoryAddr);

  const tx = await factory.create(name, symbol, totalSupply, usdcAmount, deployer.address);
  const receipt = await tx.wait();
  const { ercs20, index } = pairCreatedFromReceipt(factory, receipt);
  console.log("ERCS20 token:", ercs20);
  console.log("Factory index:", index.toString());

  const snapshot = await meta.get(ercs20);
  console.log("ERCS20Meta.get:", {
    name: snapshot[0],
    symbol: snapshot[1],
    decimals: snapshot[2],
    totalSupply: snapshot[3].toString(),
    usdcSeedAmount: snapshot[4].toString(),
  });
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
