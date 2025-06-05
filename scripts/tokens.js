const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const tokensFilePath = path.join(__dirname, "../tokens.json");

// Gas Limit Buffer: Add 20% to estimated gas limit
const GAS_LIMIT_BUFFER_PERCENT = 20;

// Helper to read user input
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
});

function prompt(query) {
  return new Promise((resolve) => rl.question(query, resolve));
}

// Function to load deployed tokens
function loadDeployedTokens() {
  if (fs.existsSync(tokensFilePath)) {
    const data = fs.readFileSync(tokensFilePath, "utf8");
    return JSON.parse(data);
  }
  return [];
}

// Function to save a newly deployed token
function saveDeployedToken(tokenDetails) {
  const tokens = loadDeployedTokens();
  // Assign a simple incrementing ID
  tokenDetails.id = tokens.length > 0 ? Math.max(...tokens.map(t => t.id || 0)) + 1 : 1;
  tokens.push(tokenDetails);
  fs.writeFileSync(tokensFilePath, JSON.stringify(tokens, null, 2));
  return tokenDetails.id; // Return the assigned ID
}

// --- Helper for formatting token amounts to human-readable strings ---
// This function converts raw BigInt amounts to human-readable decimal strings.
function formatTokenAmount(amountWei, decimals) {
  return hre.ethers.formatUnits(amountWei, decimals);
}

// --- Helper to parse numbers with K, M, B, T abbreviations ---
function parseAbbreviatedNumber(input) {
    if (typeof input !== 'string') {
        return input; // Not a string, return as is
    }
    input = input.trim().toUpperCase(); // Convert to uppercase for consistent checking

    const lastChar = input.slice(-1);
    const numericPart = input.slice(0, -1);
    let factor = 1;

    switch (lastChar) {
        case 'K':
            factor = 1_000;
            break;
        case 'M':
            factor = 1_000_000;
            break;
        case 'B':
            factor = 1_000_000_000;
            break;
        case 'T':
            factor = 1_000_000_000_000;
            break;
        default:
            // No abbreviation, return original input string
            return input;
    }

    // Attempt to parse the numeric part. parseFloat handles decimals (e.g., "1.5M")
    const num = parseFloat(numericPart);
    if (isNaN(num)) {
        // If numericPart is not a valid number (e.g., "abcM"), throw an error
        throw new Error(`Invalid numerical part for abbreviation: "${numericPart}" in "${input}"`);
    }

    // Calculate the full number and convert to string for `hre.ethers.parseUnits` or `hre.ethers.getBigInt`
    return (num * factor).toString();
}


