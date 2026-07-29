require("@nomiclabs/hardhat-waffle");

const { subtask } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } = require("hardhat/builtin-tasks/task-names");

subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, async ({ solcVersion }, runSuper) => {
  if (solcVersion === "0.8.24") {
    return {
      compilerPath: require.resolve("solc/soljson.js"),
      isSolcJs: true,
      version: "0.8.24",
      longVersion: "0.8.24+commit.e11b9ed9",
    };
  }
  return runSuper();
});

const networks = {};
if (process.env.BASE_SEPOLIA_RPC_URL && process.env.DEPLOYER_PRIVATE_KEY) {
  networks.baseSepolia = {
    url: process.env.BASE_SEPOLIA_RPC_URL,
    chainId: 84532,
    accounts: [process.env.DEPLOYER_PRIVATE_KEY],
  };
}

module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 500 },
      viaIR: true,
    },
  },
  networks,
  paths: {
    sources: "./contracts-production",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  mocha: { timeout: 40000 },
};
