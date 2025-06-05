const { ethers } = require("ethers");
const hre = require("hardhat");
const readline = require("readline");
const fs = require("fs");
const path = require("path");

const DEPLOYMENT_PATH = path.join(__dirname, "amm_deployment.json");
const TOKENS_PATH = path.join(__dirname, "../tokens.json");
const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

async function prompt(question) {
    return new Promise(resolve => {
        rl.question(question, answer => resolve(answer.trim()));
    });
}

const GAS_LIMIT_BUFFER_PERCENT = 20;

function getDefaultDeadline() {
    return (Math.floor(Date.now() / 1000) + 60 * 20).toString();
}

async function handleTransaction(user, contractMethod, args, options = {}, gasLimitType = 'DEFAULT') {
    const provider = user.provider;

    try {
        console.log(`\nEstimating gas for transaction...`);
        let estimatedGas;
        try {
            estimatedGas = await contractMethod.estimateGas(...args, { ...options, from: user.address });
            const bufferedGasLimit = estimatedGas * BigInt(100 + GAS_LIMIT_BUFFER_PERCENT) / BigInt(100);
            console.log(`Estimated Gas Limit: ${estimatedGas.toString()}`);
            console.log(`Buffered Gas Limit (${GAS_LIMIT_BUFFER_PERCENT}% buffer): ${bufferedGasLimit.toString()}`);
            options.gasLimit = bufferedGasLimit;
        } catch (estimationError) {
            console.warn(`Gas estimation failed: ${estimationError.message}`);
            console.warn(`Proceeding without strict gas estimate. You may need to set gas manually if it fails.`);
        }

        const feeData = await provider.getFeeData();
        if (feeData.maxFeePerGas && feeData.maxPriorityFeePerGas) {
            console.log(`Using EIP-1559 gas pricing.`);
            options.maxFeePerGas = feeData.maxFeePerGas;
            options.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas;
            delete options.gasPrice;
            console.log(`Max Fee Per Gas: ${ethers.formatUnits(feeData.maxFeePerGas, 'gwei')} Gwei`);
            console.log(`Max Priority Fee Per Gas: ${ethers.formatUnits(feeData.maxPriorityFeePerGas, 'gwei')} Gwei`);
        } else if (feeData.gasPrice) {
            console.log(`Using legacy gas pricing.`);
            options.gasPrice = feeData.gasPrice;
            delete options.maxFeePerGas;
            delete options.maxPriorityFeePerGas;
            console.log(`Gas Price: ${ethers.formatUnits(feeData.gasPrice, 'gwei')} Gwei`);
        } else {
            console.warn("Could not retrieve gas price data. Using default gas settings.");
        }

        let estimatedCost = BigInt(0);
        if (options.gasLimit && (options.maxFeePerGas || options.gasPrice)) {
            const gasPriceToUse = options.maxFeePerGas || options.gasPrice;
            estimatedCost = options.gasLimit * gasPriceToUse;
            console.log(`Estimated Max Transaction Cost: ${ethers.formatEther(estimatedCost)} ETH`);
        } else {
            console.log(`Could not estimate transaction cost accurately.`);
        }

        const confirm = await prompt("Confirm transaction? (y/n): ");
        if (confirm.toLowerCase() !== 'y') {
            throw new Error("Transaction cancelled by user");
        }

        console.log("Sending transaction...");
        const tx = await contractMethod(...args, options);
        console.log(`Transaction sent. Hash: ${tx.hash}`);
        console.log("Waiting for confirmation...");

        const receipt = await tx.wait();
        console.log(`Transaction successful. Block: ${receipt.blockNumber}`);
        if (receipt.gasUsed && receipt.effectiveGasPrice) {
            const actualCost = receipt.gasUsed * receipt.effectiveGasPrice;
            console.log(`Actual Gas Used: ${receipt.gasUsed.toString()}`);
            console.log(`Actual Gas Price Used: ${ethers.formatUnits(receipt.effectiveGasPrice, 'gwei')} Gwei`);
            console.log(`Actual Transaction Cost: ${ethers.formatEther(actualCost)} ETH`);
        }

        return tx;
    } catch (error) {
        console.error("Transaction failed:");
        if (error.reason) {
            console.error("Revert Reason:", error.reason);
            console.error("Transaction Hash (if available):", error.transactionHash || "N/A");
        } else if (error.data && typeof error.data === 'string' && error.data.startsWith('0x')) {
            try {
                const decodedError = ethers.AbiCoder.defaultAbiCoder().decode(['string'], ethers.getBytes(error.data.slice(10)));
                console.error("Decoded Revert Data:", decodedError[0]);
            } catch (decodeError) {
                console.error("Raw Revert Data:", error.data);
            }
        } else {
            console.error("Error Message:", error.message);
        }
        return null;
    }
}

const toBigNumber = (input, fieldName) => {
    try {
        if (typeof input === 'string' && input.match(/^\d+(\.\d+)?$/)) {
            return ethers.parseUnits(input, 18);
        }
        if (typeof input === 'number' && Number.isInteger(input) && input >= 0) {
            return BigInt(input);
        }
        throw new Error(`Invalid input type or value for ${fieldName}: '${input}'`);
    } catch (e) {
        throw new Error(`Invalid ${fieldName} - must be a non-negative number or string: ${e.message}`);
    }
};

