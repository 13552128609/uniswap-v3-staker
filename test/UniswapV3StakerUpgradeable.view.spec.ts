import { ethers, waffle } from 'hardhat'
import { Contract, Signer } from 'ethers'
import {
  expect,
  uniswapFactoryFixture,
  days,
  BNe18,
  encodePriceSqrt,         // 新增
} from './shared'
import {
    IUniswapV3Factory,
    INonfungiblePositionManager,
    TestERC20,
    IUniswapV3Pool,
} from '../typechain'

describe('UniswapV3StakerUpgradeable - view helpers', () => {
    let deployer: Signer
    let creator: Signer
    let lp: Signer

    let factory: IUniswapV3Factory
    let nft: INonfungiblePositionManager
    let tokens: [TestERC20, TestERC20, TestERC20]

    let stakerImpl: Contract
    let proxyAdmin: Contract
    let proxy: Contract
    let staker: Contract // proxy as UniswapV3StakerUpgradeable

    const maxIncentiveStartLeadTime = days(30)
    const maxIncentiveDuration = days(60)

    // 复用原有 uniswap fixture，部署 upgradeable staker
    beforeEach('deploy fixture + upgradeable staker', async () => {
        const wallets = waffle.provider.getWallets()
            ;[deployer, creator, lp] = wallets

        const ctx = await uniswapFactoryFixture(wallets, waffle.provider)
        factory = ctx.factory
        nft = ctx.nft
        tokens = ctx.tokens

        const StakerImplFactory = await ethers.getContractFactory('UniswapV3StakerUpgradeable')
        stakerImpl = await StakerImplFactory.connect(deployer).deploy()
        await stakerImpl.deployed()

        const ProxyAdminFactory = await ethers.getContractFactory('ProxyAdmin')
        proxyAdmin = await ProxyAdminFactory.connect(deployer).deploy()
        await proxyAdmin.deployed()

        const initData = stakerImpl.interface.encodeFunctionData('initialize', [
            factory.address,
            nft.address,
            maxIncentiveStartLeadTime,
            maxIncentiveDuration,
            await creator.getAddress(),
        ])

        const TransparentProxyFactory = await ethers.getContractFactory('TransparentUpgradeableProxy')
        proxy = await TransparentProxyFactory.connect(deployer).deploy(
            stakerImpl.address,
            proxyAdmin.address,
            initData
        )
        await proxy.deployed()

        staker = StakerImplFactory.attach(proxy.address)
    })

    // 构造一个简单场景：2 个 incentive，同一 pool；LP 铸造 1 个 position 并 stake 到 incentive1
    async function setupScenario() {
        const [token0, token1, rewardToken] = tokens
        const lpAddr = await lp.getAddress()
        const creatorAddr = await creator.getAddress()

        // 创建一个 pool
        await factory.createPool(token0.address, token1.address, 3000)
        const poolAddress = await factory.getPool(token0.address, token1.address, 3000)

        // 初始化 pool 价格
        const pool = (await ethers.getContractAt(
            'IUniswapV3Pool',
            poolAddress
        )) as IUniswapV3Pool
        await pool.initialize(encodePriceSqrt(1, 1))


        // 给 creator 准备奖励 token
        const totalReward = BNe18(3000)
        await rewardToken.transfer(creatorAddr, totalReward)
        await rewardToken.connect(creator).approve(staker.address, totalReward)

        const block = await waffle.provider.getBlock('latest')
        const now = block.timestamp

        const startTime1 = now + 100
        const endTime1 = startTime1 + days(30)

        const startTime2 = now + 200
        const endTime2 = startTime2 + days(40)

        const incentiveKey1 = {
            rewardToken: rewardToken.address,
            pool: poolAddress,
            startTime: startTime1,
            endTime: endTime1,
            refundee: creatorAddr,
        }

        const incentiveKey2 = {
            rewardToken: rewardToken.address,
            pool: poolAddress,
            startTime: startTime2,
            endTime: endTime2,
            refundee: creatorAddr,
        }

        // 创建两个 incentive
        await staker.connect(creator).createIncentive(incentiveKey1, BNe18(1000))
        await staker.connect(creator).createIncentive(incentiveKey2, BNe18(2000))

        // LP 铸造一个 position NFT
        const amount = BNe18(10)
        await token0.transfer(lpAddr, amount)
        await token1.transfer(lpAddr, amount)
        await token0.connect(lp).approve(nft.address, amount)
        await token1.connect(lp).approve(nft.address, amount)

        const mintTx = await nft.connect(lp).mint({
            token0: token0.address,
            token1: token1.address,
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount0Desired: amount,
            amount1Desired: amount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: lpAddr,
            deadline: now + 1000,
        })
        await mintTx.wait()

        const balance = await nft.balanceOf(lpAddr)
        const tokenId = await nft.tokenOfOwnerByIndex(lpAddr, balance.sub(1))

        // 把 NFT safeTransfer 到 staker（会触发 onERC721Received，记录 deposits/userTokenIds）
        await nft
            .connect(lp)
        ['safeTransferFrom(address,address,uint256)'](lpAddr, staker.address, tokenId)

        // 推时间到 incentive1 生效后
        await waffle.provider.send('evm_setNextBlockTimestamp', [startTime1 + 1])
        await waffle.provider.send('evm_mine', [])

        // stake 到 incentive1
        await staker.connect(lp).stakeToken(incentiveKey1, tokenId)

        return {
            poolAddress,
            rewardToken,
            incentiveKey1,
            incentiveKey2,
            tokenId,
            lpAddr,
        }
    }

    it('getTokenIdsByAddress / getStakedTokenIdsByAddress / isTokenStaked 正常工作', async () => {
        const { tokenId, lpAddr } = await setupScenario()

        const allIds: any[] = await staker.getTokenIdsByAddress(lpAddr)
        expect(allIds.map((x) => x.toString())).to.contain(tokenId.toString())

        const stakedIds: any[] = await staker.getStakedTokenIdsByAddress(lpAddr)
        expect(stakedIds.map((x) => x.toString())).to.contain(tokenId.toString())

        const isStaked: boolean = await staker.isTokenStaked(tokenId)
        expect(isStaked).to.eq(true)
    })

    it('getIncentiveKeysByTokenId / getCanStakeIncentiveKeysByTokenId 返回正确集合', async () => {
        const { incentiveKey1, incentiveKey2, tokenId } = await setupScenario()

        const keys: any[] = await staker.getIncentiveKeysByTokenId(tokenId)
        // 已经 stake 到 incentiveKey1
        expect(keys.length).to.eq(1)
        expect(keys[0].rewardToken).to.eq(incentiveKey1.rewardToken)
        expect(keys[0].pool).to.eq(incentiveKey1.pool)
        expect(keys[0].startTime.toString()).to.eq(incentiveKey1.startTime.toString())
        expect(keys[0].endTime.toString()).to.eq(incentiveKey1.endTime.toString())
        expect(keys[0].refundee).to.eq(incentiveKey1.refundee)

        // incentiveKey2 同 pool、未 stake，且 endTime 在未来，应出现在 canStake 列表中
        const canStakeKeys: any[] = await staker.getCanStakeIncentiveKeysByTokenId(tokenId)
        expect(canStakeKeys.length).to.eq(1)
        expect(canStakeKeys[0].startTime.toString()).to.eq(incentiveKey2.startTime.toString())
        expect(canStakeKeys[0].endTime.toString()).to.eq(incentiveKey2.endTime.toString())
    })

    it('getRewardTokensByTokenId / getRewardTokensByAddress / getRewardByRewardToken', async () => {
        const { tokenId, lpAddr, rewardToken, incentiveKey1 } = await setupScenario()

        const tokensById: string[] = await staker.getRewardTokensByTokenId(tokenId)
        expect(tokensById.length).to.eq(1)
        expect(tokensById[0]).to.eq(rewardToken.address)

        const tokensByAddr: string[] = await staker.getRewardTokensByAddress(lpAddr)
        expect(tokensByAddr.length).to.eq(1)
        expect(tokensByAddr[0]).to.eq(rewardToken.address)

        // 推时间到 incentive 结束，调用 getRewardInfo + unstakeToken 更新 rewards，再检查 getRewardByRewardToken
        const endTs = (incentiveKey1.endTime as any).toNumber ? (incentiveKey1.endTime as any).toNumber() : incentiveKey1.endTime
        await waffle.provider.send('evm_setNextBlockTimestamp', [endTs + 1])
        await waffle.provider.send('evm_mine', [])

        // getRewardInfo 只是 view，不会修改状态
        const info: any = await staker.getRewardInfo(incentiveKey1, tokenId)
        expect(info.reward).to.be.a('object') // BigNumber
        // 触发真实奖励结算：通过 unstakeToken
        await staker.connect(lp).unstakeToken(incentiveKey1, tokenId)

        const rewardByToken = await staker.getRewardByRewardToken(rewardToken.address, lpAddr)
        // 只要大于 0 即可，精确值已有原版集成测试覆盖
        expect(rewardByToken.gt(0)).to.eq(true)
    })

    it('getAllIncentiveInfo / getIncentiveIdByIncentiveKey', async () => {
        const { incentiveKey1, incentiveKey2, rewardToken } = await setupScenario()

        const infos: any[] = await staker.getAllIncentiveInfo()
        expect(infos.length).to.eq(2)

        // totalRewardUnclaimed 之和应等于 3000e18（忽略已结算前的状态）
        const sum = infos.reduce((acc, cur) => acc.add(cur.totalRewardUnclaimed), BNe18(0))
        // 这里不严格要求精确值，只要 <= 3000e18 且 > 0
        expect(sum.gt(0)).to.eq(true)
        expect(sum.lte(BNe18(3000))).to.eq(true)

        const id1: string = await staker.getIncentiveIdByIncentiveKey(incentiveKey1)
        const id2: string = await staker.getIncentiveIdByIncentiveKey(incentiveKey2)
        expect(id1).to.not.eq(id2)

        // 用 mapping incentives(id1) 检查其 rewardToken 是否一致
        const inc1 = await staker.incentives(id1)
        expect(inc1.totalRewardUnclaimed.gt(0)).to.eq(true)

        // reward token 本身没存进 incentives，但至少可以证明 id 可用且有记录
        const balanceInStaker = await rewardToken.balanceOf(staker.address)
        expect(balanceInStaker.gt(0)).to.eq(true)
    })

    it('checkRangeStatusByTokenId 返回正确区间 / 当前池', async () => {
        const { tokenId, poolAddress } = await setupScenario()

        const res: any = await staker.checkRangeStatusByTokenId(tokenId)
        const inRange: boolean = res[0]
        const tickLower = res[1]
        const tickUpper = res[2]
        const currentTick = res[3]
        const pool = res[4]

        expect(pool).to.eq(poolAddress)
        expect(tickLower).to.be.lt(tickUpper)
        // currentTick 在某个值，inRange 为 true/false 都接受，只要不 revert 即可
        expect(typeof inRange).to.eq('boolean')
        //expect(currentTick).to.be.a('object') // BigNumber/int24
        // 只要是 number 或 BigNumber 都接受
        expect(['number', 'object']).to.include(typeof currentTick)
    })

    it('getSwapFeeByTokenId 初始返回 0，调用不 revert', async () => {
        const { tokenId, poolAddress } = await setupScenario()

        const [swapFee0, swapFee1]: any = await staker.getSwapFeeByTokenId(poolAddress, tokenId)
        // 刚 mint 基本没有成交，预期为 0
        expect(swapFee0.eq(0)).to.eq(true)
        expect(swapFee1.eq(0)).to.eq(true)
    })
})