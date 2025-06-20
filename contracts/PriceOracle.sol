// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Price Oracle
 * @dev Enhanced TWAP implementation with price history and transaction tracking including amounts.
 *      Now supports calculating prices both ways by respecting the input order of tokenA and tokenB.
 */
contract PriceOracle {
    struct PriceData {
        uint256 cumulativePrice;
        uint256 lastPrice;
        uint256 timestamp;
        uint256[] priceHistory; // Stores historical prices for charting
        uint256[] historyTimestamps; // Stores timestamps for price history
    }

    struct TransactionData {
        uint256 buyCount; // Number of buys (token1 -> token2)
        uint256 sellCount; // Number of sells (token2 -> token1)
        uint256 lastUpdated;
        uint256[] inputAmounts;    // Stores the input amounts for each transaction
        uint256[] receivedAmounts; // Stores the received amounts for each transaction
        uint256[] txTimestamps;    // Stores the transaction timestamps
    }

    uint256 public constant WINDOW_SIZE = 24 hours;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_STALE = 1 hours;
    uint256 public constant HISTORY_INTERVAL = 5 minutes; // Interval for storing price history

    address public immutable amm;
    mapping(address => mapping(address => PriceData)) public priceRecords;
    mapping(address => mapping(address => TransactionData)) public transactionRecords;

    event PriceUpdated(address indexed token1, address indexed token2, uint256 price, uint256 timestamp);
    event TransactionRecorded(
        address indexed token1,
        address indexed token2,
        bool isBuy,
        uint256 inputAmount,
        uint256 receivedAmount,
        uint256 timestamp
    );

    constructor(address _amm) {
        amm = _amm;
    }

    modifier onlyAMM() {
        require(msg.sender == amm, "Unauthorized");
        _;
    }

    /**
     * @notice Updates price and records transaction type along with amounts.
     * @param tokenA First token address.
     * @param tokenB Second token address.
     * @param newPrice Latest price to update.
     * @param isBuy True if transaction is a buy (token1 -> token2) when tokenA is the lower token.
     * @param inputAmount Amount sent in the transaction.
     * @param receivedAmount Amount received from the transaction.
     */
    function updatePrice(
        address tokenA,
        address tokenB,
        uint256 newPrice,
        bool isBuy,
        uint256 inputAmount,
        uint256 receivedAmount
    ) external onlyAMM {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        
        bool isDirect = (tokenA == token1);
        uint256 effectivePrice = isDirect ? newPrice : ((PRECISION * PRECISION) / newPrice);
        bool effectiveIsBuy = isDirect ? isBuy : !isBuy;
        
        if (!isDirect) {
            (inputAmount, receivedAmount) = (receivedAmount, inputAmount);
        }

        PriceData storage record = priceRecords[token1][token2];
        TransactionData storage txnRecord = transactionRecords[token1][token2];

        if (record.timestamp > 0) {
            uint256 elapsed = block.timestamp - record.timestamp;
            uint256 effectiveElapsed = elapsed > WINDOW_SIZE ? WINDOW_SIZE : elapsed;

            record.cumulativePrice = record.lastPrice * effectiveElapsed;

            if (elapsed > WINDOW_SIZE) {
                record.cumulativePrice = effectivePrice * WINDOW_SIZE;
            } else {
                record.cumulativePrice += effectivePrice * effectiveElapsed;
                record.cumulativePrice -= (record.cumulativePrice * effectiveElapsed) / WINDOW_SIZE;
            }

            if (elapsed >= HISTORY_INTERVAL) {
                record.priceHistory.push(effectivePrice);
                record.historyTimestamps.push(block.timestamp);
            }
        }

        if (effectiveIsBuy) {
            txnRecord.buyCount++;
        } else {
            txnRecord.sellCount++;
        }
        txnRecord.lastUpdated = block.timestamp;
        txnRecord.inputAmounts.push(inputAmount);
        txnRecord.receivedAmounts.push(receivedAmount);
        txnRecord.txTimestamps.push(block.timestamp);

        record.lastPrice = effectivePrice;
        record.timestamp = block.timestamp;

        emit PriceUpdated(token1, token2, effectivePrice, block.timestamp);
        emit TransactionRecorded(token1, token2, effectiveIsBuy, inputAmount, receivedAmount, block.timestamp);
    }

    /**
     * @notice Fetches the TWAP for a specific pair, returning tokenB per tokenA based on input order.
     * @param tokenA First token in the pair.
     * @param tokenB Second token in the pair.
     * @return TWAP of tokenB per tokenA, scaled by PRECISION.
     */
    function getTWAP(address tokenA, address tokenB) external view returns (uint256) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        PriceData storage record = priceRecords[token1][token2];

        require(block.timestamp - record.timestamp <= MAX_STALE, "Data stale");
        uint256 elapsed = block.timestamp - record.timestamp;
        require(elapsed > 0, "Insufficient data");

        uint256 twap = (record.cumulativePrice * PRECISION) / elapsed;
        if (tokenA == token1) {
            return twap; // token2 per token1, i.e., tokenB per tokenA
        } else {
            return (PRECISION * PRECISION) / twap; // token1 per token2, i.e., tokenB per tokenA
        }
    }

    /**
     * @notice Fetches price history for charting, returning prices as tokenB per tokenA.
     * @param tokenA First token in the pair.
     * @param tokenB Second token in the pair.
     * @param range Time range for history (e.g., 24 hours).
     * @return prices Array of prices (tokenB per tokenA), timestamps Array of corresponding timestamps.
     */
    function getPriceHistory(address tokenA, address tokenB, uint256 range) external view returns (uint256[] memory, uint256[] memory) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        bool isDirect = (tokenA == token1);
        PriceData storage record = priceRecords[token1][token2];

        uint256 endTime = block.timestamp;
        uint256 startTime = endTime - range;

        uint256 count = 0;
        for (uint256 i = 0; i < record.priceHistory.length; i++) {
            if (record.historyTimestamps[i] >= startTime && record.historyTimestamps[i] <= endTime) {
                count++;
            }
        }

        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < record.priceHistory.length; i++) {
            if (record.historyTimestamps[i] >= startTime && record.historyTimestamps[i] <= endTime) {
                uint256 price = record.priceHistory[i];
                if (!isDirect) {
                    price = (PRECISION * PRECISION) / price;
                }
                prices[index] = price;
                timestamps[index] = record.historyTimestamps[i];
                index++;
            }
        }

        return (prices, timestamps);
    }

    /**
     * @notice Fetches transaction data, adjusting buy/sell counts based on input order.
     * @param tokenA First token in the pair.
     * @param tokenB Second token in the pair.
     * @return buyCount Number of buys (tokenA -> tokenB), sellCount Number of sells (tokenB -> tokenA), lastUpdated Last update timestamp.
     */
    function getTransactionData(address tokenA, address tokenB) external view returns (
        uint256 buyCount,
        uint256 sellCount,
        uint256 lastUpdated
    ) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        TransactionData storage txnRecord = transactionRecords[token1][token2];

        if (tokenA == token1) {
            return (txnRecord.buyCount, txnRecord.sellCount, txnRecord.lastUpdated);
        } else {
            return (txnRecord.sellCount, txnRecord.buyCount, txnRecord.lastUpdated);
        }
    }

    // Normalize token pair order.
    function normalizePair(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}