require('dotenv').config()
const HDWalletProvider = require("@truffle/hdwallet-provider");
const mnemonic = process.env.TRUFFLE_MNEMONIC;
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY;
const INFURA_API_KEY = process.env.INFURA_API_KEY;

module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "*", // Match any network id
      gasLimit: 10000000,
      gas: 10000000
    },
    live: {
      provider: new HDWalletProvider(mnemonic, "https://mainnet.infura.io/v3/" + INFURA_API_KEY),
      network_id: 1,
      gasPrice: 100000000000,
      websockets: true
    },
    moonriver: {
      provider: new HDWalletProvider(mnemonic, "https://rpc.api.moonriver.moonbeam.network/"),
      network_id: 1285
    },
    moonbeam: {
      provider: new HDWalletProvider(mnemonic, "https://rpc.api.moonbeam.network"),
      network_id: 1284
    },
    goerli: {
      provider: new HDWalletProvider(mnemonic, "https://goerli.infura.io/v3/" + INFURA_API_KEY),
      network_id: 5
    },
    leprichain: {
      provider: new HDWalletProvider(mnemonic, "https://node.leprichain.blockwell.ai"),
      network_id: 49777,
      gasPrice: 0
    },
    polygon: {
      provider: new HDWalletProvider(mnemonic, "https://polygon-rpc.com"),
      network_id: 137,
    },
    mumbai: {
      provider: new HDWalletProvider(mnemonic, "https://rpc-mumbai.maticvigil.com"),
      network_id: 80001,
    }
  },
  // Configure your compilers
  compilers: {
    solc: {
      version: "0.8.10",    // Fetch exact version from solc-bin (default: truffle's version)
      // docker: true,        // Use "0.5.1" you've installed locally with docker (default: false)
      // settings: {          // See the solidity docs for advice about optimization and evmVersion
      //  optimizer: {
      //    enabled: false,
      //    runs: 200
      //  },
      //  evmVersion: "byzantium"
      // }
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }
  },
  plugins: [
    'truffle-contract-size',
    'truffle-plugin-verify'
  ],
  api_keys: {
    etherscan: ETHERSCAN_API_KEY
  }
};
