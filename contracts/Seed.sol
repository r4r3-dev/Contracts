// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
██████╗  █████╗ ██████╗ ███████╗██████╗  █████╗ ██╗   ██╗
██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔══██╗╚██╗ ██╔╝
██████╔╝███████║██████╔╝█████╗  ██████╔╝███████║ ╚████╔╝ 
██╔══██╗██╔══██║██╔══██╗██╔══╝  ██╔══██╗██╔══██║  ╚██╔╝  
██║  ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║   ██║ 
 * @title RAREPresale_V3_Audited
 * @author Rarebay
 * @notice This contract facilitates a presale of RARE tokens using CORE, WCORE, and USDT.
 * It includes functionality for a main presale round and a separate pre-seed round, with individual caps and whitelisting for both.
 * @dev This version has been audited to fix critical bugs, remove outdated libraries (SafeMath),
 * improve security, and enhance clarity for mainnet deployment.
 * Changes include:
 * - Removed SafeMath; Solidity ^0.8.0 has built-in overflow checks.
 * - Fixed critical bug: declared missing state variables `committedWithCORE` and `committedWithWCORE`.
 * - Fixed security flaw in `depositRareTokens` by tying the check to `presaleStartTime`.
 * - Replaced magic numbers in `getOutputAmount` with a `Currency` enum for type safety.
 * - Added missing event in `updatePreseedWhitelist`.
 * - Improved NatSpec documentation for clarity.
 */