async function getArg(paramName, type, description = "", currentUserAddress = null, tokenDecimals = {}) {
    let value;
    let isValid = false;
    let promptMessage = `Enter ${paramName} (${type})${description ? ` ${description}` : ''}`;

    if (paramName.toLowerCase() === 'to' && currentUserAddress) {
        const defaultToUser = await prompt(`${promptMessage} (Press Enter to default to your address: ${currentUserAddress}): `);
        if (defaultToUser === '') {
            console.log(`Defaulting 'to' address to current user: ${currentUserAddress}`);
            return currentUserAddress;
        }
        value = defaultToUser;
    }

    while (!isValid) {
        if (!value) value = await prompt(`${promptMessage}: `);

        try {
            switch (type) {
                case "address":
                    let resolvedAddress = null;
                    if (tokens[value]) {
                        resolvedAddress = tokens[value].address;
                    } else if (value.toUpperCase() === "WCORE" && deployments.WCOREAddress_for_router) {
                        resolvedAddress = deployments.WCOREAddress_for_router;
                    } else if (value.toUpperCase() === "FACTORY" && deployments.factoryAddress) {
                        resolvedAddress = deployments.factoryAddress;
                    } else if (value.toUpperCase() === "ROUTER" && deployments.routerAddress) {
                        resolvedAddress = deployments.routerAddress;
                    }
                    if (resolvedAddress) {
                        ethers.getAddress(resolvedAddress);
                        value = resolvedAddress;
                    } else {
                        ethers.getAddress(value);
                    }
                    isValid = true;
                    break;
                case "address[]":
                    const parts = value.split(',').map(a => a.trim());
                    if (parts.length === 0 && value === '') throw new Error("Empty address list");
                    const resolvedParts = [];
                    for (const part of parts) {
                        if (part === '') throw new Error("Empty address in list");
                        let tempResolved = null;
                        if (tokens[part]) {
                            tempResolved = tokens[part].address;
                        } else if (part.toUpperCase() === "WCORE" && deployments.WCOREAddress_for_router) {
                            tempResolved = deployments.WCOREAddress_for_router;
                        }
                        if (tempResolved) {
                            ethers.getAddress(tempResolved);
                            resolvedParts.push(tempResolved);
                        } else {
                            ethers.getAddress(part);
                            resolvedParts.push(part);
                        }
                    }
                    value = resolvedParts;
                    isValid = true;
                    break;
                case "uint":
                case "uint256":
                    const decimals = tokenDecimals[paramName] || 18;
                    value = ethers.parseUnits(value.toString(), decimals);
                    isValid = true;
                    break;
                case "uint[]":
                case "uint256[]":
                    const uints = value.split(',').map(u => u.trim());
                    if (uints.length === 0 && value === '') throw new Error("Empty uint list");
                    value = uints.map((u, i) => ethers.parseUnits(u, tokenDecimals[`${paramName}[${i}]`] || 18));
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
                case "bytes32":
                    if (ethers.isHexString(value)) {
                        value = ethers.getBytes(value);
                        isValid = true;
                    } else {
                        throw new Error("Must be a hex string (e.g., 0x...)");
                    }
                    break;
                case "ether":
                    value = ethers.parseEther(value);
                    isValid = true;
                    break;
                default:
                    console.warn(`Unknown type: ${type}. Allowing raw input for ${paramName}.`);
                    isValid = true;
                    break;
            }
        } catch (e) {
            console.error(`Invalid input for ${paramName} ('${value}'): ${e.message}`);
            isValid = false;
            value = null;
        }
    }
    return value;
}

const IERC20_ABI = [
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function balanceOf(address owner) view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)"
];

const IWCORE_ABI = [
    ...IERC20_ABI,
    "function deposit() external payable",
    "function withdraw(uint wad) external"
];

const IRareBayV2Factory_ABI_Minimal = [
    "function getPair(address tokenA, address tokenB) external view returns (address pair)",
    "function allPairs(uint256 index) external view returns (address pair)",
    "function allPairsLength() external view returns (uint256 length)",
    "function createPair(address tokenA, address tokenB) external returns (address pair)",
    "function getPairOracle(address pair) external view returns (address oracle)"
];

const IRareBayV2Pair_ABI_Minimal = [
    "function token0() external view returns (address)",
    "function token1() external view returns (address)",
    "function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)"
];

let tokens = {};
let factoryContract, routerContract, pairContract, oracleContract;
let deployer, user;
const deployments = {
    factoryAddress: null,
    routerAddress: null,
    WCOREAddress_for_router: null,
    USDTAddress: null,
    USDCAddress: null,
    WBTCAddress: null,
    pairs: {},
    oracles: {}
};

async function loadDeploymentAddresses() {
    if (fs.existsSync(DEPLOYMENT_PATH)) {
        const data = fs.readFileSync(DEPLOYMENT_PATH, 'utf8');
        Object.assign(deployments, JSON.parse(data));
        console.log("Loaded deployment addresses from:", DEPLOYMENT_PATH);
    }
}

async function loadTokens() {
    if (fs.existsSync(TOKENS_PATH)) {
        tokens = JSON.parse(fs.readFileSync(TOKENS_PATH, 'utf8'));
        console.log("Loaded tokens from:", TOKENS_PATH);
    } else {
        console.warn("Tokens file not found at:", TOKENS_PATH);
    }
}

