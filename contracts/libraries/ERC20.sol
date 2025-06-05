// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC20
 * @dev Interface for the ERC20 standard.
 * This interface defines the essential functions for interacting with ERC20 tokens.
 */
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    // Optional functions (often included)
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/**
 * @title SafeERC20Helper
 * @dev A simple helper library for interacting with ERC20 tokens safely.
 * This library aims to handle potential issues with ERC20 token implementations
 * that don't strictly follow the standard (e.g., returning false instead of reverting).
 * This is a simplified version compared to battle-tested libraries like OpenZeppelin's SafeERC20.
 */
library SafeERC20Helper {
    /**
     * @dev Performs a safe ERC20 transfer.
     * Reverts if the token contract call fails or returns false.
     * @param token The address of the ERC20 token.
     * @param to The recipient address.
     * @param amount The amount to transfer.
     */
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        bool success = token.transfer(to, amount);
        require(success, "SafeERC20Helper: transfer failed");
    }

    /**
     * @dev Performs a safe ERC20 transferFrom.
     * Reverts if the token contract call fails or returns false.
     * @param token The address of the ERC20 token.
     * @param from The sender address.
     * @param to The recipient address.
     * @param amount The amount to transfer.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        bool success = token.transferFrom(from, to, amount);
        require(success, "SafeERC20Helper: transferFrom failed");
    }

    /**
     * @dev Performs a safe ERC20 approve.
     * Reverts if the token contract call fails or returns false.
     * Note: Some tokens have issues with changing allowance from non-zero to non-zero.
     * It's generally recommended to first set allowance to zero before increasing it,
     * but this simple helper doesn't enforce that. Consider using a more robust library
     * for production if this is a concern.
     * @param token The address of the ERC20 token.
     * @param spender The spender address.
     * @param amount The allowance amount.
     */
    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        // Some token implementations fail when changing approval from non-zero to non-zero.
        // A robust library might handle this by first setting to zero.
        // This simple helper does not.
        bool success = token.approve(spender, amount);
        require(success, "SafeERC20Helper: approve failed");
    }
}