contract RAREPresale_V3_Audited is Ownable, ReentrancyGuard {

    // --- Token Interfaces ---
    IERC20 public immutable rareToken;
    IERC20 public immutable usdtToken;
    IERC20 public immutable wcoreToken;

    // --- Token Decimals ---
    uint8 public immutable rareDecimals;
    uint8 public immutable usdtDecimals;
    uint8 public immutable wcoreDecimals;

    // --- Constants ---
    uint256 public constant MAX_PER_WALLET = 100_000 * 1e18; // 100,000 RARE (assuming 18 decimals)

    // --- Enums ---
    enum Currency { CORE, WCORE, USDT }

    // --- State Variables ---
    /// @notice The price of 1 RARE token in USDT, scaled by usdtDecimals.
    uint256 public rarePriceUSDT;
    /// @notice The price of 1 CORE token in USDT, scaled by usdtDecimals.
    uint256 public corePriceUSDT;

    // --- Presale Round State ---
    uint256 public presaleStartTime;
    uint256 public presaleEndTime;
    bool public presaleActive = false;
    
    /// @notice Minimum purchase amount in native CORE or WCORE, scaled by 1e18.
    uint256 public minCoreEquivalent;
    /// @notice Minimum purchase amount in USDT, scaled by usdtDecimals.
    uint256 public minUSDT;

    /// @notice Total RARE tokens deposited by the owner for the presale.
    uint256 public totalDeposited;
    /// @notice Total RARE tokens sold to buyers across all rounds.
    uint256 public totalSold;
    
    // --- Pre-seed Round State ---
    uint256 public preseedStartTime;
    uint256 public preseedEndTime;
    /// @notice Total RARE tokens sold to buyers in the pre-seed round (via CORE).
    uint256 public committedWithCOREPreseed;

    /// @notice Mapping to track pre-seed whitelist status.
    mapping(address => bool) public preseedWhitelist;
    /// @notice Mapping to track the maximum RARE amount each pre-seed investor can buy.
    mapping(address => uint256) public preseedCaps;

    // --- Purchase and Whitelist Mappings ---
    /// @notice Mapping to track main presale whitelist status.
    mapping(address => bool) public whitelist;
    /// @notice Mapping to track RARE tokens purchased by each buyer.
    mapping(address => uint256) public purchasedAmount;
    /// @notice Mapping to prevent double claims.
    mapping(address => bool) public hasClaimed;

    // --- Collected Funds & Committed Tokens Per Currency ---
    uint256 public committedWithCORE;
    uint256 public committedWithWCORE;
    uint256 public collectedCORE;
    uint256 public collectedWCORE;
    uint256 public collectedUSDT;

    // --- Events ---
    event TokensCommitted(address indexed buyer, uint256 rareAmount, uint256 paidAmount, string currencyName, uint256 timestamp);
    event TokensClaimed(address indexed buyer, uint256 rareAmount);
    event WhitelistUpdated(address indexed user, bool status);
    event PresaleTimingUpdated(uint256 startTime, uint256 endTime);
    event PreseedTimingUpdated(uint256 startTime, uint256 endTime);
    event PresaleStateUpdated(bool isActive);
    event CorePriceUpdated(uint256 newPrice);
    event RarePriceUpdated(uint256 newPrice);
    event TokensDeposited(uint256 amount);
    event MinimumAmountsUpdated(uint256 newMinCoreEquivalent, uint256 newMinUSDT);
    event FundsWithdrawn(address indexed token, address indexed to, uint256 amount);
    event NativeFundsWithdrawn(address indexed to, uint256 amount);
    event PreseedCapUpdated(address indexed user, uint256 cap);

    // --- Modifiers ---
    modifier onlyDuringPresale() {
        require(presaleActive, "Presale: Not active");
        require(block.timestamp >= presaleStartTime, "Presale: Not started");
        require(block.timestamp <= presaleEndTime, "Presale: Ended");
        _;
    }

    modifier onlyDuringPreseed() {
        require(block.timestamp >= preseedStartTime, "Preseed: Not started");
        require(block.timestamp <= preseedEndTime, "Preseed: Ended");
        _;
    }

    modifier onlyAfterPresale() {
        require(block.timestamp > presaleEndTime, "Presale: Still active");
        _;
    }

    modifier onlyWhitelisted() {
        require(whitelist[msg.sender], "Presale: Not whitelisted");
        _;
    }

    modifier onlyPreseedWhitelisted() {
        require(preseedWhitelist[msg.sender], "Preseed: Not whitelisted");
        _;
    }
    
    // --- Constructor ---
    constructor(
        address _rareToken,
        address _usdtToken,
        address _wcoreToken,
        uint256 _rarePriceUSDT,
        uint256 _corePriceUSDT
    ) Ownable(msg.sender) {
        require(_rareToken != address(0) && _usdtToken != address(0) && _wcoreToken != address(0), "Error: Invalid token address");
        require(_rarePriceUSDT > 0 && _corePriceUSDT > 0, "Error: Prices must be > 0");

        rareToken = IERC20(_rareToken);
        usdtToken = IERC20(_usdtToken);
        wcoreToken = IERC20(_wcoreToken);
        
        rareDecimals = IERC20Metadata(_rareToken).decimals();
        usdtDecimals = IERC20Metadata(_usdtToken).decimals();
        wcoreDecimals = IERC20Metadata(_wcoreToken).decimals();

        require(wcoreDecimals == 18, "Error: WCORE must have 18 decimals");
        
        rarePriceUSDT = _rarePriceUSDT;
        corePriceUSDT = _corePriceUSDT;
        
        minCoreEquivalent = 10 * (10**wcoreDecimals); // Default: 10 CORE/WCORE
        minUSDT = 5 * (10**usdtDecimals);       // Default: 5 USDT
    }
    
    /// @dev Rejects direct native currency transfers.
    receive() external payable {
        revert("Error: Direct transfers not allowed");
    }
    
    // --- Owner Functions ---
    function setPresaleTiming(uint256 startTime, uint256 endTime) external onlyOwner {
        require(startTime > block.timestamp, "Error: Start time must be in the future");
        require(startTime < endTime, "Error: Invalid timing");
        presaleStartTime = startTime;
        presaleEndTime = endTime;
        emit PresaleTimingUpdated(startTime, endTime);
    }
    
    function setPreseedTiming(uint256 startTime, uint256 endTime) external onlyOwner {
        require(startTime > block.timestamp, "Error: Start time must be in the future");
        require(startTime < endTime, "Error: Invalid timing");
        preseedStartTime = startTime;
        preseedEndTime = endTime;
        emit PreseedTimingUpdated(startTime, endTime);
    }
    
    function setPresaleActive(bool isActive) external onlyOwner {
        presaleActive = isActive;
        emit PresaleStateUpdated(isActive);
    }
    
    function setCorePrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Error: Price must be > 0");
        corePriceUSDT = newPrice;
        emit CorePriceUpdated(newPrice);
    }
    
    function setRarePrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Error: Price must be > 0");
        rarePriceUSDT = newPrice;
        emit RarePriceUpdated(newPrice);
    }

    function setMinimumAmounts(uint256 newMinCore, uint256 newMinUSDT) external onlyOwner {
        minCoreEquivalent = newMinCore;
        minUSDT = newMinUSDT;
        emit MinimumAmountsUpdated(newMinCore, newMinUSDT);
    }
    
    /**
     * @notice Deposits RARE tokens into the contract for the presale.
     * @dev SECURITY: This function can only be called BEFORE the main presale starts.
     * @param amount The amount of RARE tokens to deposit.
     */
    function depositRareTokens(uint256 amount) external onlyOwner {
        require(block.timestamp < presaleStartTime, "Error: Cannot deposit after presale starts");
        
        totalDeposited += amount;
        
        require(rareToken.transferFrom(msg.sender, address(this), amount), "Deposit: RARE transfer failed");
        emit TokensDeposited(amount);
    }

    function updateWhitelist(address[] calldata users, bool status) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = status;
            emit WhitelistUpdated(users[i], status);
        }
    }

    function updatePreseedWhitelist(address[] calldata users, bool status) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            preseedWhitelist[users[i]] = status;
            emit WhitelistUpdated(users[i], status); // Emitting same event for unified off-chain tracking
        }
    }
    
    function setPreseedCaps(address[] calldata users, uint256[] calldata caps) external onlyOwner {
        require(users.length == caps.length, "Error: Array lengths mismatch");
        for (uint256 i = 0; i < users.length; i++) {
            preseedCaps[users[i]] = caps[i];
            emit PreseedCapUpdated(users[i], caps[i]);
        }
    }

    // --- Purchase Functions ---
    function buyWithCOREPreseed() external payable onlyDuringPreseed onlyPreseedWhitelisted nonReentrant {
        uint256 rareAmount = _calculateRareAmountFromCORE(msg.value);
        require(rareAmount > 0, "Error: RARE amount is zero");

        uint256 newPurchasedAmount = purchasedAmount[msg.sender] + rareAmount;
        
        require(newPurchasedAmount <= preseedCaps[msg.sender], "Preseed: Exceeds individual cap");
        require(totalSold + rareAmount <= totalDeposited, "Sale: Insufficient RARE supply");
        
        purchasedAmount[msg.sender] = newPurchasedAmount;
        totalSold += rareAmount;
        committedWithCOREPreseed += rareAmount;
        collectedCORE += msg.value;
        
        emit TokensCommitted(msg.sender, rareAmount, msg.value, "CORE (Preseed)", block.timestamp);
    }
    
    function buyWithCORE() external payable onlyDuringPresale onlyWhitelisted nonReentrant {
        require(msg.value >= minCoreEquivalent, "Error: Amount below minimum");
        
        uint256 rareAmount = _calculateRareAmountFromCORE(msg.value);
        require(rareAmount > 0, "Error: RARE amount is zero");
        
        uint256 newPurchasedAmount = purchasedAmount[msg.sender] + rareAmount;
        require(newPurchasedAmount <= MAX_PER_WALLET, "Sale: Exceeds wallet limit");
        require(totalSold + rareAmount <= totalDeposited, "Sale: Insufficient RARE supply");
        
        purchasedAmount[msg.sender] = newPurchasedAmount;
        totalSold += rareAmount;
        committedWithCORE += rareAmount;
        collectedCORE += msg.value;
        
        emit TokensCommitted(msg.sender, rareAmount, msg.value, "CORE", block.timestamp);
    }

    function buyWithWCORE(uint256 amountIn) external onlyDuringPresale onlyWhitelisted nonReentrant {
        require(amountIn >= minCoreEquivalent, "Error: Amount below minimum");
        
        uint256 rareAmount = _calculateRareAmountFromCORE(amountIn);
        require(rareAmount > 0, "Error: RARE amount is zero");
        
        uint256 newPurchasedAmount = purchasedAmount[msg.sender] + rareAmount;
        require(newPurchasedAmount <= MAX_PER_WALLET, "Sale: Exceeds wallet limit");
        require(totalSold + rareAmount <= totalDeposited, "Sale: Insufficient RARE supply");
        
        purchasedAmount[msg.sender] = newPurchasedAmount;
        totalSold += rareAmount;
        committedWithWCORE += rareAmount;
        collectedWCORE += amountIn;

        require(wcoreToken.transferFrom(msg.sender, address(this), amountIn), "Purchase: WCORE transfer failed");
        
        emit TokensCommitted(msg.sender, rareAmount, amountIn, "WCORE", block.timestamp);
    }

    function buyWithUSDT(uint256 amountIn) external onlyDuringPresale onlyWhitelisted nonReentrant {
        require(amountIn >= minUSDT, "Error: Amount below minimum");
        
        uint256 rareAmount = _calculateRareAmountFromUSDT(amountIn);
        require(rareAmount > 0, "Error: RARE amount is zero");
        
        uint256 newPurchasedAmount = purchasedAmount[msg.sender] + rareAmount;
        require(newPurchasedAmount <= MAX_PER_WALLET, "Sale: Exceeds wallet limit");
        require(totalSold + rareAmount <= totalDeposited, "Sale: Insufficient RARE supply");
        
        purchasedAmount[msg.sender] = newPurchasedAmount;
        totalSold += rareAmount;
        collectedUSDT += amountIn;

        require(usdtToken.transferFrom(msg.sender, address(this), amountIn), "Purchase: USDT transfer failed");
        
        emit TokensCommitted(msg.sender, rareAmount, amountIn, "USDT", block.timestamp);
    }

    // --- Claim & Withdrawal ---

    /**
     * @notice Allows participants to claim their purchased RARE tokens.
     * @dev Both pre-seed and main presale participants can only claim after the MAIN presale has ended.
     * This ensures a single, unified Token Generation Event (TGE).
     */
    function claimTokens() external nonReentrant {
        require(block.timestamp > presaleEndTime, "Claim: Presale has not ended");
        
        uint256 rareAmountToClaim = purchasedAmount[msg.sender];
        require(rareAmountToClaim > 0, "Claim: No tokens to claim");
        require(!hasClaimed[msg.sender], "Claim: Tokens already claimed");

        // Checks-Effects-Interactions Pattern
        hasClaimed[msg.sender] = true;
        
        require(rareToken.transfer(msg.sender, rareAmountToClaim), "Claim: RARE transfer failed");
        
        emit TokensClaimed(msg.sender, rareAmountToClaim);
    }

    function withdrawCORE(address payable to, uint256 amount) external onlyOwner onlyAfterPresale nonReentrant {
        require(to != address(0), "Error: Zero address");
        require(amount > 0 && collectedCORE >= amount, "Withdrawal: Invalid amount");
        
        collectedCORE -= amount;
        
        (bool success, ) = to.call{value: amount}("");
        require(success, "Withdrawal: CORE transfer failed");
        
        emit NativeFundsWithdrawn(to, amount);
    }
 
    function withdrawWCORE(address to, uint256 amount) external onlyOwner onlyAfterPresale nonReentrant {
        _withdrawToken(wcoreToken, to, amount, collectedWCORE);
        collectedWCORE -= amount;
    }
    
    function withdrawUSDT(address to, uint256 amount) external onlyOwner onlyAfterPresale nonReentrant {
        _withdrawToken(usdtToken, to, amount, collectedUSDT);
        collectedUSDT -= amount;
    }

    function withdrawOtherTokens(IERC20 token, address to) external onlyOwner nonReentrant {
        require(address(token) != address(rareToken) && 
                address(token) != address(usdtToken) && 
                address(token) != address(wcoreToken), 
                "Error: Use specific withdrawal functions");
        
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "Error: No tokens to withdraw");
        require(token.transfer(to, balance), "Withdrawal: Token transfer failed");
        emit FundsWithdrawn(address(token), to, balance);
    }

    // --- Internal & View Functions ---

    function _withdrawToken(IERC20 token, address to, uint256 amount, uint256 collectedAmount) private {
        require(to != address(0), "Error: Zero address");
        require(amount > 0 && collectedAmount >= amount, "Withdrawal: Invalid amount");

        require(token.transfer(to, amount), "Withdrawal: Token transfer failed");
        emit FundsWithdrawn(address(token), to, amount);
    }

    function _calculateRareAmountFromCORE(uint256 amountInCORE) internal view returns (uint256) {
        // (amountInCORE * corePriceUSDT / rarePriceUSDT) scaled by decimals
        // To avoid precision loss, multiply by target decimals first.
        uint256 numerator = amountInCORE * corePriceUSDT * (10**rareDecimals);
        uint256 denominator = rarePriceUSDT * (10**wcoreDecimals);
        return numerator / denominator;
    }

    function _calculateRareAmountFromUSDT(uint256 amountInUSDT) internal view returns (uint256) {
        // (amountInUSDT / rarePriceUSDT) scaled by decimals
        return amountInUSDT * (10**rareDecimals) / rarePriceUSDT;
    }

    function getOutputAmount(uint256 amount, Currency currency) external view returns (uint256) {
        require(rarePriceUSDT > 0, "Error: Price not set");
        if (currency == Currency.CORE || currency == Currency.WCORE) {
            require(corePriceUSDT > 0, "Error: Price not set");
            return _calculateRareAmountFromCORE(amount);
        } else if (currency == Currency.USDT) {
            return _calculateRareAmountFromUSDT(amount);
        }
        revert("Error: Invalid currency");
    }

    function isPresaleCurrentlyActive() external view returns (bool) {
        return presaleActive && block.timestamp >= presaleStartTime && block.timestamp <= presaleEndTime;
    }

    function isPreseedCurrentlyActive() external view returns (bool) {
        return block.timestamp >= preseedStartTime && block.timestamp <= preseedEndTime;
    }
}