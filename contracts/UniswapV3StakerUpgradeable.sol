// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IUniswapV3Staker.sol';
import './libraries/IncentiveId.sol';
import './libraries/RewardMath.sol';
import './libraries/NFTPositionInfo.sol';
import './libraries/TransferHelperExtended.sol';
import './libraries/Tick.sol';
import './libraries/utils.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';


import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';
import '@uniswap/v3-periphery/contracts/libraries/PositionKey.sol';

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
    using EnumerableSet for EnumerableSet.UintSet;


    /// @notice Event emitted when a reward token has been claimed
    /// @param to The address where claimed rewards were sent to
    /// @param pool The Uniswap V3 pool
    /// @param rewardToken The rewardToken
    /// @param reward The amount of reward tokens claimed
    event RewardByIncentiveIdClaimed(address indexed to,IUniswapV3Pool indexed pool,address indexed rewardToken, uint256 reward);

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
    /// Deprecated. leave it because of contract upgrade.replace by userTokenIds
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

    /// @dev userTokenIds[owner] => UintSet
    mapping(address => EnumerableSet.UintSet) private userTokenIds;

    /// @dev tokenIdIncentiveIds[tokenId] => Bytes32Set(IncentiveIds)
    mapping(uint => EnumerableSet.Bytes32Set) private tokenIdIncentiveIds;

    /// @dev userRewardTokens[address] => Bytes32Set(rewardToken)
    mapping(address => EnumerableSet.Bytes32Set) private userRewardTokens;

    // Reserve storage gap for future variable additions (to preserve storage layout for upgrades)
    // since there is no requirement for future contract inherit this contract ,so comment __stakeGap
    //uint256[50] private __stakerGap;

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

        require(!userTokenIds[from].contains(tokenId),'tokenId is already in userTokenIds');
        userTokenIds[from].add(tokenId);

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

        require(userTokenIds[owner].contains(tokenId),'tokenId is not in userTokenIds of from address');
        require(!userTokenIds[to].contains(tokenId),'tokenId is already in userTokenIds of to address');
        userTokenIds[owner].remove(tokenId);
        userTokenIds[to].add(tokenId);

        updateRewardTokenForRemoveTokenId(tokenId,owner);
        updateRewardTokenForAddTokenId(tokenId,to);

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

        require(userTokenIds[msg.sender].contains(tokenId),'tokenId is not in userTokenIds when withdrawToken');
        userTokenIds[msg.sender].remove(tokenId);

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
        tokenIdIncentiveIds[tokenId].remove(incentiveId);

        if( canDeleteRewardToken(address(key.rewardToken),msg.sender)){
            userRewardTokens[msg.sender].remove(utils.addressToBytes32(address(key.rewardToken)));
        }

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

    /// @dev
    /// 1. used for unstakeToken, unstakeToken one incentive key, may be there is another incentive key related the reward token.
    /// before call canDeleteRewardToken in unstakeToken funtcion, tokenIdIncentiveIds has remove the incentiveKey of the tokenId
    /// so no need to filter the original incentiveKey.
    /// 2. used for transfer tokenId to others, so check if other tokenIds are related rewardToken or not.
    /// before call canDeleteRewardToken in function transferDeposit, userTokenIds has deleted the tokenId
    /// so no need to filter the tokenId in transfer
    function canDeleteRewardToken(
        address rewardToken,
        address user
    ) internal view returns (bool canDelete) {
        canDelete = true;
        uint256 count = 0;
        uint256 len = userTokenIds[user].length();
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = userTokenIds[user].at(i);
            IncentiveKey[] memory keys = getIncentiveKeysByTokenId(tokenId);
            for (uint256 j = 0; j < keys.length; j++) {
                IncentiveKey memory key = keys[j];
                if (address(key.rewardToken) == rewardToken) {
                    count ++;
                    if (count > 1) {
                        canDelete = false;
                        break;
                    }
                }
            }
            if (!canDelete) {
                break;
            }
        }
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

        tokenIdIncentiveIds[tokenId].add(incentiveId);
        bytes32 rewardTokenBytes32 = utils.addressToBytes32(address(key.rewardToken));
        if (!userRewardTokens[deposits[tokenId].owner].contains(rewardTokenBytes32)){
            userRewardTokens[deposits[tokenId].owner].add(rewardTokenBytes32);
        }

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

    /// @dev get tokenIds (include staked and unstaked) by address
    function getTokenIdsByAddress(address from)
    public
    view
    returns (uint256[] memory tokenIds)
    {
        uint256 length = userTokenIds[from].length();
        tokenIds = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            tokenIds[i] = userTokenIds[from].at(i);
        }
    }

    /// @dev get staked tokenIds owned by from address
    function getStakedTokenIdsByAddress(address from)
    public
    view
    returns (uint256[] memory tokenIds)
    {
        uint256[] memory tokenIdsAll = getTokenIdsByAddress(from);
        uint256 len = tokenIdsAll.length;
        uint256 count = 0;
        uint256[] memory tokenIdsTemp = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            if (isTokenStaked(tokenIdsAll[i])) {
                tokenIdsTemp[count] = tokenIdsAll[i];
                count++;
            }
        }
        tokenIds = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = tokenIdsTemp[i];
        }
    }

    /// @dev check token staked or not
    function isTokenStaked(uint256 tokenId)
    public
    view
    returns (bool staked)
    {
        staked = false;
        uint256 len = incentiveIds.length();
        for(uint256 i=0 ; i<len; i++){
            if(_stakes[tokenId][incentiveIds.at(i)].liquidityNoOverflow != 0){
                staked = true;
                break;
            }
        }
    }

    /// @dev get reward by rewardToken
    /// @param rewardToken rewardToken of incentive
    /// @param owner users address
    /// @param reward the reward of rewardToken owned by owner address.
    function getRewardByRewardToken(address rewardToken, address owner)
    public
    view
    returns (uint256 reward)
    {
        return rewards[IERC20Minimal(rewardToken)][owner];
    }

    /// @dev get all rewardTokens by TokenId
    function getRewardTokensByTokenId(uint256 tokenId)
    public
    view
    returns (address[] memory rewardTokens)
    {
        IncentiveKey[] memory keys = getIncentiveKeysByTokenId(tokenId);
        address[] memory tempRewardToken = new address[](keys.length);
        uint256 tempCount = 0;
        for (uint256 j = 0; j < keys.length; j++) {
            // check duplicated
            bool exists = false;
            for (uint256 k = 0; k < tempCount; k++) {
                if (tempRewardToken[k] == address(keys[j].rewardToken)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                tempRewardToken[tempCount] = address(keys[j].rewardToken);
                tempCount++;
            }
        }

        rewardTokens = new address[](tempCount);
        for (uint256 i = 0; i < tempCount; i++) {
            rewardTokens[i] = tempRewardToken[i];
        }
    }

    /// @dev update the rewardTokens of user, when transfer tokenId to other address.
    function updateRewardTokenForRemoveTokenId(uint256 tokenId, address user) internal {
        address[] memory rewardTokens =  getRewardTokensByTokenId(tokenId);
        for( uint256 i = 0; i< rewardTokens.length; i++){
            address rewardToken = rewardTokens[i];
            if(canDeleteRewardToken(rewardToken,user)){
                bytes32 rewardTokenBytes32 = utils.addressToBytes32(rewardToken);
                userRewardTokens[user].remove(rewardTokenBytes32);
            }
        }
    }

    /// @dev update the rewardTokens of user, when receive tokenId from other user
    function updateRewardTokenForAddTokenId(uint256 tokenId, address user) internal {
        address[] memory rewardTokens =  getRewardTokensByTokenId(tokenId);
        for( uint256 i = 0; i< rewardTokens.length; i++){
            address rewardToken = address(rewardTokens[i]);
            bytes32 rewardTokenBytes32 = utils.addressToBytes32(rewardToken);
            if(!userRewardTokens[user].contains(rewardTokenBytes32)){
                userRewardTokens[user].add(rewardTokenBytes32);
            }
        }
    }

    /// @dev get incentiveKeys of specific tokenId
    function getIncentiveKeysByTokenId(uint256 tokenId)
    public
    view
    returns (IncentiveKey[] memory keys)
    {
        uint256 length = tokenIdIncentiveIds[tokenId].length();

        keys = new IncentiveKey[](length);
        for (uint256 i = 0; i < length; i++) {
            bytes32 incentiveId = tokenIdIncentiveIds[tokenId].at(i);
            keys[i] = incentiveKeys[incentiveId];
        }
    }

    /// @dev get all the reward tokens of from address
    function getRewardTokensByAddress(address from)
    public
    view
    returns (address[] memory rewardTokens)
    {
        uint256 len = userRewardTokens[from].length();
        rewardTokens = new address[](len);
        for( uint256 i = 0; i<len; i++){
            bytes32   rewardTokenBytes32 = userRewardTokens[from].at(i);
            rewardTokens[i] = utils.bytes32ToAddress(rewardTokenBytes32);
        }
    }

    /// @notice cost much gas, need to increase gas limit when invoke this function.
    /// @dev claim All Reward of msg.sender, includes all token of all incentives staked by msg.sender.
    function claimAllReward(address to)
    external {
        updateAllReward(msg.sender);
        address[] memory rewardTokens = getRewardTokensByAddress(msg.sender);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            claimReward(IERC20Minimal(rewardTokens[i]), to, 0); // claim all reward of one token.
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
        uint256[] memory tokenIds = getStakedTokenIdsByAddress(from);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            IncentiveKey[] memory keys = getIncentiveKeysByTokenId(tokenId);
            for (uint256 j = 0; j < keys.length; j++) {
                updateReward(keys[j], tokenId);
            }
        }
    }

    /// @dev claim reward of specific tokenId and  specific incentive key.
    /// @notice Transfers `amountRequested` of accrued `rewardToken` rewards from the contract to the recipient `to` by incentive key
    /// @param key The key of the incentive
    /// @param tokenId The ID of the token
    /// @param to The address where claimed rewards will be sent to
    /// @param amountRequested The amount of reward tokens to claim. Claims entire reward amount if set to 0.
    /// @return reward The amount of reward tokens claimed
    function claimRewardByIncentiveKey(
        IncentiveKey memory key,
        uint256 tokenId,
        address to,
        uint256 amountRequested
    )
    external
    returns (uint256 reward) {

        address owner = deposits[tokenId].owner;
        require(owner == msg.sender, "UniswapV3Staker::claimRewardByIncentiveKey: only deposit owner can claim");

        updateReward(key, tokenId);

        reward = rewards[key.rewardToken][owner];

        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[key.rewardToken][owner] -= reward;
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

    struct GrowthInsideParameters {
        IUniswapV3Pool pool; int24 tickLower;int24 tickUpper; int24 tickCurrent;uint256 feeGrowthGlobal0X128;uint256 feeGrowthGlobal1X128;
    }
    function getLatestFeeGrowthInsideByTick(GrowthInsideParameters memory pars)
    view
    internal
    returns(uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128){

        (,,uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pars.pool.ticks(pars.tickLower);
        (,,uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pars.pool.ticks(pars.tickUpper);

        (feeGrowthInside0LastX128, feeGrowthInside1LastX128) = Tick.getFeeGrowthInside(
            lowerFeeGrowthOutside0X128,
            lowerFeeGrowthOutside1X128,
            upperFeeGrowthOutside0X128,
            upperFeeGrowthOutside1X128,
            pars.tickLower,
            pars.tickUpper,
            pars.tickCurrent,
            pars.feeGrowthGlobal0X128,
            pars.feeGrowthGlobal1X128
        );
    }

    /// @dev get swap fee by token id
    function getSwapFeeByTokenId(IUniswapV3Pool pool, uint256 tokenId)
    external
    view
    returns (uint128 swapFee0, uint128 swapFee1)
    {
        (,,,,,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128Old,
            uint256 feeGrowthInside1LastX128Old,
            uint128 tokensOwed0,
            uint128 tokensOwed1) = INonfungiblePositionManager(nonfungiblePositionManager).positions(tokenId);
        if (liquidity > 0) {

            (,int24 tickCurrent,,,,,) = pool.slot0();
            GrowthInsideParameters memory para = GrowthInsideParameters({
                pool: pool,
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: tickCurrent,
                feeGrowthGlobal0X128: pool.feeGrowthGlobal0X128(),
                feeGrowthGlobal1X128: pool.feeGrowthGlobal1X128()
            });

            (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = getLatestFeeGrowthInsideByTick(para);


            tokensOwed0 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - feeGrowthInside0LastX128Old,
                    liquidity,
                    FixedPoint128.Q128
                )
            );
            tokensOwed1 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - feeGrowthInside1LastX128Old,
                    liquidity,
                    FixedPoint128.Q128
                )
            );
        }

        swapFee0 = tokensOwed0;
        swapFee1 = tokensOwed1;

    }

    /// @dev check tokenId range is out of current tick or not
    function checkRangeStatusByTokenId(uint256 tokenId)
    external
    view
    returns (bool inRange,int24 tickLowerRet, int24 tickUpperRet, int24 currentTick, address pool)
    {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            ,
            ,
            ,
            ,

        ) = INonfungiblePositionManager(nonfungiblePositionManager).positions(tokenId);
        tickLowerRet = tickLower;
        tickUpperRet = tickUpper;

        pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        (,currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        inRange = (tickLower <= currentTick && currentTick < tickUpper);
    }

    /// @dev filter incentive keys of staked by tokenId
    function getCanStakeIncentiveKeysByTokenId(uint256 tokenId)
    external
    view
    returns (IncentiveKey[] memory keys)
    {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = INonfungiblePositionManager(nonfungiblePositionManager).positions(tokenId);
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        uint256 len = incentiveIds.length();
        IncentiveKey[] memory tempKeys = new IncentiveKey[](len);
        uint256 tempCount = 0;

        for(uint256 i = 0; i< len; i++){
            bytes32 incentiveId = incentiveIds.at(i);
            IncentiveKey memory key = incentiveKeys[incentiveId];
            if( address(key.pool) == pool && (!tokenIdIncentiveIds[tokenId].contains(incentiveId))){
                tempKeys[tempCount] = key;
                tempCount++;
            }
        }

        keys = new IncentiveKey[](tempCount);
        for(uint256 i =0; i< tempCount; i++){
            keys[i] = tempKeys[i];
        }
    }
}