// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './interfaces/IERC20.sol';
import './interfaces/IRareBayV2Pair.sol';
import './interfaces/IRareBayV2Factory.sol';

interface IWCORE is IERC20 {
    function deposit() external payable;
    function withdraw(uint wad) external;
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract RareBayV2Router {
    address public immutable factory;
    address public immutable WCORE; // Wrapped CORE

    address public immutable USDT;
    address public immutable USDC;
    address public immutable WBTC;

    uint8 public constant UI_DECIMALS = 18;
    uint8 public constant WCORE_DECIMALS = 18;
    uint8 public constant USDT_DECIMALS = 6;
    uint8 public constant USDC_DECIMALS = 6;
    uint8 public constant WBTC_DECIMALS = 8;

    mapping(address => uint8) public tokenDecimals;

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

        tokenDecimals[WCORE] = WCORE_DECIMALS;
        tokenDecimals[USDT] = USDT_DECIMALS;
        tokenDecimals[USDC] = USDC_DECIMALS;
        tokenDecimals[WBTC] = WBTC_DECIMALS;
        // For other tokens, their decimals need to be added, e.g., via an admin function
        // or by reading from token contract (if a known interface like decimals() exists)
    }

    receive() external payable {}

    function setTokenDecimals(address token, uint8 decimals) external {
        require(token != address(0), "Router: zero address");
        require(tokenDecimals[token] == 0, "Router: decimals already set");
        tokenDecimals[token] = decimals;
    }
    // --- Decimal Conversion Helpers ---
    function _toNativeDecimals(address token, uint256 amountUIDecimals) internal view returns (uint256) {
        uint8 nativeDecs = tokenDecimals[token];
        require(nativeDecs > 0, "Router: Unknown token decimals");
        if (nativeDecs == UI_DECIMALS) return amountUIDecimals;
        if (nativeDecs < UI_DECIMALS) return amountUIDecimals / (10**(UI_DECIMALS - nativeDecs));
        // This case (nativeDecs > UI_DECIMALS) implies UI_DECIMALS is smaller than some token's native decimals.
        // For example, if UI_DECIMALS = 6 and native is 18.
        return amountUIDecimals * (10**(nativeDecs - UI_DECIMALS));
    }

    function _fromUIDecimals(address token, uint256 amountNativeDecimals) internal view returns (uint256) {
        uint8 nativeDecs = tokenDecimals[token];
        require(nativeDecs > 0, "Router: Unknown token decimals");
        if (nativeDecs == UI_DECIMALS) return amountNativeDecimals;
        if (nativeDecs < UI_DECIMALS) return amountNativeDecimals * (10**(UI_DECIMALS - nativeDecs));
        // This case (nativeDecs > UI_DECIMALS)
        return amountNativeDecimals / (10**(nativeDecs - UI_DECIMALS));
    }
    function _getTokenDecimals(address token) private view returns (uint8) {
        if (tokenDecimals[token] != 0) {
            return tokenDecimals[token];
        }
        try IERC20Decimals(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            revert("Router: Unknown token decimals");
        }
    }
    function _normalizeAmountsArray(address[] memory path, uint[] memory nativeAmounts) internal view returns (uint[] memory uiAmounts) {
        uiAmounts = new uint[](nativeAmounts.length);
        for (uint i = 0; i < nativeAmounts.length; i++) {
            uiAmounts[i] = _fromUIDecimals(path[i], nativeAmounts[i]);
        }
    }

    function _addPairToActive(address pair) private {
        if (!_isActivePair[pair]) {
            _isActivePair[pair] = true;
            _activePairs.push(pair);
        }
    }

