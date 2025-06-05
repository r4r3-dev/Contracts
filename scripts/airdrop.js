// scripts/interact.js
const { ethers } = require("hardhat");
const readline = require("readline");
const fs = require("fs");
const path = require("path");

// Path to store the deployment information (contract address and ABI)
const DEPLOYMENT_PATH = path.join(__dirname, "./airdrop_deployment.json");

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

// Minimal ERC20 ABI for common functions needed for approval and token info
const IERC20_ABI = [
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)"
];

/**
 * Prompts the user for input.
 * @param {string} question The question to ask the user.
 * @returns {Promise<string>} A promise that resolves with the user's trimmed answer.
 */
async function prompt(question) {
    return new Promise(resolve => {
        rl.question(question, answer => resolve(answer.trim()));
    });
}

// Buffer percentage for gas limit estimation to prevent out-of-gas errors
const GAS_LIMIT_BUFFER_PERCENT = 20;

/**
 * Handles sending a transaction to the blockchain, including gas estimation and user confirmation.
 * @param {ethers.Signer} user The signer (wallet) to send the transaction from.
 * @param {Function} contractMethod The contract method to call (e.g., `airdrop.createPublicAirdrop`).
 * @param {Array} args An array of arguments for the contract method.
 * @param {Object} options Optional transaction parameters (e.g., `value` for payable functions).
 * @param {string} gasLimitType Optional. A hint for gas estimation (e.g., 'APPROVE_TOKEN_SYMBOL').
 * @returns {Promise<ethers.ContractTransaction | undefined>} The transaction object if successful, otherwise undefined.
 */
async function handleTransaction(user, contractMethod, args, options = {}, gasLimitType = 'DEFAULT') {
    const provider = user.provider;

    try {
        console.log(`\nEstimating gas for transaction...`);
        let estimatedGas;
        try {
            // Attempt to estimate gas for the transaction
            estimatedGas = await contractMethod.estimateGas(...args, options);
            // Add a buffer to the estimated gas limit
            const bufferedGasLimit = estimatedGas.mul(100 + GAS_LIMIT_BUFFER_PERCENT).div(100);
            console.log(`Estimated Gas Limit: ${estimatedGas.toString()}`);
            console.log(`Buffered Gas Limit (${GAS_LIMIT_BUFFER_PERCENT}% buffer): ${bufferedGasLimit.toString()}`);
            options.gasLimit = bufferedGasLimit;

        } catch (estimationError) {
            console.warn(`Gas estimation failed: ${estimationError.message}`);
            console.warn(`Proceeding without gas estimation. Transaction might fail.`);
        }

        // Get current network fee data
        const feeData = await provider.getFeeData();

        // Determine gas pricing strategy (EIP-1559 or legacy)
        if (feeData.maxFeePerGas && feeData.maxPriorityFeePerGas) {
            console.log(`Using EIP-1559 gas pricing.`);
            options.maxFeePerGas = feeData.maxFeePerGas;
            options.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas;
            delete options.gasPrice; // Ensure legacy gasPrice is not set
            console.log(`Max Fee Per Gas: ${ethers.utils.formatUnits(feeData.maxFeePerGas, 'gwei')} Gwei`);
            console.log(`Max Priority Fee Per Gas: ${ethers.utils.formatUnits(feeData.maxPriorityFeePerGas, 'gwei')} Gwei`);

        } else if (feeData.gasPrice) {
            console.log(`Using legacy gas pricing.`);
            options.gasPrice = feeData.gasPrice;
            delete options.maxFeePerGas; // Ensure EIP-1559 fields are not set
            delete options.maxPriorityFeePerGas;
            console.log(`Gas Price: ${ethers.utils.formatUnits(feeData.gasPrice, 'gwei')} Gwei`);

        } else {
            console.warn("Could not retrieve gas price data. Transaction might fail.");
        }

        // Estimate total transaction cost
        let estimatedCost = ethers.BigNumber.from(0);
        if (options.gasLimit && (options.maxFeePerGas || options.gasPrice)) {
            const gasPriceEstimate = options.maxFeePerGas || options.gasPrice;
            estimatedCost = options.gasLimit.mul(gasPriceEstimate);
        }

        if (estimatedCost.gt(0)) {
            console.log(`Estimated Max Transaction Cost: ${ethers.utils.formatEther(estimatedCost)} ETH (Based on buffered gas limit and current gas prices)`);
        } else {
            console.log(`Could not estimate transaction cost accurately.`);
        }

        // Confirm transaction with the user
        const confirm = await prompt("Confirm transaction? (y/n): ");
        if (confirm.toLowerCase() !== 'y') {
            throw new Error("Transaction cancelled by user");
        }

        console.log("Sending transaction...");
        const tx = await contractMethod(...args, options); // Execute the contract method

        console.log(`Transaction sent. Hash: ${tx.hash}`);
        console.log("Waiting for confirmation...");

        const receipt = await tx.wait(); // Wait for the transaction to be mined
        console.log(`Transaction successful. Block: ${receipt.blockNumber}`);

        // Calculate actual transaction cost
        const actualGasPriceUsed = receipt.effectiveGasPrice || options.gasPrice || options.maxFeePerGas;
        if (actualGasPriceUsed) {
            const actualCost = receipt.gasUsed.mul(actualGasPriceUsed);
            console.log(`Actual Gas Used: ${receipt.gasUsed.toString()}`);
            console.log(`Actual Gas Price Used: ${ethers.utils.formatUnits(actualGasPriceUsed, 'gwei')} Gwei`);
            console.log(`Actual Transaction Cost: ${ethers.utils.formatEther(actualCost)} ETH`);
        } else {
            console.log(`Could not determine actual transaction cost.`);
        }

        return tx; // Return the transaction object

    } catch (error) {
        console.error("Transaction failed:");
        if (error.error && error.error.message) {
            console.error("Ethers Error:", error.error.message);
        } else if (error.message) {
            console.error("Message:", error.message);
        } else {
            console.error(error);
        }

        if (error.message !== "Transaction cancelled by user") {
            throw error; // Re-throw if not cancelled by user
        }
    }
}

