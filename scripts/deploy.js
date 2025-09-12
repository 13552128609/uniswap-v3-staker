const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);

  const FACTORY = "0xeb3e557f6fdcaba8dc98bda833e017866fc168cb";
  const NONFUNGIBLE_POSITION_MANAGER = "0x73fe2A8aB6a56b11657ba31718C1febc96291076"; // mainnet

  const MAX_INCENTIVE_STAR_TLEADTIME = 86400;
  const MAX_INCENTIVE_DURATION = 86400 * 365;


  const Staker = await ethers.getContractFactory("UniswapV3Staker");
  const staker = await Staker.deploy(
      FACTORY,
      NONFUNGIBLE_POSITION_MANAGER,
      MAX_INCENTIVE_STAR_TLEADTIME,
      MAX_INCENTIVE_DURATION
  );

  await staker.deployed();
  console.log("UniswapV3Staker deployed to:", staker.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

