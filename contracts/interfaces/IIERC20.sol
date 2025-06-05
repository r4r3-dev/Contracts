// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IERC2981.sol";
import "../interfaces/IERC20.sol";

/**
 * @title RoyaltyEngine Library
 * @dev Provides helper functions to calculate and retrieve royalty information.
 * Supports ERC2981 standard. Includes fallback mechanism.
 */
library RoyaltyEngine {
    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;
    uint96 public constant DEFAULT_ROYALTY_BASIS_POINTS = 500; // 5%
    uint96 public constant MAX_ROYALTY_BASIS_POINTS = 10000; // Denominator

    struct RoyaltyInfo {
        address receiver;
        uint256 amount;
    }

    /**
     * @dev Gets royalty information for a given NFT sale.
     * Prefers ERC2981 if supported by the NFT contract.
     * Falls back to a default royalty if ERC2981 is not supported or returns 0.
     * @param nftContract Address of the NFT contract.
     * @param tokenId ID of the token being sold.
     * @param salePrice Total price for which the NFT is sold.
     * @param defaultReceiver Address to receive royalties if ERC2981 is not supported or returns zero address.
     * @return info RoyaltyInfo struct containing receiver address and amount.
     */
    function getRoyalty(
        address nftContract,
        uint256 tokenId,
        uint256 salePrice,
        address defaultReceiver
    ) internal view returns (RoyaltyInfo memory info) {
        // --- Check ERC2981 support using modified try/catch ---
        bool supportsRoyaltyStandard = false; // Default assumption
        bool checkSuccess; // Flag to see if the try block succeeded
        bool returnedSupports; // Variable to capture the return value

        try IERC165(nftContract).supportsInterface(_INTERFACE_ID_ERC2981) returns (bool supportsValue) {
            // Assign the returned value inside the try block
            returnedSupports = supportsValue;
            checkSuccess = true; // Mark the check as successful
        } catch {
            // Call failed (e.g., contract doesn't implement IERC165 or reverted)
            checkSuccess = false;
        }

        // Update supportsRoyaltyStandard only if the check was successful
        if (checkSuccess) {
            supportsRoyaltyStandard = returnedSupports;
        }
        // --- End ERC2981 support check ---


        if (supportsRoyaltyStandard) {
            // --- Attempt to get ERC2981 royalty info using modified try/catch ---
            bool royaltyInfoSuccess; // Flag for success
            address receiver; // Variable for receiver
            uint256 royaltyAmount; // Variable for amount

            try IERC2981(nftContract).royaltyInfo(tokenId, salePrice) returns (
                address returnedReceiver,
                uint256 returnedAmount
            ) {
                // Assign returned values inside the try block
                receiver = returnedReceiver;
                royaltyAmount = returnedAmount;
                royaltyInfoSuccess = true; // Mark as successful
            } catch {
                // Call failed or reverted
                royaltyInfoSuccess = false;
            }

            // Process royalty info only if the call succeeded and data is valid
            if (royaltyInfoSuccess) {
                // Validate royalty amount against sale price
                if (royaltyAmount > 0 && royaltyAmount <= salePrice) {
                   // Use ERC2981 info if valid receiver and amount
                   if (receiver != address(0)) {
                        info.receiver = receiver;
                        info.amount = royaltyAmount;
                        return info; // Return immediately with ERC2981 data
                   }
                }
                // Fallthrough to default if ERC2981 returned invalid data (e.g., amount > salePrice, zero receiver)
            }
            // Fallthrough to default if the try/catch itself failed (royaltyInfoSuccess is false)
            // --- End ERC2981 royalty info attempt ---
        }

        // Fallback: Calculate default royalty if ERC2981 not supported, failed, or returned invalid data
        info.receiver = defaultReceiver; // Send to specified default
        info.amount = (salePrice * DEFAULT_ROYALTY_BASIS_POINTS) / MAX_ROYALTY_BASIS_POINTS;

        // Ensure default receiver is valid
        if (info.receiver == address(0)) {
            info.amount = 0; // No royalty if default receiver is invalid
        }

        return info;
    }
}


/**
 * @title TransferHelper Library
 * @dev Provides safe transfer functions for Native Currency (CORE), ERC20, ERC721, ERC1155.
 * Includes checks for successful transfers where applicable.
 */
library TransferHelper {
    bytes4 private constant _INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant _INTERFACE_ID_ERC1155 = 0xd9b67a26;

    enum TokenType { NATIVE, ERC20, ERC721, ERC1155, UNKNOWN }

    /**
     * @dev Determines the type of token based on ERC165 interface checks.
     * @param tokenContract Address of the token contract (address(0) for native).
     * @return TokenType The determined type.
     */
    function getTokenType(address tokenContract) internal view returns (TokenType) {
        if (tokenContract == address(0)) {
            return TokenType.NATIVE;
        }
        try IERC165(tokenContract).supportsInterface(0x01ffc9a7) returns (bool isERC165) { // ERC165 ID
            if (!isERC165) return TokenType.UNKNOWN; // Assume unknown if not ERC165

            // Check specific interfaces
            if (IERC165(tokenContract).supportsInterface(_INTERFACE_ID_ERC1155)) {
                return TokenType.ERC1155;
            }
            if (IERC165(tokenContract).supportsInterface(_INTERFACE_ID_ERC721)) {
                return TokenType.ERC721;
            }
             // Basic check for ERC20 (transfer function selector) - less reliable than ERC165
             // A contract could have this function without being a full ERC20
            if (tokenContract.code.length > 0) {
                 try IERC20(tokenContract).totalSupply() returns (uint256) {
                     // It looks like an ERC20, but could be other things too.
                     // Let's assume ERC20 if it's not NFT and has basic functions.
                     // A more robust check might involve checking multiple ERC20 functions.
                     return TokenType.ERC20;
                 } catch {
                     return TokenType.UNKNOWN;
                 }
            }
        } catch {
            // If supportsInterface fails or contract doesn't exist
            return TokenType.UNKNOWN;
        }
        return TokenType.UNKNOWN;
    }

    /**
     * @dev Safely transfers native currency (CORE).
     * @param to Recipient address.
     * @param amount Amount to send.
     */
    function safeTransferNative(address payable to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, ) = to.call{value: amount}("");
        require(success, "TransferHelper: Native transfer failed");
    }

    /**
     * @dev Safely transfers ERC20 tokens. Requires allowance.
     * @param tokenContract Address of the ERC20 token.
     * @param from Sender address.
     * @param to Recipient address.
     * @param amount Amount to send.
     */
    function safeTransferERC20(address tokenContract, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        // Use transferFrom - requires caller (Marketplace) to have allowance
        bool success = IERC20(tokenContract).transferFrom(from, to, amount);
        require(success, "TransferHelper: ERC20 transferFrom failed");
    }

     /**
     * @dev Safely transfers ERC20 tokens directly from contract balance (e.g., paying out).
     * @param tokenContract Address of the ERC20 token.
     * @param to Recipient address.
     * @param amount Amount to send.
     */
    function safeTransferERC20Direct(address tokenContract, address to, uint256 amount) internal {
        if (amount == 0) return;
        // Use transfer - assumes contract holds the tokens
        bool success = IERC20(tokenContract).transfer(to, amount);
        require(success, "TransferHelper: ERC20 transfer failed");
    }


    /**
     * @dev Safely transfers an ERC721 token. Requires approval or operator status.
     * @param nftContract Address of the ERC721 token.
     * @param from Sender address.
     * @param to Recipient address.
     * @param tokenId ID of the token.
     */
}