// --- Gas Handling and Transaction Execution for *Contract Methods* ---
// This function is intended for calls like contract.transfer(), contract.approve()
async function handleTransaction(user, contractMethod, args, options = {}) {
  const provider = user.provider;

  try {
    console.log(`\nEstimating gas for transaction...`);
    let estimatedGas;
    try {
      // For contract methods, estimateGas is directly on the method
      estimatedGas = await contractMethod.estimateGas(...args, options);
      
      const bufferedGasLimit = estimatedGas + (estimatedGas * BigInt(GAS_LIMIT_BUFFER_PERCENT)) / BigInt(100);
      options.gasLimit = bufferedGasLimit;
      
      console.log(`Estimated Gas Limit: ${estimatedGas.toString()}`);
      console.log(`Buffered Gas Limit (${GAS_LIMIT_BUFFER_PERCENT}% buffer): ${bufferedGasLimit.toString()}`);
    } catch (estimationError) {
      console.warn(`Gas estimation failed: ${estimationError.message}`);
      console.warn(`This might be because the transaction is expected to fail, or it's a complex interaction.`);
      console.warn(`Proceeding without a strict gas estimate. You may need to set gas manually if it fails.`);
      if (!options.gasLimit) {
        options.gasLimit = 3000000n; // A reasonable default for many transactions, adjust if needed
        console.warn(`Using default gasLimit: ${options.gasLimit}`);
      }
    }

    const feeData = await provider.getFeeData();

    if (feeData.maxFeePerGas && feeData.maxPriorityFeePerGas) {
      console.log(`Using EIP-1559 gas pricing.`);
      options.maxFeePerGas = feeData.maxFeePerGas;
      options.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas;
      delete options.gasPrice; // Remove legacy gasPrice if EIP-1559 is used
      console.log(`Max Fee Per Gas: ${hre.ethers.formatUnits(feeData.maxFeePerGas, 'gwei')} Gwei`);
      console.log(`Max Priority Fee Per Gas: ${hre.ethers.formatUnits(feeData.maxPriorityFeePerGas, 'gwei')} Gwei`);
    } else if (feeData.gasPrice) {
      console.log(`Using legacy gas pricing.`);
      options.gasPrice = feeData.gasPrice;
      delete options.maxFeePerGas;
      delete options.maxPriorityFeePerGas;
      console.log(`Gas Price: ${hre.ethers.formatUnits(feeData.gasPrice, 'gwei')} Gwei`);
    } else {
      console.warn("Could not retrieve gas price data. Transaction might fail or use default gas settings.");
    }
    
    let estimatedCost = BigInt(0);
    if (options.gasLimit && (options.maxFeePerGas || options.gasPrice)) {
        const gasPriceToUse = options.maxFeePerGas || options.gasPrice;
        estimatedCost = BigInt(options.gasLimit) * BigInt(gasPriceToUse);
    }

    if (estimatedCost > BigInt(0)) {
      console.log(`Estimated Max Transaction Cost: ${hre.ethers.formatEther(estimatedCost)} ETH (Based on buffered gas limit and current gas prices)`);
    } else if (options.gasLimit) {
      console.log(`Could not accurately estimate transaction cost (gas price info missing), but gas limit is set to ${options.gasLimit.toString()}`);
    } else {
      console.log(`Could not estimate transaction cost accurately.`);
    }

    const confirm = await prompt("Confirm transaction? (y/n): ");
    if (confirm.toLowerCase() !== 'y') {
      throw new Error("Transaction cancelled by user");
    }

    console.log("Sending transaction...");
    const tx = await contractMethod(...args, options); // This is where the method is actually called

    console.log(`Transaction sent. Hash: ${tx.hash}`);
    console.log("Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log(`Transaction successful. Block: ${receipt.blockNumber}`);
    
    const actualGasPriceUsed = receipt.effectiveGasPrice || options.gasPrice;
    if (actualGasPriceUsed && receipt.gasUsed) {
      const actualCost = BigInt(receipt.gasUsed) * BigInt(actualGasPriceUsed);
      console.log(`Actual Gas Used: ${receipt.gasUsed.toString()}`);
      console.log(`Actual Gas Price Used: ${hre.ethers.formatUnits(actualGasPriceUsed, 'gwei')} Gwei`);
      console.log(`Actual Transaction Cost: ${hre.ethers.formatEther(actualCost)} ETH`);
    } else {
      console.log(`Could not determine actual transaction cost (effectiveGasPrice missing or gasUsed missing). Gas used: ${receipt.gasUsed ? receipt.gasUsed.toString() : 'N/A'}`);
    }

    return tx;

  } catch (error) {
    console.error("Transaction failed:");
    if (error.reason) { // Ethers v6 style error with reason
      console.error("Revert Reason:", error.reason);
      if (error.transactionHash) {
        console.error("Transaction Hash:", error.transactionHash);
      }
    } else if (error.message) {
      console.error("Message:", error.message);
    } else {
      console.error(error);
    }
    
    if (error.data && typeof error.data === 'string' && error.data.startsWith('0x')) {
      try {
        const decodedError = hre.ethers.AbiCoder.defaultAbiCoder.decode(['string'], hre.ethers.dataSlice(error.data, 4));
        console.error("Decoded Revert Data (Error String):", decodedError[0]);
      } catch (decodeError) {
        console.error("Raw Revert Data (could not decode as string):", error.data);
      }
    }

    return null; // Indicate cancellation or failure
  }
}

// --- Argument Parsing and Conversion ---
const toBigInt = (input, fieldName) => {
    try {
        const value = hre.ethers.getBigInt(input);
        if (value < 0) {
            throw new Error("Value cannot be negative.");
        }
        return value;
    } catch (e) {
        throw new Error(`Invalid ${fieldName} - must be a non-negative integer or string representation: ${e.message}`);
    }
};

async function getArg(paramName, type, description = "", contractDecimals = null) {
  let value;
  let isValid = false;
  let promptMessage = `Enter ${paramName} (${type})${description ? ` ${description}` : ''}`;

  while (!isValid) {
    value = await prompt(`${promptMessage}: `);

    try {
      // --- IMPORTANT: Pre-process user input for abbreviations ---
      // This applies to any numeric-like input that might use K, M, B, T
      if (['uint', 'uint256', 'tokenAmount', 'ether'].includes(type)) {
          value = parseAbbreviatedNumber(value);
      }
      // --- End of abbreviation pre-processing ---

      switch (type) {
        case "address":
          hre.ethers.getAddress(value); // Validate as a direct address
          isValid = true;
          break;
        case "address[]":
          const parts = value.split(',').map(a => a.trim());
          if (parts.length === 0 && value === '') throw new Error("Input cannot be empty for address[]");
          
          const resolvedParts = [];
          for (const part of parts) {
              if (part === '') throw new Error("Empty address part in list not allowed.");
              hre.ethers.getAddress(part); // Validate as direct address
              resolvedParts.push(part);
          }
          value = resolvedParts;
          isValid = true;
          break;
        case "uint":
        case "uint256":
          value = toBigInt(value, paramName); // 'value' is now the expanded number string
          isValid = true;
          break;
        case "tokenAmount": // Custom type for token amounts that need decimal conversion
            if (contractDecimals === null) {
                throw new Error("contractDecimals must be provided for 'tokenAmount' type.");
            }
            value = hre.ethers.parseUnits(value, contractDecimals); // 'value' is now the expanded number string
            isValid = true;
            break;
        case "uint[]":
        case "uint256[]":
          const uints = value.split(',').map(u => u.trim());
          if (uints.length === 0 && value === '') throw new Error("Input cannot be empty for uint[]");
          value = uints.map((u, i) => toBigInt(u, `${paramName}[${i}]`));
          isValid = true;
          break;
        case "bool":
          if (value.toLowerCase() === 'true' || value.toLowerCase() === 'false') {
            value = value.toLowerCase() === 'true';
            isValid = true;
          } else {
            throw new Error("Must be 'true' or 'false'");
          }
          break;
        case "string":
          isValid = true;
          break;
        case "bytes":
        case "bytes32": // Often represented as hex strings
          if (hre.ethers.isHexString(value)) {
            isValid = true;
          } else {
            throw new Error("Must be a hex string (e.g., 0x...)");
          }
          break;
        case "ether": // For explicit ETH value inputs (like msg.value)
          value = hre.ethers.parseEther(value); // 'value' is now the expanded number string
          isValid = true;
          break;
        default:
          console.warn(`Unknown type: ${type}. Allowing raw input for ${paramName}.`);
          isValid = true;
          break;
      }
    } catch (e) {
      // Display the original value for clearer error messages if parsing fails
      console.error(`Invalid input for ${paramName} ('${value}'): ${e.message}`);
      isValid = false;
    }
  }
  return value;
}

// --- Deployment Logic (Specific for Token Deployment) ---
async function deployNewToken(deployer) {
  console.log("\n--- Deploying a new Token ---");
  const tokenName = await getArg("token name", "string", "e.g., USD Coin");
  // IMPORTANT: For initial supply, user should enter full number (e.g., "10000000" or "10M")
  // The `getArg` function with `tokenAmount` type will handle the conversion.
  const tokenSymbol = await getArg("token symbol", "string", "e.g., USDC");
  const initialSupplyHuman = await getArg("initial supply", "string", "e.g., 10000000 or 10M"); // Updated description
  const tokenDecimalsNum = Number(await getArg("decimals", "uint", "e.g., 6 for USDC"));

  if (isNaN(tokenDecimalsNum) || tokenDecimalsNum < 0 || tokenDecimalsNum > 18) {
    console.error("Invalid decimals. Please enter a number between 0 and 18.");
    return null;
  }

  // The `initialSupplyHuman` is passed directly to parseUnits, after `getArg` has pre-processed it.
  const initialSupplyWei = hre.ethers.parseUnits(initialSupplyHuman, tokenDecimalsNum);

  const TokenFactory = await hre.ethers.getContractFactory("Token");
  
  let contract;
  let tx;

  console.log("Preparing deployment transaction...");
  try {
      // Hardhat's ContractFactory.deploy() sends the transaction and waits for its confirmation
      // by default, returning the deployed Contract instance upon success.
      contract = await TokenFactory.deploy(tokenName, tokenSymbol, initialSupplyWei, tokenDecimalsNum);
      
      // Get the transaction details from the deployed contract instance
      tx = contract.deploymentTransaction();

      if (!tx) { 
          console.error("Deployment transaction object not found after contract deployment. This indicates an unexpected state.");
          return null; 
      }

      console.log(`Deployment transaction sent. Hash: ${tx.hash}`);
      console.log("Waiting for confirmation (this may take a moment)...");

      const receipt = await tx.wait(); // Explicitly wait for the deployment transaction to be mined

      console.log(`Transaction successful. Block: ${receipt.blockNumber}`);
      
      // Log actual cost of deployment
      const actualGasPriceUsed = receipt.effectiveGasPrice || tx.gasPrice; 
      if (actualGasPriceUsed && receipt.gasUsed) {
        const actualCost = BigInt(receipt.gasUsed) * BigInt(actualGasPriceUsed);
        console.log(`Actual Gas Used: ${receipt.gasUsed.toString()}`);
        console.log(`Actual Gas Price Used: ${hre.ethers.formatUnits(actualGasPriceUsed, 'gwei')} Gwei`);
        console.log(`Actual Transaction Cost: ${hre.ethers.formatEther(actualCost)} ETH`);
      } else {
        console.log(`Could not determine actual transaction cost. Gas used: ${receipt.gasUsed ? receipt.gasUsed.toString() : 'N/A'}`);
      }

      const contractAddress = await contract.getAddress();
      console.log(`Token deployed to: ${contractAddress}`);

      const deployedTokenDetails = {
        name: tokenName,
        symbol: tokenSymbol,
        decimals: tokenDecimalsNum,
        supply: initialSupplyHuman, // Store human-readable string as entered
        address: contractAddress,
        deployer: deployer.address,
        network: hre.network.name,
        timestamp: new Date().toISOString(),
      };
      const assignedId = saveDeployedToken(deployedTokenDetails);
      console.log(`Token details saved to tokens.json with ID: ${assignedId}`);
      return contract; // Return the deployed contract instance
  } catch (error) {
      console.error("Error during token deployment:");
      if (error.reason) { // Ethers v6 style error with reason
          console.error("Revert Reason:", error.reason);
      } else if (error.message) {
          console.error("Message:", error.message);
      } else {
          console.error(error);
      }
      
      if (error.data && typeof error.data === 'string' && error.data.startsWith('0x')) {
        try {
          const decodedError = hre.ethers.AbiCoder.defaultAbiCoder.decode(['string'], hre.ethers.dataSlice(error.data, 4));
          console.error("Decoded Revert Data (Error String):", decodedError[0]);
        } catch (decodeError) {
          console.error("Raw Revert Data (could not decode as string):", error.data);
        }
      }
      return null;
  }
}

// --- Interaction Logic (For already deployed tokens) ---
async function interactWithToken(deployer, contract, tokenDetails) {
  const { name, symbol, decimals } = tokenDetails;
  console.log(`\n--- Interacting with ${name} (${symbol}) at ${contract.target} ---`);

  while (true) {
    console.log("\n--- Token Interaction Menu ---");
    console.log("1. name() [View]");
    console.log("2. symbol() [View]");
    console.log("3. decimals() [View]");
    console.log("4. totalSupply() [View]");
    console.log("5. balanceOf(account) [View]");
    console.log("6. allowance(owner, spender) [View]");
    console.log("7. getHolders() [View]");
    console.log("8. transfer(to, amount) [Transaction]");
    console.log("9. approve(spender, amount) [Transaction]");
    console.log("10. transferFrom(from, to, amount) [Transaction]");
    console.log("11. Back to Token Selection");
    console.log("0. Exit CLI");

    const choice = await prompt("Enter your choice: ");

    try {
      switch (parseInt(choice)) {
        case 1:
          const contractName = await contract.name();
          console.log("Name:", contractName);
          break;
        case 2:
          const contractSymbol = await contract.symbol();
          console.log("Symbol:", contractSymbol);
          break;
        case 3:
          console.log("Decimals:", decimals);
          break;
        case 4:
          const totalSupply = await contract.totalSupply();
          console.log(
            "Total Supply:",
            formatTokenAmount(totalSupply, decimals) // Formatted using helper
          );
          break;
        case 5:
          const account = await getArg("account address", "address");
          const balance = await contract.balanceOf(account);
          console.log(
            `Balance of ${account}:`,
            formatTokenAmount(balance, decimals) // Formatted using helper
          );
          break;
        case 6:
          const owner = await getArg("owner address", "address");
          const spender = await getArg("spender address", "address");
          const allowance = await contract.allowance(owner, spender);
          console.log(
            `Allowance for ${owner} to spend for ${spender}:`,
            formatTokenAmount(allowance, decimals) // Formatted using helper
          );
          break;
        case 7:
          const [holders, balances] = await contract.getHolders();
          console.log("Token Holders:");
          if (holders.length === 0) {
            console.log("No holders found.");
          } else {
            holders.forEach((holder, i) => {
              console.log(
                `- ${holder}: ${formatTokenAmount(balances[i], decimals)}` // Formatted using helper
              );
            });
          }
          break;
        case 8:
          const toAddress = await getArg("recipient address", "address", "(to)");
          const amountTransfer = await getArg("amount to transfer", "tokenAmount", `(e.g., 50.5 for ${symbol})`, decimals);
          await handleTransaction(deployer, contract.transfer, [toAddress, amountTransfer]);
          break;
        case 9:
          const approveSpender = await getArg("spender address", "address");
          const approveAmount = await getArg("amount to approve", "tokenAmount", `(e.g., 1000 for ${symbol})`, decimals);
          await handleTransaction(deployer, contract.approve, [approveSpender, approveAmount]);
          break;
        case 10:
          const fromAddress = await getArg("sender address", "address", "(from)");
          const transferToAddress = await getArg("recipient address", "address", "(to)");
          const transferAmountFrom = await getArg("amount to transferFrom", "tokenAmount", `(e.g., 75 for ${symbol})`, decimals);
          await handleTransaction(deployer, contract.transferFrom, [fromAddress, transferToAddress, transferAmountFrom]);
          break;
        case 11:
          return true; // Go back to token selection
        case 0:
          console.log("Exiting CLI.");
          rl.close();
          return false; // Exit the entire CLI
        default:
          console.log("Invalid choice. Please try again.");
      }
    } catch (error) {
      console.error("Error interacting with contract function:");
      if (error.reason) {
        console.error("Reason:", error.reason);
      } else if (error.message) {
        console.error("Message:", error.message);
      } else {
        console.error(error);
      }
    }
  }
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Using deployer account:", deployer.address);

  let runCli = true;

  while (runCli) {
    const existingTokens = loadDeployedTokens();
    console.log("\n--- Hardhat Token CLI ---");

    if (existingTokens.length > 0) {
      console.log("\n--- Deployed Tokens ---");
      existingTokens.forEach((token) => {
        console.log(
          `${token.id}. ${token.name} (${token.symbol}) at ${token.address} (Network: ${token.network})`
        );
      });
      console.log("D. Deploy a new token");
      console.log("0. Exit CLI");

      const choice = await prompt("Select a token ID to interact with, 'D' to deploy new, or '0' to exit: ");

      if (choice.toLowerCase() === 'd') {
        const newContract = await deployNewToken(deployer);
        if (newContract) {
          const newTokens = loadDeployedTokens(); // Reload to get the latest token details
          const newTokenDetails = newTokens.find(t => t.address === newContract.target);
          if (newTokenDetails) {
            runCli = await interactWithToken(deployer, newContract, newTokenDetails);
          } else {
            console.error("Error: Newly deployed token not found in tokens.json. This shouldn't happen.");
            runCli = true;
          }
        } else {
          runCli = true; // Deployment failed/cancelled, stay in main loop
        }
      } else if (choice === '0') {
        runCli = false;
        console.log("Exiting CLI.");
      } else {
        const selectedId = parseInt(choice);
        if (!isNaN(selectedId)) {
          const selectedTokenDetails = existingTokens.find(token => token.id === selectedId);
          if (selectedTokenDetails) {
            try {
              const Token = await hre.ethers.getContractFactory("Token");
              // Attach to the contract and connect the deployer signer for transactions
              const contract = Token.attach(selectedTokenDetails.address).connect(deployer);
              runCli = await interactWithToken(deployer, contract, selectedTokenDetails);
            } catch (error) {
              console.error(`Failed to attach to contract at ${selectedTokenDetails.address}: ${error.message}`);
              runCli = true;
            }
          } else {
            console.log("Invalid token ID. Please try again.");
            runCli = true;
          }
        } else {
          console.log("Invalid input. Please enter a token ID, 'D', or '0'.");
          runCli = true;
        }
      }
    } else {
      console.log("\n--- No deployed tokens found. Deploying a new one ---");
      const newContract = await deployNewToken(deployer);
      if (newContract) {
         const newTokens = loadDeployedTokens();
         const newTokenDetails = newTokens.find(t => t.address === newContract.target);
         if (newTokenDetails) {
            runCli = await interactWithToken(deployer, newContract, newTokenDetails);
         } else {
            console.error("Error: Newly deployed token not found in tokens.json. This shouldn't happen.");
            runCli = true;
         }
      } else {
        runCli = false; // If initial deployment fails/cancels, exit the CLI
      }
    }
  }
  rl.close();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});