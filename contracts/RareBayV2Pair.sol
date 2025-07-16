// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import './RareBayV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IRareBayV2Factory.sol';
import './PriceOracle.sol';
import './libraries/ReentrancyGuard.sol';
import './libraries/SafeERC20.sol';

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

contract RareBayV2Pair is RareBayV2ERC20, ReentrancyGuard {
    using Math for uint;
    using UQ112x112 for uint224;
    using SafeERC20 for IERC20;

    // **** CONSTANTS ****
    uint public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint private constant FEE_DENOMINATOR = 10000;
    uint public constant fixedFee = 50; // Fixed fee of 0.5%
    uint public adjustableFee; // Owner-settable fee (in basis points), allowed between 10 and 50

    // **** STATE VARIABLES ****
    address public immutable factory;
    address public token0;
    address public token1;
    address public immutable owner; // Pool owner
    address public usdt;
    event USDTAddressUpdated(address indexed newUSDT);
    uint112 private reserve0; // Current reserve of token0
    uint112 private reserve1; // Current reserve of token1
    uint32 private blockTimestampLast; // Last block timestamp

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1

    // **** Fee & Dividend Variables (Extended lock period: 2 weeks) ****
    uint256 public dividendPerToken0Stored;
    uint256 public dividendPerToken1Stored;
    uint256 internal constant POINTS_MULTIPLIER = 1e32;
    mapping(address => uint256) public userDividendPerToken0Paid;
    mapping(address => uint256) public userDividendPerToken1Paid;
    mapping(address => uint256) public pendingDividends0;
    mapping(address => uint256) public pendingDividends1;
    mapping(address => uint256) public dividendLockTime; // Lock timestamp per LP

    RewardEpoch[] public ownerRewardEpochs0;
    RewardEpoch[] public ownerRewardEpochs1;
    uint256 public nextWithdrawalIndex0;
    uint256 public nextWithdrawalIndex1;
    uint public lastTotalFee;
    struct RewardEpoch {
        uint256 amount;
        uint256 unlockTime;
    }

    // **** Price Oracle ****
    PriceOracle public priceOracle;

    // **** EVENTS ****
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

    modifier onlyOwner() {
        require(msg.sender == owner, 'RareBayV2: NOT_OWNER');
        _;
    }

    constructor() {
        factory = msg.sender;
        owner = msg.sender;
        adjustableFee = 10; // Default adjustable fee = 0.1%
        usdt = 0xadAF5CC54ab7F0a254F2773fD9066C44b5D74078;
    }

    function setPriceOracle(address _priceOracle) external onlyOwner {
        require(_priceOracle != address(0), 'RareBayV2: ZERO_ADDRESS');
        priceOracle = PriceOracle(_priceOracle);
        emit PriceOracleSet(_priceOracle);
    }

    function setUSDTAddress(address _usdt) external onlyOwner {
        require(_usdt != address(0), 'RareBayV2: INVALID_USDT_ADDRESS');
        usdt = _usdt;
        emit USDTAddressUpdated(_usdt);
    }

    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'RareBayV2: FORBIDDEN');
        require(_token0 != address(0), 'RareBayV2: ZERO_ADDRESS');
        require(_token1 != address(0), 'RareBayV2: ZERO_ADDRESS');
        token0 = _token0;
        token1 = _token1;
    }

    function getTokenPriceInUSDT(address token) external view returns (uint price) {
        require(token == token0 || token == token1, 'RareBayV2: TOKEN_NOT_IN_PAIR');
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        require(token0 == usdt || token1 == usdt, 'RareBayV2: PAIR_DOES_NOT_INCLUDE_USDT');

        uint256 USDT_OUTPUT_DECIMALS_FACTOR = 1e6; // USDT has 6 decimals

        if (token0 == usdt) {
            require(_reserve1 > 0, 'RareBayV2: INSUFFICIENT_LIQUIDITY');
            return (uint(_reserve0).mul(USDT_OUTPUT_DECIMALS_FACTOR)).div(_reserve1);
        } else {
            require(_reserve0 > 0, 'RareBayV2: INSUFFICIENT_LIQUIDITY');
            return (uint(_reserve1).mul(USDT_OUTPUT_DECIMALS_FACTOR)).div(_reserve0);
        }
    }

    function swapTokens(
        uint inputAmount,
        address inputToken,
        address outputToken,
        address to,
        uint amountOutMin
    ) external nonReentrant {
        require(inputToken == token0 || inputToken == token1, 'RareBayV2: INVALID_INPUT_TOKEN');
        require(outputToken == token0 || outputToken == token1, 'RareBayV2: INVALID_OUTPUT_TOKEN');
        require(inputToken != outputToken, 'RareBayV2: IDENTICAL_TOKENS');

        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        uint amountOut = getAmountOut(inputAmount, inputToken);
        require(amountOut >= amountOutMin, 'RareBayV2: SLIPPAGE_TOO_HIGH');

        if (inputToken == token0) {
            this.swap(0, amountOut, to, '');
        } else {
            this.swap(amountOut, 0, to, '');
        }
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(bytes4(keccak256('transfer(address,uint256)')), to, value)
        );
        require(success, 'RareBayV2: TRANSFER_FAILED');
        if (data.length > 0) {
            (bool decoded) = abi.decode(data, (bool));
            require(decoded, 'RareBayV2: TRANSFER_FAILED');
        }
    }

    function _distributeFees(uint amount0In, uint amount1In) internal {
        lastTotalFee = adjustableFee.add(fixedFee);
        uint256 twoWeeks = 2 weeks;

        if (amount0In > 0) {
            uint feeOwner0 = (amount0In.mul(adjustableFee)).div(FEE_DENOMINATOR);
            if (totalSupply > 0) {
                uint256 dividendIncrease = (amount0In.mul(fixedFee).mul(POINTS_MULTIPLIER)).div(FEE_DENOMINATOR.mul(totalSupply));
                dividendPerToken0Stored = dividendPerToken0Stored.add(dividendIncrease);
            }

            if (
                ownerRewardEpochs0.length > 0 &&
                block.timestamp < ownerRewardEpochs0[ownerRewardEpochs0.length - 1].unlockTime
            ) {
                ownerRewardEpochs0[ownerRewardEpochs0.length - 1].amount = ownerRewardEpochs0[ownerRewardEpochs0.length - 1].amount.add(feeOwner0);
            } else {
                ownerRewardEpochs0.push(RewardEpoch({amount: feeOwner0, unlockTime: block.timestamp + twoWeeks}));
            }
        }

        if (amount1In > 0) {
            uint feeOwner1 = (amount1In.mul(adjustableFee)).div(FEE_DENOMINATOR);
            if (totalSupply > 0) {
                uint256 dividendIncrease = (amount1In.mul(fixedFee).mul(POINTS_MULTIPLIER)).div(FEE_DENOMINATOR.mul(totalSupply));
                dividendPerToken1Stored = dividendPerToken1Stored.add(dividendIncrease);
            }

            if (
                ownerRewardEpochs1.length > 0 &&
                block.timestamp < ownerRewardEpochs1[ownerRewardEpochs1.length - 1].unlockTime
            ) {
                ownerRewardEpochs1[ownerRewardEpochs1.length - 1].amount = ownerRewardEpochs1[ownerRewardEpochs1.length - 1].amount.add(feeOwner1);
            } else {
                ownerRewardEpochs1.push(RewardEpoch({amount: feeOwner1, unlockTime: block.timestamp + twoWeeks}));
            }
        }
    }

    function _updateAccountDividend(address account) internal {
        uint256 owing0 = balanceOf[account].mul(dividendPerToken0Stored.sub(userDividendPerToken0Paid[account])).div(POINTS_MULTIPLIER);
        uint256 owing1 = balanceOf[account].mul(dividendPerToken1Stored.sub(userDividendPerToken1Paid[account])).div(POINTS_MULTIPLIER);
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

    function setAdjustableFee(uint _fee) external onlyOwner {
        require(_fee >= 10 && _fee <= 50, 'RareBayV2: FEE_OUT_OF_RANGE');
        adjustableFee = _fee;
        emit AdjustFee(_fee);
    }

    function withdrawOwnerRewards() external onlyOwner nonReentrant {
        uint256 amountToWithdraw0 = 0;
        uint256 amountToWithdraw1 = 0;

        for (uint256 i = nextWithdrawalIndex0; i < ownerRewardEpochs0.length; i++) {
            if (block.timestamp >= ownerRewardEpochs0[i].unlockTime) {
                amountToWithdraw0 = amountToWithdraw0.add(ownerRewardEpochs0[i].amount);
                ownerRewardEpochs0[i].amount = 0;
                nextWithdrawalIndex0 = i + 1;
            } else {
                break;
            }
        }

        for (uint256 i = nextWithdrawalIndex1; i < ownerRewardEpochs1.length; i++) {
            if (block.timestamp >= ownerRewardEpochs1[i].unlockTime) {
                amountToWithdraw1 = amountToWithdraw1.add(ownerRewardEpochs1[i].amount);
                ownerRewardEpochs1[i].amount = 0;
                nextWithdrawalIndex1 = i + 1;
            } else {
                break;
            }
        }

        require(amountToWithdraw0 > 0 || amountToWithdraw1 > 0, 'RareBayV2: NO_UNLOCKED_REWARDS');

        if (amountToWithdraw0 > 0) {
            _safeTransfer(token0, owner, amountToWithdraw0);
        }
        if (amountToWithdraw1 > 0) {
            _safeTransfer(token1, owner, amountToWithdraw1);
        }

        emit OwnerRewardsWithdrawn(amountToWithdraw0, amountToWithdraw1);
    }

    function withdrawDividends() external nonReentrant {
        _updateAccountDividend(msg.sender);
        require(block.timestamp >= dividendLockTime[msg.sender], 'RareBayV2: DIVIDENDS_LOCKED');
        uint256 amount0 = pendingDividends0[msg.sender];
        uint256 amount1 = pendingDividends1[msg.sender];
        require(amount0 > 0 || amount1 > 0, 'RareBayV2: NO_DIVIDENDS');
        pendingDividends0[msg.sender] = 0;
        pendingDividends1[msg.sender] = 0;
        dividendLockTime[msg.sender] = block.timestamp + 2 weeks;
        _safeTransfer(token0, msg.sender, amount0);
        _safeTransfer(token1, msg.sender, amount1);
        emit DividendsWithdrawn(msg.sender, amount0, amount1);
    }

    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, 'RareBayV2: OVERFLOW');

        uint32 _blockTimestamp = uint32(block.timestamp);
        uint32 timeElapsed = _blockTimestamp - blockTimestampLast;

        require(timeElapsed < 1 days, 'RareBayV2: INVALID_TIME_ELAPSED');

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            price0CumulativeLast = price0CumulativeLast.add(uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)).mul(timeElapsed));
            price1CumulativeLast = price1CumulativeLast.add(uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)).mul(timeElapsed));
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

    function mint(address to) external nonReentrant returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply;
        if (_totalSupply <= 0) {
            uint product = amount0.mul(amount1);
            require(product / amount0 >= amount1, 'RareBayV2: MULTIPLICATION_OVERFLOW');
            uint sqrtProduct = Math.sqrt(product);
            require(sqrtProduct >= MINIMUM_LIQUIDITY, 'RareBayV2: INSUFFICIENT_LIQUIDITY_FOR_MINIMUM');
            liquidity = sqrtProduct.sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            uint liquidity0 = (amount0.mul(_totalSupply)).div(_reserve0);
            uint liquidity1 = (amount1.mul(_totalSupply)).div(_reserve1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
        require(liquidity > 0, 'RareBayV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _updateAccountDividend(to);
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) {
            uint256 newK = uint256(reserve0).mul(reserve1);
            require(newK / reserve0 >= reserve1, 'RareBayV2: K_OVERFLOW');
            kLast = newK;
        }
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external nonReentrant returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        require(totalSupply > 0, 'RareBayV2: TOTAL_SUPPLY_ZERO');
        require(liquidity <= totalSupply, 'RareBayV2: LIQUIDITY_EXCEEDS_SUPPLY');

        uint _totalSupply = totalSupply;
        amount0 = (liquidity.mul(balance0)).div(_totalSupply);
        amount1 = (liquidity.mul(balance1)).div(_totalSupply);
        require(amount0 > 0 && amount1 > 0, 'RareBayV2: INSUFFICIENT_LIQUIDITY_BURNED');

        _burn(address(this), liquidity);
        uint newK = (balance0.sub(amount0)).mul(balance1.sub(amount1));
        require(newK / (balance0.sub(amount0)) >= (balance1.sub(amount1)), 'RareBayV2: K_OVERFLOW');
        _update(balance0.sub(amount0), balance1.sub(amount1), _reserve0, _reserve1);
        kLast = newK;

        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external nonReentrant {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        require(amount0Out > 0 || amount1Out > 0, 'RareBayV2: INSUFFICIENT_OUTPUT_AMOUNT');
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'RareBayV2: INSUFFICIENT_LIQUIDITY');

        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'RareBayV2: INVALID_TO');

        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint amount0In = balance0 > uint(_reserve0).sub(amount0Out) ? balance0.sub(uint(_reserve0).sub(amount0Out)) : 0;
        uint amount1In = balance1 > uint(_reserve1).sub(amount1Out) ? balance1.sub(uint(_reserve1).sub(amount1Out)) : 0;
        require(amount0In > 0 || amount1In > 0, 'RareBayV2: INSUFFICIENT_INPUT_AMOUNT');

        uint totalFee = adjustableFee.add(fixedFee);
        require(totalFee <= FEE_DENOMINATOR, 'RareBayV2: TOTAL_FEE_TOO_HIGH');
        uint balance0Adjusted = balance0.mul(FEE_DENOMINATOR).sub(amount0In.mul(totalFee));
        uint balance1Adjusted = balance1.mul(FEE_DENOMINATOR).sub(amount1In.mul(totalFee));
        require(
            balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(FEE_DENOMINATOR ** 2),
            'RareBayV2: K'
        );

        _distributeFees(amount0In, amount1In);
        _update(balance0, balance1, _reserve0, _reserve1);

        if (address(priceOracle) != address(0) && balance0 > 0) {
            bool isBuy = amount0Out > 0;
            uint256 newPrice = (balance1.mul(priceOracle.PRECISION())).div(balance0);
            require(newPrice > 0, 'RareBayV2: INVALID_PRICE');
            uint256 inputAmount = isBuy ? amount1In : amount0In;
            uint256 receivedAmount = isBuy ? amount0Out : amount1Out;
            priceOracle.updatePrice(token0, token1, newPrice, isBuy, inputAmount, receivedAmount);
        }

        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
        if (data.length > 0) IRareBayV2Callee(to).RareBayV2Call(msg.sender, amount0Out, amount1Out, data);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function getAmountOut(uint amountIn, address tokenIn) public view returns (uint amountOut) {
        require(tokenIn == token0 || tokenIn == token1, 'RareBayV2: INVALID_TOKEN');
        (uint112 reserveIn, uint112 reserveOut) = tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        require(reserveIn > 0 && reserveOut > 0, 'RareBayV2: INSUFFICIENT_LIQUIDITY');
        uint totalFee = adjustableFee.add(fixedFee);
        require(totalFee < FEE_DENOMINATOR, 'RareBayV2: FEE_TOO_HIGH');
        uint amountInWithFee = amountIn.mul(FEE_DENOMINATOR.sub(totalFee));
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = uint(reserveIn).mul(FEE_DENOMINATOR).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    function getAmountIn(uint amountOut, address tokenOut) external view returns (uint amountIn) {
        require(amountOut > 0, 'RareBayV2: INSUFFICIENT_OUTPUT');
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        (uint reserveIn, uint reserveOut) = tokenOut == token1
            ? (uint(_reserve0), uint(_reserve1))
            : (uint(_reserve1), uint(_reserve0));
        uint totalFee = adjustableFee.add(fixedFee);
        require(totalFee < FEE_DENOMINATOR, 'RareBayV2: FEE_TOO_HIGH');
        uint numerator = reserveIn.mul(amountOut).mul(FEE_DENOMINATOR);
        uint denominator = reserveOut.sub(amountOut).mul(FEE_DENOMINATOR.sub(totalFee));
        amountIn = (numerator / denominator).add(1);
    }

    function skim(address to) external nonReentrant {
        address _token0 = token0;
        address _token1 = token1;
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    function sync() external nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    function getUserLiquidity(address user) external view returns (uint) {
        return balanceOf[user];
    }
}
