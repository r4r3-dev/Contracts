# Hardhat Configuration

This document provides an overview of the Hardhat configuration file (`hardhat.config.ts`) used in this project for CORE smart contract development, testing, and deployment. It explains the key components, dependencies, and setup instructions for the configuration.

## Overview

The `hardhat.config.ts` file is the central configuration for the Hardhat development environment. It defines networks, Solidity compiler settings, account management, and plugins for tasks like contract verification. This configuration supports local development, testnet, and mainnet deployments, with flexibility for custom account management via an `accounts.json` file and environment variables.

## Dependencies

The following Hardhat plugins and libraries are used in the configuration:

- **`@nomicfoundation/hardhat-ethers`**: Integrates Hardhat with the `ethers.js` library (v6) for interacting with CORE networks.
- **`@nomicfoundation/hardhat-chai-matchers`**: Provides Chai matchers for CORE-specific assertions, replacing `@nomiclabs/hardhat-waffle`.
- **`@nomicfoundation/hardhat-verify`**: Enables contract verification on block explorers, replacing `@nomiclabs/hardhat-etherscan`.
- **`ethers`**: Used for utilities like `ethers.parseEther` to handle Ether values.
- **`dotenv`**: Loads environment variables from a `.env` file for sensitive data like RPC URLs and API keys.
- **`fs` and `path`**: Node.js modules for reading the `accounts.json` file to load private keys.

Ensure these dependencies are installed by running:

```bash
npm install --save-dev @nomicfoundation/hardhat-ethers @nomicfoundation/hardhat-chai-matchers @nomicfoundation/hardhat-verify dotenv
npm install ethers
```

## Configuration Details

### Environment Variables

The configuration uses a `.env` file to manage sensitive information. Create a `.env` file in the project root with the following variables (if needed):

```bash
TESTNET_URL=https://rpc.test2.btcs.network
MAINNET_URL=https://rpc.coredao.org
CORE_MAINNET_URL=https://eth-mainnet.public.blastapi.io
```

The `dotenv` package loads these variables into `process.env`. If not provided, the config falls back to default RPC URLs.

### Account Management

Accounts are loaded from an `accounts.json` file in the project root. The file should have the following structure:

```json
[
  {
    "address": "0xYourAddress1",
    "privateKey": "0xYourPrivateKey1"
  },
  {
    "address": "0xYourAddress2",
    "privateKey": "0xYourPrivateKey2"
  }
]
```

- The `loadAccounts()` function reads this file and parses it into an array of `{ address, privateKey }` objects.
- If `accounts.json` is not found or invalid, a warning is logged, and the configuration falls back to Hardhat's default accounts for the local network.
- Private keys from `accounts.json` are used for testnet, mainnet, and CORE mainnet deployments.

**Security Note**: Never commit `accounts.json` or `.env` to version control. Add them to `.gitignore`.

### Networks

The configuration defines four networks:

1. **Hardhat (Local Network)**:
   - Chain ID: `31337`
   - Allows unlimited contract sizes for testing large contracts.
   - Uses accounts from `accounts.json` with a balance of 10,000 CORE each, or falls back to default Hardhat accounts with 1,000 CORE.
   - Ideal for local development and testing.

2. **Testnet**:
   - Chain ID: `1114`
   - RPC URL: Configured via `TESTNET_URL` or defaults to `https://rpc.test2.btcs.network`.
   - Uses private keys from `accounts.json`.

3. **Mainnet**:
   - Chain ID: `1116`
   - RPC URL: Configured via `MAINNET_URL` or defaults to `https://rpc.coredao.org`.
   - Uses private keys from `accounts.json`.

4. **CORE Mainnet**:
   - Chain ID: `1`
   - RPC URL: Configured via `CORE_MAINNET_URL` or defaults to `https://eth-mainnet.public.blastapi.io`.
   - Uses private keys from `accounts.json`.

To deploy to a specific network, use the `--network` flag:

```bash
npx hardhat run scripts/deploy.js --network testnet
```

### Solidity Compiler

The Solidity configuration specifies:

- **Version**: `0.8.28`
- **Optimizer**:
  - Enabled with 200 runs for gas-efficient code.
- **IR-Based Compilation**: Enabled via `viaIR: true` for better performance and gas optimization.

### Contract Verification

The `hardhat-verify` plugin is configured for contract verification on custom chains:

- **API Keys**:
  - Testnet: Hard-coded (replace `'37be54ff861145b29e67a10d7ccf19c3e4f5b6c7'` with your API key if required).
  - Mainnet: Placeholder (`"api key"`)—replace with your actual API key.
- **Custom Chains**:
  - Testnet: Configured for chain ID `1114` with API and browser URLs.
  - Mainnet: Configured for chain ID `1116` with API and browser URLs.
- **Sourcify**: Enabled for additional source code verification.

To verify a contract:

```bash
npx hardhat verify --network testnet <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

### Default Network

The default network is set to `testnet`. Override it using the `--network` flag or by modifying `defaultNetwork` in the config.

## Setup Instructions

1. **Install Hardhat**:
   ```bash
   npm init -y
   npm install --save-dev hardhat
   npx hardhat
   ```

   Choose a TypeScript project when prompted.

2. **Install Dependencies**:
   Install the required plugins and libraries as listed in the Dependencies section.

3. **Create `accounts.json`** (optional):
   Add your accounts to `accounts.json` in the project root. Ensure it is not committed to version control.

4. **Create `.env`** (optional):
   Add network RPC URLs to a `.env` file if you want to override the defaults.

5. **Compile Contracts**:
   ```bash
   npx hardhat compile
   ```

6. **Run Tests**:
   ```bash
   npx hardhat test
   ```

7. **Deploy Contracts**:
   Use a deployment script (e.g., `scripts/deploy.ts`) and specify the network:

   ```bash
   npx hardhat run scripts/deploy.ts --network testnet
   ```

8. **Verify Contracts**:
   Follow the contract verification command provided above.

## Notes

- The `task` import from `hardhat/config` is unused in this snippet but included for potential custom task definitions. Remove it if no tasks are added.
- Ensure your RPC URLs are reliable and have sufficient rate limits for deployment and testing.
- For large-scale projects, consider adjusting the optimizer `runs` value or disabling `allowUnlimitedContractSize` for production.

## Troubleshooting

- **Missing `accounts.json`**: Ensure the file exists in the root directory or accept the fallback to Hardhat's default accounts.
- **Invalid JSON in `accounts.json`**: Check the file for syntax errors.
- **Network Connection Issues**: Verify RPC URLs in `.env` or defaults. Test connectivity with tools like `curl`.
- **Verification Errors**: Ensure the correct API key is provided and the contract was deployed on the specified network.

For additional help, refer to the [Hardhat Documentation](https://hardhat.org/docs) or open an issue in the project repository.# Contracts
