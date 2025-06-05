// File: RoyaltyAMM.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./libraries/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/math/Math.sol"; // For Math.mulDiv

// --- Interfaces ---

/**
 * @dev Optional extended interface for ERC721, e.g., to include totalSupply.
 * Not strictly required by the core AMM logic if not used.
 */
interface IERC721Extended is IERC721 {
    function totalSupply() external view returns (uint256);
}

/**
 * @notice Interface for a royalty engine that can provide royalty recipients and amounts for a sale.
 * @dev This contract (RoyaltyAMM) can itself act as an IRoyaltyEngine.
 */
interface IRoyaltyEngine {
    /**
     * @notice Retrieves royalty information for a given token and sale value.
     * @param tokenAddress The address of the NFT contract.
     * @param tokenId The ID of the specific token.
     * @param value The sale value upon which royalties are calculated.
     * @return recipients An array of addresses to receive royalty payments.
     * @return amounts An array of corresponding royalty amounts.
     */
    function getRoyalty(
        address tokenAddress,
        uint256 tokenId,
        uint256 value
    ) external view returns (address payable[] memory recipients, uint256[] memory amounts);
}

/**
 * @title RoyaltyAMM
 * @author Your Name/Organization
 * @notice An Automated Market Maker (AMM) for ERC721 NFTs, paired with ERC20 tokens or native currency.
 * @dev This contract allows users to create liquidity pools, trade NFTs, and earn fees.
 * It also includes a system for setting and distributing royalties on NFT sales.
 * This contract takes custody of NFTs and tokens deposited into its liquidity pools.
 * It uses a constant product formula (X*Y=K adapted for discrete NFTs) for pricing.
 */
