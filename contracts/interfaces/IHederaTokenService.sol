// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IHederaTokenService {
    // Token transfer parameters
    struct TransferTokenParams {
        address token;
        address sender;
        address receiver;
        int64 amount;
    }

    // Multi-transfer parameters
    struct TransferTokensParams {
        address token;
        address[] senders;
        address[] receivers;
        int64[] amounts;
    }

    // Token creation parameters
    struct Token {
        string name;
        string symbol;
        address treasury;
        bytes32 adminKey;
        bytes32 supplyKey;
        bytes32 freezeKey;
        bytes32 wipeKey;
        uint8 decimals;
    }

    // Token information structure
    struct TokenInfo {
        string name;
        string symbol;
        uint8 decimals;
        uint64 totalSupply;
        address treasury;
    }

    // Token transfer function
    function transferToken(TransferTokenParams memory params) external returns (int responseCode);

    // Batch token transfer function
    function transferTokens(TransferTokensParams memory params) external returns (int responseCode);

    // Fungible token creation
    function createFungibleToken(Token memory tokenInfo) external returns (address createdToken);

    // Associate token with account
    function tokenAssociate(address account, address token) external returns (int responseCode);

    // Dissociate token from account
    function tokenDissociate(address account, address token) external returns (int responseCode);

    // Get token information
    function getTokenInfo(address token) external view returns (TokenInfo memory info);

    // Get token balance
    function getTokenBalance(address account, address token) external view returns (int64 balance);

    // Get token decimals
    function getTokenDecimals(address token) external view returns (uint8 decimals);

    // Wrapped HBAR operations
    function depositHBAR() external payable returns (int responseCode);
    function withdrawHBAR(uint amount) external returns (int responseCode);

    // Approval mechanisms
    function approveToken(address token, address spender, int64 amount) external returns (int responseCode);
    function allowanceToken(address token, address owner, address spender) external view returns (int64 remaining);
}