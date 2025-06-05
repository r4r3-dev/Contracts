// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Interface for the CollectionPool contract
 */
interface ICollectionPool {
    // Event emitted when a pool is registered or updated
    event PoolRegistered(address indexed collection, address indexed currency, uint96 royaltyPercentForPool);
    // Event emitted when an NFT is swapped for currency
    event NFTSwapped(address indexed collection, uint256 indexed tokenId, address indexed swapper, uint256 amountPaid);
    // Event emitted when funds are added to the pool from a sale
    event PoolFunded(address indexed collection, uint256 amountAdded);

    // Function called by Marketplace to register/configure a pool
    function registerPool(address collection, address currency, uint96 royaltyPercentForPool) external;
    // Function called by Marketplace to add funds from sales
    function addFunds(address collection, uint256 amount) external payable;
    // Function called by users to swap an NFT
    function swapNFTForCurrency(address collection, uint256 tokenId, uint256 // ERC1155 amount (use 1 for ERC721)
    ) external returns (uint256 amountPaid);
    // View function to get pool details
    function getPoolInfo(address collection) external view returns (address currency, uint256 balance, uint96 royaltyPercentForPool, bool isEnabled);
    // View function to calculate the current swap value for an NFT
    function getSwapValue(address collection, uint256 tokenId // ERC1155 tokenId (ignored for ERC721)
    ) external view returns (uint256);
}