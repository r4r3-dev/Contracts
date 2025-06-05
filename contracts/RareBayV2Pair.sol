// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RareBayV2ERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IRareBayV2Factory.sol";
import "./PriceOracle.sol";

/*
██████╗  █████╗ ██████╗ ███████╗██████╗  █████╗ ██╗   ██╗
██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔══██╗╚██╗ ██╔╝
██████╔╝███████║██████╔╝█████╗  ██████╔╝███████║ ╚████╔╝ 
██╔══██╗██╔══██║██╔══██╗██╔══╝  ██╔══██╗██╔══██║  ╚██╔╝  
██║  ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║   ██║   
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝   ╚═╝                                                         
*/

interface IRareBayV2Callee {
    function RareBayV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external;
}

contract RareBayV2Pair is RareBayV2ERC20 {
    using SafeMath for uint;
    using UQ112x112 for uint224;

    // **** CONSTANTS ****
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    uint private constant FEE_DENOMINATOR = 10000;
    uint public fixedFee = 50; // fixed fee of 0.5%
    uint public adjustableFee; // owner-settable fee (in basis points), allowed between 10 and 50

    // **** STATE VARIABLES ****
    address public factory;
    address public token0;
    address public token1;
    address public owner; // pool owner

    uint112 private reserve0;  // current reserve of token0
    uint112 private reserve1;  // current reserve of token1
    uint32  private blockTimestampLast; // last block timestamp

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1

    // **** Fee & Dividend Variables (Extended lock period: 2 weeks) ****
    uint256 public dividendPerToken0Stored;
    uint256 public dividendPerToken1Stored;
    uint256 constant internal POINTS_MULTIPLIER = 1e32;
    mapping(address => uint256) public userDividendPerToken0Paid;
    mapping(address => uint256) public userDividendPerToken1Paid;
    mapping(address => uint256) public pendingDividends0;
    mapping(address => uint256) public pendingDividends1;
    mapping(address => uint256) public dividendLockTime;  // lock timestamp per LP

    uint256 public ownerReward0;
    uint256 public ownerReward1;
    uint256 public ownerRewardLockTimestamp; // owner rewards locked for 2 weeks
    uint256 public ownerWithdrawn0;
    uint256 public ownerWithdrawn1;

    // **** New Public Variable for Total Fees ****
    // This variable will store the sum of adjustableFee and fixedFee
    uint public lastTotalFee;

    // **** Price Oracle ****
    PriceOracle public priceOracle;
    
    // **** EVENTS ****
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(address indexed sender, uint amount0In, uint amount1In, uint amount0Out, uint amount1Out, address indexed to);
    event Sync(uint112 reserve0, uint112 reserve1);
    event AdjustFee(uint newAdjustableFee);
    event OwnerRewardsWithdrawn(uint amount0, uint amount1);
    event DividendsWithdrawn(address indexed user, uint amount0, uint amount1);
    event PriceOracleSet(address indexed priceOracle);

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "RareBayV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "RareBayV2: NOT_OWNER");
        _;
    }

    // **** CONSTRUCTOR ****
    constructor() {
        factory = msg.sender;
        owner = msg.sender;
        adjustableFee = 10; // default adjustable fee = 0.1%
    }

    /**
     * @notice Sets the PriceOracle contract address.
     * @param _priceOracle The address of the deployed PriceOracle.
     */
    function setPriceOracle(address _priceOracle) external onlyOwner {
        priceOracle = PriceOracle(_priceOracle);
        emit PriceOracleSet(_priceOracle);
    }

    // Called once by the factory at deployment.
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "RareBayV2: FORBIDDEN");
        token0 = _token0;
        token1 = _token1;
    }

        /**
     * @notice Returns the price of a token in USDT, calculated using reserves.
     * @param token The address of the token to get the price for.
     * @return price The price of the token in USDT (scaled by 1e18 for precision).
     */
    function getTokenPriceInUSDT(address token) external view returns (uint price) {
        require(token == token0 || token == token1, "RareBayV2: TOKEN_NOT_IN_PAIR");

        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();

        // Determine if USDT is in the pair
        address usdt = 0x809F26F719c0Cd95d64A1cbCE6C34B67E1613498; // USDT address
        require(token0 == usdt || token1 == usdt, "RareBayV2: PAIR_DOES_NOT_INCLUDE_USDT");

        if (token0 == usdt) {
            // USDT is token0, price of token1 in USDT
            require(_reserve1 > 0, "RareBayV2: INSUFFICIENT_LIQUIDITY");
            return uint(_reserve0) * 1e18 / _reserve1; // price of token1 in USDT
        } else {
            // USDT is token1, price of token0 in USDT
            require(_reserve0 > 0, "RareBayV2: INSUFFICIENT_LIQUIDITY");
            return uint(_reserve1) * 1e18 / _reserve0; // price of token0 in USDT
        }
    }

