// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './interfaces/IERC20.sol';
import './interfaces/IRareBayV2Pair.sol';
import './interfaces/IRareBayV2Factory.sol';

interface IWCORE is IERC20 {
    function deposit() external payable;
    function withdraw(uint wad) external;
}

contract RareBayV2Router {
    address public immutable factory;
    address public immutable WCORE; // Wrapped CORE
    address public immutable USDT;
    address public immutable USDC;
    address public immutable WBTC;

    uint private _locked = 1;
    address[] private _activePairs;
    mapping(address => bool) private _isActivePair;

    modifier ensure(uint deadline) {
        require(block.timestamp <= deadline, 'Router: EXPIRED');
        _;
    }
    modifier lock() {
        require(_locked == 1, 'Router: LOCKED');
        _locked = 0;
        _;
        _locked = 1;
    }

    struct PoolInfo {
        address pair;
        address token0;
        address token1;
        uint reserve0;
        uint reserve1;
        uint256 upvotes;
        uint256 downvotes;
    }

    mapping(address => address[]) private _userWatchlists;
    mapping(address => mapping(address => uint256)) private _userWatchlistPairIndex;
    mapping(address => mapping(address => bool)) private _isPairWatchlisted;

    struct VoteStats {
        uint256 upvotes;
        uint256 downvotes;
    }
    mapping(address => VoteStats) public pairVotes;
    mapping(address => mapping(address => int8)) private _userVoteStatus;

    event PairWatchlisted(address indexed user, address indexed pair);
    event PairUnwatchlisted(address indexed user, address indexed pair);
    event PairUpvoted(address indexed user, address indexed pair, uint256 totalUpvotes);
    event PairDownvoted(address indexed user, address indexed pair, uint256 totalDownvotes);

    constructor(
        address _factory,
        address _WCORE,
        address _USDT,
        address _USDC,
        address _WBTC
    ) {
        factory = _factory;
        WCORE = _WCORE;
        USDT = _USDT;
        USDC = _USDC;
        WBTC = _WBTC;
    }

    receive() external payable {}
// --- Dividend Management ---

    /**
     * @notice A struct to hold a user's dividend information for a single pair.
     * @param pendingDividend0 The amount of token0 dividends waiting to be claimed.
     * @param pendingDividend1 The amount of token1 dividends waiting to be claimed.
     * @param lockTime The Unix timestamp until which the dividends are locked.
     */
    struct DividendInfo {
        uint256 pendingDividend0;
        uint256 pendingDividend1;
        uint256 lockTime;
    }

    /**
     * @notice Retrieves the pending dividend amounts and lock status for the caller.
     * @dev This function checks the user's dividend position in a specific liquidity pool.
     * @param tokenA The address of the first token in the pair.
     * @param tokenB The address of the second token in the pair.
     * @return A DividendInfo struct containing the pending amounts of token0 and token1 and the lock timestamp.
     */
    function checkDividends(address tokenA, address tokenB) external view returns (DividendInfo memory) {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');

        IRareBayV2Pair pair = IRareBayV2Pair(pairAddress);
        address token0 = pair.token0();

        // Ensure correct order of dividends based on token0/token1
        uint256 pending0;
        uint256 pending1;

        if (tokenA == token0) {
            pending0 = pair.pendingDividends0(msg.sender);
            pending1 = pair.pendingDividends1(msg.sender);
        } else {
            pending0 = pair.pendingDividends1(msg.sender);
            pending1 = pair.pendingDividends0(msg.sender);
        }

        return DividendInfo({
            pendingDividend0: pending0,
            pendingDividend1: pending1,
            lockTime: pair.dividendLockTime(msg.sender)
        });
    }

    /**
     * @notice Gets the timestamp until which a user's dividends for a pair are locked.
     * @param tokenA The address of the first token in the pair.
     * @param tokenB The address of the second token in the pair.
     * @return The Unix timestamp of the lock period's expiration.
     */
    function getDividendLockTime(address tokenA, address tokenB) external view returns (uint256) {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        return IRareBayV2Pair(pairAddress).dividendLockTime(msg.sender);
    }

    /**
     * @notice Withdraws the caller's unlocked dividends from a specific pair.
     * @dev This function will fail if the dividends are still within their lock period.
     * @param tokenA The address of the first token in the pair.
     * @param tokenB The address of the second token in the pair.
     */
    function withdrawDividends(address tokenA, address tokenB) external lock {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        IRareBayV2Pair(pairAddress).withdrawDividends();
    }
    // --- Helper/Getter Functions ---
    function _getReserves(address pair, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = _sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IRareBayV2Pair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'Router: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Router: ZERO_ADDRESS');
    }

    function quote(uint amountA, uint reserveA, uint reserveB) public pure returns (uint amountB) {
        require(amountA > 0, 'Router: INSUFFICIENT_AMOUNT_QUOTE');
        require(reserveA > 0 && reserveB > 0, 'Router: INSUFFICIENT_LIQUIDITY_QUOTE');
        amountB = (amountA * reserveB) / reserveA;
    }

    function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, 'Router: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i = 0; i < path.length - 1; i++) {
            address pairAddress = IRareBayV2Factory(factory).getPair(path[i], path[i + 1]);
            require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
            amounts[i + 1] = IRareBayV2Pair(pairAddress).getAmountOut(amounts[i], path[i]);
        }
    }

    function getAmountsIn(uint amountOut, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, 'Router: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            address pairAddress = IRareBayV2Factory(factory).getPair(path[i - 1], path[i]);
            require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
            amounts[i - 1] = IRareBayV2Pair(pairAddress).getAmountIn(amounts[i], path[i]);
        }
    }

    // --- Core Liquidity Logic (Internal) ---
    function _addPairToActive(address pair) private {
        if (!_isActivePair[pair]) {
            _isActivePair[pair] = true;
            _activePairs.push(pair);
        }
    }

    function _calculateLiquidityAmounts(
        uint amountADesired, uint amountBDesired,
        uint amountAMin, uint amountBMin,
        address tokenA, address tokenB,
        address pairAddress
    ) private view returns (uint actualA, uint actualB) {
        (uint reserveA, uint reserveB) = _getReserves(pairAddress, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            actualA = amountADesired;
            actualB = amountBDesired;
        } else {
            uint amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'Router: INSUFFICIENT_B_AMOUNT');
                actualA = amountADesired;
                actualB = amountBOptimal;
            } else {
                uint amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                require(amountAOptimal <= amountADesired, 'Router: INSUFFICIENT_A_OPTIMAL');
                require(amountAOptimal >= amountAMin, 'Router: INSUFFICIENT_A_AMOUNT');
                actualA = amountAOptimal;
                actualB = amountBDesired;
            }
        }
    }

    function _addLiquidityLogic(
        address tokenA, address tokenB,
        uint amountADesired, uint amountBDesired,
        uint amountAMin, uint amountBMin,
        address to
    ) internal returns (uint actualA, uint actualB, uint liquidity) {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        _addPairToActive(pairAddress);
        (actualA, actualB) = _calculateLiquidityAmounts(amountADesired, amountBDesired, amountAMin, amountBMin, tokenA, tokenB, pairAddress);
        require(IERC20(tokenA).transferFrom(msg.sender, pairAddress, actualA), "Transfer failed");
        require(IERC20(tokenB).transferFrom(msg.sender, pairAddress, actualB), "Transfer failed");
        liquidity = IRareBayV2Pair(pairAddress).mint(to);
    }

    function _addLiquidityCORELogic(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountCOREMin,
        address to,
        uint coreValueFromMsg
    ) internal returns (uint actualToken, uint actualCORE, uint liquidity) {
        require(coreValueFromMsg > 0, 'Router: NO_CORE_SENT');
        address pairAddress = IRareBayV2Factory(factory).getPair(token, WCORE);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        _addPairToActive(pairAddress);
        (actualToken, actualCORE) = _calculateLiquidityAmounts(
            amountTokenDesired, coreValueFromMsg,
            amountTokenMin, amountCOREMin,
            token, WCORE,
            pairAddress
        );
        require(IERC20(token).transferFrom(msg.sender, pairAddress, actualToken), "Transfer failed");
        IWCORE(WCORE).deposit{value: actualCORE}();
        require(IWCORE(WCORE).transfer(pairAddress, actualCORE), 'Router: WCORE_TRANSFER_FAILED');
        liquidity = IRareBayV2Pair(pairAddress).mint(to);
        if (coreValueFromMsg > actualCORE) {
            payable(msg.sender).transfer(coreValueFromMsg - actualCORE);
        }
    }

    function _removeLiquidity(
        address tokenA, address tokenB,
        uint liquidityVal,
        uint amountAMin, uint amountBMin,
        address to
    ) internal returns (uint amountA, uint amountB) {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        require(IERC20(pairAddress).transferFrom(msg.sender, pairAddress, liquidityVal), "Transfer failed");
        (uint amount0, uint amount1) = IRareBayV2Pair(pairAddress).burn(to);
        address token0 = IRareBayV2Pair(pairAddress).token0();
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin && amountB >= amountBMin, 'Router: INSUFFICIENT_LIQUIDITY_BURNED');
    }

    function _removeLiquidityCORE(
        address token,
        uint liquidityVal,
        uint amountTokenMin,
        uint amountCOREMin,
        address to
    ) internal returns (uint amountToken, uint amountCORE) {
        address pairAddress = IRareBayV2Factory(factory).getPair(token, WCORE);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        require(IERC20(pairAddress).transferFrom(msg.sender, pairAddress, liquidityVal), "Transfer failed");
        (uint amount0, uint amount1) = IRareBayV2Pair(pairAddress).burn(address(this));
        address token0 = IRareBayV2Pair(pairAddress).token0();
        (amountToken, amountCORE) = token == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountToken >= amountTokenMin, 'Router: INSUFFICIENT_TOKEN_AMOUNT');
        require(amountCORE >= amountCOREMin, 'Router: INSUFFICIENT_CORE_AMOUNT');
        require(IERC20(token).transfer(to, amountToken), "Transfer failed");
        IWCORE(WCORE).withdraw(amountCORE);
        payable(to).transfer(amountCORE);
    }

    // --- Core Swap Logic (Internal) ---
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal {
        for (uint i = 0; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            address pairAddress = IRareBayV2Factory(factory).getPair(input, output);
            require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
            _addPairToActive(pairAddress);
            address token0 = IRareBayV2Pair(pairAddress).token0();
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address recipientForThisHop = i < path.length - 2 ? IRareBayV2Factory(factory).getPair(output, path[i + 2]) : _to;
            require(IERC20(input).transfer(pairAddress, amounts[i]), "Transfer failed");
            IRareBayV2Pair(pairAddress).swap(amount0Out, amount1Out, recipientForThisHop, new bytes(0));
        }
    }

    // --- Swap Logic Functions (Internal, No Modifiers) ---
    function _swapExactTokensForTokens(
        uint amountIn, address[] calldata path, address to, uint amountOutMin
    ) internal returns (uint[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'Router: INSUFFICIENT_OUTPUT_AMOUNT');
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amounts[0]), "Transfer failed");
        _swap(amounts, path, to);
    }

    function _swapTokensForExactTokens(
        uint amountOut, address[] calldata path, address to, uint amountInMax
    ) internal returns (uint[] memory amounts) {
        amounts = getAmountsIn(amountOut, path);
        require(amounts[0] <= amountInMax, 'Router: EXCESSIVE_INPUT_AMOUNT');
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amounts[0]), "Transfer failed");
        _swap(amounts, path, to);
    }

    function _swapExactCOREForTokens(
        uint amountInCORE, address[] calldata path, address to, uint amountOutMinToken
    ) internal returns (uint[] memory amounts) {
        require(path[0] == WCORE, 'Router: INVALID_PATH');
        amounts = getAmountsOut(amountInCORE, path);
        require(amounts[amounts.length - 1] >= amountOutMinToken, 'Router: INSUFFICIENT_OUTPUT_AMOUNT');
        IWCORE(WCORE).deposit{value: amounts[0]}();
        _swap(amounts, path, to);
    }

    function _swapTokensForExactCORE(
        uint amountOutCORE, address[] calldata path, address to, uint amountInMaxToken
    ) internal returns (uint[] memory amounts) {
        require(path[path.length - 1] == WCORE, 'Router: INVALID_PATH');
        amounts = getAmountsIn(amountOutCORE, path);
        require(amounts[0] <= amountInMaxToken, 'Router: EXCESSIVE_INPUT_AMOUNT');
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amounts[0]), "Transfer failed");
        _swap(amounts, path, address(this));
        IWCORE(WCORE).withdraw(amounts[amounts.length - 1]);
        payable(to).transfer(amounts[amounts.length - 1]);
    }

    function _swapExactTokensForCORE(
        uint amountInToken, address[] calldata path, address to, uint amountOutMinCORE
    ) internal returns (uint[] memory amounts) {
        require(path[path.length - 1] == WCORE, 'Router: INVALID_PATH');
        amounts = getAmountsOut(amountInToken, path);
        require(amounts[amounts.length - 1] >= amountOutMinCORE, 'Router: INSUFFICIENT_OUTPUT_AMOUNT');
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amounts[0]), "Transfer failed");
        _swap(amounts, path, address(this));
        IWCORE(WCORE).withdraw(amounts[amounts.length - 1]);
        payable(to).transfer(amounts[amounts.length - 1]);
    }

    function _swapCOREForExactTokens(
        uint amountInCOREFromMsg, uint amountOutToken, address[] calldata path, address to
    ) internal returns (uint[] memory amounts) {
        require(path[0] == WCORE, 'Router: INVALID_PATH');
        amounts = getAmountsIn(amountOutToken, path);
        require(amounts[0] <= amountInCOREFromMsg, 'Router: INSUFFICIENT_CORE_AMOUNT');
        if (amounts[0] > 0) {
            IWCORE(WCORE).deposit{value: amounts[0]}();
        }
        _swap(amounts, path, to);
        if (amountInCOREFromMsg > amounts[0]) {
            payable(msg.sender).transfer(amountInCOREFromMsg - amounts[0]);
        }
    }

    // --- Public/External Swap Functions ---
    function swapExactTokensForTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amounts) {
        return _swapExactTokensForTokens(amountIn, path, to, amountOutMin);
    }

    function swapTokensForExactTokens(
        uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amounts) {
        return _swapTokensForExactTokens(amountOut, path, to, amountInMax);
    }

    function swapExactCOREForTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable ensure(deadline) lock returns (uint[] memory amounts) {
        require(msg.value > 0, 'Router: NO_CORE_SENT');
        return _swapExactCOREForTokens(msg.value, path, to, amountOutMin);
    }

    function swapTokensForExactCORE(
        uint amountOutCORE, uint amountInMax, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amounts) {
        return _swapTokensForExactCORE(amountOutCORE, path, to, amountInMax);
    }

    function swapExactTokensForCORE(
        uint amountIn, uint amountOutMinCORE, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amounts) {
        return _swapExactTokensForCORE(amountIn, path, to, amountOutMinCORE);
    }

    function swapCOREForExactTokens(
        uint amountOut, address[] calldata path, address to, uint deadline
    ) external payable ensure(deadline) lock returns (uint[] memory amounts) {
        require(msg.value > 0, 'Router: NO_CORE_SENT');
        return _swapCOREForExactTokens(msg.value, amountOut, path, to);
    }

    // --- Watchlist, Voting, Trending Functions ---
    function _getPoolInfoWithVotes(address pairAddress) private view returns (PoolInfo memory) {
        IRareBayV2Pair pairContract = IRareBayV2Pair(pairAddress);
        address t0 = pairContract.token0();
        address t1 = pairContract.token1();
        (uint r0, uint r1, ) = pairContract.getReserves();
        VoteStats storage votes = pairVotes[pairAddress];
        return PoolInfo(pairAddress, t0, t1, r0, r1, votes.upvotes, votes.downvotes);
    }

    function addToWatchlist(address pair) external {
        require(pair != address(0), 'Router: INVALID_PAIR');
        require(!_isPairWatchlisted[msg.sender][pair], 'Router: ALREADY_WATCHLISTED');
        _userWatchlists[msg.sender].push(pair);
        _userWatchlistPairIndex[msg.sender][pair] = _userWatchlists[msg.sender].length;
        _isPairWatchlisted[msg.sender][pair] = true;
        emit PairWatchlisted(msg.sender, pair);
    }

    function removeFromWatchlist(address pair) external {
        require(_isPairWatchlisted[msg.sender][pair], 'Router: NOT_WATCHLISTED');
        uint256 indexToRemove = _userWatchlistPairIndex[msg.sender][pair] - 1;
        address[] storage watchlist = _userWatchlists[msg.sender];
        uint256 lastIndex = watchlist.length - 1;
        if (indexToRemove != lastIndex) {
            address lastPair = watchlist[lastIndex];
            watchlist[indexToRemove] = lastPair;
            _userWatchlistPairIndex[msg.sender][lastPair] = indexToRemove + 1;
        }
        watchlist.pop();
        _userWatchlistPairIndex[msg.sender][pair] = 0;
        _isPairWatchlisted[msg.sender][pair] = false;
        emit PairUnwatchlisted(msg.sender, pair);
    }

    function getWatchlist(address user, uint256 page, uint256 size) external view returns (PoolInfo[] memory paginatedInfo) {
        require(page > 0, 'Router: INVALID_PAGE');
        require(size > 0, 'Router: INVALID_SIZE');
        address[] storage watchlist = _userWatchlists[user];
        uint256 totalWatchlistedPairs = watchlist.length;
        if (totalWatchlistedPairs == 0) return new PoolInfo[](0);
        uint256 startIndex = (page - 1) * size;
        if (startIndex >= totalWatchlistedPairs) return new PoolInfo[](0);
        uint256 endIndex = startIndex + size > totalWatchlistedPairs ? totalWatchlistedPairs : startIndex + size;
        uint256 count = endIndex - startIndex;
        paginatedInfo = new PoolInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            paginatedInfo[i] = _getPoolInfoWithVotes(watchlist[startIndex + i]);
        }
        return paginatedInfo;
    }

    function upvotePair(address pair) external {
        require(pair != address(0), 'Router: INVALID_PAIR');
        int8 currentVote = _userVoteStatus[msg.sender][pair];
        require(currentVote != 1, 'Router: ALREADY_UPVOTED');
        if (currentVote == -1) {
            if (pairVotes[pair].downvotes > 0) pairVotes[pair].downvotes--;
        }
        pairVotes[pair].upvotes++;
        _userVoteStatus[msg.sender][pair] = 1;
        emit PairUpvoted(msg.sender, pair, pairVotes[pair].upvotes);
    }

    function downvotePair(address pair) external {
        require(pair != address(0), 'Router: INVALID_PAIR');
        int8 currentVote = _userVoteStatus[msg.sender][pair];
        require(currentVote != -1, 'Router: ALREADY_DOWNVOTED');
        if (currentVote == 1) {
            if (pairVotes[pair].upvotes > 0) pairVotes[pair].upvotes--;
        }
        pairVotes[pair].downvotes++;
        _userVoteStatus[msg.sender][pair] = -1;
        emit PairDownvoted(msg.sender, pair, pairVotes[pair].downvotes);
    }

    function trendingPools(uint256 page, uint256 size) external view returns (PoolInfo[] memory paginatedInfo) {
        require(page > 0, 'Router: INVALID_PAGE');
        require(size > 0, 'Router: INVALID_SIZE');
        uint256 totalActivePairs = _activePairs.length;
        if (totalActivePairs == 0) return new PoolInfo[](0);
        PoolInfo[] memory allPools = new PoolInfo[](totalActivePairs);
        for (uint256 i = 0; i < totalActivePairs; i++) {
            allPools[i] = _getPoolInfoWithVotes(_activePairs[i]);
        }
        for (uint256 i = 0; i < totalActivePairs; i++) {
            for (uint256 j = i + 1; j < totalActivePairs; j++) {
                int256 scoreI = int256(allPools[i].upvotes) - int256(allPools[i].downvotes);
                int256 scoreJ = int256(allPools[j].upvotes) - int256(allPools[j].downvotes);
                if (scoreI < scoreJ) {
                    PoolInfo memory temp = allPools[i];
                    allPools[i] = allPools[j];
                    allPools[j] = temp;
                }
            }
        }
        uint256 startIndex = (page - 1) * size;
        if (startIndex >= totalActivePairs) return new PoolInfo[](0);
        uint256 endIndex = startIndex + size > totalActivePairs ? totalActivePairs : startIndex + size;
        uint256 count = endIndex - startIndex;
        paginatedInfo = new PoolInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            paginatedInfo[i] = allPools[startIndex + i];
        }
        return paginatedInfo;
    }

    function getTokenPriceInUSDT(address token) external view returns (uint price) {
        require(token != address(0) && token != USDT, 'Router: INVALID_TOKEN');
        address pairAddress = IRareBayV2Factory(factory).getPair(token, USDT);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        
        (uint reserveToken, uint reserveUSDT) = _getReserves(pairAddress, token, USDT);
        require(reserveToken > 0 && reserveUSDT > 0, 'Router: INSUFFICIENT_LIQUIDITY');
        
        uint tokenDecimals = IERC20(token).decimals();
        price = (reserveUSDT * 10**tokenDecimals) / reserveToken;
    }

    function getPairAPR(address tokenA, address tokenB, uint dailyTradingVolumeUSDT) external view returns (uint apr) {
        require(tokenA != tokenB, 'Router: IDENTICAL_TOKENS');
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');

        (uint reserveA, uint reserveB) = _getReserves(pairAddress, tokenA, tokenB);
        require(reserveA > 0 && reserveB > 0, 'Router: INSUFFICIENT_LIQUIDITY');

        uint FEE_BASIS_POINTS = 3000;
        uint BASIS_POINTS = 1000000;

        uint poolValueUSDT;
        if (tokenA == USDT) {
            poolValueUSDT = reserveA * 2;
        } else if (tokenB == USDT) {
            poolValueUSDT = reserveB * 2;
        } else {
            address pairWithUSDT = IRareBayV2Factory(factory).getPair(tokenA, USDT);
            if (pairWithUSDT != address(0)) {
                (uint reserveToken, uint reserveUSDT) = _getReserves(pairWithUSDT, tokenA, USDT);
                if (reserveToken > 0 && reserveUSDT > 0) {
                    uint tokenAPrice = (reserveUSDT * 1e6) / reserveToken;
                    poolValueUSDT = ((reserveA * tokenAPrice) / 1e6) * 2;
                }
            } else {
                pairWithUSDT = IRareBayV2Factory(factory).getPair(tokenB, USDT);
                require(pairWithUSDT != address(0), 'Router: NO_USDT_PAIR');
                (uint reserveToken, uint reserveUSDT) = _getReserves(pairWithUSDT, tokenB, USDT);
                require(reserveToken > 0 && reserveUSDT > 0, 'Router: INSUFFICIENT_LIQUIDITY');
                uint tokenBPrice = (reserveUSDT * 1e6) / reserveToken;
                poolValueUSDT = ((reserveB * tokenBPrice) / 1e6) * 2;
            }
        }

        require(poolValueUSDT > 0, 'Router: INVALID_POOL_VALUE');

        uint dailyFeesUSDT = (dailyTradingVolumeUSDT * FEE_BASIS_POINTS) / BASIS_POINTS;
        uint annualFeesUSDT = dailyFeesUSDT * 365;
        apr = (annualFeesUSDT * 10000) / poolValueUSDT;
    }

    function getPaginatedPoolInfo(uint page, uint size) external view returns (PoolInfo[] memory) {
        require(page > 0, 'Router: INVALID_PAGE');
        require(size > 0, 'Router: INVALID_SIZE');
        uint totalPairs = _activePairs.length;
        if (totalPairs == 0) return new PoolInfo[](0);
        uint startIndex = (page - 1) * size;
        if (startIndex >= totalPairs) return new PoolInfo[](0);
        uint endIndex = startIndex + size > totalPairs ? totalPairs : startIndex + size;
        uint resultCount = endIndex - startIndex;
        PoolInfo[] memory pools = new PoolInfo[](resultCount);
        for (uint i = 0; i < resultCount; i++) {
            pools[i] = _getPoolInfoWithVotes(_activePairs[startIndex + i]);
        }
        return pools;
    }
    // --- Liquidity Management ---

    /**
     * @notice Adds liquidity to an ERC20-ERC20 pair.
     * @param tokenA The address of one of the tokens.
     * @param tokenB The address of the other token.
     * @param amountADesired The desired amount of tokenA to add.
     * @param amountBDesired The desired amount of tokenB to add.
     * @param amountAMin The minimum amount of tokenA to add.
     * @param amountBMin The minimum amount of tokenB to add.
     * @param to The address that will receive the liquidity tokens.
     * @param deadline The timestamp after which the transaction will be reverted.
     * @return actualA The amount of tokenA actually deposited.
     * @return actualB The amount of tokenB actually deposited.
     * @return liquidity The amount of LP tokens minted.
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external ensure(deadline) lock returns (uint actualA, uint actualB, uint liquidity) {
        return _addLiquidityLogic(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to);
    }

    /**
     * @notice Adds liquidity to an ERC20-CORE pair.
     * @dev The CORE amount is sent as msg.value.
     * @param token The address of the ERC20 token.
     * @param amountTokenDesired The desired amount of the ERC20 token to add.
     * @param amountTokenMin The minimum amount of the ERC20 token to add.
     * @param amountCOREMin The minimum amount of CORE to add.
     * @param to The address that will receive the liquidity tokens.
     * @param deadline The timestamp after which the transaction will be reverted.
     * @return actualToken The amount of the ERC20 token actually deposited.
     * @return actualCORE The amount of CORE actually deposited.
     * @return liquidity The amount of LP tokens minted.
     */
    function addLiquidityCORE(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountCOREMin,
        address to,
        uint deadline
    ) external payable ensure(deadline) lock returns (uint actualToken, uint actualCORE, uint liquidity) {
        return _addLiquidityCORELogic(token, amountTokenDesired, amountTokenMin, amountCOREMin, to, msg.value);
    }

    /**
     * @notice Removes liquidity from an ERC20-ERC20 pair.
     * @param tokenA The address of one of the tokens.
     * @param tokenB The address of the other token.
     * @param liquidity The amount of LP tokens to burn.
     * @param amountAMin The minimum amount of tokenA to receive.
     * @param amountBMin The minimum amount of tokenB to receive.
     * @param to The address that will receive the withdrawn tokens.
     * @param deadline The timestamp after which the transaction will be reverted.
     * @return amountA The amount of tokenA received.
     * @return amountB The amount of tokenB received.
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external ensure(deadline) lock returns (uint amountA, uint amountB) {
        return _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);
    }

    /**
     * @notice Removes liquidity from an ERC20-CORE pair.
     * @param token The address of the ERC20 token.
     * @param liquidity The amount of LP tokens to burn.
     * @param amountTokenMin The minimum amount of the ERC20 token to receive.
     * @param amountCOREMin The minimum amount of CORE to receive.
     * @param to The address that will receive the withdrawn tokens.
     * @param deadline The timestamp after which the transaction will be reverted.
     * @return amountToken The amount of the ERC20 token received.
     * @return amountCORE The amount of CORE received.
     */
    function removeLiquidityCORE(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountCOREMin,
        address to,
        uint deadline
    ) external ensure(deadline) lock returns (uint amountToken, uint amountCORE) {
        return _removeLiquidityCORE(token, liquidity, amountTokenMin, amountCOREMin, to);
    }

    // --- Optional: skim & sync wrappers ---
    function skim(address tokenA, address tokenB, address to, uint deadline) external ensure(deadline) lock {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        IRareBayV2Pair(pairAddress).skim(to);
    }

    function sync(address tokenA, address tokenB, uint deadline) external ensure(deadline) lock {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND');
        IRareBayV2Pair(pairAddress).sync();
    }
}