const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");
const maxStartLead = 86400 * 7; // example
const maxDuration = 86400 * 30; // example

async function main() {
    // get signer
    const [signer] = await ethers.getSigners();
    console.log("Using account:", signer.address);

    const artifactPath = path.join(__dirname, "../artifacts/contracts/UniswapV3StakerUpgradeable.sol/UniswapV3StakerUpgradeable.json");
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    const iface = new ethers.utils.Interface(artifact.abi);

    const stakerProxy = "0xfBa7565606Fd05D0E97bffAF6b4Dd5D1f07971C0";
    const staker = new ethers.Contract(stakerProxy, artifact.abi, signer);
    console.log(staker.address);
    console.log("factory...", await staker.factory());
    console.log("owner...", await staker.owner());
    console.log("nonfungiblePositionManager...", await staker.nonfungiblePositionManager());

    const artifactPathProxy = path.join(__dirname, "../artifacts/@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json");
    const artifactProxy = JSON.parse(fs.readFileSync(artifactPathProxy, "utf8"));
    const proxy = new ethers.Contract(stakerProxy, artifactProxy.abi, signer);
    console.log("proxyAddress",proxy.address);


    const artifactPathProxyAdmin = path.join(__dirname, "../artifacts/@openzeppelin/contracts/proxy/ProxyAdmin.sol/ProxyAdmin.json");
    const artifactProxyAdmin = JSON.parse(fs.readFileSync(artifactPathProxyAdmin, "utf8"));

    const proxyAdmin = "0x987ab81266d5B5eEd6A7a76f9FDe2bb6D12d06F2";
    const admin = new ethers.Contract(proxyAdmin, artifactProxyAdmin.abi, signer);
    console.log("implement",await admin.getProxyImplementation(stakerProxy));




    const rewardToken="0x95FF98073BF8bfBceC1C62854f04f963DbF83cA2"; // ZWAN
    const pool="0x64b256bd3933119f662e8cf2cf38d727f2669432";// wan/wanEth
    const startTime=Math.floor(Date.now()/1000) + 100; // start now + 1000sec
    const endTime= startTime + maxDuration;
    const refundee="0x4C68772310BEd28fcc9C6fbEE8735908f0b09a48";
    const reward=20_000_00;

    const token = await ethers.getContractAt("IERC20", rewardToken, signer);
    const txApprove = await token.approve(staker.address,reward);
    console.log("txApprove",await txApprove.wait());

    console.log("rewardToken",rewardToken);
    console.log("pool",pool);
    console.log("startTime",startTime);
    console.log("endTime",endTime);
    console.log("refundee",refundee);
    console.log("reward",reward);

    const tx = await staker.createIncentive({rewardToken,
        pool,
        startTime,
        endTime,
        refundee},reward);
     let ret = await tx.wait();


     console.log("createIncentive ret",ret);

    // // create incentive
    //
    // const rewardToken="0x2497157Ba4B9f2c0FB481ffB635D55a7ca83EAa5"; // YWAN
    // const pool="0xcf55d75f3480e86c1e43110d800be0948050ae33";// wan/wanUsdt
    // const startTime=Math.floor(Date.now()/1000) + 100; // start now + 1000sec
    // const endTime= startTime + maxDuration;
    // const refundee="0x4C68772310BEd28fcc9C6fbEE8735908f0b09a48";
    // const reward=1000;
    //
    // const stakerProxy = "0xfBa7565606Fd05D0E97bffAF6b4Dd5D1f07971C0";
    // const calldata = iface.encodeFunctionData("createIncentive", [{
    //     rewardToken,
    //     pool,
    //     startTime,
    //     endTime,
    //     refundee
    // },reward]);
    // const tx = await signer.sendTransaction({
    //     to: stakerProxy,
    //     data: calldata,
    //     gasLimit: 1_000_000, // 手动指定 gas 上限（可选）
    // });
    // console.log("Tx sent:", tx.hash);
    // await tx.wait();
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});

// npx hardhat run ./scripts/createIncentive2.js --network wanMainnet