/**
 * @notice Swaps an exact amount of input tokens for the calculated output tokens.
 * @param inputAmount The amount of input tokens to swap.
 * @param inputToken The address of the input token (must be token0 or token1).
 * @param outputToken The address of the output token (must be the other token in the pair).
 * @param to The address to receive the output tokens.
 */
function swapTokens(
    uint inputAmount,
    address inputToken,
    address outputToken,
    address to,
    uint amountOutMin
) external { // Add lock modifier here
    require(inputToken == token0 || inputToken == token1, "RareBayV2: INVALID_INPUT_TOKEN");
    require(outputToken == token0 || outputToken == token1, "RareBayV2: INVALID_OUTPUT_TOKEN");
    require(inputToken != outputToken, "RareBayV2: IDENTICAL_TOKENS");

    // Transfer input tokens from the user to the contract
    IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);

    // Calculate the expected output amount using the current reserves
    uint amountOut = getAmountOut(inputAmount, inputToken);
    require(amountOut >= amountOutMin, "RareBayV2: SLIPPAGE_TOO_HIGH"); // Check slippage

    // Execute the swap with the calculated output amount
    if (inputToken == token0) {
        this.swap(0, amountOut, to, ""); // Use this.swap for external call
    } else {
        this.swap(amountOut, 0, to, ""); // Use this.swap for external call
    }
}
    /**
     * @notice Returns the current reserves and last block timestamp.
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /**
     * @notice Internal safe transfer function.
     */
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "RareBayV2: TRANSFER_FAILED");
    }

    // **** FEE & DIVIDEND LOGIC WITH EXTENDED LOCKS ****

    /**
     * @notice Distributes fees into owner rewards and dividends.
     * Updates lastTotalFee so that users can see the total fee.
     * Newly accrued fees are locked for 2 weeks.
     * @param amount0In Input amount for token0.
     * @param amount1In Input amount for token1.
     */
    function _distributeFees(uint amount0In, uint amount1In) internal {
        // Compute and store the total fee to be visible externally.
        lastTotalFee = adjustableFee.add(fixedFee);

        if (amount0In > 0) {
        // Ensure no overflow in fee calculations
        uint feeOwner0 = (amount0In * adjustableFee) / FEE_DENOMINATOR;  // Safe as long as FEE_DENOMINATOR > adjustableFee
        uint feeDividend0 = (amount0In * fixedFee) / FEE_DENOMINATOR;  // Safe as long as FEE_DENOMINATOR > fixedFee
        
        // Check for overflow before adding to existing rewards
        require(ownerReward0 + feeOwner0 >= ownerReward0, "RareBayV2: OWNER_REWARD_OVERFLOW");
        ownerReward0 += feeOwner0;

        if (totalSupply > 0) {
            // Check for overflow in multiplication and division
            uint256 dividendIncrease = (feeDividend0 * POINTS_MULTIPLIER) / totalSupply;
            require(dividendPerToken0Stored + dividendIncrease >= dividendPerToken0Stored, "RareBayV2: DIVIDEND_OVERFLOW");
            dividendPerToken0Stored += dividendIncrease;
        }
    }

    if (amount1In > 0) {
        // Similar checks for token1
        uint feeOwner1 = (amount1In * adjustableFee) / FEE_DENOMINATOR;
        uint feeDividend1 = (amount1In * fixedFee) / FEE_DENOMINATOR;
        
        require(ownerReward1 + feeOwner1 >= ownerReward1, "RareBayV2: OWNER_REWARD_OVERFLOW");
        ownerReward1 += feeOwner1;

        if (totalSupply > 0) {
            uint256 dividendIncrease = (feeDividend1 * POINTS_MULTIPLIER) / totalSupply;
            require(dividendPerToken1Stored + dividendIncrease >= dividendPerToken1Stored, "RareBayV2: DIVIDEND_OVERFLOW");
            dividendPerToken1Stored += dividendIncrease;
        }
    }

    // This should be safe as block.timestamp is always increasing and 2 weeks is a reasonable time frame
    if (block.timestamp >= ownerRewardLockTimestamp) {
        ownerRewardLockTimestamp = block.timestamp + 2 weeks;
    }
    }

    /**
     * @notice Updates an LP's dividend accrual.
     * Newly accrued dividends extend the lock period to 2 weeks from now.
     * @param account The liquidity provider's address.
     */
    function _updateAccountDividend(address account) internal {
        uint256 owing0 = balanceOf[account]
            .mul(dividendPerToken0Stored - userDividendPerToken0Paid[account])
            / POINTS_MULTIPLIER;
        uint256 owing1 = balanceOf[account]
            .mul(dividendPerToken1Stored - userDividendPerToken1Paid[account])
            / POINTS_MULTIPLIER;
        if (owing0 > 0 || owing1 > 0) {
            pendingDividends0[account] = pendingDividends0[account].add(owing0);
            pendingDividends1[account] = pendingDividends1[account].add(owing1);
            if (dividendLockTime[account] < block.timestamp + 2 weeks) {
                dividendLockTime[account] = block.timestamp + 2 weeks;
            }
        }
        userDividendPerToken0Paid[account] = dividendPerToken0Stored;
        userDividendPerToken1Paid[account] = dividendPerToken1Stored;
    }

    // **** OWNER FUNCTIONS ****

    function setAdjustableFee(uint _fee) external onlyOwner {
        require(_fee >= 10 && _fee <= 50, "RareBayV2: FEE_OUT_OF_RANGE");
        adjustableFee = _fee;
        emit AdjustFee(_fee);
    }

    /**
     * @notice Withdraws unlocked owner rewards.
     */
    function withdrawOwnerRewards() external onlyOwner {
        uint256 unlocked0 = _calculateOwnerUnlocked(ownerReward0, ownerWithdrawn0);
        uint256 unlocked1 = _calculateOwnerUnlocked(ownerReward1, ownerWithdrawn1);
        require(unlocked0 > 0 || unlocked1 > 0, "RareBayV2: NO_UNLOCKED_REWARDS");
        if (unlocked0 > 0) {
            ownerWithdrawn0 = ownerWithdrawn0.add(unlocked0);
            _safeTransfer(token0, owner, unlocked0);
        }
        if (unlocked1 > 0) {
            ownerWithdrawn1 = ownerWithdrawn1.add(unlocked1);
            _safeTransfer(token1, owner, unlocked1);
        }
        emit OwnerRewardsWithdrawn(unlocked0, unlocked1);
    }

    /**
     * @notice Calculates how much owner reward is unlocked.
     * @param totalReward Total owner reward accrued.
     * @param alreadyWithdrawn Amount already withdrawn.
     * @return The unlocked amount.
     */
    function _calculateOwnerUnlocked(uint256 totalReward, uint256 alreadyWithdrawn) internal view returns (uint256) {
        if (block.timestamp < ownerRewardLockTimestamp) {
            return 0;
        }
        if (totalReward <= alreadyWithdrawn) return 0;
        return totalReward - alreadyWithdrawn;
    }

    /**
     * @notice Allows an LP to withdraw pending dividends if the lock has expired.
     */
    function withdrawDividends() external {
        _updateAccountDividend(msg.sender);
        require(block.timestamp >= dividendLockTime[msg.sender], "RareBayV2: DIVIDENDS_LOCKED");
        uint256 amount0 = pendingDividends0[msg.sender];
        uint256 amount1 = pendingDividends1[msg.sender];
        require(amount0 > 0 || amount1 > 0, "RareBayV2: NO_DIVIDENDS");
        pendingDividends0[msg.sender] = 0;
        pendingDividends1[msg.sender] = 0;
        dividendLockTime[msg.sender] = block.timestamp + 2 weeks;
        _safeTransfer(token0, msg.sender, amount0);
        _safeTransfer(token1, msg.sender, amount1);
        emit DividendsWithdrawn(msg.sender, amount0, amount1);
    }

    // **** CORE FUNCTIONS (mint, burn, swap, skim, sync) ****

    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "RareBayV2: OVERFLOW");
        uint32 _blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = _blockTimestamp - blockTimestampLast;
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = _blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IRareBayV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /**
     * @notice Mints liquidity tokens by depositing token0 and token1.
     * @param to Recipient address.
     * @return liquidity Amount of liquidity tokens minted.
     */
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0 - _reserve0;
        uint amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply;
         if (_totalSupply == 0) {
        // Here, we need to ensure that the multiplication doesn't overflow before taking the square root
        uint product = amount0 * amount1;  // This multiplication might overflow, so we'll check
        require(product / amount0 == amount1, "RareBayV2: MULTIPLICATION_OVERFLOW");  // Check for overflow before sqrt
        
        uint sqrtProduct = Math.sqrt(product);
        require(sqrtProduct >= MINIMUM_LIQUIDITY, "RareBayV2: INSUFFICIENT_LIQUIDITY_FOR_MINIMUM");
        liquidity = sqrtProduct - MINIMUM_LIQUIDITY;
        _mint(address(0), MINIMUM_LIQUIDITY);  // This minting is safe due to the check above
    } else {
        // For subsequent mints, ensure division doesn't underflow
        uint liquidity0 = (amount0 * _totalSupply) / _reserve0;
        uint liquidity1 = (amount1 * _totalSupply) / _reserve1;
        liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
    }
        require(liquidity > 0, "RareBayV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _updateAccountDividend(to);
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
         if (feeOn) {
        // Ensure the multiplication for kLast doesn't overflow
        uint256 newK = uint256(reserve0) * reserve1;
        require(newK / reserve0 == reserve1, "RareBayV2: K_OVERFLOW");
        kLast = newK;
    }
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @notice Burns liquidity tokens and returns underlying tokens.
     * @param to Recipient address.
     * @return amount0 Amount of token0 returned.
     * @return amount1 Amount of token1 returned.
     */
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply;
        // Check for division by zero and overflow in multiplication
        require(_totalSupply > 0, "RareBayV2: TOTAL_SUPPLY_ZERO");
        require(liquidity <= _totalSupply, "RareBayV2: LIQUIDITY_EXCEEDS_SUPPLY");
        amount0 = liquidity * balance0 / _totalSupply;
        amount1 = liquidity * balance1 / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "RareBayV2: INSUFFICIENT_LIQUIDITY_BURNED");
         // Check if burning doesn't cause underflow in total supply
         require(_totalSupply >= liquidity, "RareBayV2: BURN_EXCEEDS_SUPPLY");
        _updateAccountDividend(msg.sender);
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) {
        // Check for overflow when calculating kLast
        uint256 newK = uint256(reserve0) * reserve1;
        require(newK / reserve0 == reserve1, "RareBayV2: K_OVERFLOW");
        kLast = newK;
    }
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * @notice Swaps tokens, updates the PriceOracle, and enforces invariant.
     * @param amount0Out Amount of token0 to send out.
     * @param amount1Out Amount of token1 to send out.
     * @param to Recipient address.
     * @param data Callback data for flash swaps.
     */
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "RareBayV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "RareBayV2: INSUFFICIENT_LIQUIDITY");

        uint balance0;
        uint balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "RareBayV2: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
            if (data.length > 0)
                IRareBayV2Callee(to).RareBayV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "RareBayV2: INSUFFICIENT_INPUT_AMOUNT");

        uint totalFee = adjustableFee.add(fixedFee);
        require(totalFee <= FEE_DENOMINATOR, "RareBayV2: TOTAL_FEE_TOO_HIGH");
        uint balance0Adjusted = balance0 * FEE_DENOMINATOR - amount0In * totalFee;
        uint balance1Adjusted = balance1 * FEE_DENOMINATOR - amount1In * totalFee;
        require(
            balance0Adjusted * balance1Adjusted >= uint(_reserve0) * _reserve1 * (FEE_DENOMINATOR ** 2),
            "RareBayV2: K"
        );

        _distributeFees(amount0In, amount1In);

       if (address(priceOracle) != address(0) && balance0 > 0) {
        bool isBuy = amount0Out > 0;
        uint256 newPrice = (balance1 * priceOracle.PRECISION()) / balance0;
        uint256 inputAmount = isBuy ? amount1In : amount0In; 
        uint256 receivedAmount = isBuy ? amount0Out : amount1Out;
        priceOracle.updatePrice(token0, token1, newPrice, isBuy, inputAmount, receivedAmount);
    }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }
     /**
     * @notice Calculates the output amount for a given input amount and token.
     * @param amountIn The input amount of the token.
     * @param tokenIn The address of the input token (either token0 or token1).
     * @return amountOut The output amount of the other token after fees.
     */
    function getAmountOut(uint amountIn, address tokenIn) public view returns (uint amountOut) {
        require(tokenIn == token0 || tokenIn == token1, "RareBayV2: INVALID_TOKEN");
        (uint112 reserveIn, uint112 reserveOut) = tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        require(reserveIn > 0 && reserveOut > 0, "RareBayV2: INSUFFICIENT_LIQUIDITY");
        uint totalFee = adjustableFee + (fixedFee);
        require(totalFee < FEE_DENOMINATOR, "RareBayV2: FEE_TOO_HIGH");
        uint amountInWithFee = amountIn*(FEE_DENOMINATOR-(totalFee));
        uint numerator = amountInWithFee*(reserveOut);
        uint denominator = reserveIn * (FEE_DENOMINATOR)+(amountInWithFee);
        amountOut = numerator/(denominator);
    }

 /**
     * @notice Given a desired output amount of one token, returns the required input amount of the other token.
     * @param amountOut The desired output token amount
     * @param tokenOut The address of the output token (must be token0 or token1)
     */
    function getAmountIn(uint amountOut, address tokenOut) external view returns (uint amountIn) {
        require(amountOut > 0, "RareBayV2: INSUFFICIENT_OUTPUT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        (uint reserveIn, uint reserveOut) = tokenOut == token1
            ? (uint(_reserve0), uint(_reserve1))
            : (uint(_reserve1), uint(_reserve0));
        uint totalFee = adjustableFee + fixedFee;
        require(totalFee < FEE_DENOMINATOR, "RareBayV2: FEE_TOO_HIGH");
        uint numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint denominator = (reserveOut - amountOut) * (FEE_DENOMINATOR - totalFee);
        amountIn = (numerator / denominator) + 1;
    }

    function skim(address to) external lock {
        address _token0 = token0;
        address _token1 = token1;
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)) - reserve0);
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)) - reserve1);
    }

    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

      /**
     * @notice Calculates the total liquidity provided by a specific user.
     * @param user The address of the user whose liquidity is being checked.
     * @return The amount of liquidity tokens held by the user.
     */
    function getUserLiquidity(address user) external view returns (uint) {
        return balanceOf[user];
    }
}
