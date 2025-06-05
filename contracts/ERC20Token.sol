// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract Token is ERC20Permit {
    uint8 private immutable _customDecimals;
    
    // Array to store token holders
    address[] private _holders;
    // Mapping to track holder indexes (1-based index; 0 = not present)
    mapping(address => uint256) private _holderIndex;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply, 
        uint8 decimals_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        _customDecimals = decimals_;
        _mint(msg.sender, initialSupply); 
    }

 
    function decimals() public view virtual override returns (uint8) {
        return _customDecimals;
    }

    // Override _update to maintain holders array
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        // Get balances before transfer
        uint256 fromBalanceBefore = from != address(0) ? balanceOf(from) : 0;
        uint256 toBalanceBefore = to != address(0) ? balanceOf(to) : 0;

        // Execute ERC20 transfer logic
        super._update(from, to, amount);

        // Skip self-transfers
        if (from == to) {
            return;
        }

        // Update receiver (mint/transfer)
        if (to != address(0)) {
            uint256 toBalanceAfter = balanceOf(to);
            // Add to holders if new balance >0 and wasn't a holder before
            if (toBalanceBefore == 0 && toBalanceAfter > 0) {
                _addHolder(to);
            }
        }

        // Update sender (burn/transfer)
        if (from != address(0)) {
            uint256 fromBalanceAfter = balanceOf(from);
            // Remove from holders if balance dropped to 0
            if (fromBalanceBefore > 0 && fromBalanceAfter == 0) {
                _removeHolder(from);
            }
        }
    }

    // Add new holder to tracking array
    function _addHolder(address holder) private {
        if (_holderIndex[holder] == 0) {
            _holders.push(holder);
            _holderIndex[holder] = _holders.length; // Store 1-based index
        }
    }

    // Remove holder from tracking array
    function _removeHolder(address holder) private {
        uint256 idx = _holderIndex[holder];
        if (idx == 0) return; // Not in array

        uint256 lastIdx = _holders.length;
        // Swap with last holder if not already last
        if (idx != lastIdx) {
            address lastHolder = _holders[lastIdx - 1];
            _holders[idx - 1] = lastHolder;
            _holderIndex[lastHolder] = idx;
        }
        
        // Remove last element
        _holders.pop();
        delete _holderIndex[holder];
    }

    // Get all holders and their balances
    function getHolders() public view returns (address[] memory, uint256[] memory) {
        uint256 holderCount = _holders.length;
        address[] memory addresses = new address[](holderCount);
        uint256[] memory balances = new uint256[](holderCount);
        
        for (uint256 i = 0; i < holderCount; i++) {
            addresses[i] = _holders[i];
            balances[i] = balanceOf(_holders[i]);
        }
        return (addresses, balances);
    }
}