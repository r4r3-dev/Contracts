// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRoyaltyEngine {
    // Royalty lookup function (already used by the market)
    function getRoyalty(
        address tokenAddress,
        uint256 tokenId,
        uint256 value
    ) external view returns (address payable[] memory recipients, uint256[] memory amounts); // Made view as in Royalty contract

    // --- AMM Pool Management ---
    // Note: User must approve/send assets to the RoyaltyEngine address *before* calling these via the market facade
    function createPool(
        address collection,
        address currency, // address(0) for native currency
        uint256[] calldata initialTokenIds,
        uint256 initialTokenAmount // Amount of `currency` to add
    ) external payable;

    function addLiquidity(
        address collection,
        address currency, // address(0) for native currency
        uint256 amount // Amount of `currency` to add
    ) external payable; // Payable to receive native currency

    function depositNFTsForSwap(
        address collection,
        address currency, // Pool currency (address(0) for native)
        uint256[] calldata tokenIds // NFTs to add as liquidity
    ) external;

    function removeLiquidity(
        address collection,
        address currency, // Pool currency (address(0) for native)
        uint256 shareAmount // Amount of LP shares to burn
    ) external;

    // --- AMM Swap Functions ---
    // Note: User must approve/send assets to the RoyaltyEngine address *before* calling these via the market facade
    function swapNFTToToken(
        address collection,
        uint256 tokenId, // NFT to sell to pool
        address currency // Pool currency (address(0) for native)
    ) external; // User receives tokens, RoyaltyEngine transfers NFT from user

    function swapTokenToNFT(
        address collection,
        address currency, // Pool currency (address(0) for native)
        uint256 tokenIdToReceive // NFT to buy from pool
    ) external payable; // User sends tokens/native currency, RoyaltyEngine transfers NFT to user

    // --- View Functions (for UI/Marketplace info) ---
    struct PoolDetail { // Define struct here for interface compatibility
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
    function getNFTPriceInPool(address collection, address currency) external view returns (uint256 priceToBuyNFT, uint256 priceToSellNFT);
    function getPools() external view returns (PoolDetail[] memory);
    function getPoolNFTs(address collection, address currency) external view returns (uint256[] memory);
    function getPendingRoyalty(address recipient, address currency) external view returns (uint256);
    function getProviderShares(address provider, address collection, address currency) external view returns (uint256);
    function addRoyaltyAsLiquidity(address collection, address currency, uint256 royaltyAmount) external payable;

    // --- Royalty Management (if market used it - currently it handles royalties internally) ---
    function distributeRoyalties(address collection, uint256 tokenId, address currency, uint256 saleAmount) external; // Not used by current market logic
    function withdrawRoyalty(address currency) external; // Not used by current market logic
}