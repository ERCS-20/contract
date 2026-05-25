import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import * as dotenv from "dotenv";
import { configVariable, defineConfig } from "hardhat/config";

dotenv.config();

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: {
          // optimizer: {
          //   enabled: true,
          //   runs: 200,
          // },
          viaIR: true,
        },
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
    },
  },
  networks: {
    /**
     * Backing chain for `npx hardhat node` (JSON-RPC on port 8545 by default).
     * Optional overrides: `npx hardhat node --network hardhatMainnet` etc.
     */
    node: {
      type: "edr-simulated",
      chainType: "l1",
    },
    /** Connect scripts/tests to a running local node: `npx hardhat run ... --network localhost` */
    local_host: {
      type: "http",
      chainType: "l1",
      url: "http://127.0.0.1:8545",
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
    },
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
  },
});