async function saveDeploymentAddresses() {
    fs.writeFileSync(DEPLOYMENT_PATH, JSON.stringify(deployments, null, 2), 'utf8');
    console.log("Saved deployment addresses to:", DEPLOYMENT_PATH);
}

async function checkAndApproveERC20(user, tokenAddress, spenderAddress, amount, tokenSymbolHint = null) {
    if (!tokenAddress || tokenAddress === ethers.ZeroAddress) {
        console.log("Skipping approval for native currency or zero address.");
        return;
    }
    if (!amount || amount === BigInt(0)) {
        console.log(`Amount for approval of ${tokenSymbolHint || tokenAddress} is zero, skipping approval.`);
        return;
    }

    const approvalAmount = ethers.MaxUint256;
    try {
        const erc20 = new ethers.Contract(tokenAddress, IERC20_ABI, user);
        const allowance = await erc20.allowance(user.address, spenderAddress);
        let actualTokenSymbol = tokenSymbolHint;
        let actualDecimals = tokens[tokenSymbolHint]?.decimals || 18;

        if (!actualTokenSymbol || !tokens[tokenSymbolHint] || tokens[tokenSymbolHint].address.toLowerCase() !== tokenAddress.toLowerCase()) {
            try {
                actualTokenSymbol = await erc20.symbol();
                actualDecimals = await erc20.decimals();
            } catch (e) {
                console.warn(`Could not fetch symbol/decimals for ${tokenAddress}, using defaults. ${e.message}`);
                actualTokenSymbol = actualTokenSymbol || tokenAddress;
            }
        }

        if (allowance < amount) {
            console.log(`\nInsufficient allowance for ${actualTokenSymbol} (${tokenAddress}).`);
            console.log(`Current allowance: ${ethers.formatUnits(allowance, actualDecimals)}. Required: ${ethers.formatUnits(amount, actualDecimals)}.`);
            const confirm = await prompt(`Approve ${spenderAddress} to spend MaxUint256 of ${actualTokenSymbol}? (y/n): `);
            if (confirm.toLowerCase() !== 'y') {
                throw new Error(`Approval cancelled for ${actualTokenSymbol}`);
            }
            await handleTransaction(
                user,
                erc20.approve,
                [spenderAddress, approvalAmount],
                {},
                `APPROVE_${actualTokenSymbol}`
            );
            console.log(`${actualTokenSymbol} approval completed.`);
        } else {
            console.log(`Sufficient allowance for ${actualTokenSymbol} (${ethers.formatUnits(allowance, actualDecimals)}).`);
        }
    } catch (error) {
        console.error(`Failed to approve ${tokenSymbolHint || tokenAddress}: ${error.message}`);
        throw error;
    }
}

async function deployContracts() {
    [deployer] = await hre.ethers.getSigners();
    user = deployer;
    console.log(`Deployer/User address: ${user.address}`);

    await loadTokens();
    await loadDeploymentAddresses();

    // Deploy/Load Factory
    if (deployments.factoryAddress && ethers.isAddress(deployments.factoryAddress)) {
        console.log(`\nReusing Factory at: ${deployments.factoryAddress}`);
        factoryContract = await hre.ethers.getContractAt("RareBayV2Factory", deployments.factoryAddress, user);
        console.log("Discovering existing pairs and oracles...");
        const numPairs = await factoryContract.allPairsLength();
        deployments.pairs = {};
        deployments.oracles = {};
        for (let i = 0; i < Number(numPairs); i++) {
            const pairAddress = await factoryContract.allPairs(i);
            const tempPairContract = await hre.ethers.getContractAt("RareBayV2Pair", pairAddress, user);
            const token0 = await tempPairContract.token0();
            const token1 = await tempPairContract.token1();
            let oracleAddress = "N/A";
            try {
                if (factoryContract.getPairOracle) {
                    oracleAddress = await factoryContract.getPairOracle(pairAddress);
                    if (oracleAddress === ethers.ZeroAddress) oracleAddress = "N/A";
                }
            } catch (e) {
                console.warn(`Could not fetch oracle for pair ${pairAddress}: ${e.message}`);
            }
            deployments.pairs[pairAddress] = { token0, token1, oracle: oracleAddress };
            if (oracleAddress !== "N/A") {
                deployments.oracles[oracleAddress] = { pair: pairAddress, token0, token1 };
            }
            console.log(`Found Pair: ${pairAddress} (Tokens: ${token0}, ${token1}, Oracle: ${oracleAddress})`);
        }
        await saveDeploymentAddresses();
    } else {
        console.log("\nDeploying RareBayV2Factory...");
        const Factory = await hre.ethers.getContractFactory("RareBayV2Factory", user);
        factoryContract = await Factory.deploy(user.address);
        await factoryContract.waitForDeployment();
        deployments.factoryAddress = await factoryContract.getAddress();
        console.log(`RareBayV2Factory deployed to: ${deployments.factoryAddress}`);
        await saveDeploymentAddresses();
    }

    // Deploy/Load Router
    if (deployments.routerAddress && ethers.isAddress(deployments.routerAddress)) {
        console.log(`\nReusing Router at: ${deployments.routerAddress}`);
        routerContract = await hre.ethers.getContractAt("RareBayV2Router", deployments.routerAddress, user);
        const routerWCore = await routerContract.WCORE();
        if (routerWCore.toLowerCase() !== deployments.WCOREAddress_for_router?.toLowerCase()) {
            console.warn(`WCORE mismatch: Router (${routerWCore}) vs stored (${deployments.WCOREAddress_for_router || "N/A"}).`);
        }
    } else {
        if (!deployments.factoryAddress) {
            console.error("Cannot deploy Router: Factory address missing.");
            return;
        }
        if (!deployments.WCOREAddress_for_router) {
            deployments.WCOREAddress_for_router = await getArg("WCORE address", "address", "(Wrapped Native Currency contract, e.g., WCORE)");
            await saveDeploymentAddresses();
        }
        if (!deployments.USDTAddress) {
            deployments.USDTAddress = await getArg("USDT address", "address", "(USDT contract address)");
            await saveDeploymentAddresses();
        }
        if (!deployments.USDCAddress) {
            deployments.USDCAddress = await getArg("USDC address", "address", "(USDC contract address)");
            await saveDeploymentAddresses();
        }
        if (!deployments.WBTCAddress) {
            deployments.WBTCAddress = await getArg("WBTC address", "address", "(WBTC contract address)");
            await saveDeploymentAddresses();
        }

        console.log(`\nDeploying RareBayV2Router...`);
        const Router = await hre.ethers.getContractFactory("RareBayV2Router", user);
        routerContract = await Router.deploy(
            deployments.factoryAddress,
            deployments.WCOREAddress_for_router,
            deployments.USDTAddress,
            deployments.USDCAddress,
            deployments.WBTCAddress
        );
        await routerContract.waitForDeployment();
        deployments.routerAddress = await routerContract.getAddress();
        console.log(`RareBayV2Router deployed to: ${deployments.routerAddress}`);
        await saveDeploymentAddresses();
    }
}

