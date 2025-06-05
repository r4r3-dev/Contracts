// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import '@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import './libraries/ReentrancyGuard.sol';
import './interfaces/IRoyaltyAMM.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Royalty} from './Royalties.sol';
import "./libraries/ERC165Utils.sol";
import "./interfaces/IERC2981.sol";


/**
 * 
██████╗  █████╗ ██████╗ ███████╗██████╗  █████╗ ██╗   ██╗
██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔══██╗╚██╗ ██╔╝
██████╔╝███████║██████╔╝█████╗  ██████╔╝███████║ ╚████╔╝ 
██╔══██╗██╔══██║██╔══██╗██╔══╝  ██╔══██╗██╔══██║  ╚██╔╝  
██║  ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║   ██║   
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝   ╚═╝   
 * @title RareMarket NFT Marketplace
 * @notice A contract for listing, buying, auctioning, and making offers on ERC721 and ERC1155 NFTs.
 * It handles platform fees and royalty distributions using the integrated RoyaltyEngine library.
 * @dev This contract requires NFTs to be transferred to it for listings and auctions.
 * It supports both native currency and ERC20 tokens for payments.
 * Access control is used for administrative functions.
 */

contract RareMarket is AccessControl, ReentrancyGuard, IERC721Receiver, IERC1155Receiver {
    using Address for address payable;
    using SafeERC20 for IERC20;
    address public royaltyEngineAddress;

    /// @notice Role for administrative actions like updating fees.
    bytes32 public constant ADMIN_ROLE = keccak256('ADMIN_ROLE');

    /// @notice The percentage of sales taken as a platform fee, in basis points (1% = 100 bps).
    uint256 public platformFeeBps;
    /// @notice The recipient of platform fees.
    address payable public platformFeeRecipient;
    /// @notice Standard address for native currency transactions (e.g., CORE), typically address(0).
    address public immutable NATIVE_CURRENCY;

    /// @dev Enum for token types.
    enum TokenType {
        ERC721,
        ERC1155
    }
    /// @dev Enum for listing/auction/offer statuses.
    enum Status {
        Inactive,
        Active,
        Sold,
        Cancelled,
        Finalized
    } // Sold might be redundant if Inactive is used after completion

    /// @notice Represents a direct sale listing.
    struct Listing {
        uint256 listingId; // Unique identifier for the listing
        address listingCreator; // Address that created the listing
        address assetContract; // Address of the NFT contract
        uint256 tokenId; // ID of the token being listed
        uint256 quantity; // Quantity of tokens (1 for ERC721)
        address currency; // Payment currency (address(0) for native)
        uint256 pricePerToken; // Price for each token unit
        uint256 startTimestamp; // Timestamp when the listing becomes active
        uint256 endTimestamp; // Timestamp when the listing expires
        TokenType tokenType; // Type of token (ERC721 or ERC1155)
        Status status; // Current status of the listing
    }

    /// @notice Represents an auction for NFTs.
    struct Auction {
        uint256 auctionId; // Unique identifier for the auction
        address creator; // Address that created the auction
        address assetContract; // Address of the NFT contract
        uint256 tokenId; // ID of the token being auctioned
        uint256 quantity; // Quantity of tokens (1 for ERC721)
        address currency; // Payment currency (address(0) for native)
        uint256 startTimestamp; // Timestamp when bidding can start
        uint256 endTimestamp; // Timestamp when the auction ends
        address highestBidder; // Current highest bidder
        uint256 highestBid; // Current highest bid amount
        TokenType tokenType; // Type of token (ERC721 or ERC1155)
        Status status; // Current status of the auction
    }

        struct SweptItemDetails {
        uint256 id;
        address creator;
        address asset;
        uint256 token;
        uint256 qty;
        address currency;
        uint256 price;
        TokenType tokenType;
    }

    /// @notice Represents an offer made by a buyer for an NFT.
    struct Offer {
        uint256 offerId; // Unique identifier for the offer
        address offeror; // Address that made the offer
        address assetContract; // Address of the NFT contract for which the offer is made
        uint256 tokenId; // ID of the token being offered for
        uint256 quantity; // Quantity of tokens (1 for ERC721)
        address currency; // Payment currency (address(0) for native)
        uint256 pricePerToken; // Price offered per token unit
        uint256 expiryTimestamp; // Timestamp when the offer expires
        TokenType tokenType; // Type of token (ERC721 or ERC1155)
        Status status; // Current status of the offer
    }
    /// @notice Input structure for items to be purchased in a sweepCollection call.
    struct SweepItemInput {
        uint256 listingId;      // ID of the listing to buy from
        uint256 quantityToBuy;  // Quantity of tokens to buy from this listing
    }
    // --- Storage ---
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Offer) public offers;

    /// @dev Tracks pending withdrawals for native currency, keyed by user address.
    mapping(address => uint256) public pendingNativeWithdrawals;
    /// @dev Tracks pending withdrawals for ERC20 tokens, keyed by user address then token address.
    mapping(address => mapping(address => uint256)) public pendingErc20Withdrawals;
    // Note: pendingRoyalties was removed as royalties are now also handled by pendingNative/Erc20Withdrawals.

    /// @notice Counter for total listings created.
    uint256 public totalListings;
    /// @notice Counter for total auctions created.
    uint256 public totalAuctions;
    /// @notice Counter for total offers made.
    uint256 public totalOffers;

    /// @notice Tracks total sales volume for each collection, per currency.
    /// @dev mapping: assetContract => currency => totalVolume
    mapping(address => mapping(address => uint256)) public totalVolumeSoldByCollectionAndCurrency;

    // --- Events ---
    event NewListing(
        uint256 indexed listingId,
        address indexed listingCreator,
        address indexed assetContract,
        uint256 tokenId,
        uint256 quantity,
        address currency,
        uint256 pricePerToken
    );
     /// @notice Emitted when a collection is swept (multiple NFTs purchased in one transaction).
    event CollectionSwept(
        address indexed buyer,
        address indexed assetContract, // This will be the contract of the *first* NFT in the sweep, or common across all if enforced
        address currency,
        uint256 totalCost,
        uint256 numberOfNFTsSwept // Total quantity of NFTs transferred
    );
    event ListingCancelled(uint256 indexed listingId, address indexed canceller);
    event ListingSold(
        uint256 indexed listingId,
        address indexed seller,
        address indexed buyer,
        uint256 quantitySold,
        uint256 totalPricePaid
    );
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed creator,
        address indexed assetContract,
        uint256 tokenId,
        uint256 quantity,
        address currency,
        uint256 endTimestamp
    );
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionCancelled(uint256 indexed auctionId, address indexed canceller); // Assuming admin might cancel, or creator if no bids
    event AuctionFinalized(
        uint256 indexed auctionId,
        address indexed winner,
        address indexed creator,
        uint256 winningBid
    );
    event NewOffer(uint256 indexed offerId, address indexed offeror, address indexed assetContract, uint256 tokenId, uint256 quantity,address currency, uint256 pricePerToken );
    event OfferAccepted(uint256 indexed offerId, address indexed acceptor, address indexed offeror);
    event OfferCancelled(uint256 indexed offerId, address indexed offeror);
    event PlatformFeeUpdated(uint256 newPlatformFeeBps);
    event PlatformFeeRecipientUpdated(address indexed newPlatformFeeRecipient);
    event FundsWithdrawn(address indexed user, address indexed currency, uint256 amount);

    /**
     * @notice Constructor to initialize the marketplace.
     * @param _platformFeeRecipient The initial address to receive platform fees.
     * @param _platformFeeBps The initial platform fee in basis points (e.g., 250 for 2.5%).
     */
    constructor(address payable _platformFeeRecipient, uint256 _platformFeeBps, address _royaltyEngineAddr) {
        require(_platformFeeRecipient != address(0), 'RareMarket: Zero address for fee recipient');
        require(_platformFeeBps <= 1000, 'RareMarket: Fee exceeds 10%'); // Max 10% platform fee

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        royaltyEngineAddress = _royaltyEngineAddr;
        platformFeeRecipient = _platformFeeRecipient;
        platformFeeBps = _platformFeeBps;
        NATIVE_CURRENCY = address(0); // Initialize native currency marker
    }

    // --- Admin Functions ---
