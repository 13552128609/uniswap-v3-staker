// scripts/deploy.js
const hre = require("hardhat");
const { ethers } = hre;

async function main() {
    const [deployer] = await ethers.getSigners();
    const owner = deployer;
    console.log("deployer:", deployer.address);
    console.log("owner (will be set as contract owner):", owner.address);    
    
    // 3) encode initialize calldata
    // prepare initialize params - adapt these to your environment (factory address, position manager address, times)
    const factoryAddress = "0xeb3e557f6fdcaba8dc98bda833e017866fc168cb";
    const positionManagerAddress = "0x73fe2A8aB6a56b11657ba31718C1febc96291076";
    const maxStartLead = 86400 * 30; // example
    const maxDuration = 86400 * 365 * 10; // example

    const Impl = await ethers.getContractFactory("UniswapV3StakerUpgradeable");
    const implInterface = new ethers.utils.Interface(Impl.interface.format()); // use the ABI
    const initData = implInterface.encodeFunctionData("initialize", [
        factoryAddress,
        positionManagerAddress,
        maxStartLead,
        maxDuration,
        owner.address // owner of the logic contract (via OwnableUpgradeable)
    ]);

    console.log("initData:", initData);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error(err);
        process.exit(1);
    });

    // npx hardhat run ./scripts/initData.js --network wanMainnet