    // --- Helper/Getter Functions (Mostly Unchanged) ---
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
        require(path.length >= 2, 'Router: INVALID_PATH_LEN_OUT');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i = 0; i < path.length - 1; i++) {
            address pairAddress = IRareBayV2Factory(factory).getPair(path[i], path[i+1]);
            require(pairAddress != address(0), "Router: PAIR_NOT_FOUND_GETAMOUNTSOUT");
            amounts[i+1] = IRareBayV2Pair(pairAddress).getAmountOut(amounts[i], path[i]);
        }
    }

    function getAmountsIn(uint amountOut, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, 'Router: INVALID_PATH_LEN_IN');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            address pairAddress = IRareBayV2Factory(factory).getPair(path[i-1], path[i]);
            require(pairAddress != address(0), "Router: PAIR_NOT_FOUND_GETAMOUNTSIN");
            // getAmountIn expects (amountOut, tokenIn)
            amounts[i-1] = IRareBayV2Pair(pairAddress).getAmountIn(amounts[i], path[i-1]);
        }
    }

    // --- CORE LIQUIDITY LOGIC (Internal) ---
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
                require(amountAOptimal <= amountADesired, 'Router: INSUFFICIENT_A_OPTIMAL'); // Should not fail if quote is right
                require(amountAOptimal >= amountAMin, 'Router: INSUFFICIENT_A_AMOUNT');
                actualA = amountAOptimal;
                actualB = amountBDesired;
            }
        }
    }

    function _addLiquidityLogic(
        address tokenA, address tokenB,
        uint amountADesired, uint amountBDesired, // Native decimals
        uint amountAMin, uint amountBMin,         // Native decimals
        address to
    ) internal returns (uint actualA, uint actualB, uint liquidity) {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND_ADD_LIQ');
        _addPairToActive(pairAddress);

        (actualA, actualB) = _calculateLiquidityAmounts(amountADesired, amountBDesired, amountAMin, amountBMin, tokenA, tokenB, pairAddress);

        IERC20(tokenA).transferFrom(msg.sender, pairAddress, actualA);
        IERC20(tokenB).transferFrom(msg.sender, pairAddress, actualB);
        liquidity = IRareBayV2Pair(pairAddress).mint(to);
    }
    
    function _addLiquidityCORELogic(
        address token,
        uint amountTokenDesired, // Native decimals
        uint amountTokenMin,     // Native decimals
        uint amountCOREMin,      // Native WCORE_DECIMALS (18)
        address to,
        uint coreValueFromMsg    // msg.value, in 18 decimals (native CORE)
    ) internal returns (uint actualToken, uint actualCORE, uint liquidity) {
        require(coreValueFromMsg > 0, 'Router: NO_CORE_SENT_ADD_LIQ');
        address pairAddress = IRareBayV2Factory(factory).getPair(token, WCORE);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND_ADD_LIQ_CORE');
        _addPairToActive(pairAddress);

        (actualToken, actualCORE) = _calculateLiquidityAmounts(
            amountTokenDesired, coreValueFromMsg, // coreValueFromMsg is desired WCORE amount
            amountTokenMin, amountCOREMin,
            token, WCORE,
            pairAddress
        );
        
        IERC20(token).transferFrom(msg.sender, pairAddress, actualToken);
        IWCORE(WCORE).deposit{value: actualCORE}(); // Wrap only the actual CORE needed
        require(IWCORE(WCORE).transfer(pairAddress, actualCORE), "Router: WCORE_TRANSFER_FAILED_ADD_LIQ");
        liquidity = IRareBayV2Pair(pairAddress).mint(to);

        if (coreValueFromMsg > actualCORE) { // Refund excess CORE
            payable(msg.sender).transfer(coreValueFromMsg - actualCORE);
        }
    }

    function _removeLiquidityLogic(
        address tokenA, address tokenB,
        uint liquidityVal, // LP token amount
        uint amountAMin, uint amountBMin, // Native decimals
        address to
    ) internal returns (uint amountA, uint amountB) {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND_REM_LIQ');
        IERC20(pairAddress).transferFrom(msg.sender, pairAddress, liquidityVal);
        (uint amount0, uint amount1) = IRareBayV2Pair(pairAddress).burn(to);

        address token0 = IRareBayV2Pair(pairAddress).token0();
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin && amountB >= amountBMin, 'Router: INSUFFICIENT_LIQUIDITY_BURNED');
    }

    function _removeLiquidityCORELogic(
        address token,
        uint liquidityVal,
        uint amountTokenMin, // Native decimals
        uint amountCOREMin,  // Native WCORE_DECIMALS (18)
        address to
    ) internal returns (uint amountToken, uint amountCORE) {
        address pairAddress = IRareBayV2Factory(factory).getPair(token, WCORE);
        require(pairAddress != address(0), 'Router: PAIR_NOT_FOUND_REM_LIQ_CORE');
        IERC20(pairAddress).transferFrom(msg.sender, pairAddress, liquidityVal);
        (uint amount0, uint amount1) = IRareBayV2Pair(pairAddress).burn(address(this)); // Burn to this contract

        address token0 = IRareBayV2Pair(pairAddress).token0();
        (amountToken, amountCORE) = token == token0 ? (amount0, amount1) : (amount1, amount0);

        require(amountToken >= amountTokenMin, 'Router: INSUFFICIENT_TOKEN_AMOUNT_REM_LIQ');
        require(amountCORE >= amountCOREMin, 'Router: INSUFFICIENT_CORE_AMOUNT_REM_LIQ');

        IERC20(token).transfer(to, amountToken);
        IWCORE(WCORE).withdraw(amountCORE);
        payable(to).transfer(amountCORE);
    }

    // --- PUBLIC/EXTERNAL LIQUIDITY FUNCTIONS (Native Decimals) ---
    function addLiquidity(
        address tokenA, address tokenB,
        uint amountADesired, uint amountBDesired,
        uint amountAMin, uint amountBMin,
        address to, uint deadline
    ) external ensure(deadline) lock returns (uint actualA, uint actualB, uint liquidity) {
        return _addLiquidityLogic(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to);
    }

    function addLiquidityCORE(
        address token,
        uint amountTokenDesired, uint amountTokenMin, uint amountCOREMin,
        address to, uint deadline
    ) external payable ensure(deadline) lock returns (uint actualToken, uint actualCORE, uint liquidity) {
         return _addLiquidityCORELogic(token, amountTokenDesired, amountTokenMin, amountCOREMin, to, msg.value);
    }

    function removeLiquidity(
        address tokenA, address tokenB,
        uint liquidityVal, uint amountAMin, uint amountBMin,
        address to, uint deadline
    ) external ensure(deadline) lock returns (uint amountA, uint amountB) {
        return _removeLiquidityLogic(tokenA, tokenB, liquidityVal, amountAMin, amountBMin, to);
    }

    function removeLiquidityCORE(
        address token, uint liquidityVal,
        uint amountTokenMin, uint amountCOREMin,
        address to, uint deadline
    ) external ensure(deadline) lock returns (uint amountToken, uint amountCORE) {
        return _removeLiquidityCORELogic(token, liquidityVal, amountTokenMin, amountCOREMin, to);
    }

    // --- PUBLIC/EXTERNAL LIQUIDITY FUNCTIONS (Normalized UI_DECIMALS) ---
    function addLiquidityNormalized(
        address tokenA, address tokenB,
        uint amountADesiredNormalized, uint amountBDesiredNormalized,
        uint amountAMinNormalized, uint amountBMinNormalized,
        address to, uint deadline
    ) external ensure(deadline) lock returns (uint actualANormalized, uint actualBNormalized, uint liquidity) {
        uint amountADesiredNative = _toNativeDecimals(tokenA, amountADesiredNormalized);
        uint amountBDesiredNative = _toNativeDecimals(tokenB, amountBDesiredNormalized);
        uint amountAMinNative = _toNativeDecimals(tokenA, amountAMinNormalized);
        uint amountBMinNative = _toNativeDecimals(tokenB, amountBMinNormalized);

        (uint actualANative, uint actualBNative, uint liq) = _addLiquidityLogic(
            tokenA, tokenB,
            amountADesiredNative, amountBDesiredNative,
            amountAMinNative, amountBMinNative, to
        );
        actualANormalized = _fromUIDecimals(tokenA, actualANative);
        actualBNormalized = _fromUIDecimals(tokenB, actualBNative);
        liquidity = liq;
    }

    function addLiquidityCORENormalized(
        address token,
        uint amountTokenDesiredNormalized, uint amountTokenMinNormalized, uint amountCOREMinNormalized,
        address to, uint deadline
    ) external payable ensure(deadline) lock returns (uint actualTokenNormalized, uint actualCORENormalized, uint liquidity) {
        uint amountTokenDesiredNative = _toNativeDecimals(token, amountTokenDesiredNormalized);
        uint amountTokenMinNative = _toNativeDecimals(token, amountTokenMinNormalized);
        require(tokenDecimals[WCORE] == UI_DECIMALS, "Router: CORE norm assumes UI_DECIMALS eq WCORE_DECIMALS");
        uint amountCOREMinNative = amountCOREMinNormalized; // WCORE is 18 dec, UI is 18 dec

        (uint actualTokenNative, uint actualCORENative, uint liq) = _addLiquidityCORELogic(
            token, amountTokenDesiredNative, amountTokenMinNative, amountCOREMinNative, to, msg.value
        );
        actualTokenNormalized = _fromUIDecimals(token, actualTokenNative);
        actualCORENormalized = _fromUIDecimals(WCORE, actualCORENative); // WCORE native is 18 dec
        liquidity = liq;
    }
    
    function removeLiquidityNormalized(
        address tokenA, address tokenB,
        uint liquidityVal,
        uint amountAMinNormalized, uint amountBMinNormalized,
        address to, uint deadline
    ) external ensure(deadline) lock returns (uint amountANormalized, uint amountBNormalized) {
        uint amountAMinNative = _toNativeDecimals(tokenA, amountAMinNormalized);
        uint amountBMinNative = _toNativeDecimals(tokenB, amountBMinNormalized);

        (uint amountANative, uint amountBNative) = _removeLiquidityLogic(
            tokenA, tokenB, liquidityVal, amountAMinNative, amountBMinNative, to
        );
        amountANormalized = _fromUIDecimals(tokenA, amountANative);
        amountBNormalized = _fromUIDecimals(tokenB, amountBNative);
    }

    function removeLiquidityCORENormalized(
        address token, uint liquidityVal,
        uint amountTokenMinNormalized, uint amountCOREMinNormalized,
        address to, uint deadline
    ) external ensure(deadline) lock returns (uint amountTokenNormalized, uint amountCORENormalized) {
        uint amountTokenMinNative = _toNativeDecimals(token, amountTokenMinNormalized);
        require(tokenDecimals[WCORE] == UI_DECIMALS, "Router: CORE norm assumes UI_DECIMALS eq WCORE_DECIMALS");
        uint amountCOREMinNative = amountCOREMinNormalized;

        (uint amountTokenNative, uint amountCORENative) = _removeLiquidityCORELogic(
            token, liquidityVal, amountTokenMinNative, amountCOREMinNative, to
        );
        amountTokenNormalized = _fromUIDecimals(token, amountTokenNative);
        amountCORENormalized = _fromUIDecimals(WCORE, amountCORENative);
    }

    // --- CORE SWAP LOGIC (Internal) ---
    // This is the heart of multi-hop swaps. It transfers tokens from this contract to pairs.
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal {
        for (uint i = 0; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i+1]);
            address pairAddress = IRareBayV2Factory(factory).getPair(input, output);
            require(pairAddress != address(0), "Router: PAIR_SWAP_NOT_FOUND_INTERNAL");
            _addPairToActive(pairAddress); // Register pair if used

            address token0 = IRareBayV2Pair(pairAddress).token0();
            uint amountOut = amounts[i+1]; // Expected output from this hop
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            
            address recipientForThisHop = i < path.length - 2 ? IRareBayV2Factory(factory).getPair(output, path[i+2]) : _to;
            
            // amounts[i] is the input amount for the current hop.
            // This contract should already have these tokens (either from user via transferFrom or from WCORE deposit).
            IERC20(input).transfer(pairAddress, amounts[i]);
            IRareBayV2Pair(pairAddress).swap(amount0Out, amount1Out, recipientForThisHop, new bytes(0));
        }
    }

    // --- Swap Logic Functions (Internal, No Modifiers) ---
    function _swapExactTokensForTokensLogic(
        uint amountIn, address[] calldata path, address to, uint amountOutMin
    ) internal returns (uint[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'Router: INSUFFICIENT_OUTPUT_SWAP');
        IERC20(path[0]).transferFrom(msg.sender, address(this), amounts[0]); // User -> Router
        _swap(amounts, path, to); // Router -> Pairs
    }

    function _swapTokensForExactTokensLogic(
        uint amountOut, address[] calldata path, address to, uint amountInMax
    ) internal returns (uint[] memory amounts) {
        amounts = getAmountsIn(amountOut, path);
        require(amounts[0] <= amountInMax, 'Router: EXCESSIVE_INPUT_SWAP');
        IERC20(path[0]).transferFrom(msg.sender, address(this), amounts[0]); // User -> Router
        _swap(amounts, path, to); // Router -> Pairs
    }

    function _swapExactCOREForTokensLogic(
        uint amountInCORE, address[] calldata path, address to, uint amountOutMinToken
    ) internal returns (uint[] memory amounts) {
        require(path[0] == WCORE, 'Router: PATH_NOT_WCORE_IN');
        amounts = getAmountsOut(amountInCORE, path);
        require(amounts[amounts.length - 1] >= amountOutMinToken, 'Router: INSUFFICIENT_OUTPUT_SWAP_CORE_IN');
        IWCORE(WCORE).deposit{value: amounts[0]}(); // Deposit only needed WCORE
        // _swap expects this contract to have WCORE, which deposit() provides.
        _swap(amounts, path, to);
    }

    function _swapTokensForExactCORELogic(
        uint amountOutCORE, address[] calldata path, address to, uint amountInMaxToken
    ) internal returns (uint[] memory amounts) {
        require(path[path.length - 1] == WCORE, 'Router: PATH_NOT_WCORE_OUT');
        amounts = getAmountsIn(amountOutCORE, path);
        require(amounts[0] <= amountInMaxToken, 'Router: EXCESSIVE_INPUT_SWAP_CORE_OUT');
        IERC20(path[0]).transferFrom(msg.sender, address(this), amounts[0]);
        _swap(amounts, path, address(this)); // Swap to this contract
        IWCORE(WCORE).withdraw(amounts[amounts.length - 1]);
        payable(to).transfer(amounts[amounts.length - 1]); // Send native CORE to user
    }

    function _swapExactTokensForCORELogic(
        uint amountInToken, address[] calldata path, address to, uint amountOutMinCORE
    ) internal returns (uint[] memory amounts) {
        require(path[path.length - 1] == WCORE, 'Router: PATH_NOT_WCORE_OUT_EXACT_IN');
        amounts = getAmountsOut(amountInToken, path);
        require(amounts[amounts.length - 1] >= amountOutMinCORE, 'Router: INSUFFICIENT_CORE_OUTPUT_SWAP');
        IERC20(path[0]).transferFrom(msg.sender, address(this), amounts[0]);
        _swap(amounts, path, address(this));
        IWCORE(WCORE).withdraw(amounts[amounts.length - 1]);
        payable(to).transfer(amounts[amounts.length - 1]);
    }
    
    function _swapCOREForExactTokensLogic(
        uint amountInCOREFromMsg, uint amountOutToken, address[] calldata path, address to
    ) internal returns (uint[] memory amounts) {
        require(path[0] == WCORE, 'Router: PATH_NOT_WCORE_IN_EXACT_OUT');
        amounts = getAmountsIn(amountOutToken, path); // amounts[0] is required WCORE
        require(amounts[0] <= amountInCOREFromMsg, 'Router: INSUFFICIENT_CORE_SENT_SWAP');
        
        if (amounts[0] > 0) { // Only deposit if WCORE is actually needed for the swap
             IWCORE(WCORE).deposit{value: amounts[0]}();
        }
        _swap(amounts, path, to);
        
        if (amountInCOREFromMsg > amounts[0]) { // Refund excess CORE
            payable(msg.sender).transfer(amountInCOREFromMsg - amounts[0]);
        }
    }

    // --- PUBLIC/EXTERNAL SWAP FUNCTIONS (Native Decimals) ---
    function swapExactTokensForTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amounts) {
        return _swapExactTokensForTokensLogic(amountIn, path, to, amountOutMin);
    }

    function swapTokensForExactTokens(
        uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amounts) {
        return _swapTokensForExactTokensLogic(amountOut, path, to, amountInMax);
    }

    function swapExactCOREForTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable ensure(deadline) lock returns (uint[] memory amounts) {
        require(msg.value > 0, "Router: NO_CORE_SWAP_IN");
        return _swapExactCOREForTokensLogic(msg.value, path, to, amountOutMin);
    }

    function swapTokensForExactCORE(
        uint amountOutCORE, uint amountInMax, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amounts) {
        return _swapTokensForExactCORELogic(amountOutCORE, path, to, amountInMax);
    }

    function swapExactTokensForCORE(
        uint amountIn, uint amountOutMinCORE, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amounts) {
        return _swapExactTokensForCORELogic(amountIn, path, to, amountOutMinCORE);
    }

    function swapCOREForExactTokens(
        uint amountOut, address[] calldata path, address to, uint deadline
    ) external payable ensure(deadline) lock returns (uint[] memory amounts) {
        require(msg.value > 0, "Router: NO_CORE_SWAP_OUT_EXACT");
        return _swapCOREForExactTokensLogic(msg.value, amountOut, path, to);
    }

    // --- PUBLIC/EXTERNAL SWAP FUNCTIONS (Normalized UI_DECIMALS) ---
    function swapExactTokensForTokensNormalized(
        uint amountInNormalized, uint amountOutMinNormalized, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amountsNormalized) {
        uint amountInNative = _toNativeDecimals(path[0], amountInNormalized);
        uint amountOutMinNative = _toNativeDecimals(path[path.length - 1], amountOutMinNormalized);
        uint[] memory nativeAmounts = _swapExactTokensForTokensLogic(amountInNative, path, to, amountOutMinNative);
        return _normalizeAmountsArray(path, nativeAmounts);
    }

    function swapTokensForExactTokensNormalized(
        uint amountOutNormalized, uint amountInMaxNormalized, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amountsNormalized) {
        uint amountOutNative = _toNativeDecimals(path[path.length - 1], amountOutNormalized);
        uint amountInMaxNative = _toNativeDecimals(path[0], amountInMaxNormalized);
        uint[] memory nativeAmounts = _swapTokensForExactTokensLogic(amountOutNative, path, to, amountInMaxNative);
        return _normalizeAmountsArray(path, nativeAmounts);
    }
    
    function swapExactCOREForTokensNormalized(
        uint amountOutMinNormalized, address[] calldata path, address to, uint deadline
    ) external payable ensure(deadline) lock returns (uint[] memory amountsNormalized) {
        require(msg.value > 0, "Router: NO_CORE_SWAP_IN_NORM");
        require(tokenDecimals[WCORE] == UI_DECIMALS, "Router: CORE norm assumes UI_DECIMALS eq WCORE_DECIMALS");
        uint amountOutMinNative = _toNativeDecimals(path[path.length-1], amountOutMinNormalized);
        // msg.value is already 18 decimals for native CORE
        uint[] memory nativeAmounts = _swapExactCOREForTokensLogic(msg.value, path, to, amountOutMinNative);
        return _normalizeAmountsArray(path, nativeAmounts);
    }

    function swapTokensForExactCORENormalized(
        uint amountOutCORENormalized, uint amountInMaxNormalized, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amountsNormalized) {
        require(tokenDecimals[WCORE] == UI_DECIMALS, "Router: CORE norm assumes UI_DECIMALS eq WCORE_DECIMALS");
        uint amountOutCoreNative = amountOutCORENormalized; // WCORE is 18 dec
        uint amountInMaxNative = _toNativeDecimals(path[0], amountInMaxNormalized);
        uint[] memory nativeAmounts = _swapTokensForExactCORELogic(amountOutCoreNative, path, to, amountInMaxNative);
        return _normalizeAmountsArray(path, nativeAmounts);
    }

    function swapExactTokensForCORENormalized(
        uint amountInNormalized, uint amountOutMinCORENormalized, address[] calldata path, address to, uint deadline
    ) external ensure(deadline) lock returns (uint[] memory amountsNormalized) {
        require(tokenDecimals[WCORE] == UI_DECIMALS, "Router: CORE norm assumes UI_DECIMALS eq WCORE_DECIMALS");
        uint amountInNative = _toNativeDecimals(path[0], amountInNormalized);
        uint amountOutMinCoreNative = amountOutMinCORENormalized; // WCORE is 18 dec
        uint[] memory nativeAmounts = _swapExactTokensForCORELogic(amountInNative, path, to, amountOutMinCoreNative);
        return _normalizeAmountsArray(path, nativeAmounts);
    }

    function swapCOREForExactTokensNormalized(
        uint amountOutNormalized, address[] calldata path, address to, uint deadline
    ) external payable ensure(deadline) lock returns (uint[] memory amountsNormalized) {
        require(msg.value > 0, "Router: NO_CORE_SWAP_OUT_EXACT_NORM");
        require(tokenDecimals[WCORE] == UI_DECIMALS, "Router: CORE norm assumes UI_DECIMALS eq WCORE_DECIMALS");
        uint amountOutNative = _toNativeDecimals(path[path.length-1], amountOutNormalized);
        uint[] memory nativeAmounts = _swapCOREForExactTokensLogic(msg.value, amountOutNative, path, to);
        return _normalizeAmountsArray(path, nativeAmounts);
    }

    // --- Watchlist, Voting, Trending Functions (Mostly Unchanged Structurally) ---
    // Ensure _getPoolInfoWithVotes and getPaginatedPoolInfo use native reserve values.
    function _getPoolInfoWithVotes(address pairAddress) private view returns (PoolInfo memory) {
        IRareBayV2Pair pairContract = IRareBayV2Pair(pairAddress);
        address t0 = address(0);
        address t1 = address(0);
        uint r0 = 0;
        uint r1 = 0;
        bool successFetchingTokens = false;
        try pairContract.token0() returns (address _t0) { t0 = _t0; successFetchingTokens = true; } catch {}
        if(successFetchingTokens) {
            try pairContract.token1() returns (address _t1) { t1 = _t1; } catch { successFetchingTokens = false; }
        }
        if (successFetchingTokens && t0 != address(0) && t1 != address(0)) {
            (r0, r1, ) = pairContract.getReserves();
        }
        VoteStats storage votes = pairVotes[pairAddress];
        return PoolInfo(pairAddress, t0, t1, r0, r1, votes.upvotes, votes.downvotes);
    }
    
    function addToWatchlist(address pair) external { /* ... original ... */ 
        require(pair != address(0), "Router: INVALID_PAIR");
        require(!_isPairWatchlisted[msg.sender][pair], "Router: ALREADY_WATCHLISTED");
        _userWatchlists[msg.sender].push(pair);
        _userWatchlistPairIndex[msg.sender][pair] = _userWatchlists[msg.sender].length;
        _isPairWatchlisted[msg.sender][pair] = true;
        emit PairWatchlisted(msg.sender, pair);
    }
    function removeFromWatchlist(address pair) external { /* ... original ... */ 
        require(_isPairWatchlisted[msg.sender][pair], "Router: NOT_WATCHLISTED");
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
    function getWatchlist(address user, uint256 page, uint256 size) external view returns (PoolInfo[] memory paginatedInfo) { /* ... original, uses _getPoolInfoWithVotes ... */
        require(page > 0, "Router: PAGE_MUST_BE_GT_ZERO");
        require(size > 0, "Router: SIZE_MUST_BE_GT_ZERO");
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
    function upvotePair(address pair) external { /* ... original, consider adding _addPairToActive if pair might not be active ... */ 
        require(pair != address(0), "Router: INVALID_PAIR_VOTE");
        int8 currentVote = _userVoteStatus[msg.sender][pair];
        require(currentVote != 1, "Router: ALREADY_UPVOTED");
        if (currentVote == -1) {
            if (pairVotes[pair].downvotes > 0) pairVotes[pair].downvotes--;
        }
        pairVotes[pair].upvotes++;
        _userVoteStatus[msg.sender][pair] = 1;
        // Attempt to add to active pairs if it's a valid pair and not yet active.
        // This requires knowing token0 and token1. A simple check could be:
        // if(!_isActivePair[pair]) { try IRareBayV2Pair(pair).token0() { _addPairToActive(pair); } catch {} }
        emit PairUpvoted(msg.sender, pair, pairVotes[pair].upvotes);
    }
    function downvotePair(address pair) external { /* ... original ... */ 
        require(pair != address(0), "Router: INVALID_PAIR_VOTE");
        int8 currentVote = _userVoteStatus[msg.sender][pair];
        require(currentVote != -1, "Router: ALREADY_DOWNVOTED");
        if (currentVote == 1) {
            if (pairVotes[pair].upvotes > 0) pairVotes[pair].upvotes--;
        }
        pairVotes[pair].downvotes++;
        _userVoteStatus[msg.sender][pair] = -1;
        emit PairDownvoted(msg.sender, pair, pairVotes[pair].downvotes);
    }
    function trendingPools(uint256 page, uint256 size) external view returns (PoolInfo[] memory paginatedInfo) { /* ... original, uses _getPoolInfoWithVotes ... */
        require(page > 0, "Router: PAGE_MUST_BE_GT_ZERO_TREND");
        require(size > 0, "Router: SIZE_MUST_BE_GT_ZERO_TREND");
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
    function getPaginatedPoolInfo(uint page, uint size) external view returns (PoolInfo[] memory) { /* ... original, uses _getPoolInfoWithVotes ... */
        require(page > 0, "Router: PAGE_MUST_BE_GT_ZERO_PAGINATED");
        require(size > 0, "Router: SIZE_MUST_BE_GT_ZERO_PAGINATED");
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

    // --- OPTIONAL: skim & sync wrappers (Unchanged) ---
    function skim(address tokenA, address tokenB, address to, uint deadline) external ensure(deadline) lock {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), "Router: PAIR_NOT_FOUND_SKIM");
        IRareBayV2Pair(pairAddress).skim(to);
    }
    function sync(address tokenA, address tokenB, uint deadline) external ensure(deadline) lock {
        address pairAddress = IRareBayV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), "Router: PAIR_NOT_FOUND_SYNC");
        IRareBayV2Pair(pairAddress).sync();
    }
}
