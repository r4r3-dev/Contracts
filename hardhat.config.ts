import { HardhatUserConfig, task } from 'hardhat/config'; // 'task' is imported but not used in this config snippet.

import '@nomicfoundation/hardhat-ethers';
import '@nomicfoundation/hardhat-chai-matchers'; // Replaces @nomiclabs/hardhat-waffle for matchers
import '@nomicfoundation/hardhat-verify';       // Replaces @nomiclabs/hardhat-etherscan for verification

import { ethers } from 'ethers'; // Keep this for ethers.parseEther (ethers v6 syntax)
import * as fs from 'fs';
import * as path from 'path';

// Load environment variables from .env file if it exists.
// This should typically be at the very top of your config file.
import 'dotenv/config';

// Define an interface for your account structure for type safety
interface Account {
  address: string;
  privateKey: string;
}

// Function to load accounts from accounts.json
function loadAccounts(): Account[] {
  const accountsPath = path.resolve(__dirname, 'accounts.json');
  if (fs.existsSync(accountsPath)) {
    const data = fs.readFileSync(accountsPath, 'utf8');
    try {
      return JSON.parse(data);
    } catch (e) {
      console.error(`Error parsing accounts.json: ${e}`);
      return [];
    }
  }
  console.warn('accounts.json not found. Ensure it exists in the root directory if you intend to use custom accounts.');
  return [];
}

const accounts = loadAccounts();
const privateKeys = accounts.map(account => account.privateKey);

const config: HardhatUserConfig = {
  // Set the default network. This can be overridden via CLI.
  defaultNetwork: 'testnet',
  networks: {
    hardhat: {
      // Allows deploying large contracts on the local Hardhat network.
      allowUnlimitedContractSize: true,
      // Use the accounts from accounts.json for the Hardhat local network.
      // If accounts.json is empty, it falls back to Hardhat's default accounts with a specified balance.
      accounts: accounts.length > 0 ? accounts.map(acc => ({
        privateKey: acc.privateKey,
        balance: ethers.parseEther("10000").toString() // Increased balance for local testing
      })) : {
        accountsBalance: ethers.parseEther("1000").toString() // Fallback balance for default Hardhat accounts
      },
      chainId: 31337, // Default Hardhat Network chainId
    },
    testnet: {
      url: process.env.TESTNET_URL || 'https://rpc.test2.btcs.network', // Use environment variable, fallback to default URL
      accounts: privateKeys.length > 0 ? privateKeys : [], // Use private keys from accounts.json
      chainId: 1114,
    },
    mainnet: {
      url: process.env.MAINNET_URL || 'https://rpc.coredao.org', // Use environment variable, fallback to default URL
      accounts: privateKeys.length > 0 ? privateKeys : [], // Use private keys from accounts.json
      chainId: 1116,
    },
    eth: {
      url: process.env.ETH_MAINNET_URL || 'https://eth-mainnet.public.blastapi.io', // Added environment variable for consistency, fallback to default URL
      accounts: privateKeys.length > 0 ? privateKeys : [], // Use private keys from accounts.json
      chainId: 1,
    },
  },
  solidity: {
    version: '0.8.28', // Specify the Solidity compiler version
    settings: {
      optimizer: {
        enabled: true, // Enable the Solidity optimizer
        runs: 200, // Number of optimizer runs (commonly 200)
      },
      viaIR: true, // Enable the IR-based code generation (can improve performance/gas)
    },
  },
  // If you are using hardhat-etherscan, you would configure it here:
  etherscan: {
    apiKey: {
      testnet: '37be54ff861145b29e67a10d7ccf19c3',
      mainnet: "api key",
    },
    customChains: [
      {
        network: "testnet",
        chainId: 1114,
        urls: {
          apiURL: "https://api.test2.btcs.network/api",
          browserURL: "https://scan.test2.btcs.network/",
        },
      },
      {
        network: "mainnet",
        chainId: 1116,
        urls: {
          apiURL: "https://openapi.coredao.org/api",
          browserURL: "https://scan.coredao.org/",
        },
      },
    ],
  },
  sourcify: {
    enabled: true
  }
};

export default config;