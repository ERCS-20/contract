import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";
import { HDNodeWallet } from "ethers";
import { HardhatUserConfig } from "hardhat/config";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.18",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000
      },
      viaIR: true
    }
  },
  defaultNetwork: "hardhat_local",
  networks: {
    hardhat_local: {
      chainId: 31337,
      mining: {
        auto: false,
        interval: 1000
      },
      url: "http://127.0.0.1:8545/",
      accounts: [
        process.env.TEST0_PRIVATE_KEY!,
        process.env.TEST1_PRIVATE_KEY!,
        process.env.TEST2_PRIVATE_KEY!,
        process.env.TEST3_PRIVATE_KEY!,
        process.env.TEST4_PRIVATE_KEY!,
        process.env.TEST5_PRIVATE_KEY!,
        process.env.TEST6_PRIVATE_KEY!,
        process.env.TEST7_PRIVATE_KEY!,
        process.env.TEST8_PRIVATE_KEY!,
        process.env.TEST9_PRIVATE_KEY!,
        process.env.TEST10_PRIVATE_KEY!
      ]
    }
  },
};

export default config;