/**
 * Converts an input to an Ethers BigNumber, with validation.
 * @param {string | number} input The value to convert.
 * @param {string} fieldName The name of the field for error messages.
 * @returns {ethers.BigNumber} The converted BigNumber.
 * @throws {Error} If the input is invalid.
 */
const toBigNumber = (input, fieldName) => {
    try {
        if (typeof input === 'string' && input.match(/^\d+$/)) {
            const bn = ethers.BigNumber.from(input);
            return bn;
        }
        if (typeof input === 'number' && Number.isInteger(input) && input >= 0) {
            return ethers.BigNumber.from(input);
        }
        throw new Error(`Invalid input type or value for ${fieldName}`);
    } catch (e) {
        throw new Error(`Invalid ${fieldName} - must be a non-negative integer or string representation of a non-negative integer: ${e.message}`);
    }
};

/**
 * Prompts the user for an argument with type validation.
 * @param {string} paramName The name of the parameter.
 * @param {string} type The expected type ('address', 'uint', 'bool', 'string', 'bytes', 'ether', 'address[]').
 * @param {string} description Optional description for the prompt.
 * @returns {Promise<any>} The validated and parsed argument value.
 */
async function getArg(paramName, type, description = "") {
    let value;
    let isValid = false;

    while (!isValid) {
        value = await prompt(`Enter ${paramName} (${type})${description ? ` ${description}` : ''}: `);
        try {
            switch (type) {
                case "address":
                    ethers.utils.getAddress(value); // Validate address format
                    isValid = true;
                    break;
                case "address[]":
                    // Split comma-separated addresses and validate each
                    const addresses = value.split(',').map(addr => addr.trim());
                    for (const addr of addresses) {
                        ethers.utils.getAddress(addr);
                    }
                    value = addresses; // Return as an array of addresses
                    isValid = true;
                    break;
                case "uint":
                    toBigNumber(value, paramName); // Validate as BigNumber
                    isValid = true;
                    break;
                case "bool":
                    if (value.toLowerCase() === 'true') {
                        value = true;
                        isValid = true;
                    } else if (value.toLowerCase() === 'false') {
                        value = false;
                        isValid = true;
                    } else {
                        throw new Error("Must be 'true' or 'false'");
                    }
                    break;
                case "string":
                    isValid = true;
                    break;
                case "bytes":
                    if (ethers.utils.isHexString(value)) {
                        isValid = true;
                    } else {
                        throw new Error("Must be a hex string (e.g., 0x...)");
                    }
                    break;
                case "ether":
                    ethers.utils.parseEther(value); // Validate as Ether amount
                    isValid = true;
                    break;
                default:
                    console.warn(`Unknown type: ${type}. Allowing raw input.`);
                    isValid = true;
                    break;
            }
        } catch (e) {
            console.error(`Invalid input for ${paramName}: ${e.message}`);
            isValid = false;
        }
    }
    return value;
}

