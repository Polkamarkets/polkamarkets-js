require("dotenv").config();
const HDWalletProvider = require("@truffle/hdwallet-provider");

const mnemonic = process.env.TRUFFLE_MNEMONIC || "";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "";
const POLYGONSCAN_API_KEY = process.env.POLYGONSCAN_API_KEY || "";
const GNOSIS_API_KEY = process.env.GNOSIS_API_KEY || "";
const CELO_API_KEY = process.env.CELO_API_KEY || "";
const INFURA_API_KEY = process.env.INFURA_API_KEY || "";
const ARBITRUM_API_KEY = process.env.ARBITRUM_API_KEY || "";

module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "*",
      gas: 10000000,
      gasLimit: 10000000,
    },
    live: {
      provider: () =>
        new HDWalletProvider(
          mnemonic,
          "https://mainnet.infura.io/v3/" + INFURA_API_KEY
        ),
      network_id: 1,
      gasPrice: 100000000000,
      websockets: true,
    },
    chiado: {
      provider: () =>
        new HDWalletProvider(mnemonic, "https://rpc.chiadochain.net"),
      network_id: 10200,
      gas: 5000000,
      gasPrice: 10000000,
      skipDryRun: true, // added
      networkCheckTimeout: 200000, // added: slow RPC protection (200s)
      timeoutBlocks: 200, // added
    },
    sepolia: {
      provider: () =>
        new HDWalletProvider(
          mnemonic,
          "https://sepolia.infura.io/v3/" + INFURA_API_KEY
        ),
      network_id: 11155111,
      networkCheckTimeout: 200000, // added: slow RPC protection (200s)
      gas: 5500000,
      gasPrice: 10000000000,
      confirmations: 2,
      timeoutBlocks: 200,
      skipDryRun: true,
    },
    gnosis: {
      provider: () =>
        new HDWalletProvider(mnemonic, "https://rpc.gnosischain.com"),
      network_id: 100,
      gas: 5000000,
      gasPrice: 10000000000,
    },
    alfajores: {
      provider: () =>
        new HDWalletProvider(
          mnemonic,
          "https://alfajores-forno.celo-testnet.org/"
        ),
      network_id: 44787,
      gas: 5000000,
      gasPrice: 10000000000,
    },
    celo: {
      provider: () => new HDWalletProvider(mnemonic, "https://forno.celo.org"),
      network_id: 42220,
      gas: 5000000,
      gasPrice: 10000000000,
    },
    moonriver: {
      provider: () =>
        new HDWalletProvider(
          mnemonic,
          "https://rpc.api.moonriver.moonbeam.network/"
        ),
      network_id: 1285,
    },
    moonbeam: {
      provider: () =>
        new HDWalletProvider(mnemonic, "https://rpc.api.moonbeam.network"),
      network_id: 1284,
    },
    polygon: {
      provider: () => new HDWalletProvider(mnemonic, "https://polygon-rpc.com"),
      network_id: 137,
      gasPrice: 200000000000,
      skipDryRun: true,
      networkCheckTimeout: 10000,
      timeoutBlocks: 200,
      gas: 25000000,
    },
    arbitrum: {
      provider: () =>
        new HDWalletProvider(mnemonic, "https://arb1.arbitrum.io/rpc"),
      network_id: 42161,
      gasPrice: 200000000,
      skipDryRun: true,
      networkCheckTimeout: 10000,
      timeoutBlocks: 200,
      gas: 25000000,
    },
    arbitrum_sepolia: {
      provider: () =>
        new HDWalletProvider(
          mnemonic,
          "https://sepolia-rollup.arbitrum.io/rpc"
        ),
      network_id: 421614,
      gasPrice: 200000000,
      skipDryRun: true,
      networkCheckTimeout: 10000,
      timeoutBlocks: 200,
      gas: 25000000,
      verify: {
        apiUrl: "https://api-sepolia.arbiscan.io/api",
        apiKey: ARBITRUM_API_KEY,
        explorerUrl: "https://sepolia.arbiscan.io/address",
      },
    },
  },
  compilers: {
    solc: {
      version: "0.8.18",
      settings: {
        optimizer: { enabled: true, runs: 200 },
      },
    },
  },
  plugins: ["truffle-contract-size", "truffle-plugin-verify"],
  api_keys: {
    etherscan: ETHERSCAN_API_KEY,
    polygonscan: POLYGONSCAN_API_KEY,
    gnosisscan: GNOSIS_API_KEY,
    celoscan: CELO_API_KEY,
    arbiscan: ARBITRUM_API_KEY,
  },
};
