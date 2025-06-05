// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ERC165Utils.sol";
import "../interfaces/IERC2981.sol";

/// @title  RoyaltyEngine
/// @dev    Helper to fetch ERC-2981 royalties or fallback to defaults.
library RoyaltyEngine {
    // ERC-2981 interface ID
    bytes4 private constant _INTERFACE_ID_ERC2981 = type(IERC2981).interfaceId;

    // Default fallback royalty = 5% (500 / 10000)
    uint96 public constant DEFAULT_ROYALTY_BASIS_POINTS = 500;
    uint96 public constant MAX_ROYALTY_BASIS_POINTS     = 10000;

    struct RoyaltyInfo {
        address receiver;
        uint256 amount;
    }

    /**
     * @notice Get royalty info for a sale.
     * @param nftContract       Collection contract address.
     * @param tokenId           Token ID being sold.
     * @param salePrice         Total sale price.
     * @param defaultReceiver   Who to pay if no ERC-2981 support or ERC-2981 returns address(0).
     * @return info RoyaltyInfo struct containing the receiver and amount.
     */
    function getRoyalty(
        address nftContract,
        uint256 tokenId,
        uint256 salePrice,
        address defaultReceiver
    ) internal view returns (RoyaltyInfo memory info) {
        // 1) Check ERC-2981 support on-chain
        bool supportsRoyalty = ERC165Utils.supportsInterface(nftContract, _INTERFACE_ID_ERC2981);

        // 2) If supported, try reading the on-chain royalty
        if (supportsRoyalty) {
            try IERC2981(nftContract).royaltyInfo(tokenId, salePrice) returns (
                address receiver,
                uint256 royaltyAmount
            ) {
                // Only accept non-zero receiver & amount ≤ salePrice
                if (receiver != address(0) && royaltyAmount > 0 && royaltyAmount <= salePrice) {
                    info.receiver = receiver;
                    info.amount   = royaltyAmount;
                    return info;
                }
                // If ERC2981 returns address(0) for receiver, or invalid amount, fall through to default.
            } catch {
                // Swallow reverts and fallback below
            }
        }

        // 3) Fallback: default % to the defaultReceiver
        // If defaultReceiver is address(0) (e.g., if seller is not available or shouldn't receive default),
        // royalty amount will be zero.
        if (defaultReceiver != address(0)) {
            info.receiver = defaultReceiver;
            info.amount = (salePrice * DEFAULT_ROYALTY_BASIS_POINTS) / MAX_ROYALTY_BASIS_POINTS;
            if (info.amount > salePrice) { // Sanity check to prevent overflow issues if constants were different
                info.amount = salePrice;
            }
        } else {
            info.receiver = address(0);
            info.amount = 0;
        }
        return info;
    }

    
}