/**
 * Saves deployment information (contract address and ABI) to a JSON file.
 * @param {string} contractName The name of the deployed contract.
 * @param {string} contractAddress The address of the deployed contract.
 * @param {ethers.ContractInterface} contractAbi The ABI of the deployed contract.
 */
function saveDeploymentInfo(contractName, contractAddress, contractAbi) {
    const deploymentInfo = {
        contractName: contractName,
        address: contractAddress,
        abi: contractAbi
    };
    fs.writeFileSync(DEPLOYMENT_PATH, JSON.stringify(deploymentInfo, null, 2));
    console.log(`Deployment info saved to ${DEPLOYMENT_PATH}`);
}

/**
 * Loads deployment information from a JSON file.
 * @returns {Object | null} The deployment information if found, otherwise null.
 */
function loadDeploymentInfo() {
    if (fs.existsSync(DEPLOYMENT_PATH)) {
        const data = fs.readFileSync(DEPLOYMENT_PATH, 'utf8');
        return JSON.parse(data);
    }
    return null;
}

/**
 * Checks and approves ERC20 tokens for a spender if the current allowance is insufficient.
 * @param {ethers.Signer} user The signer (wallet) performing the approval.
 * @param {string} tokenAddress The address of the ERC20 token.
 * @param {string} spenderAddress The address of the contract that will spend the tokens (e.g., AirdropContract).
 * @param {ethers.BigNumber} amount The amount of tokens required for the subsequent transaction.
 * @param {string | null} tokenSymbolHint An optional hint for the token's symbol (e.g., "USDC").
 */