async function updatePairInfoInDeployments(pairTokenA, pairTokenB) {
    if (!factoryContract) {
        console.warn("Cannot update pair info: Factory not available.");
        return;
    }
    try {
        const pairAddress = await factoryContract.getPair(pairTokenA, pairTokenB);
        if (pairAddress && pairAddress !== ethers.ZeroAddress) {
            const pairContractInstance = await hre.ethers.getContractAt("RareBayV2Pair", pairAddress, user);
            const token0 = await pairContractInstance.token0();
            const token1 = await pairContractInstance.token1();
            let oracleAddress = "N/A";
            try {
                if (factoryContract.getPairOracle) {
                    oracleAddress = await factoryContract.getPairOracle(pairAddress);
                    if (oracleAddress === ethers.ZeroAddress) oracleAddress = "N/A";
                }
            } catch (e) {
                console.warn(`Could not fetch oracle for pair ${pairAddress}: ${e.message}`);
            }
            deployments.pairs[pairAddress] = { token0, token1, oracle: oracleAddress };
            if (oracleAddress !== "N/A") {
                deployments.oracles[oracleAddress] = { pair: pairAddress, token0, token1 };
            }
            await saveDeploymentAddresses();
            console.log(`Updated pair info for ${pairAddress} (Tokens: ${token0}, ${token1}, Oracle: ${oracleAddress}).`);
        } else {
            console.log(`Pair not found for ${pairTokenA}-${pairTokenB}. Creating pair...`);
            await handleTransaction(
                user,
                factoryContract.createPair,
                [pairTokenA, pairTokenB],
                {},
                "CREATE_PAIR"
            );
            const newPairAddress = await factoryContract.getPair(pairTokenA, pairTokenB);
            if (newPairAddress && newPairAddress !== ethers.ZeroAddress) {
                const pairContractInstance = await hre.ethers.getContractAt("RareBayV2Pair", newPairAddress, user);
                const token0 = await pairContractInstance.token0();
                const token1 = await pairContractInstance.token1();
                let oracleAddress = "N/A";
                try {
                    if (factoryContract.getPairOracle) {
                        oracleAddress = await factoryContract.getPairOracle(newPairAddress);
                        if (oracleAddress === ethers.ZeroAddress) oracleAddress = "N/A";
                    }
                } catch (e) {
                    console.warn(`Could not fetch oracle for pair ${newPairAddress}: ${e.message}`);
                }
                deployments.pairs[newPairAddress] = { token0, token1, oracle: oracleAddress };
                if (oracleAddress !== "N/A") {
                    deployments.oracles[oracleAddress] = { pair: newPairAddress, token0, token1 };
                }
                await saveDeploymentAddresses();
                console.log(`Created and updated pair: ${newPairAddress} (Tokens: ${token0}, ${token1}, Oracle: ${oracleAddress}).`);
            }
        }
    } catch (error) {
        console.error(`Error updating pair info for ${pairTokenA}-${pairTokenB}: ${error.message}`);
    }
}

