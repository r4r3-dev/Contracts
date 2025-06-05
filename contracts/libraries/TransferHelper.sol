// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IERC2981.sol";
import "../interfaces/IERC1155.sol";
import "../interfaces/IERC20.sol";


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
     * @dev Safely transfers ERC1155 tokens. Requires approval or operator status.
     * @param nftContract Address of the ERC1155 token.
     * @param from Sender address.
     * @param to Recipient address.
     * @param tokenId ID of the token.
     * @param amount Amount of tokens to transfer.
     * @param data Additional data.
     */
    function safeTransferERC1155(address nftContract, address from, address to, uint256 tokenId, uint256 amount, bytes memory data) internal {
        // Use safeTransferFrom - requires caller (Marketplace) to be approved or operator
        IERC1155(nftContract).safeTransferFrom(from, to, tokenId, amount, data);
    }
}
