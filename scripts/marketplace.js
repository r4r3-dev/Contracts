// scripts/interact.js
const { ethers } = require("hardhat");
const readline = require("readline");
const fs = require("fs");
const path = require("path");

const DEPLOYMENT_PATH = path.join(__dirname, "./rm_deployment.json"); // Changed filename for clarity

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

async function prompt(question) {
    return new Promise(resolve => {
        rl.question(question, answer => resolve(answer.trim()));
    });
}

// We will no longer rely primarily on fixed gas price and limits,
// but estimate dynamically. Keep these as potential fallbacks or info.
// const FIXED_GAS_PRICE = ethers.utils.parseUnits("30", "gwei"); // 30 Gwei
const GAS_LIMIT_BUFFER_PERCENT = 20; // Add 20% buffer to estimated gas limit

// Modified transaction handler - KEEP THIS AS PREVIOUSLY UPDATED
async function handleTransaction(user, contractMethod, args, options = {}, gasLimitType = 'DEFAULT') {
    const provider = user.provider;

    try {
        // 1. Estimate Gas Limit
        console.log(`Estimating gas for transaction...`);
        let estimatedGas;
        try {
            // Estimate gas requires the same arguments and options (like value)
            estimatedGas = await contractMethod.estimateGas(...args, options);
            // Add a buffer to the estimated gas limit
            const bufferedGasLimit = estimatedGas.mul(100 + GAS_LIMIT_BUFFER_PERCENT).div(100);
            console.log(`Estimated Gas Limit: ${estimatedGas.toString()}`);
            console.log(`Buffered Gas Limit (${GAS_LIMIT_BUFFER_PERCENT}% buffer): ${bufferedGasLimit.toString()}`);
            options.gasLimit = bufferedGasLimit; // Use the buffered estimate

        } catch (estimationError) {
            console.warn(`Gas estimation failed: ${estimationError.message}`);
            console.warn(`Proceeding without gas estimation. Transaction might fail.`);
            // Optionally, use a large default gas limit here if estimation failed completely
            // options.gasLimit = ethers.BigNumber.from(5000000); // Example large fallback limit
            // Or just let ethers handle it, but that might lead to out-of-gas errors more often
        }

        // 2. Get Gas Price (EIP-1559 or Legacy)
        const feeData = await provider.getFeeData();

        if (feeData.maxFeePerGas && feeData.maxPriorityFeePerGas) {
            // Network supports EIP-1559
            console.log(`Using EIP-1559 gas pricing.`);
            options.maxFeePerGas = feeData.maxFeePerGas;
            options.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas;
            // Remove gasPrice if it was somehow set
            delete options.gasPrice;
            console.log(`Max Fee Per Gas: ${ethers.utils.formatUnits(feeData.maxFeePerGas, 'gwei')} Gwei`);
            console.log(`Max Priority Fee Per Gas: ${ethers.utils.formatUnits(feeData.maxPriorityFeePerGas, 'gwei')} Gwei`);

        } else if (feeData.gasPrice) {
            // Legacy network
            console.log(`Using legacy gas pricing.`);
            options.gasPrice = feeData.gasPrice;
             // Remove EIP-1559 options if they were somehow set
            delete options.maxFeePerGas;
            delete options.maxPriorityFeePerGas;
            console.log(`Gas Price: ${ethers.utils.formatUnits(feeData.gasPrice, 'gwei')} Gwei`);

        } else {
             // Fallback - should not happen with modern ethers/networks but good practice
             console.warn("Could not retrieve gas price data. Transaction might fail.");
        }

        // Calculate estimated cost for user confirmation (based on estimated gas and obtained gas price)
        let estimatedCost = ethers.BigNumber.from(0);
         if (options.gasLimit && (options.maxFeePerGas || options.gasPrice)) {
             // Use maxFeePerGas for estimate if available, fallback to gasPrice
             const gasPriceEstimate = options.maxFeePerGas || options.gasPrice;
             estimatedCost = options.gasLimit.mul(gasPriceEstimate);
         }

        if (estimatedCost.gt(0)) {
            console.log(`Estimated Max Transaction Cost: ${ethers.utils.formatEther(estimatedCost)} ETH (Based on buffered gas limit and current gas prices)`); // Changed CORE to ETH for generality
        } else {
            console.log(`Could not estimate transaction cost accurately.`);
        }

        const confirm = await prompt("Confirm transaction? (y/n): ");
        if (confirm.toLowerCase() !== 'y') {
            throw new Error("Transaction cancelled by user");
        }

        // 3. Send Transaction with determined gas options
        console.log("Sending transaction...");
        const tx = await contractMethod(...args, options);

        console.log(`Transaction sent. Hash: ${tx.hash}`);
        console.log("Waiting for confirmation...");

        const receipt = await tx.wait();
        console.log(`Transaction successful. Block: ${receipt.blockNumber}`);

        // Calculate actual cost from receipt
        const actualGasPriceUsed = receipt.effectiveGasPrice || options.gasPrice || options.maxFeePerGas; // Use effectiveGasPrice if available (EIP-1559)
        if (actualGasPriceUsed) {
             const actualCost = receipt.gasUsed.mul(actualGasPriceUsed);
             console.log(`Actual Gas Used: ${receipt.gasUsed.toString()}`);
             console.log(`Actual Gas Price Used: ${ethers.utils.formatUnits(actualGasPriceUsed, 'gwei')} Gwei`);
             console.log(`Actual Transaction Cost: ${ethers.utils.formatEther(actualCost)} ETH`); // Changed CORE to ETH
        } else {
             console.log(`Could not determine actual transaction cost.`);
        }

        return tx; // Return the transaction object for further processing if needed

    } catch (error) {
        console.error("Transaction failed:");
        // Provide more detailed error if available
        if (error.error && error.error.message) {
            console.error("Ethers Error:", error.error.message);
        } else if (error.message) {
             console.error("Message:", error.message);
        } else {
             console.error(error);
        }

        // Do not re-throw if cancelled by user, just exit the interaction for this function
        if (error.message !== "Transaction cancelled by user") {
             throw error; // Re-throw other errors
        }
    }
}

