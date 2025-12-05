import { ethers, waffle } from 'hardhat'
import { Contract, Signer } from 'ethers'
import { expect, uniswapFactoryFixture, days, BNe18 } from './shared'
import {
    IUniswapV3Factory,
    INonfungiblePositionManager,
    TestERC20,
} from '../typechain'

describe('UniswapV3StakerUpgradeable', () => {
    let deployer: Signer
    let creator: Signer
    let lp: Signer
    let other: Signer

    let factory: IUniswapV3Factory
    let nft: INonfungiblePositionManager
    let tokens: [TestERC20, TestERC20, TestERC20]

    let stakerImpl: Contract
    let proxyAdmin: Contract
    let proxy: Contract
    let staker: Contract // proxy as UniswapV3StakerUpgradeable

    const maxIncentiveStartLeadTime = days(30)
    const maxIncentiveDuration = days(60)

    beforeEach('deploy fixture + upgradeable staker', async () => {
        const wallets = waffle.provider.getWallets()
            ;[deployer, creator, lp, other] = wallets

        // 1. 先用现有 fixture 搭好 Uniswap V3 环境
        const ctx = await uniswapFactoryFixture(wallets, waffle.provider)
        factory = ctx.factory
        nft = ctx.nft
        tokens = ctx.tokens

        // 2. 部署逻辑合约实现
        const StakerImplFactory = await ethers.getContractFactory('UniswapV3StakerUpgradeable')
        stakerImpl = await StakerImplFactory.connect(deployer).deploy()
        await stakerImpl.deployed()

        // 3. 部署 ProxyAdmin
        const ProxyAdminFactory = await ethers.getContractFactory('ProxyAdmin')
        proxyAdmin = await ProxyAdminFactory.connect(deployer).deploy()
        await proxyAdmin.deployed()

        // 4. 编码 initialize 调用数据
        const initData = stakerImpl.interface.encodeFunctionData('initialize', [
            factory.address,
            nft.address,
            maxIncentiveStartLeadTime,
            maxIncentiveDuration,
            await creator.getAddress(), // _owner
        ])

        // 5. 部署 TransparentUpgradeableProxy
        const TransparentProxyFactory = await ethers.getContractFactory('TransparentUpgradeableProxy')
        proxy = await TransparentProxyFactory.connect(deployer).deploy(
            stakerImpl.address,
            proxyAdmin.address,
            initData
        )
        await proxy.deployed()

        // 6. 通过实现合约 ABI 连接到 proxy
        staker = StakerImplFactory.attach(proxy.address)
    })

    it('初始化后关键状态变量正确', async () => {
        expect(await staker.factory()).to.eq(factory.address)
        expect(await staker.nonfungiblePositionManager()).to.eq(nft.address)
        expect(await staker.maxIncentiveStartLeadTime()).to.eq(maxIncentiveStartLeadTime)
        expect(await staker.maxIncentiveDuration()).to.eq(maxIncentiveDuration)

        const owner = await staker.owner()
        expect(owner).to.eq(await creator.getAddress())
    })

    it('initialize 只能被调用一次', async () => {
        await expect(
            staker.initialize(
                factory.address,
                nft.address,
                maxIncentiveStartLeadTime,
                maxIncentiveDuration,
                await creator.getAddress()
            )
        ).to.be.reverted // OpenZeppelin 的 Initializable 会用 "contract is already initialized" 之类的 revert
    })

    it('ProxyAdmin 正确记录实现和 admin', async () => {
        const implFromAdmin = await proxyAdmin.getProxyImplementation(proxy.address)
        const adminFromAdmin = await proxyAdmin.getProxyAdmin(proxy.address)

        expect(implFromAdmin).to.eq(stakerImpl.address)
        expect(adminFromAdmin).to.eq(proxyAdmin.address)
    })

    it('通过 proxy 调用 createIncentive / endIncentive 的简单闭环', async () => {
        const [token0, token1, rewardToken] = tokens
        const [walletDeployer] = waffle.provider.getWallets()

        // 创建一个 pool，用于 IncentiveKey.pool
        await factory.createPool(token0.address, token1.address, 3000)
        const poolAddress = await factory.getPool(token0.address, token1.address, 3000)

        // 给 creator 一些 rewardToken 并授权给 staker
        const rewardAmount = BNe18(1000)
        await rewardToken.transfer(await creator.getAddress(), rewardAmount)
        await rewardToken.connect(creator).approve(staker.address, rewardAmount)

        const currentBlock = await waffle.provider.getBlock('latest')
        const now = currentBlock.timestamp
        const startTime = now + 100
        const endTime = startTime + days(10)

        const key = {
            rewardToken: rewardToken.address,
            pool: poolAddress,
            startTime,
            endTime,
            refundee: await creator.getAddress(),
        }

        // 通过 proxy 调用 createIncentive
        await expect(
            staker.connect(creator).createIncentive(key, rewardAmount)
        ).to.emit(staker, 'IncentiveCreated')

        // incentives mapping 中的数据应正确记录
        // const incentiveId = await staker.callStatic['IncentiveId_compute'](key).catch(() => null)
        // 如果你没有对外暴露 compute，可以跳过上面这行，只检查 endIncentive 的行为

        // 推进时间到 endTime 以后
        await waffle.provider.send('evm_setNextBlockTimestamp', [endTime + 1])
        await waffle.provider.send('evm_mine', [])

        // endIncentive 退回未分配奖励
        const beforeBalance = await rewardToken.balanceOf(await creator.getAddress())
        const tx = await staker.connect(creator).endIncentive(key)
        const receipt = await tx.wait()
        const afterBalance = await rewardToken.balanceOf(await creator.getAddress())

        // 求 refund 事件参数或返回值
        const refund = afterBalance.sub(beforeBalance)
        expect(refund).to.eq(rewardAmount)
    })

    // 示例：非常简化的 stake/withdraw 流程，只验证能走通
    // 真正的流动性/奖励分配逻辑已经由原 UniswapV3Staker 的集成测试覆盖
    it.skip('可以通过 proxy 调用 stakeToken / withdrawToken 的基本流程', async () => {
        const [token0, token1, rewardToken] = tokens
        const wallets = waffle.provider.getWallets()
        const lpWallet = wallets[2]

        // 还是先建 pool
        await factory.createPool(token0.address, token1.address, 3000)
        const poolAddress = await factory.getPool(token0.address, token1.address, 3000)

        // creator 创建一个有奖励的 incentive，只测试流程
        const rewardAmount = BNe18(1)

        // 给 creator 一点 rewardToken 并授权给 staker
        await rewardToken.transfer(await creator.getAddress(), rewardAmount)
        await rewardToken.connect(creator).approve(staker.address, rewardAmount)

        const currentBlock = await waffle.provider.getBlock('latest')
        const now = currentBlock.timestamp
        const startTime = now + 100
        const endTime = startTime + days(10)

        const key = {
            rewardToken: rewardToken.address,
            pool: poolAddress,
            startTime,
            endTime,
            refundee: await creator.getAddress(),
        }

        await staker.connect(creator).createIncentive(key, rewardAmount)

        // 给 LP 准备一些 token 并铸造一个 LP NFT
        const amount = BNe18(10)
        await token0.transfer(lpWallet.address, amount)
        await token1.transfer(lpWallet.address, amount)
        await token0.connect(lpWallet).approve(nft.address, amount)
        await token1.connect(lpWallet).approve(nft.address, amount)

        const mintTx = await nft.connect(lpWallet).mint({
            token0: token0.address,
            token1: token1.address,
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount0Desired: amount,
            amount1Desired: amount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: lpWallet.address,
            deadline: now + 1000,
        })
        const mintReceipt = await mintTx.wait()
        const transferEvent = mintReceipt.events?.find((e: any) => e.event === 'IncreaseLiquidity') // 或者从 logs 解析 tokenId
        // 为简单起见，你可以直接读 positionManager 的 tokenOfOwnerByIndex
        const balance = await nft.balanceOf(lpWallet.address)
        const tokenId = await nft.tokenOfOwnerByIndex(lpWallet.address, balance.sub(1))

        // LP 把 NFT safeTransfer 到 staker（proxy 地址），触发 onERC721Received + 自动记录 deposit
        await nft
            .connect(lpWallet)
        ['safeTransferFrom(address,address,uint256)'](lpWallet.address, staker.address, tokenId)

        const deposit = await staker.deposits(tokenId)
        expect(deposit.owner).to.eq(lpWallet.address)

        // 在 incentive 生效时间之后，可以 stakeToken
        await waffle.provider.send('evm_setNextBlockTimestamp', [startTime + 1])
        await waffle.provider.send('evm_mine', [])

        await expect(staker.connect(lpWallet).stakeToken(key, tokenId)).to.emit(staker, 'TokenStaked')

        // 到结束之后，un-stake + withdraw 走通
        await waffle.provider.send('evm_setNextBlockTimestamp', [endTime + 1])
        await waffle.provider.send('evm_mine', [])

        await expect(staker.connect(lpWallet).unstakeToken(key, tokenId)).to.emit(staker, 'TokenUnstaked')

        await expect(
            staker.connect(lpWallet).withdrawToken(tokenId, lpWallet.address, '0x')
        ).to.emit(staker, 'DepositTransferred')
    })
})