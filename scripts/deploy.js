// scripts/deploy.js
const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    const owner = deployer;
    console.log("deployer:", deployer.address);
    console.log("owner (will be set as contract owner):", owner.address);

    // 1) 部署 Implementation
    const Impl = await ethers.getContractFactory("UniswapV3StakerUpgradeable");
    const impl = await Impl.deploy(); // For upgradeable, implementation constructor is not used; but we deploy impl contract
    await impl.deployed();
    console.log("Implementation deployed:", impl.address);

    // 2) 部署 ProxyAdmin
    // Fully qualified name for OZ Transparent ProxyAdmin in node_modules:
    const ProxyAdminFactory = await ethers.getContractFactory("@openzeppelin/contracts/proxy/ProxyAdmin.sol:ProxyAdmin");
    const proxyAdmin = await ProxyAdminFactory.deploy();
    await proxyAdmin.deployed();
    console.log("ProxyAdmin deployed:", proxyAdmin.address);

    // 3) encode initialize calldata
    // prepare initialize params - adapt these to your environment (factory address, position manager address, times)
    const factoryAddress = "0xeb3e557f6fdcaba8dc98bda833e017866fc168cb";
    const positionManagerAddress = "0x73fe2A8aB6a56b11657ba31718C1febc96291076";
    const maxStartLead = 86400 * 30; // example
    const maxDuration = 86400 * 365 * 10; // example

    const implInterface = new ethers.utils.Interface(Impl.interface.format()); // use the ABI
    const initData = implInterface.encodeFunctionData("initialize", [
        factoryAddress,
        positionManagerAddress,
        maxStartLead,
        maxDuration,
        owner.address // owner of the logic contract (via OwnableUpgradeable)
    ]);

    // 4) 部署 TransparentUpgradeableProxy
    const ProxyFactory = await ethers.getContractFactory("@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy");
    // constructor(address _logic, address admin_, bytes memory _data)
    const proxy = await ProxyFactory.deploy(impl.address, proxyAdmin.address, initData);
    await proxy.deployed();
    console.log("Proxy deployed:", proxy.address);

    // 5) Print addresses
    console.log("\nDeployed addresses:");
    console.log("Implementation:", impl.address);
    console.log("ProxyAdmin:", proxyAdmin.address);
    console.log("Proxy:", proxy.address);

    // Optional: attach the proxied contract via the implementation ABI
    const proxied = Impl.attach(proxy.address);
    console.log("Proxied contract as seen by owner:", proxied.address);

    // Example read: call factory() through proxy (works because ABI matches)
    // const f = await proxied.factory();
    // console.log("factory via proxy:", f);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error(err);
        process.exit(1);
    });

    // npx hardhat run ./scripts/deploy.js --network wanMainnet