async function checkAndApproveERC20(user, tokenAddress, spenderAddress, amount, tokenSymbolHint = null) {
    if (!tokenAddress || tokenAddress === ethers.constants.AddressZero) {
        console.log("Skipping approval for native currency or zero address.");
        return;
    }
    if (!amount || ethers.BigNumber.from(amount).isZero()) {
        console.log(`Amount for approval of ${tokenSymbolHint || tokenAddress} is zero, skipping approval.`);
        return;
    }
    
    // Use MaxUint256 for approval, which is a common and efficient practice for DEX approvals
    const approvalAmount = ethers.constants.MaxUint256; 

    try {
        const erc20 = new ethers.Contract(tokenAddress, IERC20_ABI, user);
        const allowance = await erc20.allowance(user.address, spenderAddress);
        
        let actualTokenSymbol = tokenSymbolHint;
        let actualDecimals = 18; // Default to 18 decimals

        // Try to fetch symbol and decimals from the ERC20 contract if not hinted or if hint doesn't match
        try {
            if (!actualTokenSymbol) actualTokenSymbol = await erc20.symbol();
            actualDecimals = await erc20.decimals();
        } catch (e) {
            console.warn(`Could not fetch symbol/decimals for ${tokenAddress}, using defaults. ${e.message}`);
            if (!actualTokenSymbol) actualTokenSymbol = tokenAddress; // Fallback symbol to address
        }

        if (allowance.lt(amount)) { // Check if current allowance is less than the required amount
            console.log(`\nInsufficient allowance for ${actualTokenSymbol} (${tokenAddress}) for spender ${spenderAddress}.`);
            console.log(`Current allowance: ${ethers.utils.formatUnits(allowance, actualDecimals)}. Required: ${ethers.utils.formatUnits(amount, actualDecimals)}.`);

            const confirm = await prompt(`Approve ${spenderAddress} to spend MaxUint256 of ${actualTokenSymbol}? (y/n): `);
            if (confirm.toLowerCase() !== 'y') {
                throw new Error("Approval cancelled by user for " + actualTokenSymbol);
            }
            
            await handleTransaction(
                user,
                erc20.approve.bind(erc20), // Bind context to erc20 contract
                [spenderAddress, approvalAmount],
                {},
                `APPROVE_${actualTokenSymbol}` // Custom gasLimitType for logging
            );
            console.log(`${actualTokenSymbol} approval transaction completed (approved for MaxUint256).`);
        } else {
            console.log(`Sufficient allowance already exists for ${actualTokenSymbol} (${ethers.utils.formatUnits(allowance, actualDecimals)}) for spender ${spenderAddress}.`);
        }
    } catch (error) {
        const symbolForError = tokenSymbolHint || tokenAddress;
        console.error(`Failed to check/approve ERC20 ${symbolForError} for spender ${spenderAddress}: ${error.message}`);
        throw error; // Re-throw to be caught by the calling menu
    }
}


/**
 * Main function to deploy the contract or load existing deployment, then start the CLI.
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Connected to wallet:", deployer.address);

    let airdropContractAddress;
    let airdropContractAbi;

    const deploymentInfo = loadDeploymentInfo();

    if (deploymentInfo) {
        console.log(`Found existing deployment at ${deploymentInfo.address}`);
        airdropContractAddress = deploymentInfo.address;
        airdropContractAbi = deploymentInfo.abi;
    } else {
        // Deploy the AirdropContract
        const AirdropContractFactory = await ethers.getContractFactory("AirdropContract");
        console.log("Deploying AirdropContract...");
        const airdrop = await AirdropContractFactory.deploy();
        await airdrop.deployed();
        airdropContractAddress = airdrop.address;
        // FIX: Changed 'true' to 'json' for ABI formatting
        airdropContractAbi = AirdropContractFactory.interface.format('json'); 

        console.log("AirdropContract deployed to:", airdropContractAddress);
        saveDeploymentInfo("AirdropContract", airdropContractAddress, airdropContractAbi);
    }

    // Attach to the deployed contract
    const airdrop = new ethers.Contract(airdropContractAddress, airdropContractAbi, deployer);

    // Main CLI loop
    await cli(airdrop, deployer);

    rl.close(); // Close readline interface when done
}

/**
 * The main CLI (Command Line Interface) loop for interacting with the AirdropContract.
 * @param {ethers.Contract} airdrop The AirdropContract instance.
 * @param {ethers.Signer} deployer The signer (wallet) for sending transactions.
 */