async function routerMenu() {
    if (!routerContract) {
        console.log("Router contract not loaded. Deploy or load first.");
        return;
    }

    console.log("\n--- RareBayV2Router Menu ---");
    console.log("Connected to Router at:", routerContract.address);
    console.log("Using WCORE at:", deployments.WCOREAddress_for_router);

    const routerABI = (await hre.ethers.getContractFactory("RareBayV2Router")).interface;
    const callableFunctions = Object.values(routerABI.fragments).filter(
        fn => fn.type === 'function' && !fn.name.startsWith('_')
    );

    let running = true;
    while (running) {
        console.log("\nRouter Functions:");
        callableFunctions.forEach((fn, i) => {
            const params = fn.inputs.map(ip => `${ip.type} ${ip.name}`).join(', ');
            const returnTypes = fn.outputs.length > 0 ? `returns (${fn.outputs.map(op => op.type).join(', ')})` : '';
            console.log(`${i + 1}. ${fn.name}(${params}) ${fn.stateMutability} ${returnTypes}`);
        });
        console.log(`${callableFunctions.length + 1}. Back to Main Menu`);

        const choice = await prompt("Choose a function to call: ");
        const fnIndex = parseInt(choice) - 1;

        if (fnIndex === callableFunctions.length) {
            running = false;
            continue;
        }
        if (fnIndex < 0 || fnIndex >= callableFunctions.length) {
            console.log("Invalid choice.");
            continue;
        }

        const selectedFn = callableFunctions[fnIndex];
        const args = [];
        const txOptions = {};
        let tokenDecimals = {};

        console.log(`\nCalling Router Function: ${selectedFn.name}`);
        for (const input of selectedFn.inputs) {
            let argDescription = "";
            if (input.type.startsWith("uint") && input.name.toLowerCase().includes("amount")) {
                argDescription = `(in token's smallest unit, e.g., ${tokens[input.name]?.decimals || 18} decimals)`;
                tokenDecimals[input.name] = tokens[input.name]?.decimals || 18;
            } else if (input.type === "address[]" && input.name.toLowerCase() === "path") {
                argDescription = "(comma-separated addresses or token symbols like USDT,USDC,WBTC,WCORE)";
            } else if (input.type.startsWith("uint") && input.name.toLowerCase() === "deadline") {
                const defaultDeadline = getDefaultDeadline();
                argDescription = `(default: ${defaultDeadline} - ${new Date(Number(defaultDeadline) * 1000).toLocaleString()})`;
                const deadlineInput = await getArg(input.name, input.type, argDescription, user.address);
                args.push(deadlineInput || defaultDeadline);
                continue;
            }
            args.push(await getArg(input.name, input.type, argDescription, user.address, tokenDecimals));
        }

        if (selectedFn.payable) {
            const value = await getArg("msg.value", "ether", "(Amount of native CORE to send)");
            if (value && value > BigInt(0)) txOptions.value = value;
        }

        let pathForApproval = null, amountInForApproval = null;
        let tokenA_forApproval, amountA_forApproval;
        let tokenB_forApproval, amountB_forApproval;
        let singleToken_forApproval, singleTokenAmount_forApproval;

        selectedFn.inputs.forEach((input, i) => {
            if (input.name.toLowerCase() === "path") pathForApproval = args[i];
            if (input.name.toLowerCase() === "amountin" || input.name.toLowerCase() === "amountinmax") amountInForApproval = args[i];
            if (input.name.toLowerCase() === "tokena") tokenA_forApproval = args[i];
            if (input.name.toLowerCase() === "amountadesired") amountA_forApproval = args[i];
            if (input.name.toLowerCase() === "tokenb") tokenB_forApproval = args[i];
            if (input.name.toLowerCase() === "amountbdesired") amountB_forApproval = args[i];
            if (input.name.toLowerCase() === "token" && selectedFn.name.toLowerCase().includes("core")) singleToken_forApproval = args[i];
            if (input.name.toLowerCase() === "amounttokendesired" && selectedFn.name.toLowerCase().includes("core")) singleTokenAmount_forApproval = args[i];
        });

        try {
            // Approval Logic
            if (selectedFn.name === "addLiquidity") {
                if (tokenA_forApproval && amountA_forApproval) {
                    await checkAndApproveERC20(user, tokenA_forApproval, routerContract.address, amountA_forApproval, Object.keys(tokens).find(k => tokens[k].address.toLowerCase() === tokenA_forApproval.toLowerCase()));
                }
                if (tokenB_forApproval && amountB_forApproval) {
                    await checkAndApproveERC20(user, tokenB_forApproval, routerContract.address, amountB_forApproval, Object.keys(tokens).find(k => tokens[k].address.toLowerCase() === tokenB_forApproval.toLowerCase()));
                }
                await updatePairInfoInDeployments(tokenA_forApproval, tokenB_forApproval);
            } else if (selectedFn.name === "addLiquidityCORE") {
                if (singleToken_forApproval && singleTokenAmount_forApproval) {
                    await checkAndApproveERC20(user, singleToken_forApproval, routerContract.address, singleTokenAmount_forApproval, Object.keys(tokens).find(k => tokens[k].address.toLowerCase() === singleToken_forApproval.toLowerCase()));
                }
                await updatePairInfoInDeployments(singleToken_forApproval, deployments.WCOREAddress_for_router);
            } else if (selectedFn.name.startsWith("swapExactTokensFor") || selectedFn.name.startsWith("swapTokensForExact")) {
                if (pathForApproval && pathForApproval.length > 0 && amountInForApproval) {
                    const inputTokenAddress = pathForApproval[0];
                    if (inputTokenAddress.toLowerCase() !== deployments.WCOREAddress_for_router.toLowerCase()) {
                        const inputTokenSymbol = Object.keys(tokens).find(key => tokens[key].address.toLowerCase() === inputTokenAddress.toLowerCase()) || inputTokenAddress;
                        await checkAndApproveERC20(user, inputTokenAddress, routerContract.address, amountInForApproval, inputTokenSymbol);
                    }
                    for (let i = 0; i < pathForApproval.length - 1; i++) {
                        await updatePairInfoInDeployments(pathForApproval[i], pathForApproval[i + 1]);
                    }
                }
            } else if (selectedFn.name === "removeLiquidity" || selectedFn.name === "removeLiquidityCORE") {
                const liquidityTokenAddress = await factoryContract.getPair(
                    selectedFn.name === "removeLiquidity" ? args[0] : args[0],
                    selectedFn.name === "removeLiquidity" ? args[1] : deployments.WCOREAddress_for_router
                );
                const liquidityAmount = args[selectedFn.name === "removeLiquidity" ? 2 : 1];
                await checkAndApproveERC20(user, liquidityTokenAddress, routerContract.address, liquidityAmount, `LP_${liquidityTokenAddress.substring(0, 6)}`);
            }

            // Call Function
            if (selectedFn.stateMutability === 'view' || selectedFn.stateMutability === 'pure') {
                const result = await routerContract[selectedFn.name](...args);
                console.log("\n--- View Function Result ---");
                if (Array.isArray(result)) {
                    console.log(result.map(r => typeof r === 'bigint' ? r.toString() : JSON.stringify(r)));
                } else if (typeof result === 'bigint') {
                    console.log(result.toString());
                } else {
                    console.dir(result, { depth: null });
                }
                console.log("----------------------------");
            } else {
                await handleTransaction(user, routerContract[selectedFn.name], args, txOptions);
                if (selectedFn.name.startsWith("addLiquidity") || selectedFn.name.startsWith("removeLiquidity")) {
                    const tokenA = selectedFn.name.includes("CORE") ? args[0] : args[0];
                    const tokenB = selectedFn.name.includes("CORE") ? deployments.WCOREAddress_for_router : args[1];
                    if (tokenA && tokenB) await updatePairInfoInDeployments(tokenA, tokenB);
                }
            }
        } catch (error) {
            console.error(`Operation ${selectedFn.name} failed: ${error.message}`);
        }
    }
}

