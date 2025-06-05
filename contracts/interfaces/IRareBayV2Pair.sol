// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IRareBayV2Pair {
    // --- ERC20 ---
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    // --- ERC2612 Permit ---
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);
    function permit(
        address owner,
        address spender,
        uint value,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    // --- Core state getters ---
    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fixedFee() external view returns (uint);
    function adjustableFee() external view returns (uint);
    function reserve0() external view returns (uint112);
    function reserve1() external view returns (uint112);
    function blockTimestampLast() external view returns (uint32);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    // --- Dividend & fee tracking getters ---
    function dividendPerToken0Stored() external view returns (uint256);
    function dividendPerToken1Stored() external view returns (uint256);
    function userDividendPerToken0Paid(address) external view returns (uint256);
    function userDividendPerToken1Paid(address) external view returns (uint256);
    function pendingDividends0(address user) external view returns (uint256);
    function pendingDividends1(address user) external view returns (uint256);
    function dividendLockTime(address) external view returns (uint256);
    function ownerReward0() external view returns (uint256);
    function ownerReward1() external view returns (uint256);
    function ownerRewardLockTimestamp() external view returns (uint256);
    function ownerWithdrawn0() external view returns (uint256);
    function ownerWithdrawn1() external view returns (uint256);
    function lastTotalFee() external view returns (uint);

    function priceOracle() external view returns (address);

    // --- Limit order struct/getter ---
    struct LimitOrder {
        uint    inputAmount;
        address inputToken;
        address outputToken;
        address to;
        address owner;
        uint    limitPrice;
        uint    expiration;
        bool    isBuy;
        uint8   status;
    }
    function limitOrders(uint orderId)
        external
        view
        returns (
            uint    inputAmount,
            address inputToken,
            address outputToken,
            address to,
            address owner,
            uint    limitPrice,
            uint    expiration,
            bool    isBuy,
            uint8   status
        );
    function nextOrderId() external view returns (uint);

    // --- Initialization & owner ops ---
    function initialize(address _token0, address _token1) external;
    function setPriceOracle(address _priceOracle) external;
    function setAdjustableFee(uint _fee) external;
    function withdrawOwnerRewards() external;
    function withdrawDividends() external;

    // --- Core liquidity & swap ---
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32  blockTimestampLast
        );

    /// @notice Given `amountIn` of `tokenIn`, returns `amountOut` of the other token.
    function getAmountOut(uint amountIn, address tokenIn)
        external
        view
        returns (uint amountOut);

    /// @notice Given desired `amountOut` of `tokenOut`, returns required `amountIn`.
    function getAmountIn(uint amountOut, address tokenOut)
        external
        view
        returns (uint amountIn);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    // --- User helpers ---
    function getUserLiquidity(address user) external view returns (uint);

    // --- Events ---
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event AdjustFee(uint newAdjustableFee);
    event OwnerRewardsWithdrawn(uint amount0, uint amount1);
    event DividendsWithdrawn(address indexed user, uint amount0, uint amount1);
    event PriceOracleSet(address indexed priceOracle);
    event OrderCreated(
        uint indexed orderId,
        address indexed owner,
        uint inputAmount,
        address inputToken,
        address outputToken,
        address to,
        uint limitPrice,
        uint expiration,
        bool isBuy
    );
    event OrderExecuted(uint indexed orderId, address indexed executor);
    event OrderCanceled(uint indexed orderId);
}
