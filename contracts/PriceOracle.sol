// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Price Oracle
 * @dev Update-based TWAP implementation with price history and transaction tracking including amounts.
 *      Supports calculating prices both ways by respecting the input order of tokenA and tokenB.
 */
contract PriceOracle {
    struct PriceData {
        uint256 cumulativePrice;       // Cumulative price for TWAP calculation
        uint256 lastPrice;             // Most recent price
        uint256 updateCount;           // Total number of price updates
        uint256 lastUpdateCount;       // Update count at last price recording
        uint256[] priceHistory;        // Historical prices for charting
        uint256[] historyUpdateCounts; // Corresponding update counts for history
    }

    struct TransactionData {
        uint256 buyCount;           // Number of buys (token1 -> token2)
        uint256 sellCount;          // Number of sells (token2 -> token1)
        uint256 lastUpdateCount;    // Last update count when transaction happened
        uint256[] inputAmounts;     // Input amounts for each transaction
        uint256[] receivedAmounts;  // Received amounts for each transaction
        uint256[] txUpdateCounts;   // Update counts for each transaction
    }

    uint256 public constant WINDOW_UPDATES = 100;           // Number of updates for TWAP window
    uint256 public constant PRECISION = 1e18;              // Precision for price calculations
    uint256 public constant MAX_STALE_UPDATES = 50;        // Max update staleness
    uint256 public constant HISTORY_INTERVAL_UPDATES = 5;  // Interval (in updates) for price history

    address public immutable amm; // AMM contract address

    mapping(address => mapping(address => PriceData)) public priceRecords;
    mapping(address => mapping(address => TransactionData)) public transactionRecords;

    event PriceUpdated(address indexed token1, address indexed token2, uint256 price, uint256 updateCount);
    event TransactionRecorded(
        address indexed token1,
        address indexed token2,
        bool isBuy,
        uint256 inputAmount,
        uint256 receivedAmount,
        uint256 updateCount
    );

    constructor(address _amm) {
        require(_amm != address(0), "Invalid AMM address");
        amm = _amm;
    }

    modifier onlyAMM() {
        require(msg.sender == amm, "Unauthorized");
        _;
    }

    function updatePrice(
        address tokenA,
        address tokenB,
        uint256 newPrice,
        bool isBuy,
        uint256 inputAmount,
        uint256 receivedAmount
    ) external onlyAMM {
        require(newPrice > 0, "Invalid price");
        (address token1, address token2) = normalizePair(tokenA, tokenB);

        bool isDirect = (tokenA == token1);
        uint256 effectivePrice = isDirect ? newPrice : mulDiv(PRECISION, PRECISION, newPrice);
        bool effectiveIsBuy = isDirect ? isBuy : !isBuy;
        if (!isDirect) {
            (inputAmount, receivedAmount) = (receivedAmount, inputAmount);
        }

        PriceData storage record = priceRecords[token1][token2];
        TransactionData storage txn = transactionRecords[token1][token2];

        // Increment update count
        uint256 currentCount = record.updateCount + 1;
        uint256 elapsed = currentCount - record.lastUpdateCount;
        uint256 effectiveElapsed = elapsed > WINDOW_UPDATES ? WINDOW_UPDATES : elapsed;

        // TWAP cumulative logic
        if (record.lastUpdateCount > 0) {
            uint256 priceContribution = mulDiv(record.lastPrice, effectiveElapsed * PRECISION, WINDOW_UPDATES);
            record.cumulativePrice += priceContribution;

            if (elapsed > WINDOW_UPDATES) {
                record.cumulativePrice = mulDiv(effectivePrice, WINDOW_UPDATES * PRECISION, WINDOW_UPDATES);
            } else {
                uint256 newContribution = mulDiv(effectivePrice, effectiveElapsed * PRECISION, WINDOW_UPDATES);
                record.cumulativePrice = mulDiv(record.cumulativePrice, (WINDOW_UPDATES - effectiveElapsed), WINDOW_UPDATES) + newContribution;
            }

            // History on interval
            if (elapsed >= HISTORY_INTERVAL_UPDATES) {
                record.priceHistory.push(effectivePrice);
                record.historyUpdateCounts.push(currentCount);
            }
        } else {
            // First update initialization
            record.cumulativePrice = mulDiv(effectivePrice, WINDOW_UPDATES * PRECISION, WINDOW_UPDATES);
        }

        // Update record state
        record.lastPrice = effectivePrice;
        record.lastUpdateCount = currentCount;
        record.updateCount = currentCount;

        // Transaction tracking
        if (effectiveIsBuy) txn.buyCount++; else txn.sellCount++;
        txn.lastUpdateCount = currentCount;
        txn.inputAmounts.push(inputAmount);
        txn.receivedAmounts.push(receivedAmount);
        txn.txUpdateCounts.push(currentCount);

        emit PriceUpdated(token1, token2, effectivePrice, currentCount);
        emit TransactionRecorded(token1, token2, effectiveIsBuy, inputAmount, receivedAmount, currentCount);
    }

    function getTWAP(address tokenA, address tokenB) external view returns (uint256) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        PriceData storage record = priceRecords[token1][token2];

        uint256 stale = record.updateCount - record.lastUpdateCount;
        require(stale <= MAX_STALE_UPDATES, "Data stale");
        require(stale > 0, "Insufficient data");

        uint256 twap = mulDiv(record.cumulativePrice, PRECISION, stale);
        if (tokenA == token1) {
            return twap;
        } else {
            return mulDiv(PRECISION, PRECISION, twap);
        }
    }

    function getPriceHistory(
        address tokenA,
        address tokenB,
        uint256 rangeUpdates
    ) external view returns (uint256[] memory prices, uint256[] memory updateCounts) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        bool isDirect = (tokenA == token1);
        PriceData storage record = priceRecords[token1][token2];

        uint256 startCount = record.updateCount >= rangeUpdates
            ? record.updateCount - rangeUpdates
            : 0;

        uint256 total = record.priceHistory.length;
        uint256 count = 0;
        for (uint256 i = 0; i < total; i++) {
            if (record.historyUpdateCounts[i] >= startCount) count++;
        }

        prices = new uint256[](count);
        updateCounts = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < total; i++) {
            uint256 ucount = record.historyUpdateCounts[i];
            if (ucount >= startCount) {
                uint256 price = record.priceHistory[i];
                prices[idx] = isDirect ? price : mulDiv(PRECISION, PRECISION, price);
                updateCounts[idx] = ucount;
                idx++;
            }
        }
    }

    function getTransactionData(
        address tokenA,
        address tokenB
    ) external view returns (
        uint256 buyCount,
        uint256 sellCount,
        uint256 lastCount
    ) {
        (address token1, address token2) = normalizePair(tokenA, tokenB);
        TransactionData storage txn = transactionRecords[token1][token2];
        if (tokenA == token1) {
            buyCount = txn.buyCount;
            sellCount = txn.sellCount;
        } else {
            buyCount = txn.sellCount;
            sellCount = txn.buyCount;
        }
        lastCount = txn.lastUpdateCount;
    }

    function normalizePair(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        require(denominator > 0, "Divide by zero");
        unchecked {
            result = (x * y) / denominator;
        }
    }
}