async function cli(airdrop, deployer) {
    let running = true;
    while (running) {
        console.log("\n--- Airdrop Contract CLI ---");
        console.log("1. Create Public Airdrop");
        console.log("2. Create Allowlist Airdrop");
        console.log("3. Deposit Tokens");
        console.log("4. Add to Allowlist");
        console.log("5. Remove from Allowlist");
        console.log("6. Deactivate Airdrop");
        console.log("7. Withdraw Remaining Tokens");
        console.log("8. Claim Tokens");
        console.log("--- View Functions ---");
        console.log("9. Get Airdrop Details");
        console.log("10. Get Claimed Count");
        console.log("11. Is Address Allowed (Allowlist Check)");
        console.log("12. Get All Active Airdrop IDs");
        console.log("0. Exit");

        const choice = await prompt("Enter your choice: ");

        try {
            switch (choice) {
                case "1": // Create Public Airdrop
                    {
                        console.log("\n--- Create Public Airdrop ---");
                        const tokenAddress = await getArg("tokenAddress", "address");
                        const amountPerClaimStr = await getArg("amountPerClaim", "uint", "(e.g., 100 for 100 tokens, assuming 18 decimals)");
                        const amountPerClaim = ethers.utils.parseUnits(amountPerClaimStr, 18); // Assuming 18 decimals for ERC20
                        const maxClaimsPerWallet = toBigNumber(await getArg("maxClaimsPerWallet", "uint"), "maxClaimsPerWallet");
                        const durationInSeconds = toBigNumber(await getArg("durationInSeconds", "uint"), "durationInSeconds");

                        await handleTransaction(
                            deployer,
                            airdrop.connect(deployer).createPublicAirdrop,
                            [tokenAddress, amountPerClaim, maxClaimsPerWallet, durationInSeconds]
                        );
                    }
                    break;
                case "2": // Create Allowlist Airdrop
                    {
                        console.log("\n--- Create Allowlist Airdrop ---");
                        const tokenAddress = await getArg("tokenAddress", "address");
                        const amountPerClaimStr = await getArg("amountPerClaim", "uint", "(e.g., 100 for 100 tokens, assuming 18 decimals)");
                        const amountPerClaim = ethers.utils.parseUnits(amountPerClaimStr, 18); // Assuming 18 decimals for ERC20
                        const maxClaimsPerWallet = toBigNumber(await getArg("maxClaimsPerWallet", "uint"), "maxClaimsPerWallet");
                        const durationInSeconds = toBigNumber(await getArg("durationInSeconds", "uint"), "durationInSeconds");

                        await handleTransaction(
                            deployer,
                            airdrop.connect(deployer).createAllowlistAirdrop,
                            [tokenAddress, amountPerClaim, maxClaimsPerWallet, durationInSeconds]
                        );
                    }
                    break;
                case "3": // Deposit Tokens
                    {
                        console.log("\n--- Deposit Tokens ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");
                        const amountStr = await getArg("amount", "uint", "(e.g., 500 for 500 tokens, assuming 18 decimals)");
                        const amount = ethers.utils.parseUnits(amountStr, 18); // Assuming 18 decimals for ERC20

                        // Retrieve airdrop details to get the token address
                        const airdropDetails = await airdrop.getAirdropDetails(airdropId);
                        const tokenAddress = airdropDetails.tokenAddress;

                        // Check and approve ERC20 tokens before depositing
                        await checkAndApproveERC20(deployer, tokenAddress, airdrop.address, amount);
                        
                        await handleTransaction(
                            deployer,
                            airdrop.connect(deployer).depositTokens,
                            [airdropId, amount]
                        );
                    }
                    break;
                case "4": // Add to Allowlist
                    {
                        console.log("\n--- Add to Allowlist ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");
                        const addresses = await getArg("addresses", "address[]", "(comma-separated, e.g., 0xabc...,0xdef...)");

                        await handleTransaction(
                            deployer,
                            airdrop.connect(deployer).addToAllowlist,
                            [airdropId, addresses]
                        );
                    }
                    break;
                case "5": // Remove from Allowlist
                    {
                        console.log("\n--- Remove from Allowlist ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");
                        const addresses = await getArg("addresses", "address[]", "(comma-separated, e.g., 0xabc...,0xdef...)");

                        await handleTransaction(
                            deployer,
                            airdrop.connect(deployer).removeFromAllowlist,
                            [airdropId, addresses]
                        );
                    }
                    break;
                case "6": // Deactivate Airdrop
                    {
                        console.log("\n--- Deactivate Airdrop ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");

                        await handleTransaction(
                            deployer,
                            airdrop.connect(deployer).deactivateAirdrop,
                            [airdropId]
                        );
                    }
                    break;
                case "7": // Withdraw Remaining Tokens
                    {
                        console.log("\n--- Withdraw Remaining Tokens ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");

                        await handleTransaction(
                            deployer,
                            airdrop.connect(deployer).withdrawRemainingTokens,
                            [airdropId]
                        );
                    }
                    break;
                case "8": // Claim Tokens
                    {
                        console.log("\n--- Claim Tokens ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");

                        await handleTransaction(
                            deployer,
                            airdrop.connect(deployer).claimTokens,
                            [airdropId]
                        );
                    }
                    break;
                case "9": // Get Airdrop Details (View)
                    {
                        console.log("\n--- Get Airdrop Details ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");
                        const details = await airdrop.getAirdropDetails(airdropId);
                        console.log("Airdrop Details:");
                        console.log(`  Creator: ${details.creator}`);
                        console.log(`  Token Address: ${details.tokenAddress}`);
                        console.log(`  Amount Per Claim: ${ethers.utils.formatUnits(details.amountPerClaim, 18)} (assuming 18 decimals)`);
                        console.log(`  Max Claims Per Wallet: ${details.maxClaimsPerWallet.toString()}`);
                        console.log(`  Airdrop Type: ${details.airdropType === 0 ? "PUBLIC" : "ALLOWLIST"}`);
                        console.log(`  Is Active: ${details.isActive}`);
                        console.log(`  Start Time: ${new Date(details.startTime.toNumber() * 1000).toLocaleString()}`);
                        console.log(`  End Time: ${new Date(details.endTime.toNumber() * 1000).toLocaleString()}`);
                        console.log(`  Total Tokens Deposited: ${ethers.utils.formatUnits(details.totalTokensDeposited, 18)}`);
                        console.log(`  Total Tokens Claimed: ${ethers.utils.formatUnits(details.totalTokensClaimed, 18)}`);
                    }
                    break;
                case "10": // Get Claimed Count (View)
                    {
                        console.log("\n--- Get Claimed Count ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");
                        const claimerAddress = await getArg("claimerAddress", "address");
                        const count = await airdrop.getClaimedCount(airdropId, claimerAddress);
                        console.log(`Claimed Count for ${claimerAddress} in Airdrop ${airdropId}: ${count.toString()}`);
                    }
                    break;
                case "11": // Is Address Allowed (View)
                    {
                        console.log("\n--- Is Address Allowed ---");
                        const airdropId = toBigNumber(await getArg("airdropId", "uint"), "airdropId");
                        const addressToCheck = await getArg("addressToCheck", "address");
                        const isAllowed = await airdrop.isAddressAllowed(airdropId, addressToCheck);
                        console.log(`Is ${addressToCheck} allowed in Airdrop ${airdropId}: ${isAllowed}`);
                    }
                    break;
                case "12": // Get All Active Airdrop IDs (View)
                    {
                        console.log("\n--- Get All Active Airdrop IDs ---");
                        const activeIds = await airdrop.getAllAirdropIds();
                        if (activeIds.length > 0) {
                            console.log("Active Airdrop IDs:", activeIds.map(id => id.toString()).join(', '));
                        } else {
                            console.log("No active airdrops found.");
                        }
                    }
                    break;
                case "0": // Exit
                    running = false;
                    console.log("Exiting CLI. Goodbye!");
                    break;
                default:
                    console.log("Invalid choice. Please try again.");
            }
        } catch (error) {
            console.error("Operation failed:", error.message);
        }
    }
}

// Ensure the main function runs and handles errors
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