async function mainMenu() {
    await deployContracts();

    let running = true;
    while (running) {
        console.log("\n--- Main Menu ---");
        console.log("1. Interact with Factory");
        console.log("2. Interact with a Pair");
        console.log("3. Interact with an Oracle");
        console.log("4. Interact with Router");
        console.log("5. View All Deployments");
        console.log("6. Refresh Discovered Pairs and Oracles");
        console.log("7. Exit");

        const choice = await prompt("Choose an option: ");

        switch (choice) {
            case '1':
                if (factoryContract) await factoryMenu();
                else console.log("Factory not available.");
                break;
            case '2':
                await pairSelectionMenu();
                break;
            case '3':
                await oracleSelectionMenu();
                break;
            case '4':
                if (routerContract) await routerMenu();
                else console.log("Router not available.");
                break;
            case '5':
                console.log(JSON.stringify(deployments, null, 2));
                break;
            case '6':
                console.log("Re-running discovery of pairs and oracles...");
                await deployContracts();
                console.log("Discovery complete.");
                break;
            case '7':
                running = false;
                break;
            default:
                console.log("Invalid option.");
        }
    }
    rl.close();
}

async function factoryMenu() {
    console.log("\n--- RareBayV2Factory Menu ---");
    console.log("Connected to Factory at:", factoryContract.address);

    const factoryABI = (await hre.ethers.getContractFactory("RareBayV2Factory")).interface;
    const callableFunctions = Object.values(factoryABI.fragments).filter(
        fn => fn.type === 'function' && !fn.name.startsWith('_')
    );

    let running = true;
    while (running) {
        console.log("\nFactory Functions:");
        callableFunctions.forEach((fn, i) => {
            const params = fn.inputs.map(ip => `${ip.type} ${ip.name}`).join(', ');
            const returnTypes = fn.outputs.length > 0 ? `returns (${fn.outputs.map(op => op.type).join(', ')})` : '';
            console.log(`${i + 1}. ${fn.name}(${params}) ${fn.stateMutability} ${returnTypes}`);
        });
        console.log(`${callableFunctions.length + 1}. Back to Main Menu`);

        const choice = await prompt("Choose a function to call: ");
        const fnIndex = parseInt(choice) - 1;

        if (fnIndex === callableFunctions.length) {
            running = false;
            continue;
        }
        if (fnIndex < 0 || fnIndex >= callableFunctions.length) {
            console.log("Invalid choice.");
            continue;
        }

        const selectedFn = callableFunctions[fnIndex];
        const args = [];
        const txOptions = {};

        console.log(`\nCalling Factory Function: ${selectedFn.name}`);
        for (const input of selectedFn.inputs) {
            args.push(await getArg(input.name, input.type, "", user.address));
        }
        if (selectedFn.payable) {
            const value = await getArg("msg.value", "ether", "(Amount of native currency to send)");
            if (value && value > BigInt(0)) txOptions.value = value;
        }

        try {
            if (selectedFn.stateMutability === 'view' || selectedFn.stateMutability === 'pure') {
                const result = await factoryContract[selectedFn.name](...args);
                console.log("\n--- View Function Result ---");
                if (Array.isArray(result)) {
                    console.log(result.map(r => typeof r === 'bigint' ? r.toString() : JSON.stringify(r)));
                } else if (typeof result === 'bigint') {
                    console.log(result.toString());
                } else {
                    console.dir(result, { depth: null });
                }
                console.log("----------------------------");
            } else {
                await handleTransaction(user, factoryContract[selectedFn.name], args, txOptions);
                if (selectedFn.name === 'createPair') {
                    await updatePairInfoInDeployments(args[0], args[1]);
                }
            }
        } catch (error) {
            console.error(`Error calling factory function ${selectedFn.name}: ${error.message}`);
        }
    }
}