// BigNumber conversion helper - KEEP THIS AS PREVIOUSLY UPDATED
const toBigNumber = (input, fieldName) => {
    try {
        if (typeof input === 'string' && input.match(/^-?\d+$/)) { // Allow negative string for potential future use, but contract expects positive
             const bn = ethers.BigNumber.from(input);
             // Basic check for non-negative for contract inputs
             if (bn.lt(0)) throw new Error("Value cannot be negative");
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

// Currency address parser - KEEP THIS AS PREVIOUSLY UPDATED
const parseCurrencyAddress = (input) => {
    if (input === '0' || input.toLowerCase() === 'native') { // Use 'native' as alias for 0
        return ethers.constants.AddressZero; // 0x0000...0000
    }
    if (!ethers.utils.isAddress(input)) {
        throw new Error("Invalid address - must be 0/native for native currency or valid contract address");
    }
    return ethers.utils.getAddress(input); // Return checksummed address
};

// Simplified ERC20 ABI for approval check and decimals
const ERC20_ABI_APPROVAL = [
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function decimals() view returns (uint8)", // Added to handle different decimals
    "function symbol() view returns (string)" // Added for better logging
];

// ERC721/ERC1155 ABIs for ownership/approval check
const ERC721_ABI = ["function getApproved(uint256) view returns (address)", "function isApprovedForAll(address,address) view returns (bool)", "function approve(address,uint256)", "function ownerOf(uint256) view returns (address)"];
const ERC1155_ABI = ["function isApprovedForAll(address,address) view returns (bool)", "function setApprovalForAll(address,bool)", "function balanceOf(address account, uint256 id) view returns (uint256)"]; // Added balanceOf for ERC1155 ownership check


// checkAndApproveNFT function
async function checkAndApproveNFT(user, contractAddress, tokenId, spenderAddress) {
    console.log(`Checking NFT approval for ${contractAddress}:${tokenId} for spender ${spenderAddress}...`);
    try {
        // Check ERC721 specific approval
        const erc721 = new ethers.Contract(contractAddress, ERC721_ABI, user);
        try {
             const owner = await erc721.ownerOf(tokenId);

             if (owner.toLowerCase() !== user.address.toLowerCase()) {
                 // Check if the spender is approved for all by the owner
                 const isApprovedForAll = await erc721.isApprovedForAll(owner, spenderAddress);
                 if (isApprovedForAll) {
                     console.log(`Note: You are not the owner of NFT ${tokenId} (${owner}), but owner has approved spender for all (ERC721).`);
                      return 'ERC721_ApprovedForAll'; // Indicate it was approved for all by owner
                 }
                 console.warn(`Warning: You are not the owner of NFT ${tokenId} (${owner}). Cannot perform approval check/action.`);
                 throw new Error(`Not the owner of NFT ${tokenId}`); // Re-throw if ownership check failed
             }

            const approvedAddress = await erc721.getApproved(tokenId);

            if (approvedAddress.toLowerCase() !== spenderAddress.toLowerCase()) {
                console.log("NFT not approved for the required contract (ERC721). Need approval...");
                const confirm = await prompt(`Approve NFT ${tokenId} for ${spenderAddress}? (y/n): `);
                if (confirm.toLowerCase() !== 'y') throw new Error("Approval cancelled by user");

                await handleTransaction(
                    user, // Use the provided user signer
                    erc721.approve,
                    [spenderAddress, tokenId],
                     {}, // No extra options like value
                     'APPROVE_ERC721' // Optional: Specific gas limit type
                );
                console.log("ERC721 approval completed");
            } else {
                 console.log("NFT already approved for token ID (ERC721)");
            }
            return 'ERC721'; // Indicate it was ERC721

        } catch (e721_specific) {
             // If token-specific ERC721 check/ownerOf fails, might be ERC1155 or ERC721 that only uses setApprovalForAll
             console.log(`ERC721 specific check failed (${e721_specific.message}). Checking ERC721/ERC1155 setApprovalForAll...`);
             // Continue to setApprovalForAll check below
        }


        // Check ERC721/ERC1155 setApprovalForAll
        try {
            const erc165 = new ethers.Contract(contractAddress, ["function supportsInterface(bytes4 interfaceId) view returns (bool)"], user.provider);
            const isERC721 = await erc165.supportsInterface("0x80ac58cd"); // ERC721 interface ID
            const isERC1155 = await erc165.supportsInterface("0xd9b67a26"); // ERC1155 interface ID

            if (isERC721 || isERC1155) {
                 const contract = new ethers.Contract(contractAddress, isERC721 ? ERC721_ABI : ERC1155_ABI, user);
                 const isApproved = await contract.isApprovedForAll(user.address, spenderAddress);

                 if (!isApproved) {
                     const tokenStandard = isERC721 ? "ERC721 Collection" : "ERC1155 Collection";
                     console.log(`\n${tokenStandard} not approved for the required contract. Need approval...`);
                     const confirm = await prompt(`Approve entire collection ${contractAddress} for ${spenderAddress}? (y/n): `);
                     if (confirm.toLowerCase() !== 'y') throw new Error("Approval cancelled by user");

                      await handleTransaction(
                          user, // Use the provided user signer
                          contract.setApprovalForAll,
                          [spenderAddress, true],
                          {}, // No extra options
                          isERC721 ? 'APPROVE_ERC721_ALL' : 'APPROVE_ERC1155_ALL' // Optional: Specific gas limit type
                      );
                     console.log(`${tokenStandard} approval completed`);
                 } else {
                     const tokenStandard = isERC721 ? "ERC721 Collection" : "ERC1155 Collection";
                      console.log(`${tokenStandard} already approved (setApprovalForAll)`);
                 }
                 return isERC721 ? 'ERC721_All' : 'ERC1155_All';

            } else {
                 throw new Error("Contract does not support ERC721 or ERC1155 interfaces.");
            }


        } catch (e_all) {
            console.error(`Failed to check/approve NFT collection/token for spender ${spenderAddress}: ${e_all.message}`);
             // Log original ERC721 specific error if it occurred
            if (e721_specific) console.error(`Original ERC721 Specific Error: ${e721_specific.message}`);
            throw new Error(`NFT approval failed: ${e_all.message}`);
        }


    } catch (error) {
        // Catch errors from the ERC721 ownerOf check or initial issues
         console.error(`Failed during initial NFT approval check: ${error.message}`);
         throw error; // Re-throw the original error
    }
}


// checkAndApproveERC20 function
async function checkAndApproveERC20(user, tokenAddress, spenderAddress, amount) {
    // Skip check for native currency
    if (tokenAddress === ethers.constants.AddressZero) {
        return;
    }

    try {
        const erc20 = new ethers.Contract(tokenAddress, ERC20_ABI_APPROVAL, user);
        const allowance = await erc20.allowance(user.address, spenderAddress);
        const decimals = await erc20.decimals();
        const symbol = await erc20.symbol();

        console.log(`Checking allowance for ${symbol} (${tokenAddress}) for spender ${spenderAddress}... Current allowance: ${ethers.utils.formatUnits(allowance, decimals)}`);


        if (allowance.lt(amount)) {
            console.log(`\nInsufficient allowance. Need to approve ${ethers.utils.formatUnits(amount, decimals)} ${symbol}.`);
            const confirm = await prompt(`Approve ${spenderAddress} to spend ${ethers.utils.formatUnits(amount, decimals)} ${symbol}? (y/n): `);
            if (confirm.toLowerCase() !== 'y') throw new Error("Approval cancelled by user");

            // Use the handleTransaction helper for the approval transaction
            // Approve maximum for simplicity, or approve specific amount
            const amountToApprove = ethers.constants.MaxUint256; // Approve maximum
            // const amountToApprove = amount; // Approve only the required amount

            await handleTransaction(
                user, // Use the provided user signer
                erc20.approve,
                [spenderAddress, amountToApprove],
                 {}, // No extra options
                 'APPROVE_ERC20' // Optional: Specific gas limit type
            );
            console.log("ERC20 approval completed");
        } else {
             console.log("Sufficient ERC20 allowance exists.");
        }
    } catch (error) {
        console.error(`Failed to check/approve ERC20 ${tokenAddress} for spender ${spenderAddress}: ${error.message}`);
        throw new Error(`ERC20 approval failed: ${error.message}`);
    }
}


async function main() {
    const [deployer] = await ethers.getSigners();
    let deployments = {};

    if (fs.existsSync(DEPLOYMENT_PATH)) {
        try {
            deployments = JSON.parse(fs.readFileSync(DEPLOYMENT_PATH));
            console.log("Loaded deployment addresses from", DEPLOYMENT_PATH);
             // Basic check if required addresses are present
            if (!deployments.RoyaltyAMM || !deployments.RareMarket) {
                 console.warn("Deployment file incomplete or outdated. Proceeding to deploy.");
                 deployments = {}; // Reset if incomplete
            }
        } catch (e) {
             console.error("Failed to parse deployment file:", e);
             deployments = {}; // Reset on error
        }
    }

    // Deploy contracts if needed
    if (Object.keys(deployments).length === 0) {
        console.log("Deploying contracts...");
        console.log("Deployer address:", deployer.address);

        // Deploy RoyaltyAMM (contract name is Royalty)
        const RoyaltyAMMFactory = await ethers.getContractFactory("Royalty"); // Use the actual contract name 'Royalty'
        const royaltyAMM = await RoyaltyAMMFactory.deploy(); // Constructor takes no arguments
        await royaltyAMM.deployed();
        console.log("Royalty AMM deployed to:", royaltyAMM.address);

        // Deploy RareMarket
        // constructor(address payable _platformFeeRecipient, uint256 _platformFeeBps)
        const RareMarketFactory = await ethers.getContractFactory("RareMarket");

        // Prompt for initial marketplace parameters
        const initialFeeRecipientInput = await prompt("Initial Platform Fee Recipient (address, leave empty for deployer): ");
        const initialFeeRecipient = parseCurrencyAddress(initialFeeRecipientInput || deployer.address);

        const initialFeeBpsInput = await prompt("Initial Platform Fee (0-1000 basis points, e.g., 250 for 2.5%): ");
        const initialFeeBps = parseInt(initialFeeBpsInput);
        if (isNaN(initialFeeBps) || initialFeeBps < 0 || initialFeeBps > 1000) {
             throw new Error("Invalid initial platform fee. Must be an integer between 0 and 1000.");
        }

        const rareMarket = await RareMarketFactory.deploy(
            initialFeeRecipient,
            initialFeeBps,
            '0x0000000000000000000000000000000000000000'
        );
        await rareMarket.deployed();
         console.log("RareMarket deployed to:", rareMarket.address);


        deployments = {
            RoyaltyAMM: royaltyAMM.address, // Use RoyaltyAMM for deployment key
            RareMarket: rareMarket.address
        };
        fs.writeFileSync(DEPLOYMENT_PATH, JSON.stringify(deployments, null, 2));
        console.log("Deployment addresses saved to", DEPLOYMENT_PATH);
    }

     // Connect to contracts with the deployer signer for transactions and views
     const market = await ethers.getContractAt("RareMarket", deployments.RareMarket, deployer);
     const royaltyAMM = await ethers.getContractAt("Royalty", deployments.RoyaltyAMM, deployer); // Use the actual contract name 'Royalty'


    console.log("Connected to contracts with deployer account:", deployer.address);
    console.log("- RareMarket:", deployments.RareMarket);
    console.log("- Royalty AMM:", deployments.RoyaltyAMM);

    // Helper to get a signer for another address (e.g., for bidding/buying as a different user)
    // Note: This is for simulation/testing. In a real scenario, each user would run the script with their own private key.
    async function getSigner(address) {
         const signers = await ethers.getSigners();
         for (const signer of signers) {
              if (signer.address.toLowerCase() === address.toLowerCase()) {
                   return signer;
              }
         }
         console.warn(`Signer with address ${address} not found among available signers. Using deployer.`);
         return deployer; // Fallback to deployer if specified signer isn't available
    }


    // CLI Interface
    while (true) {
        console.log("\n=== RareMarket & Royalty AMM CLI ===");
        console.log("--- RareMarket Actions ---");
        console.log(" 1. Create Listing");
        console.log(" 2. Buy from Listing");
        console.log(" 3. Cancel Listing");
        console.log(" 4. Create Auction");
        console.log(" 5. Bid on Auction");
        console.log(" 6. Finalize Auction");
        console.log(" 7. Create Offer");
        console.log(" 8. Cancel Offer");
        console.log(" 9. Accept Offer");
        console.log("10. Withdraw Funds (Native/ERC20) from RareMarket");
        console.log("11. Update Platform Fee Bps (RareMarket Admin)");
        console.log("12. Update Platform Fee Recipient (RareMarket Admin)");

        console.log("--- RareMarket View Functions ---");
        console.log("13. Get Listing Details");
        console.log("14. Get Auction Details");
        console.log("15. Get Offer Details");
        console.log("16. Get RareMarket Total Listings Count");
        console.log("17. Get RareMarket Total Auctions Count");
        console.log("18. Get RareMarket Total Offers Count");
        console.log("19. Get RareMarket Platform Fee Bps");
        console.log("20. Get RareMarket Platform Fee Recipient");
        console.log("21. Get RareMarket Pending Native Withdrawals");
        console.log("22. Get RareMarket Pending ERC20 Withdrawals");

        console.log("--- Royalty AMM Actions ---");
        console.log("23. Create Pool");
        console.log("24. Add Token Liquidity");
        console.log("25. Deposit NFTs for Swap Liquidity");
        console.log("26. Remove Token Liquidity");
        console.log("27. Withdraw LP Fees");
        console.log("28. Swap NFT to Token");
        console.log("29. Swap Token to NFT");
        console.log("30. Set Royalty (Public)"); // Public function in Royalty.sol
        console.log("31. Admin Set Royalty (Admin)"); // Admin function in Royalty.sol
        console.log("32. Withdraw Royalties"); // From Royalty AMM

        console.log("--- Royalty AMM View Functions ---");
        console.log("33. Get Pool Details");
        console.log("34. Get Royalty Info (IRoyaltyEngine format)"); // Uses getRoyalty
        console.log("35. Get Royalty Info (Internal format)"); // Uses royaltyInfo
        console.log("36. Get Royalty AMM Swap Fee Bps"); // Uses SWAP_FEE_BPS
        console.log("37. Get Royalty AMM Total Pool Identifiers Count"); // Uses allPoolIdentifiers.length
        console.log("38. Get Royalty AMM Collection Stats"); // Uses collectionStats
        console.log("39. Get Royalty AMM Pending Royalties"); // Uses pendingRoyalties


        console.log("0. Exit");

        const choice = await prompt("Select an option: ");

        try {
            switch (choice) {
                // --- RareMarket Actions ---
                case '1': {
                    console.log("\n--- RareMarket: Create Listing ---");
                    const assetContract = await prompt("NFT contract address: ");
                    const tokenId = toBigNumber(await prompt("Token ID (integer): "), "token ID");
                     // Approve NFT for the Marketplace contract
                    await checkAndApproveNFT(deployer, assetContract, tokenId, deployments.RareMarket);

                    const quantity = toBigNumber(await prompt("Quantity (integer): "), "quantity");
                    const currencyInput = await prompt("Currency (0/native for native, or token address): ");
                    const currency = parseCurrencyAddress(currencyInput || 'native'); // Default to native if empty

                    const priceString = await prompt("Price per token (in unit of currency): ");
                     let price;
                     try {
                          if (currency === ethers.constants.AddressZero) {
                              price = ethers.utils.parseEther(priceString); // Assume native currency is 18 decimals
                          } else {
                               // Attempt to get decimals for the ERC20 token
                              const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                              const decimals = await erc20.decimals();
                               price = ethers.utils.parseUnits(priceString, decimals);
                               console.log(`Parsed price ${priceString} with ${decimals} decimals.`);
                          }
                     } catch (e) {
                         console.error("Error parsing price or fetching token decimals:", e.message);
                         throw new Error("Invalid price input or failed to get token decimals.");
                     }


                    const days = parseInt(await prompt("Duration (days): ") || 0);
                     if (days <= 0) throw new Error("Duration must be greater than 0 days.");
                    const start = Math.floor(Date.now() / 1000);
                    const end = start + 86400 * days;

                    await handleTransaction(
                         deployer,
                         market.createListing,
                         [assetContract, tokenId, quantity, currency, price, start, end],
                         {},
                          'CREATE_LISTING'
                    );
                    console.log("RareMarket: Listing creation transaction sent!");
                    break;
                }

                case '2': {
                    console.log("\n--- RareMarket: Buy from Listing ---");
                    const listingId = toBigNumber(await prompt("Listing ID: "), "listing ID");
                    const quantity = toBigNumber(await prompt("Quantity (integer): "), "quantity");
                    const buyer = await prompt("Recipient address (leave empty for your address): ") || deployer.address; // Default recipient is caller

                     // Fetch listing details to get price and currency
                    const listing = await market.listings(listingId);

                     if (listing.status !== 1) { // Assuming 1 is Active
                          console.log(`RareMarket: Listing ${listingId.toString()} is not active or found.`);
                          break;
                     }
                     if (listing.quantity.lt(quantity)) {
                          console.log(`RareMarket: Requested quantity (${quantity.toString()}) exceeds available quantity (${listing.quantity.toString()}).`);
                          break;
                     }
                     const now = Math.floor(Date.now() / 1000);
                     if (now < listing.startTimestamp) {
                         console.log(`RareMarket: Listing ${listingId.toString()} has not started yet.`);
                         break;
                     }
                     if (now > listing.endTimestamp) {
                         console.log(`RareMarket: Listing ${listingId.toString()} has expired.`);
                         break;
                     }


                    const valueToSend = listing.pricePerToken.mul(quantity);
                    let txOptions = {};

                    // If currency is native (AddressZero), send value
                    if (listing.currency === ethers.constants.AddressZero) {
                        txOptions.value = valueToSend;
                         console.log(`RareMarket: Sending ${ethers.utils.formatEther(valueToSend)} ETH with the transaction.`);
                    } else {
                         // For ERC20 purchases, handle ERC20 approval *before* calling buyFromListing
                         const erc20 = new ethers.Contract(listing.currency, ERC20_ABI_APPROVAL, deployer);
                         const decimals = await erc20.decimals();
                         const symbol = await erc20.symbol();
                         console.log(`RareMarket: Purchasing with ERC20 token ${symbol} (${listing.currency}). Checking/requesting approval for ${ethers.utils.formatUnits(valueToSend, decimals)}...`);
                         await checkAndApproveERC20(deployer, listing.currency, deployments.RareMarket, valueToSend);
                         // No 'value' is sent with the transaction itself for ERC20.
                    }

                    await handleTransaction(
                         deployer,
                         market.buyFromListing,
                         [listingId, quantity, buyer],
                         txOptions,
                         'BUY_LISTING'
                    );
                    console.log("RareMarket: Buy transaction sent!");
                    break;
                }

                case '3': {
                    console.log("\n--- RareMarket: Cancel Listing ---");
                    const listingId = toBigNumber(await prompt("Listing ID to cancel: "), "listing ID");

                     const listing = await market.listings(listingId);
                     if (listing.listingCreator.toLowerCase() !== deployer.address.toLowerCase()) {
                          console.log(`RareMarket: You are not the creator of listing ${listingId.toString()}. Cannot cancel.`);
                          break;
                     }
                     if (listing.status !== 1) { // Assuming 1 is Active
                          console.log(`RareMarket: Listing ${listingId.toString()} is not active and cannot be cancelled.`);
                          break;
                     }

                    await handleTransaction(
                         deployer,
                         market.cancelListing,
                         [listingId],
                         {},
                         'CANCEL_LISTING'
                    );
                    console.log("RareMarket: Listing cancellation transaction sent!");
                    break;
                }

                case '4': {
                     console.log("\n--- RareMarket: Create Auction ---");
                     const assetContract = await prompt("NFT contract address: ");
                     const tokenId = toBigNumber(await prompt("Token ID (integer): "), "token ID");
                     // Approve NFT for the Marketplace contract
                     await checkAndApproveNFT(deployer, assetContract, tokenId, deployments.RareMarket);

                     const currencyInput = await prompt("Currency (0/native for native, or token address): ");
                     const currency = parseCurrencyAddress(currencyInput || 'native');

                     const days = parseInt(await prompt("Auction duration (days): ") || 0);
                      if (days <= 0) throw new Error("Duration must be greater than 0 days.");
                     const durationSeconds = 86400 * days;
                     const startTimestamp = Math.floor(Date.now() / 1000);
                     const endTimestamp = startTimestamp + durationSeconds;

                      const initialBidString = await prompt("Initial bid amount (in unit of auction currency, leave empty for 0): ");
                      let initialBid = ethers.BigNumber.from(0);
                       if (initialBidString) {
                            try {
                                if (currency === ethers.constants.AddressZero) {
                                     initialBid = ethers.utils.parseEther(initialBidString); // Assume native currency is 18 decimals
                                } else {
                                     // Attempt to get decimals for the ERC20 token
                                    const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                                    const decimals = await erc20.decimals();
                                     initialBid = ethers.utils.parseUnits(initialBidString, decimals);
                                     console.log(`RareMarket: Parsed initial bid ${initialBidString} with ${decimals} decimals.`);
                                }
                            } catch (e) {
                                console.error("RareMarket: Error parsing initial bid or fetching token decimals:", e.message);
                                throw new Error("RareMarket: Invalid initial bid input or failed to get token decimals.");
                            }
                       }

                     // Quantity is typically 1 for NFT auctions in the contract definition struct, but function takes it
                      const quantity = toBigNumber(await prompt("Quantity to auction (integer, usually 1 for ERC721): "), "quantity");


                     await handleTransaction(
                          deployer,
                          market.createAuction,
                          [assetContract, tokenId, quantity, currency, startTimestamp, endTimestamp, initialBid],
                          {},
                           'CREATE_AUCTION'
                     );
                     console.log("RareMarket: Auction creation transaction sent!");
                     break;
                    }

                    case '5': {
                        console.log("\n--- RareMarket: Bid on Auction ---");
                        const auctionId = toBigNumber(await prompt("Auction ID: "), "auction ID");
                        const bidAmountString = await prompt("Bid amount (in unit of auction currency): ");

                         const auction = await market.auctions(auctionId);

                         if (auction.status !== 1) { // Assuming 1 is Active
                              console.log(`RareMarket: Auction ${auctionId.toString()} is not active or found.`);
                              break;
                         }
                         const now = Math.floor(Date.now() / 1000);
                         if (now < auction.startTimestamp) {
                             console.log(`RareMarket: Auction ${auctionId.toString()} has not started yet.`);
                             break;
                         }
                         if (now > auction.endTimestamp) {
                             console.log(`RareMarket: Auction ${auctionId.toString()} has ended and cannot receive new bids. Please finalize it.`);
                             break;
                         }

                        let bidAmount;
                         try {
                              if (auction.currency === ethers.constants.AddressZero) {
                                   bidAmount = ethers.utils.parseEther(bidAmountString); // Assume native currency is 18 decimals
                              } else {
                                   // Attempt to get decimals for the ERC20 token
                                  const erc20 = new ethers.Contract(auction.currency, ERC20_ABI_APPROVAL, deployer); // Use deployer to fetch info
                                  const decimals = await erc20.decimals();
                                   bidAmount = ethers.utils.parseUnits(bidAmountString, decimals);
                                   console.log(`RareMarket: Parsed bid amount ${bidAmountString} with ${decimals} decimals.`);
                              }
                         } catch (e) {
                             console.error("RareMarket: Error parsing bid amount or fetching token decimals:", e.message);
                             throw new Error("RareMarket: Invalid bid amount input or failed to get token decimals.");
                         }


                         if (bidAmount.lte(auction.highestBid)) {
                             const highestBidFormatted = auction.currency === ethers.constants.AddressZero
                               ? ethers.utils.formatEther(auction.highestBid)
                               : ethers.utils.formatUnits(auction.highestBid, await new ethers.Contract(auction.currency, ERC20_ABI_APPROVAL, deployer).decimals());
                             console.log(`RareMarket: Bid amount (${bidAmountString}) must be greater than the current highest bid (${highestBidFormatted}).`);
                              break;
                         }

                        let txOptions = {};
                        // If auction currency is native, send value with bid
                        if (auction.currency === ethers.constants.AddressZero) {
                            txOptions.value = bidAmount;
                             console.log(`RareMarket: Sending ${ethers.utils.formatEther(bidAmount)} ETH with the bid.`);
                        } else {
                             // For ERC20 bids, handle ERC20 approval *before* calling bidInAuction
                             console.log(`RareMarket: Bidding with ERC20 token ${auction.currency}. Checking/requesting approval for ${ethers.utils.formatUnits(bidAmount, (await new ethers.Contract(auction.currency, ERC20_ABI_APPROVAL, deployer).decimals()))}...`);
                             await checkAndApproveERC20(deployer, auction.currency, deployments.RareMarket, bidAmount);
                             // No 'value' is sent with the transaction itself for ERC20.
                        }

                        await handleTransaction(
                             deployer,
                             market.bidInAuction,
                             [auctionId, bidAmount],
                             txOptions,
                             'PLACE_BID'
                        );
                        console.log("RareMarket: Bid transaction sent!");
                        break;
                    }

                    case '6': {
                         console.log("\n--- RareMarket: Finalize Auction ---");
                         const auctionId = toBigNumber(await prompt("Auction ID to finalize: "), "auction ID");

                         const auction = await market.auctions(auctionId);
                         if (auction.status !== 1) { // Assuming 1 is Active
                              console.log(`RareMarket: Auction ${auctionId.toString()} is not active and cannot be finalized.`);
                              break;
                         }
                          const now = Math.floor(Date.now() / 1000);
                          if (now <= auction.endTimestamp) {
                              console.log(`RareMarket: Auction ${auctionId.toString()} has not ended yet.`);
                              break;
                          }

                         await handleTransaction(
                              deployer,
                              market.finalizeAuction,
                              [auctionId],
                              {},
                              'FINALIZE_AUCTION'
                         );
                         console.log("RareMarket: Auction finalization transaction sent!");
                         break;
                    }


                    case '7': {
                         console.log("\n--- RareMarket: Create Offer ---");
                         const assetContract = await prompt("NFT contract address: ");
                         const tokenId = toBigNumber(await prompt("Token ID (integer): "), "token ID");
                         const quantity = toBigNumber(await prompt("Quantity (integer): "), "quantity");
                         const currencyInput = await prompt("Currency (0/native for native, or token address): ");
                         const currency = parseCurrencyAddress(currencyInput || 'native'); // Default to native if empty

                         const priceString = await prompt("Price per token (in unit of currency): ");
                          let price;
                          try {
                               if (currency === ethers.constants.AddressZero) {
                                   price = ethers.utils.parseEther(priceString); // Assume native currency is 18 decimals
                               } else {
                                    // Attempt to get decimals for the ERC20 token
                                   const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                                   const decimals = await erc20.decimals();
                                    price = ethers.utils.parseUnits(priceString, decimals);
                                    console.log(`RareMarket: Parsed price ${priceString} with ${decimals} decimals.`);
                               }
                          } catch (e) {
                              console.error("RareMarket: Error parsing price or fetching token decimals:", e.message);
                              throw new Error("RareMarket: Invalid price input or failed to get token decimals.");
                          }

                         const days = parseInt(await prompt("Offer expiry (days from now): ") || 0);
                          if (days <= 0) throw new Error("Duration must be greater than 0 days.");
                         const expiryTimestamp = Math.floor(Date.now() / 1000) + 86400 * days;

                         const totalOfferAmount = price.mul(quantity);
                         let txOptions = {};

                         // Offeror pays upfront, handle payment
                         if (currency === ethers.constants.AddressZero) {
                              txOptions.value = totalOfferAmount;
                              console.log(`RareMarket: Sending ${ethers.utils.formatEther(totalOfferAmount)} ETH with the offer.`);
                         } else {
                              // For ERC20 offers, check/approve ERC20 transfer
                              console.log(`RareMarket: Offering with ERC20 token ${currency}. Checking/requesting approval for ${ethers.utils.formatUnits(totalOfferAmount, (await new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer).decimals()))}...`);
                              await checkAndApproveERC20(deployer, currency, deployments.RareMarket, totalOfferAmount);
                         }

                         await handleTransaction(
                              deployer,
                              market.createOffer,
                              [assetContract, tokenId, quantity, currency, price, expiryTimestamp],
                              txOptions,
                              'CREATE_OFFER'
                         );
                         console.log("RareMarket: Offer creation transaction sent!");
                         break;
                    }

                    case '8': {
                        console.log("\n--- RareMarket: Cancel Offer ---");
                        const offerId = toBigNumber(await prompt("Offer ID to cancel: "), "offer ID");

                         const offer = await market.offers(offerId);
                         if (offer.offeror.toLowerCase() !== deployer.address.toLowerCase()) {
                              console.log(`RareMarket: You are not the creator of offer ${offerId.toString()}. Cannot cancel.`);
                              break;
                         }
                         if (offer.status !== 1) { // Assuming 1 is Active
                              console.log(`RareMarket: Offer ${offerId.toString()} is not active and cannot be cancelled.`);
                              break;
                         }
                          const now = Math.floor(Date.now() / 1000);
                          if (now > offer.expiryTimestamp) {
                              console.log(`RareMarket: Offer ${offerId.toString()} has already expired.`);
                              break;
                          }

                        await handleTransaction(
                             deployer,
                             market.cancelOffer,
                             [offerId],
                             {},
                             'CANCEL_OFFER'
                        );
                        console.log("RareMarket: Offer cancellation transaction sent!");
                        break;
                    }

                    case '9': {
                         console.log("\n--- RareMarket: Accept Offer ---");
                         const offerId = toBigNumber(await prompt("Offer ID to accept: "), "offer ID");

                         const offer = await market.offers(offerId);
                         if (offer.status !== 1) { // Assuming 1 is Active
                              console.log(`RareMarket: Offer ${offerId.toString()} is not active or found.`);
                              break;
                         }
                          const now = Math.floor(Date.now() / 1000);
                          if (now > offer.expiryTimestamp) {
                              console.log(`RareMarket: Offer ${offerId.toString()} has expired.`);
                              break;
                          }

                         // The acceptor must own the NFT and approve the marketplace to transfer it
                         const assetContract = offer.assetContract;
                         const tokenId = offer.tokenId;
                         const quantity = offer.quantity;
                         const tokenType = offer.tokenType; // Assuming TokenType enum matches 0/1 for ERC721/ERC1155

                         console.log(`RareMarket: Accepting offer for NFT ${assetContract}:${tokenId}, quantity ${quantity.toString()}`);

                         // Check ownership before requesting approval
                         let isOwner = false;
                         if (tokenType === 0) { // ERC721
                              try {
                                   const owner = await new ethers.Contract(assetContract, ERC721_ABI, deployer).ownerOf(tokenId);
                                   if (owner.toLowerCase() === deployer.address.toLowerCase()) isOwner = true;
                              } catch (e) {
                                   console.error("RareMarket: Failed to check ERC721 ownership:", e.message);
                              }
                         } else if (tokenType === 1) { // ERC1155
                              try {
                                   const balance = await new ethers.Contract(assetContract, ERC1155_ABI, deployer).balanceOf(deployer.address, tokenId);
                                   if (balance.gte(quantity)) isOwner = true;
                              } catch (e) {
                                   console.error("RareMarket: Failed to check ERC1155 balance:", e.message);
                              }
                         } else {
                             console.log(`RareMarket: Unknown token type ${tokenType}. Cannot verify ownership.`);
                         }

                         if (!isOwner) {
                             console.log(`RareMarket: You do not own the required quantity of NFT ${assetContract}:${tokenId} to accept this offer.`);
                             break;
                         }

                         // Request NFT approval for the marketplace
                         console.log("RareMarket: Checking/requesting NFT approval for marketplace...");
                         await checkAndApproveNFT(deployer, assetContract, tokenId, deployments.RareMarket);


                         await handleTransaction(
                              deployer,
                              market.acceptOffer,
                              [offerId],
                              {},
                              'ACCEPT_OFFER'
                         );
                         console.log("RareMarket: Offer acceptance transaction sent!");
                         break;
                    }


                    case '10': {
                         console.log("\n--- RareMarket: Withdraw Funds (Native/ERC20) ---");
                         const currencyInput = await prompt("Currency to withdraw (0/native for native, or token address): ");
                         const currency = parseCurrencyAddress(currencyInput || 'native'); // Default to native if empty

                         if (currency === ethers.constants.AddressZero) {
                              // Withdraw native funds
                              const pending = await market.pendingNativeWithdrawals(deployer.address);
                              if (pending.isZero()) {
                                   console.log("RareMarket: No pending native currency withdrawals.");
                                   break;
                              }
                              console.log(`RareMarket: Pending native withdrawal: ${ethers.utils.formatEther(pending)} ETH.`);

                              await handleTransaction(
                                   deployer,
                                   market.withdrawNativeCurrency, // This function handles native in the contract
                                   [], // No args needed for native withdrawal
                                   {},
                                   'WITHDRAW_NATIVE'
                              );
                              console.log("RareMarket: Native withdrawal transaction sent!");

                         } else {
                             // Withdraw ERC20 funds
                             const pending = await market.pendingErc20Withdrawals(deployer.address, currency);
                             if (pending.isZero()) {
                                  console.log(`RareMarket: No pending withdrawals for ERC20 token ${currency}.`);
                                  break;
                             }
                              const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                              const decimals = await erc20.decimals();
                              const symbol = await erc20.symbol();

                             console.log(`RareMarket: Pending withdrawal for ${symbol} (${currency}): ${ethers.utils.formatUnits(pending, decimals)} ${symbol}.`);

                             await handleTransaction(
                                  deployer,
                                  market.withdrawErc20Funds,
                                  [currency], // Pass the token address
                                  {},
                                  'WITHDRAW_ERC20'
                             );
                             console.log("RareMarket: ERC20 withdrawal transaction sent!");
                         }
                         break;
                    }

                    case '11': {
                         console.log("\n--- RareMarket: Update Platform Fee Bps (Admin) ---");
                          // Check if deployer has ADMIN_ROLE - simplified check, assumes deployer was granted it in constructor/setup
                         const isAdmin = await market.hasRole(market.ADMIN_ROLE(), deployer.address);
                         if (!isAdmin) {
                             console.log("RareMarket: You do not have the ADMIN_ROLE to perform this action.");
                             break;
                         }

                         const newFeeBpsInput = await prompt("New platform fee (0-1000 basis points): ");
                         const newFeeBps = parseInt(newFeeBpsInput);
                         if (isNaN(newFeeBps) || newFeeBps < 0 || newFeeBps > 1000) {
                              throw new Error("RareMarket: Invalid platform fee. Must be an integer between 0 and 1000.");
                         }

                         await handleTransaction(
                              deployer,
                              market.updatePlatformFeeBps,
                              [newFeeBps],
                              {},
                              'UPDATE_PLATFORM_FEE'
                         );
                         console.log("RareMarket: Update platform fee transaction sent!");
                         break;
                    }

                    case '12': {
                        console.log("\n--- RareMarket: Update Platform Fee Recipient (Admin) ---");
                         // Check if deployer has ADMIN_ROLE
                        const isAdmin = await market.hasRole(market.ADMIN_ROLE(), deployer.address);
                        if (!isAdmin) {
                            console.log("RareMarket: You do not have the ADMIN_ROLE to perform this action.");
                            break;
                        }
                        const newRecipientInput = await prompt("New platform fee recipient address: ");
                        const newRecipient = parseCurrencyAddress(newRecipientInput);

                        await handleTransaction(
                             deployer,
                             market.updatePlatformFeeRecipient,
                             [newRecipient],
                             {},
                             'UPDATE_PLATFORM_RECIPIENT'
                        );
                        console.log("RareMarket: Update platform fee recipient transaction sent!");
                        break;
                    }


                    // --- RareMarket View Functions ---
                    case '13': {
                         console.log("\n--- RareMarket: Get Listing Details ---");
                         const listingId = toBigNumber(await prompt("Listing ID: "), "listing ID");
                         try {
                              const listing = await market.listings(listingId);

                              if (listing.listingCreator === ethers.constants.AddressZero && listing.assetContract === ethers.constants.AddressZero) { // Simple check if mapping entry is zeroed out
                                   console.log(`RareMarket: Listing ID ${listingId.toString()} not found or is invalid.`);
                                   break;
                              }

                              const statusMap = ["Inactive", "Active", "Sold", "Cancelled", "Finalized"]; // Match contract enum Status

                              console.log("RareMarket Listing Details:");
                              console.log(`  ID: ${listingId.toString()}`);
                              console.log(`  Creator: ${listing.listingCreator}`);
                              console.log(`  Asset Contract: ${listing.assetContract}`);
                              console.log(`  Token ID: ${listing.tokenId.toString()}`);
                               console.log(`  Quantity: ${listing.quantity.toString()}`);
                              console.log(`  Currency: ${listing.currency === ethers.constants.AddressZero ? "ETH (Native)" : listing.currency}`);
                               // Attempt to format price based on currency decimals
                              let formattedPrice = "N/A";
                               let currencySymbol = listing.currency === ethers.constants.AddressZero ? "ETH" : listing.currency;

                              try {
                                   if (listing.pricePerToken.gt(0)) {
                                        if (listing.currency === ethers.constants.AddressZero) {
                                             formattedPrice = ethers.utils.formatEther(listing.pricePerToken);
                                        } else {
                                             const erc20 = new ethers.Contract(listing.currency, ERC20_ABI_APPROVAL, deployer);
                                             const decimals = await erc20.decimals();
                                              currencySymbol = await erc20.symbol();
                                             formattedPrice = ethers.utils.formatUnits(listing.pricePerToken, decimals);
                                        }
                                   } else {
                                       formattedPrice = "0";
                                   }
                              } catch (e) {
                                  console.warn("RareMarket: Could not format price:", e.message);
                                  currencySymbol = listing.currency; // Fallback if symbol fetch fails
                              }
                              console.log(`  Price Per Token: ${formattedPrice} ${currencySymbol}`);
                              console.log(`  Start Time: ${new Date(listing.startTimestamp * 1000).toLocaleString()} (${listing.startTimestamp})`);
                              console.log(`  End Time: ${new Date(listing.endTimestamp * 1000).toLocaleString()} (${listing.endTimestamp})`);
                              console.log(`  Status: ${statusMap[listing.status] || listing.status}`);
                              console.log(`  Token Type: ${listing.tokenType === 0 ? "ERC721" : listing.tokenType === 1 ? "ERC1155" : "Unknown"}`);


                         } catch (error) {
                               console.error("RareMarket: Error fetching listing:", error.message);
                         }
                         break;
                    }

                    case '14': {
                         console.log("\n--- RareMarket: Get Auction Details ---");
                         const auctionId = toBigNumber(await prompt("Auction ID: "), "auction ID");
                         try {
                              const auction = await market.auctions(auctionId);

                              if (auction.creator === ethers.constants.AddressZero && auction.assetContract === ethers.constants.AddressZero) { // Simple check if mapping entry is zeroed out
                                   console.log(`RareMarket: Auction ID ${auctionId.toString()} not found or is invalid.`);
                                   break;
                              }

                              const statusMap = ["Inactive", "Active", "Sold", "Cancelled", "Finalized"]; // Match contract enum Status

                              // Convert timestamps to readable dates
                              const startDate = new Date(auction.startTimestamp * 1000).toLocaleString();
                              const endDate = new Date(auction.endTimestamp * 1000).toLocaleString();
                              const now = Math.floor(Date.now() / 1000);

                               console.log("RareMarket Auction Details:");
                               console.log(`  ID: ${auctionId.toString()}`);
                               console.log(`  Creator: ${auction.creator}`);
                               console.log(`  Asset Contract: ${auction.assetContract}`);
                               console.log(`  Token ID: ${auction.tokenId.toString()}`);
                                console.log(`  Quantity: ${auction.quantity.toString()}`);
                               console.log(`  Currency: ${auction.currency === ethers.constants.AddressZero ? "ETH (Native)" : auction.currency}`);

                               // Attempt to format highest bid based on currency decimals
                              let formattedHighestBid = "0";
                               let currencySymbol = auction.currency === ethers.constants.AddressZero ? "ETH" : auction.currency;
                              try {
                                   if (auction.highestBid.gt(0)) {
                                        if (auction.currency === ethers.constants.AddressZero) {
                                             formattedHighestBid = ethers.utils.formatEther(auction.highestBid);
                                        } else {
                                             const erc20 = new ethers.Contract(auction.currency, ERC20_ABI_APPROVAL, deployer);
                                             const decimals = await erc20.decimals();
                                             currencySymbol = await erc20.symbol();
                                             formattedHighestBid = ethers.utils.formatUnits(auction.highestBid, decimals);
                                        }
                                   }
                              } catch (e) {
                                   console.warn("RareMarket: Could not format highest bid:", e.message);
                                    currencySymbol = auction.currency; // Fallback
                              }

                               console.log(`  Status: ${statusMap[auction.status] || auction.status}`);
                               console.log(`  Highest Bid: ${formattedHighestBid} ${currencySymbol}`);
                               console.log(`  Highest Bidder: ${auction.highestBidder === ethers.constants.AddressZero ? "None" : auction.highestBidder}`);
                               console.log(`  Start Time: ${startDate} (${auction.startTimestamp})`);
                               console.log(`  End Time: ${endDate} (${auction.endTimestamp})`);
                               console.log(`  Time Remaining: ${auction.endTimestamp > now ? `${Math.round((auction.endTimestamp - now) / 60)} minutes remaining` : "Auction ended"}`);
                               console.log(`  Token Type: ${auction.tokenType === 0 ? "ERC721" : auction.tokenType === 1 ? "ERC1155" : "Unknown"}`);


                         } catch (error) {
                               console.error("RareMarket: Error fetching auction:", error.message);
                         }
                         break;
                    }

                     case '15': {
                         console.log("\n--- RareMarket: Get Offer Details ---");
                         const offerId = toBigNumber(await prompt("Offer ID: "), "offer ID");
                         try {
                              const offer = await market.offers(offerId);

                              if (offer.offeror === ethers.constants.AddressZero && offer.assetContract === ethers.constants.AddressZero) { // Simple check if mapping entry is zeroed out
                                   console.log(`RareMarket: Offer ID ${offerId.toString()} not found or is invalid.`);
                                   break;
                              }

                              const statusMap = ["Inactive", "Active", "Sold", "Cancelled", "Finalized"]; // Match contract enum Status

                              // Convert expiry timestamp to readable date
                              const expiryDate = new Date(offer.expiryTimestamp * 1000).toLocaleString();
                              const now = Math.floor(Date.now() / 1000);


                               console.log("RareMarket Offer Details:");
                               console.log(`  ID: ${offerId.toString()}`);
                               console.log(`  Offeror: ${offer.offeror}`);
                               console.log(`  Asset Contract: ${offer.assetContract}`);
                               console.log(`  Token ID: ${offer.tokenId.toString()}`);
                                console.log(`  Quantity: ${offer.quantity.toString()}`);
                               console.log(`  Currency: ${offer.currency === ethers.constants.AddressZero ? "ETH (Native)" : offer.currency}`);

                               // Attempt to format price based on currency decimals
                              let formattedPrice = "N/A";
                               let currencySymbol = offer.currency === ethers.constants.AddressZero ? "ETH" : offer.currency;

                              try {
                                   if (offer.pricePerToken.gt(0)) {
                                        if (offer.currency === ethers.constants.AddressZero) {
                                             formattedPrice = ethers.utils.formatEther(offer.pricePerToken);
                                        } else {
                                             const erc20 = new ethers.Contract(offer.currency, ERC20_ABI_APPROVAL, deployer);
                                             const decimals = await erc20.decimals();
                                              currencySymbol = await erc20.symbol();
                                             formattedPrice = ethers.utils.formatUnits(offer.pricePerToken, decimals);
                                        }
                                   } else {
                                       formattedPrice = "0";
                                   }
                              } catch (e) {
                                   console.warn("RareMarket: Could not format price:", e.message);
                                   currencySymbol = offer.currency; // Fallback
                              }

                               console.log(`  Price Per Token: ${formattedPrice} ${currencySymbol}`);
                               console.log(`  Expiry Time: ${expiryDate} (${offer.expiryTimestamp})`);
                               console.log(`  Time Remaining: ${offer.expiryTimestamp > now ? `${Math.round((offer.expiryTimestamp - now) / 60)} minutes remaining` : "Expired"}`);
                               console.log(`  Status: ${statusMap[offer.status] || offer.status}`);
                               console.log(`  Token Type: ${offer.tokenType === 0 ? "ERC721" : offer.tokenType === 1 ? "ERC1155" : "Unknown"}`);

                         } catch (error) {
                               console.error("RareMarket: Error fetching offer:", error.message);
                         }
                         break;
                     }

                     case '16': {
                         console.log("\n--- RareMarket: Get Total Listings Count ---");
                          const count = await market.totalListings();
                         console.log(`RareMarket Total Listings: ${count.toString()}`);
                         break;
                     }
                     case '17': {
                         console.log("\n--- RareMarket: Get Total Auctions Count ---");
                         const count = await market.totalAuctions();
                        console.log(`RareMarket Total Auctions: ${count.toString()}`);
                         break;
                    }
                     case '18': {
                         console.log("\n--- RareMarket: Get Total Offers Count ---");
                         const count = await market.totalOffers();
                         console.log(`RareMarket Total Offers: ${count.toString()}`);
                         break;
                    }

                     case '19': {
                         console.log("\n--- RareMarket: Get Platform Fee Bps ---");
                         const feeBps = await market.platformFeeBps();
                         console.log(`RareMarket Platform Fee: ${feeBps.toString()} basis points (${feeBps.toNumber() / 100}%)`);
                         break;
                     }

                     case '20': {
                         console.log("\n--- RareMarket: Get Platform Fee Recipient ---");
                          const recipient = await market.platformFeeRecipient();
                         console.log(`RareMarket Platform Fee Recipient: ${recipient}`);
                         break;
                     }

                     case '21': {
                         console.log("\n--- RareMarket: Get Pending Native Withdrawals ---");
                         const pending = await market.pendingNativeWithdrawals(deployer.address);
                         console.log(`RareMarket: Pending Native (ETH) Withdrawal for ${deployer.address}: ${ethers.utils.formatEther(pending)} ETH`);
                         break;
                     }

                     case '22': {
                        console.log("\n--- RareMarket: Get Pending ERC20 Withdrawals ---");
                        const currencyInput = await prompt("ERC20 token address to check pending withdrawals for: ");
                         const currency = parseCurrencyAddress(currencyInput);
                          if (currency === ethers.constants.AddressZero) {
                               console.log("RareMarket: Please provide an ERC20 token address, not native currency.");
                               break;
                          }

                        try {
                             const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                             const decimals = await erc20.decimals();
                             const symbol = await erc20.symbol();
                             const pending = await market.pendingErc20Withdrawals(deployer.address, currency);
                             console.log(`RareMarket: Pending ${symbol} (${currency}) Withdrawal for ${deployer.address}: ${ethers.utils.formatUnits(pending, decimals)} ${symbol}`);

                        } catch (e) {
                             console.error(`RareMarket: Could not get pending withdrawals for ERC20 ${currency}: ${e.message}`);
                        }
                         break;
                     }


                     // --- Royalty AMM Actions ---
                    case '23': {
                        console.log("\n--- Royalty AMM: Create Pool ---");
                        const collection = await prompt("NFT collection address: ");
                        const currencyInput = await prompt("Currency address (0/native for native): ");
                        const currency = parseCurrencyAddress(currencyInput || 'native');

                        const tokenIdsInput = await prompt("Comma-separated NFT Token IDs to deposit (e.g., 1,2,3): ");
                         const initialTokenIds = tokenIdsInput.split(',').map(id => toBigNumber(id.trim(), `token ID "${id.trim()}"`));
                        if (initialTokenIds.length === 0) throw new Error("Must provide at least one token ID.");

                        // Approve NFTs for the Royalty AMM contract
                        console.log("Checking/requesting NFT approval for Royalty AMM...");
                        // Need to check/approve each token individually if ERC721, or setApprovalForAll for collection
                        // checkAndApproveNFT handles this logic now.
                        // We only need to call it once for the first token to trigger collection approval if needed.
                        // A more robust check might ensure *all* tokens in the list are owned and approved.
                         if (initialTokenIds.length > 0) {
                             await checkAndApproveNFT(deployer, collection, initialTokenIds[0], deployments.RoyaltyAMM);
                         }


                        const initialTokenAmountString = await prompt("Initial token liquidity amount (in unit of currency, leave empty for 0): ");
                         let initialTokenAmount = ethers.BigNumber.from(0);
                         let txOptions = {};

                         if (initialTokenAmountString) {
                             try {
                                 if (currency === ethers.constants.AddressZero) {
                                     initialTokenAmount = ethers.utils.parseEther(initialTokenAmountString);
                                     txOptions.value = initialTokenAmount;
                                     console.log(`Royalty AMM: Sending ${ethers.utils.formatEther(initialTokenAmount)} ETH with the transaction.`);
                                 } else {
                                     const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                                     const decimals = await erc20.decimals();
                                     initialTokenAmount = ethers.utils.parseUnits(initialTokenAmountString, decimals);
                                     console.log(`Royalty AMM: Parsed initial token amount ${initialTokenAmountString} with ${decimals} decimals.`);
                                     // ERC20 approval is handled below if amount > 0
                                 }
                             } catch (e) {
                                 console.error("Royalty AMM: Error parsing initial token amount or fetching token decimals:", e.message);
                                 throw new Error("Royalty AMM: Invalid initial token amount input or failed to get token decimals.");
                             }
                         }

                         // Check/approve ERC20 transfer if necessary and amount > 0
                         if (currency !== ethers.constants.AddressZero && initialTokenAmount.gt(0)) {
                             console.log(`Royalty AMM: Depositing ERC20 token ${currency}. Checking/requesting approval for ${ethers.utils.formatUnits(initialTokenAmount, (await new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer).decimals()))}...`);
                             await checkAndApproveERC20(deployer, currency, deployments.RoyaltyAMM, initialTokenAmount);
                         }


                        await handleTransaction(
                             deployer,
                             royaltyAMM.createPool,
                             [collection, currency, initialTokenIds, initialTokenAmount],
                             txOptions,
                             'CREATE_POOL'
                        );
                        console.log("Royalty AMM: Create Pool transaction sent!");
                        break;
                    }

                    case '24': {
                        console.log("\n--- Royalty AMM: Add Token Liquidity ---");
                         const collection = await prompt("NFT collection address for the pool: ");
                         const currencyInput = await prompt("Currency address for the pool (0/native for native): ");
                         const currency = parseCurrencyAddress(currencyInput || 'native');
                         const amountString = await prompt("Amount of tokens to add (in unit of currency): ");

                         let amount;
                         let txOptions = {};

                         try {
                             if (currency === ethers.constants.AddressZero) {
                                  amount = ethers.utils.parseEther(amountString);
                                 txOptions.value = amount;
                                  console.log(`Royalty AMM: Sending ${ethers.utils.formatEther(amount)} ETH with the transaction.`);
                             } else {
                                 const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                                 const decimals = await erc20.decimals();
                                  amount = ethers.utils.parseUnits(amountString, decimals);
                                  console.log(`Royalty AMM: Parsed amount ${amountString} with ${decimals} decimals.`);
                                 // ERC20 approval is handled below if amount > 0
                             }
                         } catch (e) {
                              console.error("Royalty AMM: Error parsing token amount or fetching token decimals:", e.message);
                              throw new Error("Royalty AMM: Invalid token amount input or failed to get token decimals.");
                         }

                         require(amount.gt(0), "Royalty AMM: Amount must be greater than 0");

                         // Check/approve ERC20 transfer if necessary
                         if (currency !== ethers.constants.AddressZero) {
                             console.log(`Royalty AMM: Depositing ERC20 token ${currency}. Checking/requesting approval for ${ethers.utils.formatUnits(amount, (await new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer).decimals()))}...`);
                             await checkAndApproveERC20(deployer, currency, deployments.RoyaltyAMM, amount);
                         }


                        await handleTransaction(
                             deployer,
                             royaltyAMM.addLiquidity,
                             [collection, currency, amount],
                             txOptions,
                             'ADD_LIQUIDITY'
                        );
                        console.log("Royalty AMM: Add Token Liquidity transaction sent!");
                        break;
                    }

                    case '25': {
                        console.log("\n--- Royalty AMM: Deposit NFTs for Swap Liquidity ---");
                         const collection = await prompt("NFT collection address for the pool: ");
                         const currencyInput = await prompt("Currency address for the pool (0/native for native): ");
                         const currency = parseCurrencyAddress(currencyInput || 'native');

                         const tokenIdsInput = await prompt("Comma-separated NFT Token IDs to deposit (e.g., 4,5): ");
                         const tokenIds = tokenIdsInput.split(',').map(id => toBigNumber(id.trim(), `token ID "${id.trim()}"`));
                         if (tokenIds.length === 0) throw new Error("Must provide at least one token ID.");

                         // Approve NFTs for the Royalty AMM contract
                         console.log("Checking/requesting NFT approval for Royalty AMM...");
                         if (tokenIds.length > 0) {
                             await checkAndApproveNFT(deployer, collection, tokenIds[0], deployments.RoyaltyAMM);
                         }

                        await handleTransaction(
                             deployer,
                             royaltyAMM.depositNFTsForSwap,
                             [collection, currency, tokenIds],
                             {},
                             'DEPOSIT_NFT_LIQUIDITY'
                        );
                        console.log("Royalty AMM: Deposit NFTs transaction sent!");
                        break;
                    }

                    case '26': {
                        console.log("\n--- Royalty AMM: Remove Token Liquidity ---");
                        const collection = await prompt("NFT collection address for the pool: ");
                        const currencyInput = await prompt("Currency address for the pool (0/native for native): ");
                        const currency = parseCurrencyAddress(currencyInput || 'native');
                        const shareAmount = toBigNumber(await prompt("Amount of liquidity shares to remove (integer): "), "share amount");

                        await handleTransaction(
                            deployer,
                            royaltyAMM.removeLiquidity,
                            [collection, currency, shareAmount],
                            {},
                            'REMOVE_LIQUIDITY'
                        );
                        console.log("Royalty AMM: Remove Token Liquidity transaction sent!");
                        break;
                    }

                    case '27': {
                        console.log("\n--- Royalty AMM: Withdraw LP Fees ---");
                        const collection = await prompt("NFT collection address for the pool: ");
                        const currencyInput = await prompt("Currency address for the pool (0/native for native): ");
                        const currency = parseCurrencyAddress(currencyInput || 'native');

                        await handleTransaction(
                            deployer,
                            royaltyAMM.withdrawFees,
                            [collection, currency],
                            {},
                            'WITHDRAW_LP_FEES'
                        );
                        console.log("Royalty AMM: Withdraw LP Fees transaction sent!");
                        break;
                    }

                    case '28': {
                        console.log("\n--- Royalty AMM: Swap NFT to Token ---");
                        const collection = await prompt("NFT collection address: ");
                        const tokenId = toBigNumber(await prompt("Token ID to sell (swap from NFT to Token): "), "token ID");
                        const currencyInput = await prompt("Currency address for the pool (0/native for native): ");
                        const currency = parseCurrencyAddress(currencyInput || 'native');

                         // Approve the NFT for the Royalty AMM contract
                         console.log("Checking/requesting NFT approval for Royalty AMM...");
                         await checkAndApproveNFT(deployer, collection, tokenId, deployments.RoyaltyAMM);


                        await handleTransaction(
                            deployer,
                            royaltyAMM.swapNFTToToken,
                            [collection, tokenId, currency],
                            {},
                            'SWAP_NFT_TO_TOKEN'
                        );
                        console.log("Royalty AMM: Swap NFT to Token transaction sent!");
                        break;
                    }

                    case '29': {
                        console.log("\n--- Royalty AMM: Swap Token to NFT ---");
                        const collection = await prompt("NFT collection address: ");
                        const currencyInput = await prompt("Currency address for the pool (0/native for native): ");
                        const currency = parseCurrencyAddress(currencyInput || 'native');
                        const tokenIdToReceive = toBigNumber(await prompt("Token ID to buy (swap from Token to NFT): "), "token ID");

                         // The amount of tokens to send is calculated by the contract.
                         // We need to figure out the *minimum* amount to approve/send *before* calling the contract.
                         // The contract's swapTokenToNFT requires T/(N-1) net amount.
                         // It might be better to let the user specify max tokens to spend, or estimate the amount.
                         // For simplicity here, let's calculate the *exact* expected gross amount based on current reserves
                         // and request approval/send that amount + a small buffer, or use MaxUint256 approval.
                         // Getting decimals for accurate calculation
                         let amountInGross;
                         let txOptions = {};
                         let currencySymbol = currency === ethers.constants.AddressZero ? "ETH" : currency;
                         let currencyDecimals = 18; // Default for ETH

                         try {
                              const pool = await royaltyAMM.collectionPools(collection, currency);
                               if (pool.nftReserve.lte(1)) { // Need at least 2 NFTs to use T/(N-1) formula
                                    console.log(`Royalty AMM: Cannot swap. NFT reserve is ${pool.nftReserve.toString()}. Need at least 2 NFTs in the pool.`);
                                    break;
                               }
                              const tokenReserveBefore = pool.tokenReserve;
                              const nftReserveBefore = pool.nftReserve;
                               const SWAP_FEE_BPS = await royaltyAMM.SWAP_FEE_BPS(); // Fetch current fee from contract

                              // Recalculate the gross amount needed based on the contract's logic
                              // uint256 amountIn_net = Math.mulDiv(tokenReserveBefore, 1, nftReserveBefore - 1);
                              // uint256 amountIn_gross = Math.mulDiv(amountIn_net, 10000, 10000 - SWAP_FEE_BPS);
                               const amountInNet = tokenReserveBefore.mul(ethers.BigNumber.from(1)).div(nftReserveBefore.sub(ethers.BigNumber.from(1)));
                                amountInGross = amountInNet.mul(ethers.BigNumber.from(10000)).div(ethers.BigNumber.from(10000).sub(SWAP_FEE_BPS));


                             if (currency !== ethers.constants.AddressZero) {
                                  const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                                  currencyDecimals = await erc20.decimals();
                                   currencySymbol = await erc20.symbol();
                             }

                              console.log(`Royalty AMM: Calculated gross amount required: ${ethers.utils.formatUnits(amountInGross, currencyDecimals)} ${currencySymbol}`);


                             if (currency === ethers.constants.AddressZero) {
                                  txOptions.value = amountInGross.add(amountInGross.div(20)); // Add 5% buffer for native
                                   console.log(`Royalty AMM: Sending ~${ethers.utils.formatEther(txOptions.value)} ETH (includes buffer) with the transaction.`);
                             } else {
                                  // For ERC20, check/approve ERC20 transfer
                                  console.log(`Royalty AMM: Swapping with ERC20 token ${currency}. Checking/requesting approval for ${ethers.utils.formatUnits(amountInGross, currencyDecimals)}...`);
                                   // Approving slightly more or MaxUint256 is safer than approving the exact calculated amount due to potential minor fluctuations
                                  await checkAndApproveERC20(deployer, currency, deployments.RoyaltyAMM, amountInGross.add(amountInGross.div(20))); // Approve amount + 5% buffer
                             }

                         } catch (e) {
                             console.error("Royalty AMM: Error calculating required token amount or checking pool state:", e.message);
                             throw new Error("Royalty AMM: Failed to determine required token amount.");
                         }


                        await handleTransaction(
                            deployer,
                            royaltyAMM.swapTokenToNFT,
                            [collection, currency, tokenIdToReceive],
                            txOptions, // Pass value if native
                            'SWAP_TOKEN_TO_NFT'
                        );
                        console.log("Royalty AMM: Swap Token to NFT transaction sent!");
                        break;
                    }

                    case '30': {
                         console.log("\n--- Royalty AMM: Set Royalty (Public) ---");
                         const tokenAddress = await prompt("NFT contract address: ");
                         const tokenId = toBigNumber(await prompt("Token ID (integer): "), "token ID");
                         const recipientInput = await prompt("Royalty recipient address: ");
                         const recipient = parseCurrencyAddress(recipientInput);
                          if (recipient === ethers.constants.AddressZero) throw new Error("Royalty recipient cannot be zero address.");

                         const basisPointsInput = await prompt("Royalty percentage (0-10000 basis points): ");
                          const basisPoints = parseInt(basisPointsInput);
                          if (isNaN(basisPoints) || basisPoints < 0 || basisPoints > 10000) {
                               throw new Error("Invalid basis points. Must be an integer between 0 and 10000.");
                          }

                         // Note: This is a public function in the provided Royalty contract, anyone can call it.
                         // If it were intended to be owner-only, a check would be needed here.
                         await handleTransaction(
                              deployer,
                              royaltyAMM.setRoyalty,
                              [tokenAddress, tokenId, recipient, basisPoints],
                              {},
                              'SET_ROYALTY_PUBLIC'
                         );
                         console.log("Royalty AMM: Set Royalty (Public) transaction sent!");
                         break;
                    }

                    case '31': {
                         console.log("\n--- Royalty AMM: Admin Set Royalty (Admin) ---");
                          // Check if deployer has ADMIN_ROLE on Royalty AMM
                         const isAdmin = await royaltyAMM.hasRole(royaltyAMM.ADMIN_ROLE(), deployer.address);
                         if (!isAdmin) {
                             console.log("Royalty AMM: You do not have the ADMIN_ROLE to perform this action.");
                             break;
                         }

                         const tokenAddress = await prompt("NFT contract address: ");
                         const tokenId = toBigNumber(await prompt("Token ID (integer): "), "token ID");
                         const recipientInput = await prompt("Royalty recipient address: ");
                         const recipient = parseCurrencyAddress(recipientInput);
                         if (recipient === ethers.constants.AddressZero) throw new Error("Royalty recipient cannot be zero address.");
                         const basisPointsInput = await prompt("Royalty percentage (0-10000 basis points): ");
                         const basisPoints = parseInt(basisPointsInput);
                         if (isNaN(basisPoints) || basisPoints < 0 || basisPoints > 10000) {
                              throw new Error("Invalid basis points. Must be an integer between 0 and 10000.");
                         }

                         await handleTransaction(
                              deployer,
                              royaltyAMM.adminSetRoyalty,
                              [tokenAddress, tokenId, recipient, basisPoints],
                              {},
                              'ADMIN_SET_ROYALTY'
                         );
                         console.log("Royalty AMM: Admin Set Royalty transaction sent!");
                         break;
                    }

                    case '32': {
                         console.log("\n--- Royalty AMM: Withdraw Royalties ---");
                         const currencyInput = await prompt("Currency address for royalties to withdraw (0/native for native): ");
                         const currency = parseCurrencyAddress(currencyInput || 'native');

                         await handleTransaction(
                             deployer,
                             royaltyAMM.withdrawRoyalty,
                             [currency],
                             {},
                             'WITHDRAW_ROYALTY'
                         );
                         console.log("Royalty AMM: Withdraw Royalties transaction sent!");
                         break;
                    }


                     // --- Royalty AMM View Functions ---
                     case '33': {
                          console.log("\n--- Royalty AMM: Get Pool Details ---");
                          const collection = await prompt("NFT collection address for the pool: ");
                          const currencyInput = await prompt("Currency address for the pool (0/native for native): ");
                          const currency = parseCurrencyAddress(currencyInput || 'native');

                          try {
                               // Call the public mapping directly to get the struct
                               const pool = await royaltyAMM.collectionPools(collection, currency);

                                if (pool.currency === ethers.constants.AddressZero && pool.nftReserve.eq(0) && pool.tokenReserve.eq(0)) { // Simple check if mapping entry is zeroed out/empty
                                     console.log(`Royalty AMM: Pool for collection ${collection} and currency ${currency} not found.`);
                                     break;
                                }

                                console.log("Royalty AMM Pool Details:");
                                console.log(`  Collection: ${collection}`);
                                console.log(`  Currency: ${currency === ethers.constants.AddressZero ? "ETH (Native)" : currency}`);
                                console.log(`  Token Reserve: ${pool.tokenReserve.toString()}`); // Raw BigNumber, format below
                                console.log(`  NFT Reserve Count: ${pool.nftReserve.toString()}`);
                                console.log(`  Total Liquidity Shares: ${pool.totalLiquidityShares.toString()}`);
                                console.log(`  Accumulated Fees: ${pool.accumulatedFees.toString()}`); // Raw BigNumber, format below

                                // Attempt to format token amounts based on currency decimals
                               let currencySymbol = currency === ethers.constants.AddressZero ? "ETH" : currency;
                                let currencyDecimals = 18; // Default for ETH
                                try {
                                     if (currency !== ethers.constants.AddressZero) {
                                          const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                                          currencyDecimals = await erc20.decimals();
                                           currencySymbol = await erc20.symbol();
                                     }
                                     console.log(`  Token Reserve (Formatted): ${ethers.utils.formatUnits(pool.tokenReserve, currencyDecimals)} ${currencySymbol}`);
                                     console.log(`  Accumulated Fees (Formatted): ${ethers.utils.formatUnits(pool.accumulatedFees, currencyDecimals)} ${currencySymbol}`);

                                } catch (e) {
                                    console.warn("Royalty AMM: Could not format token amounts:", e.message);
                                }

                                // Getting price info from the dedicated view function
                                try {
                                     const prices = await royaltyAMM.getPoolPrices(collection, currency);
                                     console.log(`  Price to Buy 1 NFT (Pre-fee): ${ethers.utils.formatUnits(prices[0], currencyDecimals)} ${currencySymbol}`);
                                     console.log(`  Price to Sell 1 NFT (Pre-fee): ${ethers.utils.formatUnits(prices[1], currencyDecimals)} ${currencySymbol}`);
                                } catch (e) {
                                    console.warn("Royalty AMM: Could not get pool prices:", e.message);
                                }


                                // Getting NFT token IDs in the pool - requires calling poolNFTTokenIdsList array
                                console.log("  NFT Token IDs in Pool:");
                                // The list is dynamic, need to fetch size and then each element
                                try {
                                     const listLength = pool.poolNFTTokenIdsList.length; // Length is public
                                      if (listLength > 0) {
                                           for (let i = 0; i < listLength; i++) {
                                                const tokenId = await royaltyAMM.collectionPools(collection, currency).poolNFTTokenIdsList(i);
                                                console.log(`    - ${tokenId.toString()}`);
                                           }
                                      } else {
                                           console.log("    (None)");
                                      }
                                } catch (e) {
                                     console.warn("Royalty AMM: Could not fetch NFT Token IDs from pool list:", e.message);
                                }


                          } catch (error) {
                                console.error("Royalty AMM: Error fetching pool details:", error.message);
                          }
                          break;
                     }


                     case '34': {
                          console.log("\n--- Royalty AMM: Get Royalty Info (IRoyaltyEngine format) ---");
                          const tokenAddress = await prompt("NFT contract address: ");
                          const tokenId = toBigNumber(await prompt("Token ID (integer): "), "token ID");
                          const valueString = await prompt("Sale value (in ETH/native unit, for calculation context): ");
                           const value = ethers.utils.parseEther(valueString); // Assume value is provided in ETH units

                          try {
                                // Using the getRoyalty function which matches IRoyaltyEngine interface
                                const [recipients, amounts] = await royaltyAMM.getRoyalty(tokenAddress, tokenId, value);

                                console.log("Royalty AMM Royalty Info (IRoyaltyEngine format):");
                                if (recipients.length === 1 && recipients[0] !== ethers.constants.AddressZero && amounts.length === 1 && amounts[0].gt(0)) {
                                     console.log(`  Recipient: ${recipients[0]}`);
                                     console.log(`  Amount: ${ethers.utils.formatEther(amounts[0])} ETH`); // Assuming royalty is calculated in the same unit as value
                                } else {
                                    console.log("  No specific royalty found or recipient is zero.");
                                }

                          } catch (error) {
                                console.error("Royalty AMM: Error fetching royalty info:", error.message);
                          }
                          break;
                     }

                    case '35': {
                         console.log("\n--- Royalty AMM: Get Royalty Info (Internal format) ---");
                         const tokenAddress = await prompt("NFT contract address: ");
                         const tokenId = toBigNumber(await prompt("Token ID (integer): "), "token ID");
                          const valueString = await prompt("Sale value (in ETH/native unit, for calculation context): ");
                          const value = ethers.utils.parseEther(valueString); // Assume value is provided in ETH units


                         try {
                                // Using the internal royaltyInfo view function
                                const [receiver, royaltyAmount] = await royaltyAMM.royaltyInfo(tokenAddress, tokenId, value);

                                console.log("Royalty AMM Royalty Info (Internal format):");
                                if (receiver !== ethers.constants.AddressZero && royaltyAmount.gt(0)) {
                                     console.log(`  Recipient: ${receiver}`);
                                     console.log(`  Amount: ${ethers.utils.formatEther(royaltyAmount)} ETH`); // Assuming royalty is calculated in the same unit as value
                                     // Fetch basis points from _royalties mapping (less direct) or rely on admin/set events
                                     // const royaltyStruct = await royaltyAMM._royalties(tokenAddress, tokenId); // _royalties is private, cannot access directly via ethers contract instance

                                } else {
                                    console.log("  No specific royalty found or recipient is zero.");
                                }

                         } catch (error) {
                               console.error("Royalty AMM: Error fetching royalty info:", error.message);
                         }
                         break;
                    }

                    case '36': {
                         console.log("\n--- Royalty AMM: Get Swap Fee Bps ---");
                         const feeBps = await royaltyAMM.SWAP_FEE_BPS();
                         console.log(`Royalty AMM Swap Fee: ${feeBps.toString()} basis points (${feeBps.toNumber() / 100}%)`);
                         break;
                     }

                     case '37': {
                         console.log("\n--- Royalty AMM: Get Total Pool Identifiers Count ---");
                         // allPoolIdentifiers is a public array, can get length
                         const count = await royaltyAMM.allPoolIdentifiers.length;
                         console.log(`Royalty AMM Total Pool Identifiers: ${count.toString()}`);
                         // Optional: list them
                         const listPools = await prompt("List all pool identifiers? (y/n): ");
                         if (listPools.toLowerCase() === 'y') {
                              if (count.eq(0)) {
                                   console.log("  No pools created yet.");
                              } else {
                                  console.log("  Pool Identifiers:");
                                  for (let i = 0; i < count.toNumber(); i++) {
                                       const poolId = await royaltyAMM.allPoolIdentifiers(i);
                                       console.log(`    - Index ${i}: Collection ${poolId.collection}, Currency ${poolId.currency === ethers.constants.AddressZero ? "ETH (Native)" : poolId.currency}`);
                                  }
                              }
                         }
                         break;
                     }

                     case '38': {
                         console.log("\n--- Royalty AMM: Get Collection Stats ---");
                         const collection = await prompt("NFT collection address: ");
                         try {
                              const stats = await royaltyAMM.collectionStats(collection);
                              console.log(`Royalty AMM Stats for Collection ${collection}:`);
                              console.log(`  Total Trading Volume: ${stats.totalTradingVolume.toString()}`); // Raw BigNumber
                              console.log(`  Total Fees Collected: ${stats.totalFeesCollected.toString()}`); // Raw BigNumber

                               // Note: Formatting volume/fees requires knowing the currency used in swaps, which isn't stored per stat entry.
                               // Displaying raw values is safer unless we track stats per currency.
                               console.log("  (Note: Trading volume and fees are raw values; currency context needed for formatting.)");

                         } catch (e) {
                              console.error("Royalty AMM: Error fetching collection stats:", e.message);
                         }
                         break;
                     }

                     case '39': {
                         console.log("\n--- Royalty AMM: Get Pending Royalties ---");
                         const recipientInput = await prompt("Recipient address (leave empty for your address): ");
                         const recipient = parseCurrencyAddress(recipientInput || deployer.address);
                         const currencyInput = await prompt("Currency address to check (0/native for native): ");
                         const currency = parseCurrencyAddress(currencyInput || 'native');

                         try {
                             const pending = await royaltyAMM.pendingRoyalties(recipient, currency);
                             let formattedAmount;
                             let currencySymbol = currency === ethers.constants.AddressZero ? "ETH" : currency;

                             if (currency === ethers.constants.AddressZero) {
                                 formattedAmount = ethers.utils.formatEther(pending);
                             } else {
                                 const erc20 = new ethers.Contract(currency, ERC20_ABI_APPROVAL, deployer);
                                 const decimals = await erc20.decimals();
                                 currencySymbol = await erc20.symbol();
                                 formattedAmount = ethers.utils.formatUnits(pending, decimals);
                             }

                             console.log(`Royalty AMM: Pending Royalties for ${recipient} in ${currencySymbol} (${currency}): ${formattedAmount} ${currencySymbol}`);

                         } catch (e) {
                              console.error("Royalty AMM: Error fetching pending royalties:", e.message);
                         }
                         break;
                     }

                case '0': {
                    console.log("Exiting.");
                    rl.close();
                    process.exit(0);
                }

                default: {
                    console.log("Invalid option.");
                    break;
                }
            }
        } catch (error) {
            console.error("Operation failed:", error.message);
        }
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });