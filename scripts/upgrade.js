// scripts/upgrade.js
const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    const owner = deployer;

    // replace with your deployed addresses
    const proxyAddress = "0xfBa7565606Fd05D0E97bffAF6b4Dd5D1f07971C0";
    const proxyAdminAddress = "0x987ab81266d5B5eEd6A7a76f9FDe2bb6D12d06F2";

    console.log("Using deployer:", deployer.address, "owner:", owner.address);
    console.log("Proxy:", proxyAddress);
    console.log("ProxyAdmin:", proxyAdminAddress);

    // 1) deploy new implementation
    const NewImpl = await ethers.getContractFactory("UniswapV3StakerUpgradeable"); // your new version (can be different file/name)
    const newImpl = await NewImpl.deploy();
    await newImpl.deployed();
    console.log("New implementation deployed:", newImpl.address);

    // 2) call ProxyAdmin.upgrade(proxy, newImpl) **must be called by ProxyAdmin.owner**
    const ProxyAdminFactory = await ethers.getContractFactory("@openzeppelin/contracts/proxy/ProxyAdmin.sol:ProxyAdmin");
    const proxyAdmin = ProxyAdminFactory.attach(proxyAdminAddress);

    // if the script signer (deployer) is ProxyAdmin.owner then directly call upgrade:
    // otherwise run this script with the owner account (use Hardhat network impersonate or run with correct signer)
    const ownerAddr = await proxyAdmin.owner();
    console.log("ProxyAdmin.owner:", ownerAddr);

    // Ensure the signer is the owner
    const signer = (await ethers.getSigners())[0];
    if (signer.address.toLowerCase() !== ownerAddr.toLowerCase()) {
        console.warn("Current signer is not ProxyAdmin.owner. You must run this script using the ProxyAdmin.owner account.");
        // Still try to call - will revert if not owner
    }

    const tx = await proxyAdmin.upgrade(proxyAddress, newImpl.address);
    await tx.wait();
    console.log("Proxy upgraded to new implementation:", newImpl.address);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error(err);
        process.exit(1);
    });
//npx hardhat run ./scripts/upgrade.js --network wanMainnet


