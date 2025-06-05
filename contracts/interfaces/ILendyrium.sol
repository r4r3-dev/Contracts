// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILendyrium {
    function createOrder(
        address _erc20Token,
        uint256 _amount,
        uint256 _minCollateralPerUnit,
        uint256 _interestRate,
        uint256 _loanDuration
    ) external;

    function borrow(uint256 _orderId, uint256 _amountToBorrow) external payable;
    
    function repay(uint256 _loanId) external payable;
    
    function claimCollateral(uint256 _loanId) external;
    
    function withdrawEarnings(address erc20Token) external;

    // Aggregator view functions
    function totalMerchants() external view returns (uint256);
    function totalCustomers() external view returns (uint256);
    function totalOrders() external view returns (uint256);
    function totalLoans() external view returns (uint256);
    function totalBorrowed() external view returns (uint256);
}
