// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


/**
 * @title Interface for the AuctionEngine contract
 */
interface IAuctionEngine {
    // Define necessary events and functions for auctions
    // Example:
    event AuctionCreated(uint256 indexed auctionId, address indexed nftContract, uint256 indexed tokenId, address seller, address currency, uint256 startPrice, uint256 endTime);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionResulted(uint256 indexed auctionId, address winner, uint256 winningBid);
    event AuctionCancelled(uint256 indexed auctionId);

    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 amount, // For ERC1155, 1 for ERC721
        address currency,
        uint256 startPrice,
        uint256 duration
    ) external returns (uint256 auctionId);

    function placeBid(uint256 auctionId, uint256 amount) external payable;

    function cancelAuction(uint256 auctionId) external;

    function endAuction(uint256 auctionId) external;

    // Add view functions as needed, e.g., getAuctionDetails(uint256 auctionId)
}