async function pairSelectionMenu() {
    const pairAddresses = Object.keys(deployments.pairs);
    if (pairAddresses.length === 0) {
        console.log("\nNo pairs found. Create one via Factory or refresh discovery.");
        return;
    }

    let running = true;
    while (running) {
        console.log("\n--- Select a Pair ---");
        pairAddresses.forEach((addr, i) => {
            const pairInfo = deployments.pairs[addr];
            const token0Symbol = Object.keys(tokens).find(s => tokens[s].address.toLowerCase() === pairInfo.token0.toLowerCase()) || pairInfo.token0.substring(0, 10) + "...";
            const token1Symbol = Object.keys(tokens).find(s => tokens[s].address.toLowerCase() === pairInfo.token1.toLowerCase()) || pairInfo.token1.substring(0, 10) + "...";
            console.log(`${i + 1}. ${addr} (Tokens: ${token0Symbol}, ${token1Symbol}, Oracle: ${pairInfo.oracle})`);
        });
        console.log(`${pairAddresses.length + 1}. Back to Main Menu`);

        const choice = await prompt("Choose a pair: ");
        const pairIndex = parseInt(choice) - 1;

        if (pairIndex === pairAddresses.length) {
            running = false;
            continue;
        }
        if (pairIndex < 0 || pairIndex >= pairAddresses.length) {
            console.log("Invalid choice.");
            continue;
        }

        await pairMenu(pairAddresses[pairIndex]);
    }
}

async function pairMenu(pairAddress) {
    pairContract = await hre.ethers.getContractAt("RareBayV2Pair", pairAddress, user);
    console.log(`\n--- RareBayV2Pair Menu for ${pairAddress} ---`);
    const pairInfo = deployments.pairs[pairAddress];
    const token0Symbol = Object.keys(tokens).find(s => tokens[s].address.toLowerCase() === pairInfo.token0.toLowerCase()) || pairInfo.token0.substring(0, 10) + "...";
    const token1Symbol = Object.keys(tokens).find(s => tokens[s].address.toLowerCase() === pairInfo.token1.toLowerCase()) || pairInfo.token1.substring(0, 10) + "...";
    console.log(`Tokens: ${token0Symbol}, ${token1Symbol}, Oracle: ${pairInfo.oracle}`);

    const pairABI = (await hre.ethers.getContractFactory("RareBayV2Pair")).interface;
    const callableFunctions = Object.values(pairABI.fragments).filter(
        fn => fn.type === 'function' && !fn.name.startsWith('_')
    );

    let running = true;
    while (running) {
        console.log("\nPair Functions:");
        callableFunctions.forEach((fn, i) => {
            const params = fn.inputs.map(ip => `${ip.type} ${ip.name}`).join(', ');
            const returnTypes = fn.outputs.length > 0 ? `returns (${fn.outputs.map(op => op.type).join(', ')})` : '';
            console.log(`${i + 1}. ${fn.name}(${params}) ${fn.stateMutability} ${returnTypes}`);
        });
        console.log(`${callableFunctions.length + 1}. Back to Pair Selection`);

        const choice = await prompt("Choose a function to call: ");
        const fnIndex = parseInt(choice) - 1;

        if (fnIndex === callableFunctions.length) {
            running = false;
            continue;
        }
        if (fnIndex < 0 || fnIndex >= callableFunctions.length) {
            console.log("Invalid choice.");
            continue;
        }

        const selectedFn = callableFunctions[fnIndex];
        const args = [];
        const txOptions = {};

        console.log(`\nCalling Pair Function: ${selectedFn.name}`);
        for (const input of selectedFn.inputs) {
            args.push(await getArg(input.name, input.type, "", user.address));
        }
        if (selectedFn.payable) {
            const value = await getArg("msg.value", "ether", "(Amount of native currency to send)");
            if (value && value > BigInt(0)) txOptions.value = value;
        }

        if (selectedFn.name === 'mint' || selectedFn.name === 'swap') {
            console.warn(`Note: For direct ${selectedFn.name}, ensure tokens are transferred to the pair address first. Use Router for easier operations.`);
        }

        try {
            if (selectedFn.stateMutability === 'view' || selectedFn.stateMutability === 'pure') {
                const result = await pairContract[selectedFn.name](...args);
                console.log("\n--- View Function Result ---");
                if (Array.isArray(result)) {
                    console.log(result.map(r => typeof r === 'bigint' ? r.toString() : JSON.stringify(r)));
                } else if (typeof result === 'bigint') {
                    console.log(result.toString());
                } else {
                    console.dir(result, { depth: null });
                }
                console.log("----------------------------");
            } else {
                await handleTransaction(user, pairContract[selectedFn.name], args, txOptions);
            }
        } catch (error) {
            console.error(`Error calling pair function ${selectedFn.name}: ${error.message}`);
        }
    }
}