contract Royalty is ReentrancyGuard, AccessControl, IERC721Receiver, IERC1155Receiver {
    using SafeERC20 for IERC20;
    using Address for address payable;

    // --- Structs ---

    /**
     * @notice Stores royalty information for a specific NFT.
     * @param recipient The address that receives the royalty.
     * @param basisPoints The royalty fee in basis points (1% = 100 bps, max 10000 for 100%).
     */
    struct RoyaltyInfo {
        address payable recipient;
        uint24 basisPoints;
    }

    /**
     * @notice Represents a liquidity pool for a specific NFT collection and currency pair.
     * @param currency The ERC20 token address paired with NFTs, or address(0) for native currency.
     * @param tokenReserve Total amount of 'currency' tokens held by the pool.
     * @param nftReserve Count of NFTs from the 'collection' currently held by the pool.
     * @param totalLiquidityShares Total shares representing token liquidity provided by LPs.
     * @param accumulatedFees Accumulated swap fees in 'currency' to be distributed to LPs.
     * @param providerTokenShares Mapping from LP address to their share of token liquidity.
     * @param isNFTInPool Mapping from NFT tokenId to a boolean indicating if it's currently in this pool.
     * @param poolNFTTokenIdsList An array storing the tokenIds of NFTs currently held by this pool.
     * @param nftTokenIdToListIndex Mapping from tokenId to its 1-based index in poolNFTTokenIdsList for efficient removal.
     */
    struct LiquidityPool {
        address currency;
        uint256 tokenReserve;
        uint256 nftReserve;
        uint256 totalLiquidityShares;
        uint256 accumulatedFees;
        mapping(address => uint256) providerTokenShares;
        mapping(uint256 => bool) isNFTInPool;
        uint256[] poolNFTTokenIdsList;
        mapping(uint256 => uint256) nftTokenIdToListIndex;
    }

    /**
     * @notice Stores aggregated fee and volume statistics for an NFT collection.
     * @dev These stats are generally currency-agnostic in this struct but updated with specific currency values from swaps.
     * @param totalTradingVolume Total trading volume recorded for the collection.
     * @param totalFeesCollected Total swap fees collected for the collection.
     */
    struct CollectionFees {
        uint256 totalTradingVolume;
        uint256 totalFeesCollected;
    }

    /**
     * @notice Identifier for a unique liquidity pool.
     * @param collection The address of the NFT collection contract.
     * @param currency The address of the ERC20 currency, or address(0) for native.
     */
    struct PoolIdentifier {
        address collection;
        address currency;
    }

    /**
     * @notice Detailed information about a liquidity pool, for view functions.
     * @param collectionAddress Address of the NFT collection.
     * @param currencyAddress Address of the currency token.
     * @param tokenReserve Current token reserve in the pool.
     * @param nftReserveCount Current count of NFTs in the pool.
     * @param totalLiquidityShares Total liquidity shares issued for the pool.
     * @param accumulatedFees Accumulated fees for LPs.
     * @param nftTokenIdsInPool Array of token IDs of NFTs currently in the pool.
     * @param priceToBuyNFT Current price in tokens to buy 1 NFT from the pool (pre-fee).
     * @param priceToSellNFT Current tokens received for selling 1 NFT to the pool (pre-fee).
     */
    struct PoolDetail {
        address collectionAddress;
        address currencyAddress;
        uint256 tokenReserve;
        uint256 nftReserveCount;
        uint256 totalLiquidityShares;
        uint256 accumulatedFees;
        uint256[] nftTokenIdsInPool;
        uint256 priceToBuyNFT;
        uint256 priceToSellNFT;
    }

    // --- Constants ---

    /// @notice Default swap fee in basis points (e.g., 300 = 3%).
    uint256 public SWAP_FEE_BPS = 300;
    /// @notice Marker for native currency transactions (e.g., CORE), typically address(0).
    address public immutable NATIVE_CURRENCY;

    // --- State ---

    /// @notice Role identifier for administrators who can manage contract settings like fees.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Address of the royalty engine implementation. Can be this contract itself.
    address public royaltyEngineAddress;

    /// @notice Mapping: NFT collection address => currency address => LiquidityPool struct.
    mapping(address => mapping(address => LiquidityPool)) public collectionPools;
    /// @notice Mapping: NFT collection address => CollectionFees struct for statistics.
    mapping(address => CollectionFees) public collectionStats;
    /// @notice Mapping: Royalty recipient address => currency address => pending royalty amount to be withdrawn.
    mapping(address => mapping(address => uint256)) public pendingRoyalties;

    /// @dev Mapping: NFT contract address => tokenId => RoyaltyInfo struct. Stores on-chain royalty settings.
    mapping(address => mapping(uint256 => RoyaltyInfo)) private _royalties;

    /// @notice Array storing identifiers of all created liquidity pools.
    PoolIdentifier[] public allPoolIdentifiers;
    /// @dev Mapping: (NFT collection address, currency address) => 1-based index in allPoolIdentifiers array.
    mapping(address => mapping(address => uint256)) private poolIdentifierIndex;

    // --- Events ---
    event PoolCreated(
        address indexed collection,
        address indexed currency,
        address indexed creator,
        uint256 initialTokenAmount,
        uint256[] tokenIds
    );
    event RoyaltyFundsAddedAsLiquidity(
        address indexed collection,
        address indexed currency,
        uint256 amountAdded,
        address indexed sourceMarketplace // e.g., RareMarket contract address
    );
     event BatchSwapNFTToToken(
        address indexed collection,
        address indexed user,
        uint256[] tokenIds,
        address currency,
        uint256 totalAmountOutNet,
        uint256 totalFee
    );
    event LiquidityAdded(address indexed collection, address indexed provider, address currency, uint256 tokenAmount, uint256 sharesIssued);
    event NFTLiquidityAdded(address indexed collection, address indexed provider, address currency, uint256[] tokenIds);
    event LiquidityRemoved(address indexed collection, address indexed provider, address currency, uint256 tokenAmountRemoved, uint256 sharesBurned, uint256 feeShareReturned);
    event SwapNFTToToken(address indexed collection, address indexed user, uint256 tokenId, address currency, uint256 amountOut, uint256 fee);
    event SwapTokenToNFT(address indexed collection, address indexed user, uint256 tokenId, address currency, uint256 amountIn, uint256 fee);
    event FeesWithdrawn(address indexed collection, address indexed provider, address currency, uint256 amount);
    event RoyaltyWithdrawn(address indexed recipient, address indexed currency, uint256 amount);
    event SwapFeeSet(uint256 newFeeBps);
    event RoyaltySet(address indexed collection, uint256 indexed tokenId, address recipient, uint256 basisPoints);

    /**
     * @notice Contract constructor.
     * @dev Initializes admin roles and sets the native currency marker.
     * The deployer is granted `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE`.
     * `royaltyEngineAddress` is set to this contract's address, meaning it handles its own royalty logic.
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        royaltyEngineAddress = address(this); // This contract serves as its own royalty engine
        NATIVE_CURRENCY = address(0); // Standard for CORE or native chain currency
    }

    // --- Admin Functions ---

    /**
     * @notice Sets the swap fee for all pools.
     * @dev Only callable by an address with `ADMIN_ROLE`.
     * @param newFeeBps The new swap fee in basis points (e.g., 250 for 2.5%). Max 1000 (10%).
     */
    function setSwapFee(uint256 newFeeBps) external onlyRole(ADMIN_ROLE) {
        require(newFeeBps <= 1000, "RoyaltyAMM: Max fee is 10% (1000 bps)");
        SWAP_FEE_BPS = newFeeBps;
        emit SwapFeeSet(newFeeBps);
    }

    /**
     * @notice Sets or updates the royalty information for a specific NFT.
     * @dev Only callable by an address with `ADMIN_ROLE`.
     * @param tokenAddress The address of the NFT contract.
     * @param tokenId The ID of the token.
     * @param recipient The address to receive royalties.
     * @param basisPoints The royalty percentage in basis points (max 10000 for 100%).
     */
    function adminSetRoyalty(
        address tokenAddress,
        uint256 tokenId,
        address payable recipient,
        uint24 basisPoints
    ) external onlyRole(ADMIN_ROLE) {
        require(basisPoints <= 10000, "RoyaltyAMM: Max royalty is 100% (10000 bps)");
        _royalties[tokenAddress][tokenId] = RoyaltyInfo(recipient, basisPoints);
        emit RoyaltySet(tokenAddress, tokenId, recipient, basisPoints);
    }

    // --- Pool Management ---

    /**
     * @notice Creates a new liquidity pool for a given NFT collection and currency.
     * @dev Caller must own the initial NFTs and provide initial token liquidity if specified.
     * NFTs are transferred to this contract.
     * @param collection The address of the ERC721 NFT contract.
     * @param currency The address of the ERC20 currency token, or address(0) for native currency.
     * @param initialTokenIds An array of token IDs for the initial NFT deposit. Must not be empty.
     * @param initialTokenAmount The amount of 'currency' to deposit as initial token liquidity. Can be 0.
     */
    function createPool(
        address collection,
        address currency,
        uint256[] calldata initialTokenIds,
        uint256 initialTokenAmount
    ) external payable nonReentrant {
        require(initialTokenIds.length > 0, "RoyaltyAMM: Must deposit at least one NFT");
        require(poolIdentifierIndex[collection][currency] == 0, "RoyaltyAMM: Pool already exists");

        LiquidityPool storage pool = collectionPools[collection][currency];
        pool.currency = currency;

        IERC721 nftContract = IERC721(collection);
        for (uint i = 0; i < initialTokenIds.length; i++) {
            uint256 tokenId = initialTokenIds[i];
            require(nftContract.ownerOf(tokenId) == msg.sender, "RoyaltyAMM: Not owner of initial NFT");
            require(!pool.isNFTInPool[tokenId], "RoyaltyAMM: Initial NFT already marked in pool");

            nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
            pool.isNFTInPool[tokenId] = true;
            pool.poolNFTTokenIdsList.push(tokenId);
            pool.nftTokenIdToListIndex[tokenId] = pool.poolNFTTokenIdsList.length; // 1-based index
            pool.nftReserve = pool.nftReserve + 1;
        }

        uint256 sharesIssued = 0;
        if (initialTokenAmount > 0) {
            if (currency == NATIVE_CURRENCY) {
                require(msg.value == initialTokenAmount, "RoyaltyAMM: Native currency value mismatch");
            } else {
                require(msg.value == 0, "RoyaltyAMM: Native currency sent for ERC20 pool");
                IERC20(currency).safeTransferFrom(msg.sender, address(this), initialTokenAmount);
            }
            pool.tokenReserve = pool.tokenReserve + initialTokenAmount;

            // First LP's shares are typically equal to the initial token amount to set a base value.
            sharesIssued = initialTokenAmount;
            pool.providerTokenShares[msg.sender] = pool.providerTokenShares[msg.sender] + sharesIssued;
            pool.totalLiquidityShares = pool.totalLiquidityShares + sharesIssued;
        }

        allPoolIdentifiers.push(PoolIdentifier(collection, currency));
        poolIdentifierIndex[collection][currency] = allPoolIdentifiers.length; // 1-based index

        emit PoolCreated(collection, currency, msg.sender, initialTokenAmount, initialTokenIds);
        if (initialTokenAmount > 0) {
            emit LiquidityAdded(collection, msg.sender, currency, initialTokenAmount, sharesIssued);
        }
        // NFTLiquidityAdded is implicitly covered by PoolCreated for the initial NFTs
        // but we can emit it explicitly if desired for consistency with depositNFTsForSwap.
        // For now, PoolCreated covers the initial state.
    }


    // --- Liquidity Management ---

    /**
     * @notice Adds token liquidity to an existing pool.
     * @dev Caller provides 'currency' tokens and receives liquidity shares.
     * @param collection The address of the NFT collection contract.
     * @param currency The address of the currency token.
     * @param amount The amount of 'currency' tokens to add.
     */
    function addLiquidity(address collection, address currency, uint256 amount) external payable nonReentrant {
        require(amount > 0, "RoyaltyAMM: Amount must be positive");
        LiquidityPool storage pool = _getPool(collection, currency); // Ensures pool exists

        if (currency == NATIVE_CURRENCY) {
            require(msg.value == amount, "RoyaltyAMM: Native currency value mismatch");
        } else {
            require(msg.value == 0, "RoyaltyAMM: Native currency sent for ERC20 pool");
            IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 sharesIssued;
        if (pool.totalLiquidityShares == 0 || pool.tokenReserve == 0) {
            // If pool has NFTs but no token reserve yet, or is completely empty of shares (e.g. after full withdrawal)
            sharesIssued = amount;
        } else {
            sharesIssued = Math.mulDiv(amount, pool.totalLiquidityShares, pool.tokenReserve);
        }
        require(sharesIssued > 0, "RoyaltyAMM: Shares issued must be positive");

        pool.tokenReserve = pool.tokenReserve + amount;
        pool.providerTokenShares[msg.sender] = pool.providerTokenShares[msg.sender] + sharesIssued;
        pool.totalLiquidityShares = pool.totalLiquidityShares + sharesIssued;

        emit LiquidityAdded(collection, msg.sender, currency, amount, sharesIssued);
    }

    /**
     * @notice Deposits NFTs into an existing pool to increase its NFT liquidity.
     * @dev This does not issue token liquidity shares to the depositor directly,
     * but increases the pool's NFT depth, affecting swap prices.
     * Useful if someone wants to contribute NFTs without providing matching tokens.
     * @param collection The address of the NFT collection contract.
     * @param currency The currency address of the target pool.
     * @param tokenIds An array of token IDs to deposit.
     */
    function depositNFTsForSwap(address collection, address currency, uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length > 0, "RoyaltyAMM: No token IDs provided");
        LiquidityPool storage pool = _getPool(collection, currency); // Ensures pool exists

        IERC721 nftContract = IERC721(collection);
        for (uint i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(nftContract.ownerOf(tokenId) == msg.sender, "RoyaltyAMM: Not owner of token");
            require(!pool.isNFTInPool[tokenId], "RoyaltyAMM: NFT already in pool");

            nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
            pool.isNFTInPool[tokenId] = true;
            pool.poolNFTTokenIdsList.push(tokenId);
            pool.nftTokenIdToListIndex[tokenId] = pool.poolNFTTokenIdsList.length; // 1-based index
            pool.nftReserve = pool.nftReserve + 1;
        }
        emit NFTLiquidityAdded(collection, msg.sender, currency, tokenIds);
    }

    /**
     * @notice Removes token liquidity and a proportional share of accumulated fees from a pool.
     * @dev Caller burns their liquidity shares and receives 'currency' tokens.
     * @param collection The address of the NFT collection contract.
     * @param currency The address of the currency token.
     * @param shareAmount The amount of liquidity shares to burn.
     */
    function removeLiquidity(address collection, address currency, uint256 shareAmount) external nonReentrant {
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.providerTokenShares[msg.sender] >= shareAmount, "RoyaltyAMM: Insufficient shares");
        require(pool.totalLiquidityShares > 0, "RoyaltyAMM: No total liquidity shares in pool");
        require(shareAmount > 0, "RoyaltyAMM: Cannot remove zero shares");

        uint256 tokenAmountToWithdraw = Math.mulDiv(shareAmount, pool.tokenReserve, pool.totalLiquidityShares);
        uint256 feeShareToWithdraw = Math.mulDiv(shareAmount, pool.accumulatedFees, pool.totalLiquidityShares);

        require(tokenAmountToWithdraw > 0 || feeShareToWithdraw > 0, "RoyaltyAMM: No value to withdraw");

        pool.providerTokenShares[msg.sender] = pool.providerTokenShares[msg.sender] - shareAmount;
        pool.totalLiquidityShares = pool.totalLiquidityShares - shareAmount;
        
        if (tokenAmountToWithdraw > 0) {
            pool.tokenReserve = pool.tokenReserve - tokenAmountToWithdraw;
        }
        if (feeShareToWithdraw > 0) {
            pool.accumulatedFees = pool.accumulatedFees - feeShareToWithdraw;
        }
        
        uint256 totalWithdraw = tokenAmountToWithdraw + feeShareToWithdraw;
        if (totalWithdraw > 0) {
            _transferCurrency(currency, msg.sender, totalWithdraw);
        }

        emit LiquidityRemoved(collection, msg.sender, currency, tokenAmountToWithdraw, shareAmount, feeShareToWithdraw);
    }

    /**
     * @notice Withdraws the caller's share of accumulated fees from a pool.
     * @dev Does not burn liquidity shares.
     * @param collection The address of the NFT collection contract.
     * @param currency The address of the currency token.
     */
    function withdrawFees(address collection, address currency) external nonReentrant {
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.totalLiquidityShares > 0, "RoyaltyAMM: No total liquidity in pool");

        uint256 providerShares = pool.providerTokenShares[msg.sender];
        require(providerShares > 0, "RoyaltyAMM: No shares in this pool for provider");

        uint256 feeShare = Math.mulDiv(providerShares, pool.accumulatedFees, pool.totalLiquidityShares);
        require(feeShare > 0, "RoyaltyAMM: No fees to withdraw for provider");

        pool.accumulatedFees = pool.accumulatedFees - feeShare;
        
        _transferCurrency(currency, msg.sender, feeShare);
        emit FeesWithdrawn(collection, msg.sender, currency, feeShare);
    }

    // --- Swap Functions ---

    /**
     * @notice Swaps an NFT owned by the caller for 'currency' tokens from the pool.
     * @dev The NFT is transferred to the pool. Pricing is based on current reserves.
     * @param collection The address of the NFT collection contract.
     * @param tokenId The ID of the NFT to sell.
     * @param currency The address of the currency token.
     */
    function swapNFTToToken(address collection, uint256 tokenId, address currency) external nonReentrant {
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.tokenReserve > 0, "RoyaltyAMM: Insufficient token liquidity in pool");
        require(IERC721(collection).ownerOf(tokenId) == msg.sender, "RoyaltyAMM: Not owner of token");
        require(!pool.isNFTInPool[tokenId], "RoyaltyAMM: NFT is already pool liquidity");
        // require(pool.nftReserve > 0, "RoyaltyAMM: No NFTs in pool to determine price against"); // Price can be T/(N+1) even if N=0 initially for first NFT deposit via swap

        uint256 tokenReserveBefore = pool.tokenReserve;
        uint256 nftReserveBefore = pool.nftReserve;

        // Amount user receives (gross) = T / (N + 1)
        uint256 amountOut_gross = Math.mulDiv(tokenReserveBefore, 1, nftReserveBefore + 1); // More robust way to write T/(N+1)
        require(amountOut_gross > 0, "RoyaltyAMM: Gross amount out is zero");

        uint256 fee = Math.mulDiv(amountOut_gross, SWAP_FEE_BPS, 10000);
        uint256 amountOut_net = amountOut_gross - fee;
        require(amountOut_net > 0, "RoyaltyAMM: Net amount out is zero after fee");
        require(pool.tokenReserve >= amountOut_net, "RoyaltyAMM: AMM insufficient token reserve for swap (after fee calc)");


        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        _transferCurrency(currency, msg.sender, amountOut_net);

        pool.tokenReserve = pool.tokenReserve - amountOut_net; // Net amount is removed from reserve
        pool.nftReserve = pool.nftReserve + 1;
        pool.isNFTInPool[tokenId] = true;
        pool.poolNFTTokenIdsList.push(tokenId);
        pool.nftTokenIdToListIndex[tokenId] = pool.poolNFTTokenIdsList.length; // 1-based index

        pool.accumulatedFees = pool.accumulatedFees + fee;
        collectionStats[collection].totalTradingVolume = collectionStats[collection].totalTradingVolume + amountOut_gross;
        collectionStats[collection].totalFeesCollected = collectionStats[collection].totalFeesCollected + fee;

        emit SwapNFTToToken(collection, msg.sender, tokenId, currency, amountOut_net, fee);
    }

    /**
     * @notice Swaps 'currency' tokens from the caller for a specific NFT from the pool.
     * @dev The NFT is transferred to the caller. Pricing is based on current reserves.
     * @param collection The address of the NFT collection contract.
     * @param currency The address of the currency token.
     * @param tokenIdToReceive The ID of the specific NFT to buy from the pool.
     */
    function swapTokenToNFT(address collection, address currency, uint256 tokenIdToReceive) external payable nonReentrant {
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.nftReserve > 0, "RoyaltyAMM: No NFTs in pool to swap");
        require(pool.isNFTInPool[tokenIdToReceive], "RoyaltyAMM: Chosen NFT not in pool liquidity");
        // require(pool.nftReserve > 1, "RoyaltyAMM: Cannot swap if only one NFT remains (or use specific 1-to-0 logic)"); // This check is implicitly handled by N-1 below

        uint256 tokenReserveBefore = pool.tokenReserve;
        uint256 nftReserveBefore = pool.nftReserve;
        require(nftReserveBefore > 0, "RoyaltyAMM: NFT reserve must be positive"); // Should be caught by earlier require but good sanity

        // Amount user pays (net, before fee) = T / (N - 1)
        // This formula requires N > 1. If N=1, N-1 = 0, div by zero.
        require(nftReserveBefore > 1, "RoyaltyAMM: At least two NFTs must be in pool to buy one with this formula");
        uint256 amountIn_net = Math.mulDiv(tokenReserveBefore, 1, nftReserveBefore - 1); // T / (N-1)
        require(amountIn_net > 0, "RoyaltyAMM: Net amount in is zero");

        require(10000 > SWAP_FEE_BPS, "RoyaltyAMM: Swap fee basis points too high"); // Prevents division by zero or negative
        uint256 amountIn_gross = Math.mulDiv(amountIn_net, 10000, 10000 - SWAP_FEE_BPS);
        uint256 fee = amountIn_gross - amountIn_net;
        require(amountIn_gross > 0, "RoyaltyAMM: Gross amount in is zero");

        if (currency == NATIVE_CURRENCY) {
            require(msg.value >= amountIn_gross, "RoyaltyAMM: Insufficient native currency sent");
            if (msg.value > amountIn_gross) {
                payable(msg.sender).sendValue(msg.value - amountIn_gross); // Refund excess
            }
        } else {
            require(msg.value == 0, "RoyaltyAMM: Native currency sent for ERC20 pool");
            IERC20(currency).safeTransferFrom(msg.sender, address(this), amountIn_gross);
        }

        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenIdToReceive);

        pool.tokenReserve = pool.tokenReserve + amountIn_net; // Only net amount is added to reserve
        pool.nftReserve = pool.nftReserve - 1;
        pool.isNFTInPool[tokenIdToReceive] = false;
        _removeTokenIdFromList(pool, tokenIdToReceive);

        pool.accumulatedFees = pool.accumulatedFees + fee;
        collectionStats[collection].totalTradingVolume = collectionStats[collection].totalTradingVolume + amountIn_gross;
        collectionStats[collection].totalFeesCollected = collectionStats[collection].totalFeesCollected + fee;

        emit SwapTokenToNFT(collection, msg.sender, tokenIdToReceive, currency, amountIn_gross, fee);
    }

    // --- Royalty Functions ---

    /**
     * @notice Sets royalty information for a specific NFT by any user.
     * @dev This is a public function. For admin-controlled royalty setting, use `adminSetRoyalty`.
     * Consider adding access control if not intended to be public (e.g., only token owner or collection creator).
     * @param tokenAddress The address of the NFT contract.
     * @param tokenId The ID of the token.
     * @param recipient The address to receive royalties.
     * @param basisPoints The royalty percentage in basis points.
     */
    function setRoyalty(address tokenAddress, uint256 tokenId, address payable recipient, uint24 basisPoints) external {
        require(basisPoints <= 10000, "RoyaltyAMM: Royalty basis points too high (max 10000)");
        // Add checks here if needed: e.g., require(msg.sender == IERC721(tokenAddress).ownerOf(tokenId));
        _royalties[tokenAddress][tokenId] = RoyaltyInfo(recipient, basisPoints);
        emit RoyaltySet(tokenAddress, tokenId, recipient, basisPoints);
    }
    
    /**
     * @notice Retrieves royalty information for a token based on internal registry.
     * @dev This function's signature is NOT EIP-2981 compliant due to the `tokenAddress` parameter.
     * @param tokenAddress The address of the NFT contract.
     * @param tokenId The ID of the token.
     * @param value The sale value upon which royalties would be calculated.
     * @return receiver The address of the royalty recipient.
     * @return royaltyAmount The calculated royalty amount.
     */
    function royaltyInfo(address tokenAddress, uint256 tokenId, uint256 value)
        external view returns (address receiver, uint256 royaltyAmount)
    {
        RoyaltyInfo memory info = _royalties[tokenAddress][tokenId];
        receiver = info.recipient;
        if (info.recipient != address(0) && info.basisPoints > 0) {
            royaltyAmount = Math.mulDiv(value, info.basisPoints, 10000);
        } else {
            royaltyAmount = 0;
        }
    }

    /**
     * @notice Retrieves royalty information in the format expected by `IRoyaltyEngine`.
     * @dev This contract implements `IRoyaltyEngine` via `royaltyEngineAddress = address(this)`.
     * @param tokenAddress The address of the NFT contract.
     * @param tokenId The ID of the token.
     * @param value The sale value upon which royalties are calculated.
     * @return recipients An array containing the single royalty recipient (or address(0)).
     * @return amounts An array containing the single royalty amount (or 0).
     */
    function getRoyalty(address tokenAddress, uint256 tokenId, uint256 value)
        public view returns (address payable[] memory recipients, uint256[] memory amounts)
    {
        RoyaltyInfo memory info = _royalties[tokenAddress][tokenId];
        recipients = new address payable[](1);
        amounts = new uint256[](1);

        if (info.recipient != address(0) && info.basisPoints > 0) {
            recipients[0] = info.recipient;
            amounts[0] = Math.mulDiv(value, info.basisPoints, 10000);
        } else {
            recipients[0] = payable(address(0));
            amounts[0] = 0;
        }
        return (recipients, amounts);
    }

    /**
     * @notice Called by an external marketplace (or internally) to record and enable withdrawal of royalties.
     * @dev This function assumes the actual funds covering the royalties have been or will be
     * transferred to this contract. It then assigns these calculated amounts to recipients' pending balances.
     * @param collection The address of the NFT contract.
     * @param tokenId The ID of the token for which royalties are being distributed.
     * @param currency The currency of the sale and royalty payment.
     * @param saleAmount The total sale amount upon which royalties are calculated.
     */
    function distributeRoyalties(address collection, uint256 tokenId, address currency, uint256 saleAmount) external nonReentrant {
        (address payable[] memory recipients, uint256[] memory royaltyAmounts) = getRoyalty(collection, tokenId, saleAmount);
        
        for (uint i = 0; i < recipients.length; i++) {
            if (recipients[i] != address(0) && royaltyAmounts[i] > 0) {
                // This contract must hold the funds for `royaltyAmounts[i]` in `currency`
                // to make the subsequent withdrawal possible.
                pendingRoyalties[recipients[i]][currency] = pendingRoyalties[recipients[i]][currency] + royaltyAmounts[i];
            }
        }
    }

    /**
     * @notice Allows a royalty recipient to withdraw their pending royalty payments for a specific currency.
     * @param currency The currency of the royalties to withdraw.
     */
    function withdrawRoyalty(address currency) external nonReentrant {
        uint256 amount = pendingRoyalties[msg.sender][currency];
        require(amount > 0, "RoyaltyAMM: No royalties to withdraw for this currency");
        
        pendingRoyalties[msg.sender][currency] = 0;
        _transferCurrency(currency, msg.sender, amount);
        emit RoyaltyWithdrawn(msg.sender, currency, amount);
    }

    // --- View Functions ---

   /**
     * @notice Calculates the expected net amount of tokens a user would receive for swapping 1 NFT to the pool.
     * @dev Returns the net amount after deducting the current SWAP_FEE_BPS.
     * @param collection The address of the NFT collection contract.
     * @param currency The address of the currency token (or NATIVE_CURRENCY for native).
     * @return netAmountOut The net amount of 'currency' tokens the user would receive after fees. Returns 0 if swap is not possible or results in zero net output.
     * @return feeAmount The swap fee that would be applied to the gross amount.
     */
    function getNFTPriceInPool(address collection, address currency)
        public view
        returns (uint256 netAmountOut, uint256 feeAmount)
    {
        // Directly access pool storage. If pool doesn't exist, reserves will be 0.
        LiquidityPool storage pool = collectionPools[collection][currency];
        uint256 tokenReserve = pool.tokenReserve;
        uint256 nftReserve = pool.nftReserve;

        if (tokenReserve == 0) {
            // Cannot get tokens if the pool's token reserve is empty.
            return (0, 0);
        }

        // Gross amount out for selling 1 NFT = TokenReserve / (NFTReserve + 1)
        // This formula is valid even if nftReserve is 0.
        uint256 amountOut_gross = Math.mulDiv(tokenReserve, 1, nftReserve + 1);

        if (amountOut_gross == 0) {
            // If gross amount is zero (e.g., due to extreme reserve imbalance or zero tokenReserve), no value.
            return (0, 0);
        }

        feeAmount = Math.mulDiv(amountOut_gross, SWAP_FEE_BPS, 10000);
        
        if (amountOut_gross <= feeAmount) {
            // If the fee is greater than or equal to the gross amount, net output is 0.
            netAmountOut = 0;
            // The feeAmount returned is what would have been charged on the non-zero gross.
        } else {
            netAmountOut = amountOut_gross - feeAmount;
        }
        
        return (netAmountOut, feeAmount);
    }

    /**
     * @notice Swaps multiple NFTs owned by the caller for 'currency' tokens from the pool in a batch.
     * @dev NFTs are transferred to the pool. Pricing for each NFT is calculated based on reserves
     * updated after each preceding NFT in the batch is processed.
     * @param collection The address of the NFT collection contract.
     * @param tokenIds An array of IDs of the NFTs to sell. Must not be empty.
     * @param currency The address of the currency token (or NATIVE_CURRENCY).
     * @param minTotalAmountOut Optional: The minimum total net amount of tokens the caller expects to receive, for slippage protection. Use 0 to disable.
     */
    function batchSwapNFTToToken(
        address collection,
        uint256[] calldata tokenIds,
        address currency,
        uint256 minTotalAmountOut // Pass 0 if no minimum desired
    ) external nonReentrant {
        require(tokenIds.length > 0, "RoyaltyAMM: No token IDs provided for batch swap");
        
        // Get a reference to the pool. _getPool will revert if the pool doesn't exist.
        LiquidityPool storage pool = _getPool(collection, currency); 
        
        require(pool.tokenReserve > 0, "RoyaltyAMM: Pool has no token liquidity for swap");

        uint256 totalAmountOut_net_accumulator = 0;
        uint256 totalFee_accumulator = 0;
        IERC721 nftContract = IERC721(collection);

        for (uint i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // Ownership and state checks for each token
            require(nftContract.ownerOf(tokenId) == msg.sender, "RoyaltyAMM: Caller not owner of a token in batch");
            require(!pool.isNFTInPool[tokenId], "RoyaltyAMM: A token in batch is already pool liquidity");

            // Current reserves for this specific NFT's swap calculation
            // These read from `pool.variable` which is updated iteratively.
            uint256 currentTokenReserve = pool.tokenReserve;
            uint256 currentNftReserve = pool.nftReserve;

            // It's possible the pool's token reserve is depleted by prior swaps in the same batch.
            if (currentTokenReserve == 0) {
                // If desired, one could choose to stop here or continue if some NFTs already processed.
                // For simplicity, we'll require some tokens at the start of each mini-swap.
                // If it reaches 0, subsequent NFTs in batch won't yield tokens.
                // The initial check `pool.tokenReserve > 0` handles the all-or-nothing start.
                // This check ensures we don't try to calculate with 0 token reserve for an NFT.
                if (i > 0) { // Only break if it's not the first item and pool got depleted.
                     // Consider if partial batch execution is desired. For now, if it hits zero, next calcs will be zero.
                }
            }
            
            uint256 amountOut_gross_single = 0;
            if (currentTokenReserve > 0) { // Avoid division by zero if somehow tokenReserve became 0 mid-batch
                 amountOut_gross_single = Math.mulDiv(currentTokenReserve, 1, currentNftReserve + 1);
            }

            uint256 fee_single = 0;
            uint256 amountOut_net_single = 0;

            if (amountOut_gross_single > 0) {
                fee_single = Math.mulDiv(amountOut_gross_single, SWAP_FEE_BPS, 10000);
                if (amountOut_gross_single > fee_single) {
                    amountOut_net_single = amountOut_gross_single - fee_single;
                }
                // If amountOut_gross_single <= fee_single, net_single remains 0. Fee is still notionally 'earned' by LPs.
            }
            
            // Although we check currentTokenReserve > 0, also check if the specific net_single can be covered.
            // This is important as pool.tokenReserve is the *live* value.
            require(pool.tokenReserve >= amountOut_net_single, "RoyaltyAMM: Pool token reserve depleted for a sub-swap");

            // Transfer this NFT to the pool
            nftContract.safeTransferFrom(msg.sender, address(this), tokenId);

            // Update pool state *after* this single NFT's calculations and transfer
            if (amountOut_net_single > 0) {
                pool.tokenReserve = pool.tokenReserve - amountOut_net_single;
            }
            pool.nftReserve = pool.nftReserve + 1;
            pool.isNFTInPool[tokenId] = true;
            pool.poolNFTTokenIdsList.push(tokenId);
            pool.nftTokenIdToListIndex[tokenId] = pool.poolNFTTokenIdsList.length; // Assumes 1-based indexing

            if (fee_single > 0) {
                 pool.accumulatedFees = pool.accumulatedFees + fee_single;
            }
            
            // Update global stats using gross value of this part of the trade if it was non-zero
            if (amountOut_gross_single > 0) {
                collectionStats[collection].totalTradingVolume = collectionStats[collection].totalTradingVolume + amountOut_gross_single;
                collectionStats[collection].totalFeesCollected = collectionStats[collection].totalFeesCollected + fee_single; // Use actual fee_single calculated
            }

            totalAmountOut_net_accumulator = totalAmountOut_net_accumulator + amountOut_net_single;
            totalFee_accumulator = totalFee_accumulator + fee_single; // Sum of all fees from each step
        }

        // minTotalAmountOut check (optional slippage protection)
        if (minTotalAmountOut > 0) {
            require(totalAmountOut_net_accumulator >= minTotalAmountOut, "RoyaltyAMM: Slippage protection; less than min expected output");
        }
        
        // If, after all swaps, the total net to user is 0 (e.g., all fees consumed gross values),
        // it's still a valid transaction as NFTs were deposited and fees accrued.
        // However, a require might be desired here if user must receive *some* tokens.
        // For now, we allow totalAmountOut_net_accumulator to be 0.

        if (totalAmountOut_net_accumulator > 0) {
            _transferCurrency(currency, msg.sender, totalAmountOut_net_accumulator);
        }

        emit BatchSwapNFTToToken(
            collection,
            msg.sender,
            tokenIds,
            currency,
            totalAmountOut_net_accumulator,
            totalFee_accumulator
        );
    }

    /**
     * @notice Retrieves details for all created liquidity pools.
     * @return An array of PoolDetail structs.
     */
    function getPools() external view returns (PoolDetail[] memory) {
        PoolDetail[] memory allDetails = new PoolDetail[](allPoolIdentifiers.length);
        for (uint i = 0; i < allPoolIdentifiers.length; i++) {
            PoolIdentifier storage pId = allPoolIdentifiers[i];
            LiquidityPool storage pool = collectionPools[pId.collection][pId.currency];

            (uint256 priceToBuy, uint256 priceToSell) = getNFTPriceInPool(pId.collection, pId.currency);

            // Create a temporary in-memory copy of poolNFTTokenIdsList for the PoolDetail struct
            uint256[] memory currentNftTokenIds = new uint256[](pool.poolNFTTokenIdsList.length);
            for(uint j = 0; j < pool.poolNFTTokenIdsList.length; j++){
                currentNftTokenIds[j] = pool.poolNFTTokenIdsList[j];
            }

            allDetails[i] = PoolDetail({
                collectionAddress: pId.collection,
                currencyAddress: pId.currency,
                tokenReserve: pool.tokenReserve,
                nftReserveCount: pool.nftReserve,
                totalLiquidityShares: pool.totalLiquidityShares,
                accumulatedFees: pool.accumulatedFees,
                nftTokenIdsInPool: currentNftTokenIds,
                priceToBuyNFT: priceToBuy,
                priceToSellNFT: priceToSell
            });
        }
        return allDetails;
    }

    /**
     * @notice Retrieves the list of NFT token IDs currently held in a specific pool.
     * @param collection The address of the NFT collection.
     * @param currency The address of the currency.
     * @return An array of uint256 token IDs.
     */
    function getPoolNFTs(address collection, address currency) external view returns (uint256[] memory) {
        return collectionPools[collection][currency].poolNFTTokenIdsList;
    }


    // --- Internal Helper Functions ---

    /**
     * @dev Fetches a reference to a liquidity pool, reverting if not found.
     * @param collection The address of the NFT collection.
     * @param currency The address of the currency.
     * @return A storage reference to the LiquidityPool.
     */
    function _getPool(address collection, address currency) internal view returns (LiquidityPool storage) {
        // poolIdentifierIndex check is more robust for existence than just currency != address(0)
        require(poolIdentifierIndex[collection][currency] != 0, "RoyaltyAMM: Pool not found");
        LiquidityPool storage pool = collectionPools[collection][currency];
        // require(pool.currency != address(0), "RoyaltyAMM: Pool not found"); // Redundant if above check passes
        return pool;
    }
    
    /**
     * @dev Transfers 'currency' (native or ERC20) to a recipient.
     * @param currency The currency address (address(0) for native).
     * @param recipient The address of the recipient.
     * @param amount The amount to transfer.
     */
    function _transferCurrency(address currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (currency == NATIVE_CURRENCY) {
            payable(recipient).sendValue(amount);
        } else {
            IERC20(currency).safeTransfer(recipient, amount);
        }
    }

    /**
     * @dev Efficiently removes a tokenId from the pool's list of NFTs.
     * Uses the swap-and-pop mCOREod.
     * @param pool A storage reference to the LiquidityPool.
     * @param tokenIdToRemove The tokenId to remove from pool.poolNFTTokenIdsList.
     */
    function _removeTokenIdFromList(LiquidityPool storage pool, uint256 tokenIdToRemove) internal {
        uint256 listIndexToRemoveWithBase = pool.nftTokenIdToListIndex[tokenIdToRemove];
        require(listIndexToRemoveWithBase > 0, "RoyaltyAMM: TokenId not in list map for removal");
        uint256 listIndexToRemove = listIndexToRemoveWithBase - 1; // Convert to 0-based for array access

        uint256 listLength = pool.poolNFTTokenIdsList.length;
        require(listIndexToRemove < listLength, "RoyaltyAMM: Index out of bounds for NFT list");


        if (listIndexToRemove < listLength - 1) { // If not already the last element
            uint256 lastTokenId = pool.poolNFTTokenIdsList[listLength - 1];
            pool.poolNFTTokenIdsList[listIndexToRemove] = lastTokenId;
            pool.nftTokenIdToListIndex[lastTokenId] = listIndexToRemove + 1; // Update moved token's 1-based index
        }
        pool.poolNFTTokenIdsList.pop();
        delete pool.nftTokenIdToListIndex[tokenIdToRemove]; // Clear mapping for removed token
    }

    // --- ERC Receiver Callbacks ---
    // These allow the contract to receive NFTs via safeTransferFrom.

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }
/**
     * @notice Receives royalty amounts from an external source (like a marketplace)
     * and adds them as token liquidity to the specified pool.
     * @dev For NATIVE_CURRENCY, msg.value should equal royaltyAmount.
     * For ERC20 tokens, the tokens are expected to have been transferred to this contract
     * *before* this function call by the msg.sender (e.g., the marketplace contract).
     * This function then updates the pool's tokenReserve. No new LP shares are minted by this function;
     * the liquidity benefits the pool overall.
     * @param collection The NFT collection address of the pool.
     * @param currency The currency of the royalty and pool (address(0) for native).
     * @param royaltyAmount The amount of royalty to be added as liquidity.
     */
    function addRoyaltyAsLiquidity(
        address collection,
        address currency,
        uint256 royaltyAmount
    ) external payable nonReentrant { // Payable to receive native currency
        require(royaltyAmount > 0, "RoyaltyAMM: Royalty amount must be positive");
        
        // _getPool will revert if the pool doesn't exist.
        LiquidityPool storage pool = _getPool(collection, currency);

        if (currency == NATIVE_CURRENCY) {
            require(msg.value == royaltyAmount, "RoyaltyAMM: Native currency (msg.value) mismatch for royalty deposit");
            // Native currency is now part of this contract's balance due to msg.value.
        } else { // ERC20 Token
            require(msg.value == 0, "RoyaltyAMM: Native currency (msg.value) should not be sent for ERC20 royalty deposit");
            // For ERC20s, this function assumes that `royaltyAmount` of tokens
            // has already been transferred to this contract's address by the caller (msg.sender).
            // A 'balance check' could be added here for increased robustness, though the external
            // transfer by the caller is the primary mechanism for ERC20 receipt.
            // Example check (optional):
            // require(IERC20(currency).balanceOf(address(this)) >= previousBalance + royaltyAmount, "RoyaltyAMM: ERC20 royalty not received");
            // This check is complex due to needing `previousBalance` or dealing with concurrent receipts.
            // The current design relies on the caller (RareMarket) correctly pre-transferring ERC20s.
        }

        // Add the received royaltyAmount directly to the pool's token reserve
        pool.tokenReserve = pool.tokenReserve + royaltyAmount;

        // Note: This action increases the token liquidity of the pool.
        // It does not mint new LP shares to any specific entity.
        // This benefits existing LPs by potentially reducing slippage and increasing the underlying value per share.

        emit RoyaltyFundsAddedAsLiquidity(collection, currency, royaltyAmount, msg.sender); // msg.sender here will be the RareMarket contract
    }
    /**
     * @dev Handles the receipt of a batch of ERC1155 tokens.
     * @param operator The address which initiated the batch transfer (i.e. msg.sender)
     * @param from The address which previously owned the token
     * @param ids An array containing ids of each token being transferred (order and length must match values array)
     * @param values An array containing amounts of each token being transferred (order and length must match ids array)
     * @param data Additional data with no specified format
     * @return `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))` if transfer is allowed
     */
   function onERC1155BatchReceived(
    address operator,        // parameter: operator
    address from,            // parameter: from
    uint256[] memory ids,    // parameter: ids
    uint256[] memory values, // parameter: values
    bytes memory data        // parameter: data
) 
    public 
    pure 
    override 
    returns (bytes4)         // return type: bytes4
{
    return IERC1155Receiver.onERC1155BatchReceived.selector;
}
    
    // --- ERC165 Support ---
    /**
     * @dev See {IERC165-supportsInterface}.
     * This contract supports ERC721 and ERC1155 receiver interfaces.
     * It does NOT claim to support EIP-2981 via its royaltyInfo function due to signature mismatch.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId ||
               interfaceId == type(IERC1155Receiver).interfaceId ||
               // interfaceId == 0x2a55205a || // _INTERFACE_ID_ROYALTIES_EIP2981 - Removed, royaltyInfo signature mismatch
               super.supportsInterface(interfaceId);
    }
}

