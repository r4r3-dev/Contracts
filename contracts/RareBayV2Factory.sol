// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import './interfaces/IRareBayV2Factory.sol';
import './RareBayV2Pair.sol';
import "./interfaces/IRareBayV2Pair.sol";
import "./PriceOracle.sol";

contract RareBayV2Factory is IRareBayV2Factory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    mapping(address => address) public pairOracles;

    struct UserPosition {
        address pair;
        uint liquidity;
        uint pendingDividends0;
        uint pendingDividends1;
    }

    event OracleSet(address indexed pair, address indexed oracle);
    event AdjustableFeeSet(address indexed pair, uint fee);

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function setAdjustableFee(address pair, uint _fee) external {
        require(msg.sender == feeToSetter, 'RareBayV2: FORBIDDEN');
        IRareBayV2Pair(pair).setAdjustableFee(_fee);
        emit AdjustableFeeSet(pair, _fee);
    }

    function setPriceOracle(address pair, address oracle) external {
        require(msg.sender == feeToSetter, 'RareBayV2: FORBIDDEN');
        require(pair != address(0) && oracle != address(0), 'RareBayV2: INVALID_ADDRESS');
        require(allPairs.length > 0, 'RareBayV2: NO_PAIRS');
        bool isValidPair = false;
        for (uint i = 0; i < allPairs.length; i++) {
            if (allPairs[i] == pair) {
                isValidPair = true;
                break;
            }
        }
        require(isValidPair, 'RareBayV2: INVALID_PAIR');
        _setPairOracle(pair, oracle);
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function getPairOracle(address pair) external view returns (address) {
        return pairOracles[pair];
    }

    function _setPairOracle(address pair, address oracle) internal {
        pairOracles[pair] = oracle;
        IRareBayV2Pair(pair).setPriceOracle(oracle);
        emit OracleSet(pair, oracle);
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'RareBayV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'RareBayV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'RareBayV2: PAIR_EXISTS');
        
        bytes memory bytecode = type(RareBayV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        
        IRareBayV2Pair(pair).initialize(token0, token1);
        
        PriceOracle oracle = new PriceOracle(pair);
        _setPairOracle(pair, address(oracle));

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'RareBayV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'RareBayV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function getUserPositions(address user) external view returns (UserPosition[] memory positions) {
        uint count = 0;
        for (uint i = 0; i < allPairs.length; i++) {
            uint liquidity = IRareBayV2Pair(allPairs[i]).balanceOf(user);
            if (liquidity > 0) count++;
        }
        
        positions = new UserPosition[](count);
        uint index = 0;
        for (uint i = 0; i < allPairs.length; i++) {
            IRareBayV2Pair pair = IRareBayV2Pair(allPairs[i]);
            uint liquidity = pair.balanceOf(user);
            if (liquidity > 0) {
                positions[index] = UserPosition({
                    pair: allPairs[i],
                    liquidity: liquidity,
                    pendingDividends0: pair.pendingDividends0(user),
                    pendingDividends1: pair.pendingDividends1(user)
                });
                index++;
            }
        }
    }
}