async function oracleSelectionMenu() {
    const oracleAddresses = Object.keys(deployments.oracles);
    if (oracleAddresses.length === 0) {
        console.log("\nNo oracles found in deployments. Ensure pairs have associated oracles or refresh discovery.");
        return;
    }

    let running = true;
    while (running) {
        console.log("\n--- Select an Oracle ---");
        oracleAddresses.forEach((addr, i) => {
            const oracleInfo = deployments.oracles[addr];
            const token0Symbol = Object.keys(tokens).find(s => tokens[s].address.toLowerCase() === oracleInfo.token0.toLowerCase()) || oracleInfo.token0.substring(0, 10) + "...";
            const token1Symbol = Object.keys(tokens).find(s => tokens[s].address.toLowerCase() === oracleInfo.token1.toLowerCase()) || oracleInfo.token1.substring(0, 10) + "...";
            console.log(`${i + 1}. ${addr} (Pair: ${oracleInfo.pair}, Tokens: ${token0Symbol}, ${token1Symbol})`);
        });
        console.log(`${oracleAddresses.length + 1}. Back to Main Menu`);

        const choice = await prompt("Choose an oracle: ");
        const oracleIndex = parseInt(choice) - 1;

        if (oracleIndex === oracleAddresses.length) {
            running = false;
            continue;
        }
        if (oracleIndex < 0 || oracleIndex >= oracleAddresses.length) {
            console.log("Invalid choice.");
            continue;
        }

        await oracleMenu(oracleAddresses[oracleIndex]);
    }
}

async function oracleMenu(oracleAddress) {
    oracleContract = await hre.ethers.getContractAt("PriceOracle", oracleAddress, user);
    console.log(`\n--- PriceOracle Menu for ${oracleAddress} ---`);
    const oracleInfo = deployments.oracles[oracleAddress];
    const token0Symbol = Object.keys(tokens).find(s => tokens[s].address.toLowerCase() === oracleInfo.token0.toLowerCase()) || oracleInfo.token0.substring(0, 10) + "...";
    const token1Symbol = Object.keys(tokens).find(s => tokens[s].address.toLowerCase() === oracleInfo.token1.toLowerCase()) || oracleInfo.token1.substring(0, 10) + "...";
    console.log(`Associated Pair: ${oracleInfo.pair}, Tokens: ${token0Symbol}, ${token1Symbol}`);

    const oracleABI = (await hre.ethers.getContractFactory("PriceOracle")).interface;
    const callableFunctions = Object.values(oracleABI.fragments).filter(
        fn => fn.type === 'function' && !fn.name.startsWith('_')
    );

    let running = true;
    while (running) {
        console.log("\nOracle Functions:");
        callableFunctions.forEach((fn, i) => {
            const params = fn.inputs.map(ip => `${ip.type} ${ip.name}`).join(', ');
            const returnTypes = fn.outputs.length > 0 ? `returns (${fn.outputs.map(op => op.type).join(', ')})` : '';
            console.log(`${i + 1}. ${fn.name}(${params}) ${fn.stateMutability} ${returnTypes}`);
        });
        console.log(`${callableFunctions.length + 1}. Back to Oracle Selection`);

        const choice = await prompt("Choose a function to call: ");
        const fnIndex = parseInt(choice) - 1;

        if (fnIndex === callableFunctions.length) {
            running = false;
            continue;
        }
        if (fnIndex < 0 || fnIndex >= callableFunctions.length) {
            console.log("Invalid choice.");
            continue;
        }

        const selectedFn = callableFunctions[fnIndex];
        const args = [];
        const txOptions = {};

        console.log(`\nCalling Oracle Function: ${selectedFn.name}`);
        for (const input of selectedFn.inputs) {
            args.push(await getArg(input.name, input.type, "", user.address));
        }
        if (selectedFn.payable) {
            const value = await getArg("msg.value", "ether", "(Amount of native currency to send)");
            if (value && value > BigInt(0)) txOptions.value = value;
        }

        try {
            if (selectedFn.stateMutability === 'view' || selectedFn.stateMutability === 'pure') {
                const result = await oracleContract[selectedFn.name](...args);
                console.log("\n--- View Function Result ---");
                if (Array.isArray(result)) {
                    console.log(result.map(r => typeof r === 'bigint' ? r.toString() : JSON.stringify(r)));
                } else if (typeof result === 'bigint') {
                    console.log(result.toString());
                } else {
                    console.dir(result, { depth: null });
                }
                console.log("----------------------------");
            } else {
                await handleTransaction(user, oracleContract[selectedFn.name], args, txOptions);
            }
        } catch (error) {
            console.error(`Error calling oracle function ${selectedFn.name}: ${error.message}`);
        }
    }
}

mainMenu()
    .then(() => process.exit(0))
    .catch(error => {
        console.error("\nUnhandled error in script:", error);
        process.exit(1);
    });