// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IUniswapV3Staker.sol';
import './libraries/IncentiveId.sol';
import './libraries/RewardMath.sol';
import './libraries/NFTPositionInfo.sol';
import './libraries/TransferHelperExtended.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';


import "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/ProxyAdmin.sol";


import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@openzeppelin/contracts/utils/EnumerableMap.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

/// @title Uniswap V3 canonical staking interface (upgradeable)
contract UniswapV3StakerUpgradeable is Initializable, IUniswapV3Staker, Multicall, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using EnumerableMap for EnumerableMap.UintToAddressMap;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Represents a staking incentive
    struct Incentive {
        uint256 totalRewardUnclaimed;
        uint160 totalSecondsClaimedX128;
        uint96 numberOfStakes;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint160 secondsPerLiquidityInsideInitialX128;
        uint96 liquidityNoOverflow;
        uint128 liquidityIfOverflow;
    }

    /// @inheritdoc IUniswapV3Staker
    IUniswapV3Factory public override factory;
    /// @inheritdoc IUniswapV3Staker
    INonfungiblePositionManager public override nonfungiblePositionManager;

    /// @inheritdoc IUniswapV3Staker
    uint256 public override maxIncentiveStartLeadTime;
    /// @inheritdoc IUniswapV3Staker
    uint256 public override maxIncentiveDuration;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev depsitsUintToAddress[tokenId] => address, used in getTokenIdsByAddress
    EnumerableMap.UintToAddressMap private depsitsUintToAddress;

    /// @dev incentiveKeys[incentiveId] => IncentiveKey
    mapping(bytes32 => IncentiveKey) public incentiveKeys;

    /// @dev incentiveIds,used to enumerable all the incentiveIds, and get all incentiveKeys from all incentiveIds.
    /// not use EnumerableSet of incentiveKeys, because 0.7.6 only support bytes32 key in enumerable set, not support object such as incentiveKey.
    EnumerableSet.Bytes32Set    private  incentiveIds;

    /// @dev stakes[tokenId][incentiveHash] => Stake
    mapping(uint256 => mapping(bytes32 => Stake)) private _stakes;

    /// @dev rewards[rewardToken][owner] => uint256
    /// @inheritdoc IUniswapV3Staker
    mapping(IERC20Minimal => mapping(address => uint256)) public override rewards;

    // Reserve storage gap for future variable additions (to preserve storage layout for upgrades)
    uint256[50] private __stakerGap;

    /// @inheritdoc IUniswapV3Staker
    function stakes(uint256 tokenId, bytes32 incentiveId)
    public
    view
    override
    returns (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity)
    {
        Stake storage stake = _stakes[tokenId][incentiveId];
        secondsPerLiquidityInsideInitialX128 = stake.secondsPerLiquidityInsideInitialX128;
        liquidity = stake.liquidityNoOverflow;
        if (liquidity == type(uint96).max) {
            liquidity = stake.liquidityIfOverflow;
        }
    }



    // -------------------------
    // INITIALIZER (replaces constructor)
    // -------------------------
    /// @param _factory the Uniswap V3 factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentiveDuration the max amount of seconds into the future the incentive startTime can be set
    /// @param _owner is used to extension for future features.
    function initialize(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration,
        address _owner
    ) public initializer {

        __ReentrancyGuard_init();
        __Ownable_init();

        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentiveDuration = _maxIncentiveDuration;

        // transfer ownership to desired owner (deploy script / proxy admin will pass _owner)
        if (_owner != address(0)) {
            transferOwnership(_owner);
        }
    }

    /// @inheritdoc IUniswapV3Staker
    function createIncentive(IncentiveKey memory key, uint256 reward) external override {
        require(reward > 0, 'UniswapV3Staker::createIncentive: reward must be positive');
        require(
            block.timestamp <= key.startTime,
            'UniswapV3Staker::createIncentive: start time must be now or in the future'
        );
        require(
            key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
            'UniswapV3Staker::createIncentive: start time too far into future'
        );
        require(key.startTime < key.endTime, 'UniswapV3Staker::createIncentive: start time must be before end time');
        require(
            key.endTime - key.startTime <= maxIncentiveDuration,
            'UniswapV3Staker::createIncentive: incentive duration is too long'
        );

        bytes32 incentiveId = IncentiveId.compute(key);

        incentives[incentiveId].totalRewardUnclaimed += reward;

        incentiveKeys[incentiveId] = key;

        incentiveIds.add(incentiveId);

        TransferHelperExtended.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward);

        emit IncentiveCreated(key.rewardToken, key.pool, key.startTime, key.endTime, key.refundee, reward);
    }

    /// @inheritdoc IUniswapV3Staker
    function endIncentive(IncentiveKey memory key) external override returns (uint256 refund) {
        require(block.timestamp >= key.endTime, 'UniswapV3Staker::endIncentive: cannot end incentive before end time');

        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        refund = incentive.totalRewardUnclaimed;

        require(refund > 0, 'UniswapV3Staker::endIncentive: no refund available');
        require(
            incentive.numberOfStakes == 0,
            'UniswapV3Staker::endIncentive: cannot end incentive while deposits are staked'
        );

        // issue the refund
        incentive.totalRewardUnclaimed = 0;
        TransferHelperExtended.safeTransfer(address(key.rewardToken), key.refundee, refund);

        // note we never clear totalSecondsClaimedX128

        delete incentiveKeys[incentiveId];
        incentiveIds.remove(incentiveId);

        emit IncentiveEnded(incentiveId, refund);
    }

    /// @notice Upon receiving a Uniswap V3 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(
            msg.sender == address(nonfungiblePositionManager),
            'UniswapV3Staker::onERC721Received: not a univ3 nft'
        );

        depsitsUintToAddress.set(tokenId,from);

        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager.positions(tokenId);

        deposits[tokenId] = Deposit({owner: from, numberOfStakes: 0, tickLower: tickLower, tickUpper: tickUpper});
        emit DepositTransferred(tokenId, address(0), from);

        if (data.length > 0) {
            if (data.length == 160) {
                _stakeToken(abi.decode(data, (IncentiveKey)), tokenId);
            } else {
                IncentiveKey[] memory keys = abi.decode(data, (IncentiveKey[]));
                for (uint256 i = 0; i < keys.length; i++) {
                    _stakeToken(keys[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IUniswapV3Staker
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(0), 'UniswapV3Staker::transferDeposit: invalid transfer recipient');
        address owner = deposits[tokenId].owner;
        require(owner == msg.sender, 'UniswapV3Staker::transferDeposit: can only be called by deposit owner');
        deposits[tokenId].owner = to;
        depsitsUintToAddress.set(tokenId,to);
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IUniswapV3Staker
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external override {
        require(to != address(this), 'UniswapV3Staker::withdrawToken: cannot withdraw to staker');
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'UniswapV3Staker::withdrawToken: cannot withdraw token while staked');
        require(deposit.owner == msg.sender, 'UniswapV3Staker::withdrawToken: only owner can withdraw token');

        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        depsitsUintToAddress.remove(tokenId);

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    /// @inheritdoc IUniswapV3Staker
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        require(deposits[tokenId].owner == msg.sender, 'UniswapV3Staker::stakeToken: only owner can stake token');

        _stakeToken(key, tokenId);
    }


    /// @inheritdoc IUniswapV3Staker
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        Deposit memory deposit = deposits[tokenId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        if (block.timestamp < key.endTime) {
            require(
                deposit.owner == msg.sender,
                'UniswapV3Staker::unstakeToken: only owner can withdraw token before incentive end time'
            );
        }

        bytes32 incentiveId = IncentiveId.compute(key);

        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity) = stakes(tokenId, incentiveId);

        require(liquidity != 0, 'UniswapV3Staker::unstakeToken: stake does not exist');

        Incentive storage incentive = incentives[incentiveId];

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;

        (, uint160 secondsPerLiquidityInsideX128, ) =
            key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);
        (uint256 reward, uint160 secondsInsideX128) =
            RewardMath.computeRewardAmount(
                incentive.totalRewardUnclaimed,
                incentive.totalSecondsClaimedX128,
                key.startTime,
                key.endTime,
                liquidity,
                secondsPerLiquidityInsideInitialX128,
                secondsPerLiquidityInsideX128,
                block.timestamp
            );

        // if this overflows, e.g. after 2^32-1 full liquidity seconds have been claimed,
        // reward rate will fall drastically so it's safe
        incentive.totalSecondsClaimedX128 += secondsInsideX128;
        // reward is never greater than total reward unclaimed
        incentive.totalRewardUnclaimed -= reward;
        // this only overflows if a token has a total supply greater than type(uint256).max
        rewards[key.rewardToken][deposit.owner] += reward;

        Stake storage stake = _stakes[tokenId][incentiveId];
        delete stake.secondsPerLiquidityInsideInitialX128;
        delete stake.liquidityNoOverflow;
        if (liquidity >= type(uint96).max) delete stake.liquidityIfOverflow;
        emit TokenUnstaked(tokenId, incentiveId);
    }

    /// @inheritdoc IUniswapV3Staker
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) public override returns (uint256 reward) {
        reward = rewards[rewardToken][msg.sender];
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[rewardToken][msg.sender] -= reward;
        TransferHelperExtended.safeTransfer(address(rewardToken), to, reward);

        emit RewardClaimed(to, reward);
    }

    /// @inheritdoc IUniswapV3Staker
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId)
        external
        view
        override
        returns (uint256 reward, uint160 secondsInsideX128)
    {
        bytes32 incentiveId = IncentiveId.compute(key);

        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity) = stakes(tokenId, incentiveId);
        require(liquidity > 0, 'UniswapV3Staker::getRewardInfo: stake does not exist');

        Deposit memory deposit = deposits[tokenId];
        Incentive memory incentive = incentives[incentiveId];

        (, uint160 secondsPerLiquidityInsideX128, ) =
            key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);

        (reward, secondsInsideX128) = RewardMath.computeRewardAmount(
            incentive.totalRewardUnclaimed,
            incentive.totalSecondsClaimedX128,
            key.startTime,
            key.endTime,
            liquidity,
            secondsPerLiquidityInsideInitialX128,
            secondsPerLiquidityInsideX128,
            block.timestamp
        );
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId) private {
        require(block.timestamp >= key.startTime, 'UniswapV3Staker::stakeToken: incentive not started');
        require(block.timestamp < key.endTime, 'UniswapV3Staker::stakeToken: incentive ended');

        bytes32 incentiveId = IncentiveId.compute(key);

        require(
            incentives[incentiveId].totalRewardUnclaimed > 0,
            'UniswapV3Staker::stakeToken: non-existent incentive'
        );
        require(
            _stakes[tokenId][incentiveId].liquidityNoOverflow == 0,
            'UniswapV3Staker::stakeToken: token already staked'
        );

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            NFTPositionInfo.getPositionInfo(factory, nonfungiblePositionManager, tokenId);

        require(pool == key.pool, 'UniswapV3Staker::stakeToken: token pool is not the incentive pool');
        require(liquidity > 0, 'UniswapV3Staker::stakeToken: cannot stake token with 0 liquidity');

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(tickLower, tickUpper);

        if (liquidity >= type(uint96).max) {
            _stakes[tokenId][incentiveId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: type(uint96).max,
                liquidityIfOverflow: liquidity
            });
        } else {
            Stake storage stake = _stakes[tokenId][incentiveId];
            stake.secondsPerLiquidityInsideInitialX128 = secondsPerLiquidityInsideX128;
            stake.liquidityNoOverflow = uint96(liquidity);
        }

        emit TokenStaked(tokenId, incentiveId, liquidity);
    }

    /// @notice Collects up to a maximum amount of fees owed to a specific position to the recipient
    /// collect swap fee in uniswap pool.
    function collect(INonfungiblePositionManager.CollectParams memory params) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        address owner = deposits[params.tokenId].owner;
        require(owner == msg.sender, 'UniswapV3Staker::collect: can only be called by deposit owner');
        if (params.recipient == address(0)) params.recipient = owner;
        (amount0, amount1) = nonfungiblePositionManager.collect(params);
    }

    function getTokenIdsByAddress(address from)
    public
    view
    returns (uint256[] memory tokenIds)
    {
        uint256 length = depsitsUintToAddress.length();
        uint256 count = 0;

        for (uint256 i = 0; i < length; i++) {
            (, address addr) = depsitsUintToAddress.at(i);
            if (addr == from) {
                count++;
            }
        }

        tokenIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < length; i++) {
            (uint256 tokenId, address addr) = depsitsUintToAddress.at(i);
            if (addr == from) {
                tokenIds[index] = tokenId;
                index++;
            }
        }
    }

    function getRewardByRewardToken(address rewardToken, address owner)
    public
    view
    returns (uint256 reward)
    {
        return rewards[IERC20Minimal(rewardToken)][owner];
    }

    function getIncentiveKeysByTokenId(uint256 tokenId)
    public
    view
    returns (IncentiveKey[] memory keys)
    {
        uint256 length = incentiveIds.length();
        uint256 count = 0;

        for (uint256 i = 0; i < length; i++) {
            bytes32 incentiveId = incentiveIds.at(i);
            if (_stakes[tokenId][incentiveId].liquidityNoOverflow != 0) {
                count++;
            }
        }

        keys = new IncentiveKey[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < length; i++) {
            bytes32 incentiveId = incentiveIds.at(i);
            if (_stakes[tokenId][incentiveId].liquidityNoOverflow != 0) {
                keys[index] = incentiveKeys[incentiveId];
                index++;
            }
        }
    }

    /// @dev get all the reward tokens of from address
    function getRewardTokensByAddress(address from)
    public
    view
    returns (address[] memory rewardTokens)
    {
        uint256[] memory tokenIds = getTokenIdsByAddress(from);
        bytes32[] memory tempIncentiveIds = new bytes32[](incentiveIds.length());
        uint256 tempCount = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            IncentiveKey[] memory keys = getIncentiveKeysByTokenId(tokenIds[i]);
            for (uint256 j = 0; j < keys.length; j++) {
                bytes32 incentiveId = IncentiveId.compute(keys[j]);
                // check duplicated
                bool exists = false;
                for (uint256 k = 0; k < tempCount; k++) {
                    if (tempIncentiveIds[k] == incentiveId) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    tempIncentiveIds[tempCount] = incentiveId;
                    tempCount++;
                }
            }
        }

        rewardTokens = new address[](tempCount);
        for (uint256 i = 0; i < tempCount; i++) {
            IncentiveKey memory key = incentiveKeys[tempIncentiveIds[i]];
            rewardTokens[i] = address(key.rewardToken);
        }
    }

    /// @dev claim All Reward of msg.sender, includes all token of all incentives staked by msg.sender.
    function claimAllReward(address to)
    external {
        updateAllReward(msg.sender);
        address[] memory rewardTokens = getRewardTokensByAddress(msg.sender);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 amountRequested = getRewardByRewardToken(rewardTokens[i], msg.sender);
            claimReward(IERC20Minimal(rewardTokens[i]), to, amountRequested);
        }
    }
    
    /// @dev before claim reward by incentiveKey, it should invoke this function to update the reaward of the incentive key of the specific tokenId owner.
    function updateReward(
        IncentiveKey memory key,
        uint256 tokenId
    )
    internal {
        Deposit memory deposit = deposits[tokenId];
        bytes32 incentiveId = IncentiveId.compute(key);
        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity) = stakes(tokenId, incentiveId);
        require(liquidity != 0, 'UniswapV3Staker::claimRewardByIncentiveKey: stake does not exist');

        Incentive storage incentive = incentives[incentiveId];
        (, uint160 secondsPerLiquidityInsideX128,) =
                                key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);

        (uint256 reward, uint160 secondsInsideX128) =
            RewardMath.computeRewardAmount(
                incentive.totalRewardUnclaimed,
                incentive.totalSecondsClaimedX128,
                key.startTime,
                key.endTime,
                liquidity,
                secondsPerLiquidityInsideInitialX128,
                secondsPerLiquidityInsideX128,
                block.timestamp
            );

        incentive.totalSecondsClaimedX128 += secondsInsideX128;
        incentive.totalRewardUnclaimed -= reward;
        rewards[key.rewardToken][deposit.owner] += reward;
    }

    /// @dev update all reward owned by from address.
    function updateAllReward(address from)
    internal {
        uint256[] memory tokenIds = getTokenIdsByAddress(from);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            IncentiveKey[] memory keys = getIncentiveKeysByTokenId(tokenId);
            for (uint256 j = 0; j < keys.length; j++) {
                updateReward(keys[j], tokenId);
            }
        }
    }

    /// @dev claim reward of specific tokenId and  specific incentive key.
    function claimRewardByIncentiveKey(
        IncentiveKey memory key,
        uint256 tokenId,
        address to,
        uint256 amountRequested
    )
    external
    override
    returns (uint256 reward) {

        updateReward(key, tokenId);

        reward = rewards[key.rewardToken][msg.sender];//todo should be the owner of the tokenId, not the sender.
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[key.rewardToken][msg.sender] -= reward;
        TransferHelperExtended.safeTransfer(address(key.rewardToken), to, reward);

        emit RewardByIncentiveIdClaimed(to, key.pool, address(key.rewardToken), reward);
    }

    /// @dev from incentive key to incentive Id.
    function getIncentiveIdByIncentiveKey(IncentiveKey memory key)
    external
    pure
    returns (bytes32 incentiveId)
    {
        return IncentiveId.compute(key);
    }
}
