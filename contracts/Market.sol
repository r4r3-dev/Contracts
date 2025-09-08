// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import '@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

interface IERC721Extended is IERC721 {
    function totalSupply() external view returns (uint256);
}

interface IRoyaltyEngine {
    function getRoyalty(
        address tokenAddress,
        uint256 tokenId,
        uint256 value
    ) external view returns (address payable[] memory recipients, uint256[] memory amounts);

    function isTrusted() external view returns (bool);
}

/**
 * @title RoyaltyAMM
 * @notice An AMM for ERC721 NFTs, paired with ERC20 tokens or native currency, with royalty management.
 * @dev Handles liquidity pools, NFT trading, and royalty reinvestment into pools.
 * Integrates with RareMarket by adding royalties as liquidity. Supports multiple royalty recipients.
 */
contract Royalty is ReentrancyGuard, AccessControl, IERC721Receiver, IERC1155Receiver, Pausable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    // --- Structs ---

    struct RoyaltyInfo {
        address payable[] recipients;
        uint24[] basisPoints;
    }

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

    struct CollectionFees {
        uint256 totalTradingVolume;
        uint256 totalFeesCollected;
    }

    struct PoolIdentifier {
        address collection;
        address currency;
    }

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

    uint256 public constant SWAP_FEE_BPS = 300; // Immutable to prevent runtime changes
    address public immutable NATIVE_CURRENCY;
    uint256 public constant MAX_BATCH_SIZE = 100;

    // --- State ---

    bytes32 public constant ADMIN_ROLE = keccak256('ADMIN_ROLE');
    address public royaltyEngineAddress;
    address public rareMarket;

    mapping(address => mapping(address => LiquidityPool)) public collectionPools;
    mapping(address => CollectionFees) public collectionStats;
    mapping(address => mapping(uint256 => RoyaltyInfo)) private _royalties;
    PoolIdentifier[] public allPoolIdentifiers;
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
        address indexed sourceMarketplace
    );
    event BatchSwapNFTToToken(
        address indexed collection,
        address indexed user,
        uint256[] tokenIds,
        address currency,
        uint256 totalAmountOutNet,
        uint256 totalFee
    );
    event LiquidityAdded(
        address indexed collection,
        address indexed provider,
        address currency,
        uint256 tokenAmount,
        uint256 sharesIssued
    );
    event NFTLiquidityAdded(address indexed collection, address indexed provider, address currency, uint256[] tokenIds);
    event LiquidityRemoved(
        address indexed collection,
        address indexed provider,
        address currency,
        uint256 tokenAmountRemoved,
        uint256 sharesBurned,
        uint256 feeShareReturned
    );
    event SwapNFTToToken(
        address indexed collection,
        address indexed user,
        uint256 tokenId,
        address currency,
        uint256 amountOut,
        uint256 fee
    );
    event SwapTokenToNFT(
        address indexed collection,
        address indexed user,
        uint256 tokenId,
        address currency,
        uint256 amountIn,
        uint256 fee
    );
    event FeesWithdrawn(address indexed collection, address indexed provider, address currency, uint256 amount);
    event SwapFeeSet(uint256 newFeeBps); // Retained for compatibility, though fee is now constant
    event RoyaltySet(address indexed collection, uint256 indexed tokenId, address recipient, uint256 totalBasisPoints);
    event NoRoyaltiesApplied(address indexed collection, uint256 tokenId, address currency);
    event RoyaltyDistributed(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 amount
    );
    event RoyaltyEngineUpdated(address indexed newRoyaltyEngine);
    event RareMarketUpdated(address indexed newRareMarket);

    // --- Constructor ---

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        royaltyEngineAddress = address(0); // Default to zero until set
        NATIVE_CURRENCY = address(0);
        rareMarket = address(0); // Initialize to zero, set via admin function
    }

    // --- Admin Functions ---

    function adminSetRoyalty(
        address tokenAddress,
        uint256 tokenId,
        address payable[] memory recipients,
        uint24[] memory basisPoints
    ) external onlyRole(ADMIN_ROLE) {
        require(tokenAddress != address(0), "RoyaltyAMM: Zero token address");
        require(recipients.length == basisPoints.length, "RoyaltyAMM: Mismatched arrays");
        _setRoyalty(tokenAddress, tokenId, recipients, basisPoints);
    }

    function setRoyaltyEngineAddress(address _newRoyaltyEngine) external onlyRole(ADMIN_ROLE) {
        require(_newRoyaltyEngine != address(0), "RoyaltyAMM: Zero address for royalty engine");
        royaltyEngineAddress = _newRoyaltyEngine;
        emit RoyaltyEngineUpdated(_newRoyaltyEngine);
    }

    function setRareMarket(address _newRareMarket) external onlyRole(ADMIN_ROLE) {
        require(_newRareMarket != address(0), "RoyaltyAMM: Zero address for rare market");
        rareMarket = _newRareMarket;
        emit RareMarketUpdated(_newRareMarket);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // --- Royalty Functions ---

    function setRoyalty(
        address tokenAddress,
        uint256 tokenId,
        address payable[] memory recipients,
        uint24[] memory basisPoints
    ) external whenNotPaused {
        require(tokenAddress != address(0), "RoyaltyAMM: Zero token address");
        require(IERC721(tokenAddress).ownerOf(tokenId) == msg.sender, "RoyaltyAMM: Not token owner");
        require(recipients.length == basisPoints.length, "RoyaltyAMM: Mismatched arrays");
        _setRoyalty(tokenAddress, tokenId, recipients, basisPoints);
    }

    function _setRoyalty(
        address tokenAddress,
        uint256 tokenId,
        address payable[] memory recipients,
        uint24[] memory basisPoints
    ) internal {
        require(recipients.length > 0, "RoyaltyAMM: No recipients provided");
        uint256 totalBps = 0;
        for (uint256 i = 0; i < basisPoints.length; i++) {
            totalBps += basisPoints[i];
            require(basisPoints[i] <= 10000, "RoyaltyAMM: Individual royalty too high");
        }
        require(totalBps <= 10000, "RoyaltyAMM: Total royalty exceeds 100%");
        _royalties[tokenAddress][tokenId] = RoyaltyInfo(recipients, basisPoints);
        emit RoyaltySet(tokenAddress, tokenId, recipients[0], totalBps);
    }

    function royaltyInfo(
        address tokenAddress,
        uint256 tokenId,
        uint256 salePrice
    ) external view returns (address receiver, uint256 royaltyAmount) {
        RoyaltyInfo memory info = _royalties[tokenAddress][tokenId];
        if (info.recipients.length > 0) {
            receiver = info.recipients[0];
            royaltyAmount = info.basisPoints[0] > 0 ? (salePrice * info.basisPoints[0]) / 10000 : 0;
        }
    }

    function getRoyalty(
        address tokenAddress,
        uint256 tokenId,
        uint256 value
    ) public view returns (address payable[] memory recipients, uint256[] memory amounts) {
        if (royaltyEngineAddress != address(0) && IRoyaltyEngine(royaltyEngineAddress).isTrusted()) {
            (recipients, amounts) = IRoyaltyEngine(royaltyEngineAddress).getRoyalty(tokenAddress, tokenId, value);
        } else {
            RoyaltyInfo memory info = _royalties[tokenAddress][tokenId];
            recipients = info.recipients.length > 0 ? info.recipients : new address payable[](1);
            amounts = new uint256[](recipients.length);
            uint256 totalRoyalty = 0;
            for (uint256 i = 0; i < recipients.length; i++) {
                amounts[i] = recipients[i] != address(0) ? (value * info.basisPoints[i]) / 10000 : 0;
                totalRoyalty += amounts[i];
            }
            require(totalRoyalty <= value, "RoyaltyAMM: Royalty exceeds value");
            if (recipients.length == 0) {
                recipients = new address payable[](1);
                amounts = new uint256[](1);
                recipients[0] = payable(address(0));
                amounts[0] = 0;
            }
        }
    }

    function _getTotalRoyaltyAmount(address tokenAddress, uint256 tokenId, uint256 value) internal view returns (uint256 totalRoyalty) {
        if (royaltyEngineAddress != address(0) && IRoyaltyEngine(royaltyEngineAddress).isTrusted()) {
            (address payable[] memory recipients, uint256[] memory amounts) = IRoyaltyEngine(royaltyEngineAddress).getRoyalty(tokenAddress, tokenId, value);
            require(recipients.length == amounts.length, "RoyaltyAMM: Invalid royalty data");
            for (uint256 i = 0; i < amounts.length; i++) {
                totalRoyalty += amounts[i];
            }
        } else {
            RoyaltyInfo memory info = _royalties[tokenAddress][tokenId];
            for (uint256 i = 0; i < info.basisPoints.length; i++) {
                if (info.recipients[i] != address(0)) {
                    totalRoyalty += (value * info.basisPoints[i]) / 10000;
                }
            }
        }
        require(totalRoyalty <= value, "RoyaltyAMM: Total royalty exceeds value");
    }

    function addRoyaltyAsLiquidity(address collection, address currency, uint256 royaltyAmount) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        require(rareMarket != address(0), "RoyaltyAMM: RareMarket not set");
        require(msg.sender == rareMarket, "RoyaltyAMM: Only RareMarket can call this function");
        require(royaltyAmount > 0, "RoyaltyAMM: Royalty amount must be positive");
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");

        if (currency == NATIVE_CURRENCY) {
            require(msg.value == royaltyAmount, "RoyaltyAMM: Native currency mismatch");
        } else {
            require(msg.value == 0, "RoyaltyAMM: Native currency sent for ERC20");
            uint256 balanceBefore = IERC20(currency).balanceOf(address(this));
            IERC20(currency).safeTransferFrom(msg.sender, address(this), royaltyAmount);
            uint256 balanceAfter = IERC20(currency).balanceOf(address(this));
            require(balanceAfter >= balanceBefore + royaltyAmount, "RoyaltyAMM: ERC20 royalty not received");
        }

        LiquidityPool storage pool = collectionPools[collection][currency];
        uint256 totalRoyalty = _getTotalRoyaltyAmount(collection, 0, royaltyAmount);

        if (totalRoyalty == 0) {
            pool.tokenReserve += royaltyAmount;
            emit NoRoyaltiesApplied(collection, 0, currency);
        } else {
            require(royaltyAmount >= totalRoyalty, "RoyaltyAMM: Insufficient royalty amount for distribution");
            (address payable[] memory recipients, uint256[] memory amounts) = getRoyalty(collection, 0, royaltyAmount);
            uint256 remainingAmount = royaltyAmount;

            // State changes before external calls
            for (uint256 i = 0; i < recipients.length; i++) {
                if (amounts[i] > 0 && recipients[i] != address(0)) {
                    remainingAmount -= amounts[i];
                }
            }
            if (remainingAmount > 0) {
                pool.tokenReserve += remainingAmount;
                emit RoyaltyFundsAddedAsLiquidity(collection, currency, remainingAmount, msg.sender);
            }

            // External calls after state updates
            for (uint256 i = 0; i < recipients.length; i++) {
                if (amounts[i] > 0 && recipients[i] != address(0)) {
                    if (currency == NATIVE_CURRENCY) {
                        payable(recipients[i]).sendValue(amounts[i]);
                    } else {
                        IERC20(currency).safeTransfer(recipients[i], amounts[i]);
                    }
                    emit RoyaltyDistributed(collection, 0, recipients[i], amounts[i]);
                }
            }
        }
    }

    function createPool(address collection, address currency, uint256[] calldata initialTokenIds, uint256 initialTokenAmount) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        require(initialTokenIds.length > 0, "RoyaltyAMM: Must deposit at least one NFT");
        require(initialTokenIds.length <= MAX_BATCH_SIZE, "RoyaltyAMM: Too many tokens in batch");
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        require(poolIdentifierIndex[collection][currency] == 0, "RoyaltyAMM: Pool already exists");

        LiquidityPool storage pool = collectionPools[collection][currency];
        pool.currency = currency;

       
        allPoolIdentifiers.push(PoolIdentifier(collection, currency));
        poolIdentifierIndex[collection][currency] = allPoolIdentifiers.length;
        for (uint256 i = 0; i < initialTokenIds.length; i++) {
            uint256 tokenId = initialTokenIds[i];

            require(!pool.isNFTInPool[tokenId], "RoyaltyAMM: Initial NFT already marked in pool");

            // State changes before external call
            pool.isNFTInPool[tokenId] = true;
            pool.poolNFTTokenIdsList.push(tokenId);
            pool.nftTokenIdToListIndex[tokenId] = pool.poolNFTTokenIdsList.length;
            pool.nftReserve += 1;
        }

        uint256 sharesIssued = 0;
        if (initialTokenAmount > 0) {
            if (currency == NATIVE_CURRENCY) {
                require(msg.value == initialTokenAmount, "RoyaltyAMM: Native currency value mismatch");
            } else {
                require(msg.value == 0, "RoyaltyAMM: Native currency sent for ERC20 pool");
                IERC20(currency).safeTransferFrom(msg.sender, address(this), initialTokenAmount);
            }
            pool.tokenReserve += initialTokenAmount;
            sharesIssued = initialTokenAmount;
            pool.providerTokenShares[msg.sender] += sharesIssued;
            pool.totalLiquidityShares += sharesIssued;
        }

        emit PoolCreated(collection, currency, msg.sender, initialTokenAmount, initialTokenIds);
        if (initialTokenAmount > 0) {
            emit LiquidityAdded(collection, msg.sender, currency, initialTokenAmount, sharesIssued);
        }
    }

    function swapNFTToToken(address collection, uint256 tokenId, address currency) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.tokenReserve > 0, "RoyaltyAMM: Insufficient token liquidity in pool");
        require(IERC721(collection).ownerOf(tokenId) == msg.sender, "RoyaltyAMM: Not owner of token");
        require(!pool.isNFTInPool[tokenId], "RoyaltyAMM: NFT is already pool liquidity");

        uint256 tokenReserveBefore = pool.tokenReserve;
        uint256 nftReserveBefore = pool.nftReserve;

        uint256 amountOut_gross = (tokenReserveBefore * 1) / (nftReserveBefore + 1);
        uint256 fee = (tokenReserveBefore * SWAP_FEE_BPS) / ((nftReserveBefore + 1) * 10000);
        uint256 amountOut_net = amountOut_gross > fee ? amountOut_gross - fee : 0;
        require(amountOut_net > 0, "RoyaltyAMM: Net amount out is zero after fee");
        require(pool.tokenReserve >= amountOut_net, "RoyaltyAMM: AMM insufficient token reserve for swap");

        // State changes before external call
        pool.tokenReserve -= amountOut_net;
        pool.nftReserve += 1;
        pool.isNFTInPool[tokenId] = true;
        pool.poolNFTTokenIdsList.push(tokenId);
        pool.nftTokenIdToListIndex[tokenId] = pool.poolNFTTokenIdsList.length;
        pool.accumulatedFees += fee;
        collectionStats[collection].totalTradingVolume += amountOut_gross;
        collectionStats[collection].totalFeesCollected += fee;

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        _transferCurrency(currency, msg.sender, amountOut_net);

        emit SwapNFTToToken(collection, msg.sender, tokenId, currency, amountOut_net, fee);
    }

    function swapTokenToNFT(address collection, address currency, uint256 tokenIdToReceive) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.nftReserve > 0, "RoyaltyAMM: No NFTs in pool to swap");
        require(pool.isNFTInPool[tokenIdToReceive], "RoyaltyAMM: Chosen NFT not in pool liquidity");

        uint256 tokenReserveBefore = pool.tokenReserve;
        uint256 nftReserveBefore = pool.nftReserve;
        require(nftReserveBefore > 1, "RoyaltyAMM: At least two NFTs must be in pool to buy one");

        uint256 amountIn_net = (tokenReserveBefore * 1) / (nftReserveBefore - 1);
        uint256 amountIn_gross = (tokenReserveBefore * 10000) / ((nftReserveBefore - 1) * (10000 - SWAP_FEE_BPS));
        uint256 fee = amountIn_gross - amountIn_net;
        require(amountIn_gross > 0, "RoyaltyAMM: Gross amount in is zero");


        // State changes before external call
        pool.tokenReserve += amountIn_net;
        pool.nftReserve -= 1;
        pool.isNFTInPool[tokenIdToReceive] = false;
        _removeTokenIdFromList(pool, tokenIdToReceive);
        pool.accumulatedFees += fee;
        collectionStats[collection].totalTradingVolume += amountIn_gross;
        collectionStats[collection].totalFeesCollected += fee;

        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenIdToReceive);

        emit SwapTokenToNFT(collection, msg.sender, tokenIdToReceive, currency, amountIn_gross, fee);
    }

    function batchSwapNFTToToken(address collection, uint256[] calldata tokenIds, address currency, uint256 minTotalAmountOut) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(tokenIds.length > 0, "RoyaltyAMM: No token IDs provided for batch swap");
        require(tokenIds.length <= MAX_BATCH_SIZE, "RoyaltyAMM: Too many tokens in batch");
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.tokenReserve > 0, "RoyaltyAMM: Pool has no token liquidity for swap");

        uint256 totalAmountOutNet = 0;
        uint256 totalFee = 0;
  
        for (uint256 i = 0; i < tokenIds.length; i++) {
            
            require(!pool.isNFTInPool[tokenIds[i]], "RoyaltyAMM: A token in batch is already pool liquidity");

            uint256 amountOutGross = (pool.tokenReserve * 1) / (pool.nftReserve + 1);
            uint256 feeSingle = (pool.tokenReserve * SWAP_FEE_BPS) / ((pool.nftReserve + 1) * 10000);
            uint256 amountOutNetSingle = amountOutGross > feeSingle ? amountOutGross - feeSingle : 0;

            require(pool.tokenReserve >= amountOutNetSingle, "RoyaltyAMM: Pool token reserve depleted for a sub-swap");

            // State changes before external call
            if (amountOutNetSingle > 0) {
                pool.tokenReserve -= amountOutNetSingle;
            }
            pool.nftReserve += 1;
            pool.isNFTInPool[tokenIds[i]] = true;
            pool.poolNFTTokenIdsList.push(tokenIds[i]);
            pool.nftTokenIdToListIndex[tokenIds[i]] = pool.poolNFTTokenIdsList.length;
            pool.accumulatedFees += feeSingle;
            collectionStats[collection].totalTradingVolume += amountOutGross;
            collectionStats[collection].totalFeesCollected += feeSingle;

            totalAmountOutNet += amountOutNetSingle;
            totalFee += feeSingle;

        }

        require(totalAmountOutNet >= minTotalAmountOut, "RoyaltyAMM: Slippage protection; less than min expected output");

        if (totalAmountOutNet > 0) {
            _transferCurrency(currency, msg.sender, totalAmountOutNet);
        }

        emit BatchSwapNFTToToken(collection, msg.sender, tokenIds, currency, totalAmountOutNet, totalFee);
    }

    function addLiquidity(address collection, address currency, uint256 amount) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        require(amount > 0, "RoyaltyAMM: Amount must be positive");
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        LiquidityPool storage pool = _getPool(collection, currency);

        if (currency == NATIVE_CURRENCY) {
            require(msg.value == amount, "RoyaltyAMM: Native currency value mismatch");
        } else {
            require(msg.value == 0, "RoyaltyAMM: Native currency sent for ERC20 pool");
            IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 sharesIssued;
        if (pool.totalLiquidityShares == 0 || pool.tokenReserve == 0) {
            sharesIssued = amount;
        } else {
            sharesIssued = (amount * pool.totalLiquidityShares) / pool.tokenReserve;
        }
        require(sharesIssued > 0, "RoyaltyAMM: Shares issued must be positive");

        pool.tokenReserve += amount;
        pool.providerTokenShares[msg.sender] += sharesIssued;
        pool.totalLiquidityShares += sharesIssued;

        emit LiquidityAdded(collection, msg.sender, currency, amount, sharesIssued);
    }

    function depositNFTsForSwap(address collection, address currency, uint256[] calldata tokenIds) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(tokenIds.length > 0, "RoyaltyAMM: No token IDs provided");
        require(tokenIds.length <= MAX_BATCH_SIZE, "RoyaltyAMM: Too many tokens in batch");
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        LiquidityPool storage pool = _getPool(collection, currency);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(tokenIds.length <= 100, "Too many tokens");
            require(!pool.isNFTInPool[tokenId], "RoyaltyAMM: NFT already in pool");


            pool.isNFTInPool[tokenId] = true;
            pool.poolNFTTokenIdsList.push(tokenId);
            pool.nftTokenIdToListIndex[tokenId] = pool.poolNFTTokenIdsList.length;
            pool.nftReserve += 1;
        }
        emit NFTLiquidityAdded(collection, msg.sender, currency, tokenIds);
    }

    function removeLiquidity(address collection, address currency, uint256 shareAmount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.providerTokenShares[msg.sender] >= shareAmount, "RoyaltyAMM: Insufficient shares");
        require(pool.totalLiquidityShares > 0, "RoyaltyAMM: No total liquidity shares in pool");
        require(shareAmount > 0, "RoyaltyAMM: Cannot remove zero shares");

        uint256 tokenAmountToWithdraw = (shareAmount * pool.tokenReserve) / pool.totalLiquidityShares;
        uint256 feeShareToWithdraw = (shareAmount * pool.accumulatedFees) / pool.totalLiquidityShares;

        require(tokenAmountToWithdraw > 0 || feeShareToWithdraw > 0, "RoyaltyAMM: No value to withdraw");

        pool.providerTokenShares[msg.sender] -= shareAmount;
        pool.totalLiquidityShares -= shareAmount;
        pool.tokenReserve -= tokenAmountToWithdraw;
        pool.accumulatedFees -= feeShareToWithdraw;

        uint256 totalWithdraw = tokenAmountToWithdraw + feeShareToWithdraw;
        if (totalWithdraw > 0) {
            _transferCurrency(currency, msg.sender, totalWithdraw);
        }

        emit LiquidityRemoved(collection, msg.sender, currency, tokenAmountToWithdraw, shareAmount, feeShareToWithdraw);
    }

    function withdrawFees(address collection, address currency) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        LiquidityPool storage pool = _getPool(collection, currency);
        require(pool.totalLiquidityShares > 0, "RoyaltyAMM: No total liquidity in pool");

        uint256 providerShares = pool.providerTokenShares[msg.sender];
        require(providerShares > 0, "RoyaltyAMM: No shares in this pool for provider");

        uint256 feeShare = (providerShares * pool.accumulatedFees) / pool.totalLiquidityShares;
        require(feeShare > 0, "RoyaltyAMM: No fees to withdraw for provider");

        pool.accumulatedFees -= feeShare;
        _transferCurrency(currency, msg.sender, feeShare);
        emit FeesWithdrawn(collection, msg.sender, currency, feeShare);
    }

    function getNFTPriceInPool(address collection, address currency) public view returns (uint256 netAmountOut, uint256 feeAmount) {
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        LiquidityPool storage pool = collectionPools[collection][currency];
        uint256 tokenReserve = pool.tokenReserve;
        uint256 nftReserve = pool.nftReserve;

        if (tokenReserve == 0) {
            return (0, 0);
        }

        uint256 amountOut_gross = (tokenReserve * 1) / (nftReserve + 1);
        if (amountOut_gross == 0) {
            return (0, 0);
        }
        feeAmount = (tokenReserve * SWAP_FEE_BPS) / ((nftReserve + 1) * 10000);
        netAmountOut = amountOut_gross > feeAmount ? amountOut_gross - feeAmount : 0;
    }

    function getPools() external view returns (PoolDetail[] memory) {
        PoolDetail[] memory allDetails = new PoolDetail[](allPoolIdentifiers.length);
        for (uint256 i = 0; i < allPoolIdentifiers.length; i++) {
            PoolIdentifier storage pId = allPoolIdentifiers[i];
            LiquidityPool storage pool = collectionPools[pId.collection][pId.currency];

            (uint256 priceToBuy, uint256 priceToSell) = getNFTPriceInPool(pId.collection, pId.currency);

            uint256[] memory currentNftTokenIds = new uint256[](pool.poolNFTTokenIdsList.length);
            for (uint256 j = 0; j < pool.poolNFTTokenIdsList.length; j++) {
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

    function getPoolNFTs(address collection, address currency) external view returns (uint256[] memory) {
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        return collectionPools[collection][currency].poolNFTTokenIdsList;
    }

    function _getPool(address collection, address currency) internal view returns (LiquidityPool storage) {
        require(collection != address(0), "RoyaltyAMM: Zero collection address");
        require(currency != address(0), "RoyaltyAMM: Zero currency address");
        require(poolIdentifierIndex[collection][currency] != 0, "RoyaltyAMM: Pool not found");
        return collectionPools[collection][currency];
    }

    function _transferCurrency(address currency, address recipient, uint256 amount) internal nonReentrant {
        if (amount == 0) return;
        require(recipient != address(0), "RoyaltyAMM: Zero recipient address");
        if (currency == NATIVE_CURRENCY) {
            payable(recipient).sendValue(amount);
        } else {
            IERC20(currency).safeTransfer(recipient, amount);
        }
    }

    function _removeTokenIdFromList(LiquidityPool storage pool, uint256 tokenIdToRemove) internal {
        uint256 listIndexToRemoveWithBase = pool.nftTokenIdToListIndex[tokenIdToRemove];
        require(listIndexToRemoveWithBase > 0, "RoyaltyAMM: TokenId not in list map for removal");
        uint256 listIndexToRemove = listIndexToRemoveWithBase - 1;

        uint256 listLength = pool.poolNFTTokenIdsList.length;
        require(listIndexToRemove < listLength, "RoyaltyAMM: Index out of bounds for NFT list");

        if (listIndexToRemove < listLength - 1) {
            uint256 lastTokenId = pool.poolNFTTokenIdsList[listLength - 1];
            pool.poolNFTTokenIdsList[listIndexToRemove] = lastTokenId;
            pool.nftTokenIdToListIndex[lastTokenId] = listIndexToRemove + 1;
        }
        pool.poolNFTTokenIdsList.pop();
        delete pool.nftTokenIdToListIndex[tokenIdToRemove];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == 0x2a55205a || // EIP-2981
            super.supportsInterface(interfaceId);
    }
}