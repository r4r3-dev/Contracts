// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract WCORE {
    string public name = "Wrapped CORE";
    string public symbol = "WCORE";
    uint8  public decimals = 18;

    uint256 private _totalSupply; // Explicitly track total supply
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1000000000000000000; // 1 Million WCORE (1 * 10^6 * 1 * 10^18)

    event Approval(address indexed src, address indexed guy, uint256 amount);
    event Transfer(address indexed src, address indexed dst, uint256 amount);
    event Deposit(address indexed dst, uint256 amount);
    event Withdrawal(address indexed src, uint256 amount);

    mapping (address => uint256) public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;

    constructor(address deployer) {
        _totalSupply = INITIAL_SUPPLY;
        balanceOf[deployer] = INITIAL_SUPPLY;
        emit Transfer(address(0), deployer, INITIAL_SUPPLY);
    }

    // Use receive() for receiving native currency
    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        require(msg.value > 0, "WCORE: deposit amount must be greater than zero");
        balanceOf[msg.sender] += msg.value;
        _totalSupply += msg.value; // Increment total supply
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public {
        require(amount > 0, "WCORE: withdrawal amount must be greater than zero");
        require(balanceOf[msg.sender] >= amount, "WCORE: insufficient balance for withdrawal");

        balanceOf[msg.sender] -= amount;
        _totalSupply -= amount; // Decrement total supply

        // Using call for robustness, though transfer() is often fine for WETH patterns.
        // Ensure Checks-Effects-Interactions pattern is followed (state changes before external call).
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "WCORE: native currency transfer failed");

        emit Withdrawal(msg.sender, amount);
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply; // Return the explicitly tracked total supply
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) public returns (bool) {
        require(recipient != address(0), "WCORE: transfer to the zero address");
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        require(recipient != address(0), "WCORE: transfer to the zero address");
        uint256 currentAllowance = allowance[sender][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "WCORE: insufficient allowance");
            allowance[sender][msg.sender] = currentAllowance - amount;
        }
        _transfer(sender, recipient, amount);
        return true;
    }

    // Internal transfer function
    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "WCORE: transfer from the zero address");
        require(balanceOf[sender] >= amount, "WCORE: transfer amount exceeds balance");

        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;

        emit Transfer(sender, recipient, amount);
    }
}