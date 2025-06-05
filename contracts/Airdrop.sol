// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IERC20.sol";

/**
 * @title AirdropContract
 * @dev A smart contract for managing token airdrops with various conditions.
 * Anyone can create and manage their own airdrops.
 */
contract AirdropContract { // Removed Ownable inheritance

    // Enum to define the type of airdrop
    enum AirdropType {
        PUBLIC,
        ALLOWLIST
    }

    // Struct to hold details of each airdrop
    struct Airdrop {
        address creator;            // The address that created this airdrop
        address tokenAddress;       // Address of the ERC-20 token to be airdropped
        uint256 amountPerClaim;     // Amount of tokens a single user can claim per transaction
        uint256 maxClaimsPerWallet; // Maximum number of claims allowed per unique wallet
        AirdropType airdropType;    // Type of airdrop (PUBLIC or ALLOWLIST)
        bool isActive;              // Flag to indicate if the airdrop is active
        uint256 startTime;          // Timestamp when the airdrop becomes active
        uint256 endTime;            // Timestamp when the airdrop ends
        uint256 totalTokensDeposited; // Total tokens deposited for this specific airdrop
        uint256 totalTokensClaimed;   // Total tokens claimed for this specific airdrop
    }

    // Counter for generating unique airdrop IDs
    uint256 private airdropIdCounter;

    // Mapping from airdrop ID to Airdrop struct
    mapping(uint256 => Airdrop) public airdrops;

    // Mapping from airdrop ID to claimant address to number of claims
    mapping(uint256 => mapping(address => uint256)) public claimedAmounts;

    // Mapping for allowlist airdrops: airdrop ID => allowed address => true/false
    mapping(uint256 => mapping(address => bool)) public allowlists;

    // Event emitted when a new airdrop is created
    event AirdropCreated(
        uint256 indexed airdropId,
        address indexed creator, // Added creator to event
        address indexed tokenAddress,
        uint256 amountPerClaim,
        uint256 maxClaimsPerWallet,
        AirdropType airdropType,
        bool isActive,
        uint256 startTime,
        uint256 endTime
    );

    // Event emitted when tokens are deposited for an airdrop
    event TokensDeposited(
        uint256 indexed airdropId,
        address indexed tokenAddress,
        uint256 amount
    );

    // Event emitted when tokens are claimed by a user
    event TokensClaimed(
        uint256 indexed airdropId,
        address indexed claimant,
        uint256 amount
    );

    // Event emitted when remaining tokens are withdrawn by the creator
    event TokensWithdrawn(
        uint256 indexed airdropId,
        address indexed receiver,
        uint256 amount
    );

    /**
     * @dev Constructor initializes the airdrop ID counter.
     */
    constructor() {
        airdropIdCounter = 0; // Initialize airdrop ID counter
    }

    /**
     * @dev Allows the airdrop creator to deposit ERC-20 tokens into the contract for a specific airdrop.
     * @param _airdropId The ID of the airdrop to deposit tokens for.
     * @param _amount The amount of tokens to deposit.
     */
    function depositTokens(uint256 _airdropId, uint256 _amount) public { // Removed onlyOwner
        Airdrop storage airdrop = airdrops[_airdropId];
        require(airdrop.tokenAddress != address(0), "Airdrop does not exist");
        require(msg.sender == airdrop.creator, "Only airdrop creator can deposit tokens"); // Access control
        require(_amount > 0, "Amount must be greater than 0");

        IERC20 token = IERC20(airdrop.tokenAddress);
        // Transfer tokens from the creator to this contract
        require(token.transferFrom(msg.sender, address(this), _amount), "Token transfer failed");

        airdrop.totalTokensDeposited += _amount;
        emit TokensDeposited(_airdropId, airdrop.tokenAddress, _amount);
    }

    /**
     * @dev Creates a new public airdrop.
     * @param _tokenAddress The address of the ERC-20 token for the airdrop.
     * @param _amountPerClaim The amount of tokens a user can claim per transaction.
     * @param _maxClaimsPerWallet The maximum number of claims allowed per unique wallet.
     * @param _durationInSeconds The duration of the airdrop in seconds.
     * @return The ID of the newly created airdrop.
     */
    function createPublicAirdrop(
        address _tokenAddress,
        uint256 _amountPerClaim,
        uint256 _maxClaimsPerWallet,
        uint256 _durationInSeconds
    ) public returns (uint256) { // Removed onlyOwner
        require(_tokenAddress != address(0), "Token address cannot be zero");
        require(_amountPerClaim > 0, "Amount per claim must be greater than 0");
        require(_maxClaimsPerWallet > 0, "Max claims per wallet must be greater than 0");
        require(_durationInSeconds > 0, "Duration must be greater than 0");

        airdropIdCounter++;
        airdrops[airdropIdCounter] = Airdrop({
            creator: msg.sender, // Set the creator of the airdrop
            tokenAddress: _tokenAddress,
            amountPerClaim: _amountPerClaim,
            maxClaimsPerWallet: _maxClaimsPerWallet,
            airdropType: AirdropType.PUBLIC,
            isActive: true,
            startTime: block.timestamp,
            endTime: block.timestamp + _durationInSeconds,
            totalTokensDeposited: 0,
            totalTokensClaimed: 0
        });

        emit AirdropCreated(
            airdropIdCounter,
            msg.sender, // Emit creator in event
            _tokenAddress,
            _amountPerClaim,
            _maxClaimsPerWallet,
            AirdropType.PUBLIC,
            true,
            block.timestamp,
            block.timestamp + _durationInSeconds
        );
        return airdropIdCounter;
    }

    /**
     * @dev Creates a new allowlist airdrop.
     * @param _tokenAddress The address of the ERC-20 token for the airdrop.
     * @param _amountPerClaim The amount of tokens a user can claim per transaction.
     * @param _maxClaimsPerWallet The maximum number of claims allowed per unique wallet.
     * @param _durationInSeconds The duration of the airdrop in seconds.
     * @return The ID of the newly created airdrop.
     */
    function createAllowlistAirdrop(
        address _tokenAddress,
        uint256 _amountPerClaim,
        uint256 _maxClaimsPerWallet,
        uint256 _durationInSeconds
    ) public returns (uint256) { // Removed onlyOwner
        require(_tokenAddress != address(0), "Token address cannot be zero");
        require(_amountPerClaim > 0, "Amount per claim must be greater than 0");
        require(_maxClaimsPerWallet > 0, "Max claims per wallet must be greater than 0");
        require(_durationInSeconds > 0, "Duration must be greater than 0");

        airdropIdCounter++;
        airdrops[airdropIdCounter] = Airdrop({
            creator: msg.sender, // Set the creator of the airdrop
            tokenAddress: _tokenAddress,
            amountPerClaim: _amountPerClaim,
            maxClaimsPerWallet: _maxClaimsPerWallet,
            airdropType: AirdropType.ALLOWLIST,
            isActive: true,
            startTime: block.timestamp,
            endTime: block.timestamp + _durationInSeconds,
            totalTokensDeposited: 0,
            totalTokensClaimed: 0
        });

        emit AirdropCreated(
            airdropIdCounter,
            msg.sender, // Emit creator in event
            _tokenAddress,
            _amountPerClaim,
            _maxClaimsPerWallet,
            AirdropType.ALLOWLIST,
            true,
            block.timestamp,
            block.timestamp + _durationInSeconds
        );
        return airdropIdCounter;
    }

    /**
     * @dev Adds addresses to the allowlist of a specific allowlist airdrop.
     * Only the airdrop creator can call this.
     * @param _airdropId The ID of the allowlist airdrop.
     * @param _addresses An array of addresses to add to the allowlist.
     */
    function addToAllowlist(uint256 _airdropId, address[] calldata _addresses) public { // Removed onlyOwner
        Airdrop storage airdrop = airdrops[_airdropId];
        require(airdrop.tokenAddress != address(0), "Airdrop does not exist");
        require(msg.sender == airdrop.creator, "Only airdrop creator can modify allowlist"); // Access control
        require(airdrop.airdropType == AirdropType.ALLOWLIST, "Airdrop is not an allowlist type");

        for (uint256 i = 0; i < _addresses.length; i++) {
            require(_addresses[i] != address(0), "Address cannot be zero");
            allowlists[_airdropId][_addresses[i]] = true;
        }
    }

    /**
     * @dev Removes addresses from the allowlist of a specific allowlist airdrop.
     * Only the airdrop creator can call this.
     * @param _airdropId The ID of the allowlist airdrop.
     * @param _addresses An array of addresses to remove from the allowlist.
     */
    function removeFromAllowlist(uint256 _airdropId, address[] calldata _addresses) public { // Removed onlyOwner
        Airdrop storage airdrop = airdrops[_airdropId];
        require(airdrop.tokenAddress != address(0), "Airdrop does not exist");
        require(msg.sender == airdrop.creator, "Only airdrop creator can modify allowlist"); // Access control
        require(airdrop.airdropType == AirdropType.ALLOWLIST, "Airdrop is not an allowlist type");

        for (uint256 i = 0; i < _addresses.length; i++) {
            require(_addresses[i] != address(0), "Address cannot be zero");
            allowlists[_airdropId][_addresses[i]] = false;
        }
    }

    /**
     * @dev Deactivates an existing airdrop, preventing further claims.
     * Only the airdrop creator can call this.
     * @param _airdropId The ID of the airdrop to deactivate.
     */
    function deactivateAirdrop(uint256 _airdropId) public { // Removed onlyOwner
        Airdrop storage airdrop = airdrops[_airdropId];
        require(airdrop.tokenAddress != address(0), "Airdrop does not exist");
        require(msg.sender == airdrop.creator, "Only airdrop creator can deactivate airdrop"); // Access control
        require(airdrop.isActive, "Airdrop is already inactive");

        airdrop.isActive = false;
    }

    /**
     * @dev Allows the airdrop creator to withdraw any remaining tokens from an airdrop after its duration has ended.
     * This also sets the airdrop to inactive.
     * @param _airdropId The ID of the airdrop to withdraw from.
     */
    function withdrawRemainingTokens(uint256 _airdropId) public { // Removed onlyOwner
        Airdrop storage airdrop = airdrops[_airdropId];
        require(airdrop.tokenAddress != address(0), "Airdrop does not exist");
        require(msg.sender == airdrop.creator, "Only airdrop creator can withdraw tokens"); // Access control
        require(block.timestamp > airdrop.endTime, "Airdrop duration has not ended yet");

        uint256 remainingTokens = airdrop.totalTokensDeposited - airdrop.totalTokensClaimed;
        require(remainingTokens > 0, "No tokens remaining to withdraw");

        // Set airdrop to inactive
        airdrop.isActive = false;

        // Transfer remaining tokens to the creator
        IERC20 token = IERC20(airdrop.tokenAddress);
        require(token.transfer(msg.sender, remainingTokens), "Token withdrawal failed"); // Transfer to msg.sender (creator)

        emit TokensWithdrawn(_airdropId, msg.sender, remainingTokens);
    }

    /**
     * @dev Allows a user to claim tokens from an active airdrop.
     * @param _airdropId The ID of the airdrop to claim from.
     */
    function claimTokens(uint256 _airdropId) public {
        Airdrop storage airdrop = airdrops[_airdropId];
        require(airdrop.tokenAddress != address(0), "Airdrop does not exist");
        require(airdrop.isActive, "Airdrop is not active");
        require(block.timestamp >= airdrop.startTime && block.timestamp <= airdrop.endTime, "Airdrop is not currently active for claiming");
        require(claimedAmounts[_airdropId][msg.sender] < airdrop.maxClaimsPerWallet, "Claim limit reached for this wallet");
        require(airdrop.totalTokensClaimed + airdrop.amountPerClaim <= airdrop.totalTokensDeposited, "Not enough tokens remaining in airdrop");

        if (airdrop.airdropType == AirdropType.ALLOWLIST) {
            require(allowlists[_airdropId][msg.sender], "Address not on allowlist");
        }

        // Increment claimed count for the user
        claimedAmounts[_airdropId][msg.sender]++;
        airdrop.totalTokensClaimed += airdrop.amountPerClaim;

        // Transfer tokens to the claimant
        IERC20 token = IERC20(airdrop.tokenAddress);
        require(token.transfer(msg.sender, airdrop.amountPerClaim), "Token transfer failed");

        emit TokensClaimed(_airdropId, msg.sender, airdrop.amountPerClaim);
    }

    /**
     * @dev Returns the details of a specific airdrop.
     * @param _airdropId The ID of the airdrop.
     * @return creator The address of the airdrop creator.
     * @return tokenAddress The address of the token.
     * @return amountPerClaim The amount per claim.
     * @return maxClaimsPerWallet The maximum claims per wallet.
     * @return airdropType The type of airdrop (0 for PUBLIC, 1 for ALLOWLIST).
     * @return isActive Whether the airdrop is active.
     * @return startTime The timestamp when the airdrop starts.
     * @return endTime The timestamp when the airdrop ends.
     * @return totalTokensDeposited Total tokens deposited for this airdrop.
     * @return totalTokensClaimed Total tokens claimed for this airdrop.
     */
    function getAirdropDetails(uint256 _airdropId)
        public
        view
        returns (
            address creator, // Added creator to return
            address tokenAddress,
            uint256 amountPerClaim,
            uint256 maxClaimsPerWallet,
            AirdropType airdropType,
            bool isActive,
            uint256 startTime,
            uint256 endTime,
            uint256 totalTokensDeposited,
            uint256 totalTokensClaimed
        )
    {
        Airdrop storage airdrop = airdrops[_airdropId];
        require(airdrop.tokenAddress != address(0), "Airdrop does not exist");

        return (
            airdrop.creator, // Return creator
            airdrop.tokenAddress,
            airdrop.amountPerClaim,
            airdrop.maxClaimsPerWallet,
            airdrop.airdropType,
            airdrop.isActive,
            airdrop.startTime,
            airdrop.endTime,
            airdrop.totalTokensDeposited,
            airdrop.totalTokensClaimed
        );
    }

    /**
     * @dev Returns the number of times an address has claimed a specific airdrop.
     * @param _airdropId The ID of the airdrop.
     * @param _claimer The address of the claimant.
     * @return The number of claims.
     */
    function getClaimedCount(uint256 _airdropId, address _claimer) public view returns (uint256) {
        return claimedAmounts[_airdropId][_claimer];
    }

    /**
     * @dev Checks if an address is on the allowlist for a specific airdrop.
     * @param _airdropId The ID of the airdrop.
     * @param _address The address to check.
     * @return True if the address is allowed, false otherwise.
     */
    function isAddressAllowed(uint256 _airdropId, address _address) public view returns (bool) {
        Airdrop storage airdrop = airdrops[_airdropId];
        require(airdrop.tokenAddress != address(0), "Airdrop does not exist");
        require(airdrop.airdropType == AirdropType.ALLOWLIST, "Airdrop is not an allowlist type");
        return allowlists[_airdropId][_address];
    }

    /**
     * @dev Returns a list of all active airdrop IDs.
     * @return An array of active airdrop IDs.
     */
    function getAllAirdropIds() public view returns (uint256[] memory) {
        uint256[] memory activeIds = new uint256[](airdropIdCounter);
        uint256 count = 0;
        for (uint256 i = 1; i <= airdropIdCounter; i++) {
            // An airdrop is considered active if its 'isActive' flag is true AND current time is within its duration
            if (airdrops[i].tokenAddress != address(0) && airdrops[i].isActive && block.timestamp >= airdrops[i].startTime && block.timestamp <= airdrops[i].endTime) {
                activeIds[count] = i;
                count++;
            }
        }
        // Resize the array to only include actual active IDs
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeIds[i];
        }
        return result;
    }
}
