// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Price Oracle
 * @dev Enhanced TWAP implementation with price history and transaction tracking including amounts.
 *      Now supports calculating prices both ways by determining if the input order is direct or reversed.
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
     * @param isBuy True if transaction is a buy (token1 -> token2) when tokenA is the lower token; 
     *              should be true by default when tokenA is tokenA and tokenB is tokenB.
     * @param inputAmount Amount sent in the transaction.
     * @param receivedAmount Amount received from the transaction.
     *
     * Note: If tokenA is not the lower address (per normalization), the oracle computes the inverse price,
     * flips the isBuy flag, and swaps input/received amounts.
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
        
        // Determine if input order is direct or reversed.
        bool isDirect = (tokenA == token1);
        uint256 effectivePrice = isDirect ? newPrice : ((PRECISION * PRECISION) / newPrice);
        bool effectiveIsBuy = isDirect ? isBuy : !isBuy;
        
        // Swap amounts if the order is reversed.
        if (!isDirect) {
            (inputAmount, receivedAmount) = (receivedAmount, inputAmount);
        }

        PriceData storage record = priceRecords[token1][token2];
        TransactionData storage txnRecord = transactionRecords[token1][token2];

        // Update cumulative price with previous value.
        if (record.timestamp > 0) {
            uint256 elapsed = block.timestamp - record.timestamp;
            uint256 effectiveElapsed = elapsed > WINDOW_SIZE ? WINDOW_SIZE : elapsed;

            record.cumulativePrice = record.lastPrice * effectiveElapsed;

            if (elapsed > WINDOW_SIZE) {
                // Reset window if beyond maximum.
                record.cumulativePrice = effectivePrice * WINDOW_SIZE;
            } else {
                // Maintain rolling window.
                record.cumulativePrice += effectivePrice * effectiveElapsed;
                record.cumulativePrice -= (record.cumulativePrice * effectiveElapsed) / WINDOW_SIZE;
            }

            // Store price history at intervals.
            if (elapsed >= HISTORY_INTERVAL) {
                record.priceHistory.push(effectivePrice);
                record.historyTimestamps.push(block.timestamp);
            }
        }

        // Update transaction counts and record amounts.
        if (effectiveIsBuy) {
            txnRecord.buyCount++;
        } else {
            txnRecord.sellCount++;
        }
        txnRecord.lastUpdated = block.timestamp;
        txnRecord.inputAmounts.push(inputAmount);
        txnRecord.receivedAmounts.push(receivedAmount);
        txnRecord.txTimestamps.push(block.timestamp);

        // Update price record.
        record.lastPrice = effectivePrice;
        record.timestamp = block.timestamp;

        emit PriceUpdated(token1, token2, effectivePrice, block.timestamp);
        emit TransactionRecorded(token1, token2, effectiveIsBuy, inputAmount, receivedAmount, block.timestamp);
    }

    // Fetch TWAP for a specific pair.
    function getTWAP(address tokenA, address tokenB) external view returns (uint256) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        PriceData storage record = priceRecords[token1][token2];

        require(block.timestamp - record.timestamp <= MAX_STALE, "Data stale");
        uint256 elapsed = block.timestamp - record.timestamp;
        require(elapsed > 0, "Insufficient data");

        return (record.cumulativePrice * PRECISION) / elapsed;
    }

    // Fetch price history for charting (30m, 1hr, 5hr, 24hr).
    function getPriceHistory(address tokenA, address tokenB, uint256 range) external view returns (uint256[] memory, uint256[] memory) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        PriceData storage record = priceRecords[token1][token2];

        uint256 endTime = block.timestamp;
        uint256 startTime = endTime - range;

        uint256 count = 0;
        // Count relevant data points.
        for (uint256 i = 0; i < record.priceHistory.length; i++) {
            if (record.historyTimestamps[i] >= startTime && record.historyTimestamps[i] <= endTime) {
                count++;
            }
        }

        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);
        uint256 index = 0;

        // Populate arrays.
        for (uint256 i = 0; i < record.priceHistory.length; i++) {
            if (record.historyTimestamps[i] >= startTime && record.historyTimestamps[i] <= endTime) {
                prices[index] = record.priceHistory[i];
                timestamps[index] = record.historyTimestamps[i];
                index++;
            }
        }

        return (prices, timestamps);
    }

    // Fetch transaction data for a pair.
    function getTransactionData(address tokenA, address tokenB) external view returns (
        uint256 buyCount,
        uint256 sellCount,
        uint256 lastUpdated
    ) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        TransactionData storage txnRecord = transactionRecords[token1][token2];

        return (txnRecord.buyCount, txnRecord.sellCount, txnRecord.lastUpdated);
    }

    // Normalize token pair order.
    function normalizePair(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
