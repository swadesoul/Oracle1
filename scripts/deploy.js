const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();
  const admin = process.env.ORACLE_ADMIN_ADDRESS || deployer.address;
  const guardian = process.env.ORACLE_GUARDIAN_ADDRESS || deployer.address;
  if (!ethers.utils.isAddress(admin) || !ethers.utils.isAddress(guardian)) {
    throw new Error("Valid ORACLE_ADMIN_ADDRESS and ORACLE_GUARDIAN_ADDRESS values are required.");
  }

  const Registry = await ethers.getContractFactory("RWAOracleRegistry");
  const registry = await Registry.deploy(admin, guardian);
  await registry.deployed();

  const deployment = {
    network: network.name,
    chainId: network.config.chainId,
    contract: "RWAOracleRegistry",
    address: registry.address,
    deployer: deployer.address,
    admin,
    guardian,
    transactionHash: registry.deployTransaction.hash,
    deployedAt: new Date().toISOString(),
  };
  const outputDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outputDir, { recursive: true });
  fs.writeFileSync(
    path.join(outputDir, `${network.name}.json`),
    `${JSON.stringify(deployment, null, 2)}\n`,
  );
  console.log(JSON.stringify(deployment, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
