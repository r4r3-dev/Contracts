const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  const WCORE = await ethers.getContractFactory("WCORE");
  const wcore = await WCORE.deploy(deployer.address); // Pass the deployer's address

  await wcore.deploymentTransaction();
  const address = await wcore.getAddress();
  console.log("WCORE token deployed to:", address);
  console.log("Initial supply of 1,000,000 WCORE minted to:", deployer.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });