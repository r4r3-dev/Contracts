// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ERC165Utils {
    function supportsInterface(address account, bytes4 interfaceId) internal view returns (bool) {
        (bool success, bytes memory result) = account.staticcall{gas: 30000}(
            abi.encodeWithSelector(0x01ffc9a7, interfaceId) // ERC165 interface ID
        );
        if (!success || result.length < 32) return false;
        return abi.decode(result, (bool));
    }
}
