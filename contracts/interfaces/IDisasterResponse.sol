// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDisasterResponse Interface
 * @dev Defines the interface for the DisasterResponse contract used by Lendyrium.
 */
interface IDisasterResponse {
    /**
     * @dev Checks if a price disaster is currently active for a given token.
     * @param isNative True if checking the native token (HBAR), false for ERC20.
     * @param token Address of the ERC20 token (ignored if isNative is true).
     * @return True if a disaster is active, false otherwise.
     */
    function isPriceDisasterActive(bool isNative, address token) external view returns (bool);
}