/**
 
    /**
     * @notice Updates the platform fee percentage.
     * @dev Only callable by an address with ADMIN_ROLE.
     * @param _newFeeBps The new platform fee in basis points (e.g., 300 for 3%). Max 1000 (10%).
     */
    function updatePlatformFeeBps(uint256 _newFeeBps) external onlyRole(ADMIN_ROLE) {
        require(_newFeeBps <= 1000, 'RareMarket: Fee exceeds 10%'); // Max 10% platform fee
        platformFeeBps = _newFeeBps;
        emit PlatformFeeUpdated(_newFeeBps);
    }

    /**
     * @notice Updates the recipient address for platform fees.
     * @dev Only callable by an address with ADMIN_ROLE.
     * @param _newRecipient The new address to receive platform fees.
     */
    function updatePlatformFeeRecipient(address payable _newRecipient) external onlyRole(ADMIN_ROLE) {
        require(_newRecipient != address(0), 'RareMarket: Zero address for new recipient');
        platformFeeRecipient = _newRecipient;
        emit PlatformFeeRecipientUpdated(_newRecipient);
    }

    /* @notice Allows a user to buy multiple NFTs from different active listings in a single transaction.
     * @dev All items in the sweep must use the same `_currency`.
     * @param _itemsToSweep An array of `SweepItemInput` structs, each specifying a listingId and quantityToBuy.
     * @param _currency The currency used for payment for all items in the sweep.
     * @param _buyFor The address to receive the purchased NFTs. If address(0), defaults to msg.sender.
     */
    function sweepCollection(
        SweepItemInput[] calldata _itemsToSweep,
        address _currency,
        address _buyFor
    ) external payable nonReentrant {
        require(_itemsToSweep.length > 0, "RareMarket: No items to sweep");
        
        address buyerActual = (_buyFor == address(0)) ? msg.sender : _buyFor;
        require(buyerActual != address(0), "RareMarket: Buyer cannot be zero address");

        uint256 totalCalculatedPrice = 0;
        uint256 i; 

        for (i = 0; i < _itemsToSweep.length; i++) {
            SweepItemInput calldata item = _itemsToSweep[i];
            Listing storage listing = listings[item.listingId];

            require(listing.status == Status.Active, "RareMarket: Sweep item listing not active");
            require(block.timestamp >= listing.startTimestamp, "RareMarket: Sweep item listing not yet started");
            require(block.timestamp <= listing.endTimestamp, "RareMarket: Sweep item listing expired");
            require(item.quantityToBuy > 0, "RareMarket: Sweep item quantity must be > 0");
            require(item.quantityToBuy <= listing.quantity, "RareMarket: Not enough quantity for sweep item");
            require(listing.currency == _currency, "RareMarket: Sweep item currency mismatch");
            
            totalCalculatedPrice += listing.pricePerToken * item.quantityToBuy;
        }

        
        _processPayment(msg.sender, _currency, totalCalculatedPrice);

        uint256 totalNFTsSwept = 0;
        address firstAssetContract = address(0); // For the CollectionSwept event

       
        for (i = 0; i < _itemsToSweep.length; i++) {
            SweepItemInput calldata item = _itemsToSweep[i];
            Listing storage listing = listings[item.listingId]; // Re-access storage pointer

            uint256 itemPrice = listing.pricePerToken * item.quantityToBuy;

            _distributeSaleProceeds(
                listing.listingCreator,
                listing.assetContract,
                listing.tokenId,
                itemPrice,
                listing.currency // This is same as _currency due to earlier check
            );

            _transferNFTToUser(listing.assetContract, buyerActual, listing.tokenId, item.quantityToBuy, listing.tokenType);

            listing.quantity -= item.quantityToBuy;
            if (listing.quantity == 0) {
                listing.status = Status.Sold;
            }

            totalNFTsSwept += item.quantityToBuy;
            if (firstAssetContract == address(0)) {
                firstAssetContract = listing.assetContract;
            }

            emit ListingSold(item.listingId, listing.listingCreator, buyerActual, item.quantityToBuy, itemPrice);
        }

        emit CollectionSwept(buyerActual, firstAssetContract, _currency, totalCalculatedPrice, totalNFTsSwept);
    }
    // --- Listings ---

    /**
     * @notice Creates a new listing for selling NFTs.
     * @dev The caller must own the NFT(s) and approve this contract or transfer them. NFTs are transferred to this contract.
     * @param _assetContract Address of the ERC721 or ERC1155 contract.
     * @param _tokenId ID of the token to list.
     * @param _quantity Quantity to list (must be 1 for ERC721).
     * @param _currency Address of the ERC20 currency, or address(0) for native currency.
     * @param _pricePerToken Price per single token unit in the specified currency.
     * @param _startTimestamp Unix timestamp when the listing becomes active.
     * @param _endTimestamp Unix timestamp when the listing expires.
     * @return listingId The ID of the newly created listing.
     */
    function createListing(
        address _assetContract,
        uint256 _tokenId,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        uint256 _startTimestamp,
        uint256 _endTimestamp
    ) external nonReentrant returns (uint256 listingId) {
        require(_assetContract != address(0), 'RareMarket: Zero asset contract address');
        require(_quantity > 0, 'RareMarket: Quantity must be greater than 0');
        require(_pricePerToken > 0, 'RareMarket: Price must be greater than 0');
        require(_startTimestamp < _endTimestamp, 'RareMarket: Start time must be before end time');
        require(_endTimestamp > block.timestamp, 'RareMarket: End time must be in the future');

        TokenType tokenType = _getTokenType(_assetContract);
        if (tokenType == TokenType.ERC721) {
            require(_quantity == 1, 'RareMarket: ERC721 quantity must be 1');
            require(IERC721(_assetContract).ownerOf(_tokenId) == msg.sender, 'RareMarket: Caller not owner of ERC721');
        } else {
            // TokenType.ERC1155
            require(
                IERC1155(_assetContract).balanceOf(msg.sender, _tokenId) >= _quantity,
                'RareMarket: Insufficient ERC1155 balance'
            );
        }

        _transferNFTFromUser(_assetContract, msg.sender, _tokenId, _quantity, tokenType);

        listingId = ++totalListings; // Pre-increment for ID 1 onwards
        listings[listingId] = Listing({
            listingId: listingId,
            listingCreator: msg.sender,
            assetContract: _assetContract,
            tokenId: _tokenId,
            quantity: _quantity,
            currency: _currency,
            pricePerToken: _pricePerToken,
            startTimestamp: _startTimestamp,
            endTimestamp: _endTimestamp,
            tokenType: tokenType,
            status: Status.Active
        });

        emit NewListing(listingId, msg.sender, _assetContract, _tokenId, _quantity, _currency, _pricePerToken);
        return listingId;
    }

    /**
     * @notice Cancels an active listing.
     * @dev Only the listing creator can cancel. NFTs are returned to the creator.
     * @param _listingId The ID of the listing to cancel.
     */
    function cancelListing(uint256 _listingId) external nonReentrant {
        Listing storage listing = listings[_listingId];
        require(listing.status == Status.Active, 'RareMarket: Listing not active');
        require(listing.listingCreator == msg.sender, 'RareMarket: Not listing creator');

        listing.status = Status.Cancelled;
        _transferNFTToUser(
            listing.assetContract,
            listing.listingCreator, // Send back to the creator
            listing.tokenId,
            listing.quantity,
            listing.tokenType
        );

        emit ListingCancelled(_listingId, msg.sender);
    }

    /**
     * @notice Buys NFTs from an active listing.
     * @dev Buyer pays the total price, which is then distributed to the seller, royalty recipient, and platform.
     * @param _listingId The ID of the listing to buy from.
     * @param _quantityToBuy The quantity of tokens to purchase.
     * @param _buyFor The address to receive the purchased NFTs. If address(0), defaults to msg.sender.
     */
    function buyFromListing(uint256 _listingId, uint256 _quantityToBuy, address _buyFor) external payable nonReentrant {
        Listing storage listing = listings[_listingId];
        require(listing.status == Status.Active, 'RareMarket: Listing not active');
        require(block.timestamp >= listing.startTimestamp, 'RareMarket: Listing not yet started');
        require(block.timestamp <= listing.endTimestamp, 'RareMarket: Listing expired');
        require(_quantityToBuy > 0, 'RareMarket: Quantity must be > 0');
        require(_quantityToBuy <= listing.quantity, 'RareMarket: Not enough quantity in listing');

        address buyerActual = (_buyFor == address(0)) ? msg.sender : _buyFor;
        require(buyerActual != address(0), 'RareMarket: Buyer cannot be zero address');

        uint256 totalPrice = listing.pricePerToken * _quantityToBuy;
        _processPayment(msg.sender, listing.currency, totalPrice);

        _distributeSaleProceeds(
            listing.listingCreator,
            listing.assetContract,
            listing.tokenId,
            totalPrice,
            listing.currency
        );

        _transferNFTToUser(listing.assetContract, buyerActual, listing.tokenId, _quantityToBuy, listing.tokenType);

        listing.quantity -= _quantityToBuy;
        if (listing.quantity == 0) {
            listing.status = Status.Sold; // Or Inactive
        }

        emit ListingSold(_listingId, listing.listingCreator, buyerActual, _quantityToBuy, totalPrice);
    }

    // --- Auctions ---

    /**
     * @notice Creates a new auction for NFTs.
     * @dev The caller must own the NFT(s). NFTs are transferred to this contract.
     * @param _assetContract Address of the ERC721 or ERC1155 contract.
     * @param _tokenId ID of the token to auction.
     * @param _quantity Quantity to auction (must be 1 for ERC721).
     * @param _currency Address of the ERC20 currency, or address(0) for native currency.
     * @param _startTimestamp Unix timestamp when bidding can start.
     * @param _endTimestamp Unix timestamp when the auction ends and can be finalized.
     * @param _initialBid Optional initial bid to set (can be 0).
     * @return auctionId The ID of the newly created auction.
     */
    function createAuction(
        address _assetContract,
        uint256 _tokenId,
        uint256 _quantity,
        address _currency,
        uint256 _startTimestamp,
        uint256 _endTimestamp,
        uint256 _initialBid // Allows setting a reserve price or starting bid
    ) external nonReentrant returns (uint256 auctionId) {
        require(_assetContract != address(0), 'RareMarket: Zero asset contract address');
        require(_quantity > 0, 'RareMarket: Quantity must be > 0');
        require(_startTimestamp < _endTimestamp, 'RareMarket: Start time must be before end time');
        require(_endTimestamp > block.timestamp, 'RareMarket: End time must be in the future');
        // _initialBid can be 0

        TokenType tokenType = _getTokenType(_assetContract);
        if (tokenType == TokenType.ERC721) {
            require(_quantity == 1, 'RareMarket: ERC721 quantity must be 1');
            require(IERC721(_assetContract).ownerOf(_tokenId) == msg.sender, 'RareMarket: Caller not owner of ERC721');
        } else {
            // TokenType.ERC1155
            require(
                IERC1155(_assetContract).balanceOf(msg.sender, _tokenId) >= _quantity,
                'RareMarket: Insufficient ERC1155 balance'
            );
        }

        _transferNFTFromUser(_assetContract, msg.sender, _tokenId, _quantity, tokenType);

        auctionId = ++totalAuctions;
        auctions[auctionId] = Auction({
            auctionId: auctionId,
            creator: msg.sender,
            assetContract: _assetContract,
            tokenId: _tokenId,
            quantity: _quantity,
            currency: _currency,
            startTimestamp: _startTimestamp,
            endTimestamp: _endTimestamp,
            highestBidder: address(0),
            highestBid: _initialBid, // Set initial/reserve bid
            tokenType: tokenType,
            status: Status.Active
        });

        emit AuctionCreated(auctionId, msg.sender, _assetContract, _tokenId, _quantity, _currency, _endTimestamp);
        return auctionId;
    }

    /**
     * @notice Places a bid in an active auction.
     * @dev Bid amount must be higher than the current highest bid. Previous bidder's funds are made available for withdrawal.
     * @param _auctionId The ID of the auction to bid on.
     * @param _bidAmount The amount to bid.
     */
    function bidInAuction(uint256 _auctionId, uint256 _bidAmount) external payable nonReentrant {
        Auction storage auction = auctions[_auctionId];
        require(auction.status == Status.Active, 'RareMarket: Auction not active');
        require(block.timestamp >= auction.startTimestamp, 'RareMarket: Auction not yet started');
        require(block.timestamp <= auction.endTimestamp, 'RareMarket: Auction has ended');
        require(_bidAmount > auction.highestBid, 'RareMarket: Bid too low');

        _processPayment(msg.sender, auction.currency, _bidAmount);

        // Refund previous highest bidder
        if (auction.highestBidder != address(0)) {
            _addPendingWithdrawal(auction.highestBidder, auction.currency, auction.highestBid);
        }

        auction.highestBidder = msg.sender;
        auction.highestBid = _bidAmount;

        emit BidPlaced(_auctionId, msg.sender, _bidAmount);
    }

    /**
     * @notice Finalizes a completed auction.
     * @dev Can be called after the auction's end time. If there's a winner, funds are distributed and NFT transferred.
     * If no bids (or bids didn't meet reserve if implemented explicitly), NFT is returned to the creator.
     * @param _auctionId The ID of the auction to finalize.
     */
    function finalizeAuction(uint256 _auctionId) external nonReentrant {
        Auction storage auction = auctions[_auctionId];
        require(auction.status == Status.Active, 'RareMarket: Auction not active or already finalized');
        require(block.timestamp > auction.endTimestamp, 'RareMarket: Auction has not ended yet');

        auction.status = Status.Finalized; // Or Sold/Inactive

        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            // There's a winner
            _distributeSaleProceeds(
                auction.creator,
                auction.assetContract,
                auction.tokenId,
                auction.highestBid,
                auction.currency
            );

            _transferNFTToUser(
                auction.assetContract,
                auction.highestBidder,
                auction.tokenId,
                auction.quantity,
                auction.tokenType
            );
            emit AuctionFinalized(_auctionId, auction.highestBidder, auction.creator, auction.highestBid);
        } else {
            // No valid bids, return NFT to creator
            _transferNFTToUser(
                auction.assetContract,
                auction.creator,
                auction.tokenId,
                auction.quantity,
                auction.tokenType
            );
            // Emitting AuctionCancelled here might be appropriate if no bids were made
            // Or a specific "AuctionEndedWithoutSale" event
            emit AuctionFinalized(_auctionId, address(0), auction.creator, 0); // No winner
        }
    }

    // --- Offers ---

    /**
     * @notice Creates an offer for a specific NFT. The offeror escrows the funds.
     * @param _assetContract Address of the ERC721 or ERC1155 contract.
     * @param _tokenId ID of the token for which the offer is made.
     * @param _quantity Quantity offered for (must be 1 for ERC721).
     * @param _currency Address of the ERC20 currency, or address(0) for native currency.
     * @param _pricePerToken Price offered per token unit.
     * @param _expiryTimestamp Unix timestamp when the offer expires.
     * @return offerId The ID of the newly created offer.
     */
    function createOffer(
        address _assetContract,
        uint256 _tokenId,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        uint256 _expiryTimestamp
    ) external payable nonReentrant returns (uint256 offerId) {
        require(_assetContract != address(0), 'RareMarket: Zero asset contract address');
        require(_quantity > 0, 'RareMarket: Quantity must be > 0');
        require(_pricePerToken > 0, 'RareMarket: Price must be > 0');
        require(_expiryTimestamp > block.timestamp, 'RareMarket: Expiry must be in the future');

        TokenType tokenType = _getTokenType(_assetContract); // Determine type for struct, even if not strictly validated here
        if (tokenType == TokenType.ERC721) {
            require(_quantity == 1, 'RareMarket: ERC721 quantity must be 1');
        }

        uint256 totalPrice = _pricePerToken * _quantity;
        _processPayment(msg.sender, _currency, totalPrice); // Offeror pays upfront

        offerId = ++totalOffers;
        offers[offerId] = Offer({
            offerId: offerId,
            offeror: msg.sender,
            assetContract: _assetContract,
            tokenId: _tokenId,
            quantity: _quantity,
            currency: _currency,
            pricePerToken: _pricePerToken,
            expiryTimestamp: _expiryTimestamp,
            tokenType: tokenType,
            status: Status.Active
        });

        emit NewOffer(offerId, msg.sender, _assetContract, _tokenId, _quantity, _currency, _pricePerToken);
        return offerId;
    }

    /**
     * @notice Allows an offeror to cancel their own active offer before it's accepted or expired.
     * @dev Funds are returned to the offeror.
     * @param _offerId The ID of the offer to cancel.
     */
    function cancelOffer(uint256 _offerId) external nonReentrant {
        Offer storage offer = offers[_offerId];
        require(offer.offeror == msg.sender, 'RareMarket: Not the offeror');
        require(offer.status == Status.Active, 'RareMarket: Offer not active');
        // No expiry check needed here, offeror can cancel an active offer.

        offer.status = Status.Cancelled;
        uint256 totalAmountToRefund = offer.pricePerToken * offer.quantity;
        _addPendingWithdrawal(offer.offeror, offer.currency, totalAmountToRefund);

        emit OfferCancelled(_offerId, offer.offeror);
    }

    /**
     * @notice Accepts an active offer for an NFT.
     * @dev The caller must own the NFT(s). NFT is transferred to the offeror, and funds are distributed.
     * @param _offerId The ID of the offer to accept.
     */
    function acceptOffer(uint256 _offerId) external nonReentrant {
        Offer storage offer = offers[_offerId];
        require(offer.status == Status.Active, 'RareMarket: Offer not active');
        require(block.timestamp <= offer.expiryTimestamp, 'RareMarket: Offer expired');

        address seller = msg.sender; // The one accepting the offer is the seller

        // Verify seller owns the NFT
        if (offer.tokenType == TokenType.ERC721) {
            require(
                IERC721(offer.assetContract).ownerOf(offer.tokenId) == seller,
                'RareMarket: Seller not owner of ERC721'
            );
        } else {
            // TokenType.ERC1155
            require(
                IERC1155(offer.assetContract).balanceOf(seller, offer.tokenId) >= offer.quantity,
                'RareMarket: Seller has insufficient ERC1155 balance'
            );
        }

        offer.status = Status.Sold; // Or Inactive/Finalized

        uint256 totalPrice = offer.pricePerToken * offer.quantity;
        // Funds are already in the contract from createOffer. Now distribute them.
        _distributeSaleProceeds(seller, offer.assetContract, offer.tokenId, totalPrice, offer.currency);

        // Transfer NFT from seller to offeror
        if (offer.tokenType == TokenType.ERC721) {
            IERC721(offer.assetContract).safeTransferFrom(seller, offer.offeror, offer.tokenId);
        } else {
            // TokenType.ERC1155
            IERC1155(offer.assetContract).safeTransferFrom(
                seller,
                offer.offeror,
                offer.tokenId,
                offer.quantity,
                '' // Empty data
            );
        }

        emit OfferAccepted(_offerId, seller, offer.offeror);
    }

    // --- Fund Distribution and Payment ---

    /**
     * @dev Internal function to handle payment from a user to the contract.
     * @param _payer The address paying the funds.
     * @param _currency The currency of payment (address(0) for native).
     * @param _amount The amount to be paid.
     */
    function _processPayment(address _payer, address _currency, uint256 _amount) internal {
        if (_currency == NATIVE_CURRENCY) {
            require(msg.value == _amount, 'RareMarket: Native currency value mismatch');
            // Ether is now in the contract's balance
        } else {
            require(msg.value == 0, 'RareMarket: Native currency sent for ERC20 transaction');
            IERC20 token = IERC20(_currency);
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(_payer, address(this), _amount);
            uint256 balanceAfter = token.balanceOf(address(this));
            require(
                balanceAfter - balanceBefore == _amount,
                'RareMarket: ERC20 transfer amount mismatch (check for fee-on-transfer tokens)'
            );
        }
    }

    /**
     * @dev Internal function to distribute sale proceeds to seller, royalty recipient, and platform.
     * @param _seller The address of the NFT seller.
     * @param _assetContract The address of the NFT contract.
     * @param _tokenId The ID of the token sold.
     * @param _totalPrice The total sale price.
     * @param _currency The currency of the sale.
     */
   // In RareMarket.sol
    function _distributeSaleProceeds(
        address _seller,
        address _assetContract,
        uint256 _tokenId,
        uint256 _totalPrice,
        address _currency
    ) internal {
        require(_seller != address(0), "RareMarket: Seller cannot be zero address");

        if (_totalPrice > 0) {
            totalVolumeSoldByCollectionAndCurrency[_assetContract][_currency] += _totalPrice;
        }

        uint256 platformFeeAmount = 0;
        if (platformFeeBps > 0 && platformFeeRecipient != address(0)) {
            platformFeeAmount = (_totalPrice * platformFeeBps) / 10000;
            if (platformFeeAmount > 0) {
                _addPendingWithdrawal(platformFeeRecipient, _currency, platformFeeAmount);
            }
        }

        uint256 remainingAfterPlatformFee = _totalPrice - platformFeeAmount;
        require(remainingAfterPlatformFee <= _totalPrice, "RareMarket: Platform fee calc error");

        uint256 sellerProceeds;

    
        if (royaltyEngineAddress != address(0) && remainingAfterPlatformFee > 0) {
            // Query the Royalty AMM for royalty details
            // The getRoyalty function in your Royalty AMM returns arrays.
            // Assuming your AMM's getRoyalty logic (as previously discussed) primarily uses the first element for a single royalty setup.
            (, uint256[] memory royaltyAmounts) = // We don't need recipients here for direct payout
                IRoyaltyEngine(royaltyEngineAddress).getRoyalty(_assetContract, _tokenId, remainingAfterPlatformFee);

            uint256 totalRoyaltyAmountDue = 0;
            if (royaltyAmounts.length > 0) {
                // Summing amounts if multiple, or taking amounts[0] if single royalty is standard from your AMM
                for(uint i = 0; i < royaltyAmounts.length; i++){
                    totalRoyaltyAmountDue += royaltyAmounts[i];
                }
            }
            
            // Ensure royalty doesn't exceed remaining amount
            if (totalRoyaltyAmountDue > remainingAfterPlatformFee) {
                totalRoyaltyAmountDue = remainingAfterPlatformFee;
            }

            if (totalRoyaltyAmountDue > 0) {
                // Transfer royalty amount to the Royalty AMM to be added as liquidity
                if (_currency == NATIVE_CURRENCY) {
                    IRoyaltyEngine(royaltyEngineAddress).addRoyaltyAsLiquidity{value: totalRoyaltyAmountDue}(
                        _assetContract,
                        NATIVE_CURRENCY, // Pass address(0) for native
                        totalRoyaltyAmountDue
                    );
                } else { // ERC20 Token
                    // 1. RareMarket transfers the ERC20 tokens to the royaltyEngineAddress
                    IERC20(_currency).safeTransfer(royaltyEngineAddress, totalRoyaltyAmountDue);
                    // 2. RareMarket then calls addRoyaltyAsLiquidity on the AMM (with no msg.value)
                    IRoyaltyEngine(royaltyEngineAddress).addRoyaltyAsLiquidity(
                        _assetContract,
                        _currency,
                        totalRoyaltyAmountDue
                    );
                }
                sellerProceeds = remainingAfterPlatformFee - totalRoyaltyAmountDue;
            } else {
                // No royalty due or amount is zero
                sellerProceeds = remainingAfterPlatformFee;
            }
        } else {
            // No royalty engine set or no amount left for royalties
            sellerProceeds = remainingAfterPlatformFee;
        }
   
        require(sellerProceeds <= remainingAfterPlatformFee, "RareMarket: Seller proceeds calc error");

        if (sellerProceeds > 0) {
            _addPendingWithdrawal(_seller, _currency, sellerProceeds);
        }
    }

    // --- NFT Handling ---

    /**
     * @dev Determines if a contract is likely ERC721 or ERC1155 based on interface support.
     * Prefers ERC721 if both are supported (unlikely but possible with misbehaving contracts).
     * @param _contractAddress Address of the token contract.
     * @return TokenType (ERC721 or ERC1155). Reverts if neither.
     */
    function _getTokenType(address _contractAddress) internal view returns (TokenType) {
        bool supportsERC721 = ERC165Utils.supportsInterface(_contractAddress, type(IERC721).interfaceId);
        bool supportsERC1155 = ERC165Utils.supportsInterface(_contractAddress, type(IERC1155).interfaceId);

        if (supportsERC721) {
            return TokenType.ERC721;
        }
        if (supportsERC1155) {
            return TokenType.ERC1155;
        }
        revert('RareMarket: Contract is not ERC721 or ERC1155');
    }

    /**
     * @dev Internal: Transfers NFT from a user to this contract.
     * Caller (user) must have approved this contract or be the owner.
     */
    function _transferNFTFromUser(
        address _assetContract,
        address _from,
        uint256 _tokenId,
        uint256 _quantity,
        TokenType _tokenType
    ) internal {
        if (_tokenType == TokenType.ERC721) {
            IERC721(_assetContract).safeTransferFrom(_from, address(this), _tokenId);
        } else {
            // TokenType.ERC1155
            IERC1155(_assetContract).safeTransferFrom(_from, address(this), _tokenId, _quantity, ''); // Empty data
        }
    }

    /**
     * @dev Internal: Transfers NFT from this contract to a user.
     */
    function _transferNFTToUser(
        address _assetContract,
        address _to,
        uint256 _tokenId,
        uint256 _quantity,
        TokenType _tokenType
    ) internal {
        require(_to != address(0), 'RareMarket: Cannot transfer NFT to zero address');
        if (_tokenType == TokenType.ERC721) {
            IERC721(_assetContract).safeTransferFrom(address(this), _to, _tokenId);
        } else {
            // TokenType.ERC1155
            IERC1155(_assetContract).safeTransferFrom(address(this), _to, _tokenId, _quantity, ''); // Empty data
        }
    }

    // --- Withdrawals ---

    /**
     * @dev Adds an amount to a user's pending withdrawal balance for a specific currency.
     * @param _user The address of the user.
     * @param _currency The currency (address(0) for native, ERC20 address otherwise).
     * @param _amount The amount to add.
     */
    function _addPendingWithdrawal(address _user, address _currency, uint256 _amount) internal {
        if (_amount == 0) return; // No-op for zero amount
        require(_user != address(0), 'RareMarket: Cannot add pending withdrawal for zero address');

        if (_currency == NATIVE_CURRENCY) {
            pendingNativeWithdrawals[_user] += _amount;
        } else {
            pendingErc20Withdrawals[_user][_currency] += _amount;
        }
    }

    /**
     * @notice Withdraws pending native currency (e.g., CORE) for the caller.
     */
    function withdrawNativeCurrency() external nonReentrant {
        uint256 amount = pendingNativeWithdrawals[msg.sender];
        require(amount > 0, 'RareMarket: No native currency to withdraw');

        pendingNativeWithdrawals[msg.sender] = 0;
        payable(msg.sender).sendValue(amount); // Using OpenZeppelin's sendValue for safety

        emit FundsWithdrawn(msg.sender, NATIVE_CURRENCY, amount);
    }

    /**
     * @notice Withdraws pending ERC20 tokens for the caller.
     * @param _tokenContract The address of the ERC20 token to withdraw.
     */
    function withdrawErc20Token(address _tokenContract) external nonReentrant {
        require(_tokenContract != NATIVE_CURRENCY, 'RareMarket: Use withdrawNativeCurrency for native currency');
        require(_tokenContract != address(0), 'RareMarket: Invalid token address');

        uint256 amount = pendingErc20Withdrawals[msg.sender][_tokenContract];
        require(amount > 0, 'RareMarket: No such ERC20 tokens to withdraw');

        pendingErc20Withdrawals[msg.sender][_tokenContract] = 0;
        IERC20(_tokenContract).safeTransfer(msg.sender, amount);

        emit FundsWithdrawn(msg.sender, _tokenContract, amount);
    }

    // --- Receiver Interfaces (for this contract to receive NFTs) ---

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     * This function is called when an ERC721 token is `safeTransferFrom`'d to this contract.
     * It allows the contract to accept ERC721 tokens.
     * It is not meant to be called directly by users for marketplace operations like listing.
     */
    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155Received}.
     * Allows the contract to accept a single ERC1155 token type.
     */
    function onERC1155Received(
        address /* operator */,
        address /* from */,
        uint256 /* id */,
        uint256 /* value */,
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155BatchReceived}.
     * Allows the contract to accept multiple ERC1155 token types.
     */
    function onERC1155BatchReceived(
        address /* operator */,
        address /* from */,
        uint256[] calldata /* ids */,
        uint256[] calldata /* values */,
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @notice Gets the current floor price for a specific collection in a specific currency.
     * @dev Iterates through all created listings. This can be gas-intensive if `totalListings` is very large.
     * Considers only active listings that have started, not ended, and match the asset and currency.
     * "Floor price" here means the lowest `pricePerToken` among such listings.
     * @param _assetContract The address of the NFT collection contract.
     * @param _currency The currency (address(0) for native) for which to find the floor price.
     * @return floorPrice The lowest `pricePerToken` for an active listing. Returns `type(uint256).max` if no suitable active listing is found.
     */
    function getCollectionFloorPrice(
        address _assetContract,
        address _currency
    ) external view returns (uint256 floorPrice) {
        floorPrice = type(uint256).max; // Initialize with the highest possible value
        uint256 currentTotalListings = totalListings; // Cache totalListings to avoid re-reading in loop

        // Iterate from listingId 1 up to the total number of listings created
        for (uint256 i = 1; i <= currentTotalListings; i++) {
            Listing storage listing = listings[i]; // Get a reference to the listing

            // Check if the listing is for the correct collection and currency
            if (listing.assetContract == _assetContract && listing.currency == _currency) {
                // Check if the listing is currently active
                if (
                    listing.status == Status.Active &&
                    block.timestamp >= listing.startTimestamp &&
                    block.timestamp <= listing.endTimestamp &&
                    listing.pricePerToken > 0 // Ensure the price is valid
                ) {
                    // If this active listing's price is lower than the current floor, update the floor
                    if (listing.pricePerToken < floorPrice) {
                        floorPrice = listing.pricePerToken;
                    }
                }
            }
        }

        // If no active listing was found matching the criteria, floorPrice will remain type(uint256).max
        return floorPrice;
    }

    /**
     * @notice Gets the total sales volume for a specific collection in a specific currency.
     * @dev Volume is accumulated from all successful sales (direct buys, auction finalizations, accepted offers).
     * @param _assetContract The address of the NFT collection contract.
     * @param _currency The currency (address(0) for native) for which to fetch the volume.
     * @return volume The total volume transacted for this collection in the specified currency.
     */
    function getCollectionVolume(address _assetContract, address _currency) external view returns (uint256 volume) {
        return totalVolumeSoldByCollectionAndCurrency[_assetContract][_currency];
    }

      /**
     * @notice Returns the price per token for a specific NFT listing.
     * @param _listingId The unique ID of the listing.
     * @param _tokenId The ID of the token in the listing (for validation).
     * @param _assetContract The address of the NFT contract (for validation).
     * @return price The price per token of the NFT as specified in the listing.
     */
    function getNFTPrice(
        uint256 _listingId,
        uint256 _tokenId,
        address _assetContract
    ) external view returns (uint256 price) {
        Listing storage listing = listings[_listingId];

        require(listing.listingId != 0, "RareMarket: Listing not found"); // Check if listing ID corresponds to an existing listing
        require(listing.status == Status.Active, "RareMarket: Listing not active");
        require(listing.assetContract == _assetContract, "RareMarket: Asset contract mismatch for listing ID");
        require(listing.tokenId == _tokenId, "RareMarket: Token ID mismatch for listing ID");

        return listing.pricePerToken;
    }
     /**
     * @notice Returns up to 100 of the most recent active NFT listings.
     * @dev This function iterates backwards from the latest listing ID, stopping once 100 active
     * listings are found or all listings have been checked. This is efficient for large numbers of listings.
     * @return allListings An array of up to 100 Listing structs, representing the latest active listings.
     */
    function getAllListings() external view returns (Listing[] memory) {
        uint256 MAX_ITEMS = 100;
        Listing[] memory latestActiveListings = new Listing[](MAX_ITEMS);
        uint256 currentCount = 0;

        // Iterate backwards from the latest listing ID to get the most recent ones first
        for (uint256 i = totalListings; i >= 1; i--) {
            Listing storage listing = listings[i];

            // Check if the listing exists and is currently active
            if (listing.listingId != 0 && listing.status == Status.Active) {
                latestActiveListings[currentCount] = listing; // Copy the entire struct
                currentCount++;

                // Stop if we have collected the maximum number of items
                if (currentCount == MAX_ITEMS) {
                    break;
                }
            }
        }

        // Return a dynamically sized array with only the found active listings
        Listing[] memory finalListings = new Listing[](currentCount);
        for (uint256 i = 0; i < currentCount; i++) {
            finalListings[i] = latestActiveListings[i];
        }

        return finalListings;
    }

     /**
     * @notice Retrieves the number of active listings for a specific collection contract.
     * @param _collectionAddress The address of the collection contract.
     * @return The count of active listings for the specified collection.
     */
    function getCollectionListingCount(address _collectionAddress) public view returns (uint256) {
        require(_collectionAddress != address(0), "RareMarket: Zero address for collection");
        uint256 count = 0;
        // Iterate through all potential listing IDs
        for (uint256 i = 1; i <= totalListings; i++) {
            // Check if the listing is active and belongs to the specified collection
            if (listings[i].status == Status.Active && listings[i].assetContract == _collectionAddress) {
                count++;
            }
        }
        return count;
    }
}
