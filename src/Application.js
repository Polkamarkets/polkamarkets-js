const Web3 = require("web3");

const PolkamarketsSmartAccount = require("./models/PolkamarketsSmartAccount");

const ERC20Contract = require("./models/index").ERC20Contract;
const PredictionMarketContract = require("./models/index").PredictionMarketContract;
const PredictionMarketV2Contract = require("./models/index").PredictionMarketV2Contract;
const PredictionMarketV3Contract = require("./models/index").PredictionMarketV3Contract;
const PredictionMarketV3PlusContract = require("./models/index").PredictionMarketV3PlusContract;
const PredictionMarketV3ManagerContract = require("./models/index").PredictionMarketV3ManagerContract;
const PredictionMarketV3ControllerContract = require("./models/index").PredictionMarketV3ControllerContract;
const PredictionMarketV3FactoryContract = require("./models/index").PredictionMarketV3FactoryContract;
const AchievementsContract = require("./models/index").AchievementsContract;
const RealitioERC20Contract = require("./models/index").RealitioERC20Contract;
const VotingContract = require("./models/index").VotingContract;
const FantasyERC20Contract = require("./models/index").FantasyERC20Contract;
const WETH9Contract = require("./models/index").WETH9Contract;
const ArbitrationContract = require("./models/index").ArbitrationContract;
const ArbitrationProxyContract = require("./models/index").ArbitrationProxyContract;

const Account = require('./utils/Account');


const networksEnum = Object.freeze({
  1: "Main",
  2: "Morden",
  3: "Ropsten",
  4: "Rinkeby",
  42: "Kovan",
});

class Application {
  constructor({
    web3Provider,
    web3PrivateKey,
    web3EventsProvider,
    gasPrice,
    isSocialLogin = false,
    socialLoginParams,
    startBlock,
    defaultDecimals
  }) {
    this.web3Provider = web3Provider;
    // evm logs http source (optional)
    this.web3EventsProvider = web3EventsProvider;
    // fixed gas price for txs (optional)
    this.gasPrice = gasPrice;
    this.isSocialLogin = isSocialLogin;
    this.startBlock = startBlock;
    this.defaultDecimals = defaultDecimals;

    if (this.isSocialLogin) {
      this.socialLoginParams = socialLoginParams;
    }

    // IMPORTANT: this parameter should only be used for testing purposes
    if (web3PrivateKey && !this.isSocialLogin) {
      this.start();
      this.login();
      this.account = new Account(this.web3, this.web3.eth.accounts.privateKeyToAccount(web3PrivateKey));
    }
  }

  /**********/
  /** CORE **/
  /**********/

  /**
   * @name start
   * @description Start the Application
   */
  start() {
    this.web3 = new Web3(new Web3.providers.HttpProvider(this.web3Provider));
    this.web3.eth.handleRevert = true;
    if (typeof window !== "undefined") {
      window.web3 = this.web3;
    }
  }

  /**
   * @name login
   * @description Login with Metamask or a web3 provider
   */
  async login(provider = null, isConnectedWallet = null) {
    if (this.isSocialLogin) {
      if (!this.provider) {
        this.smartAccount = PolkamarketsSmartAccount.singleton.getInstanceIfExists()
      }

      if ((!this.smartAccount || !this.smartAccount.provider) && provider) {
        PolkamarketsSmartAccount.singleton.clearInstance();
        this.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(provider, this.socialLoginParams.networkConfig, isConnectedWallet);
      }

      return true;
    } else {
      try {
        if (typeof window === "undefined") { return false; }
        if (window.ethereum) {
          window.web3 = new Web3(window.ethereum);
          this.web3 = window.web3;
          await window.ethereum.enable();
          return true;
        }
        return false;
      } catch (err) {
        throw err;
      }
    }
  };

  /**
   * @name isLoggedIn
   * @description Returns wether metamask account is connected to service or not
   */
  async isLoggedIn() {
    if (this.isSocialLogin) {
      return !!(this.smartAccount && this.smartAccount.provider);
    } else {
      try {
        if (typeof window === "undefined" || typeof window.ethereum === "undefined") { return false; }
        const accounts = await ethereum.request({ method: 'eth_accounts' });

        return accounts.length > 0;
      } catch (err) {
        return false;
      }
    }
  };

  contractDefaultParams(contractAddress) {
    return {
      web3: this.web3,
      contractAddress,
      acc: this.account,
      web3EventsProvider: this.web3EventsProvider,
      gasPrice: this.gasPrice,
      isSocialLogin: this.isSocialLogin,
      startBlock: this.startBlock,
      defaultDecimals: this.defaultDecimals
    };
  }

  /*************/
  /** GETTERS **/
  /*************/

  /**
   * @name getPredictionMarketContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarket Contract
   */
  getPredictionMarketContract({ contractAddress = null } = {}) {
    try {
      return new PredictionMarketContract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getPredictionMarketV2Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV2 Contract
   */
  getPredictionMarketV2Contract({ contractAddress = null } = {}) {
    try {
      return new PredictionMarketV2Contract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getPredictionMarketV3Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3 Contract
   */
  getPredictionMarketV3Contract({ contractAddress = null, querierContractAddress = null } = {}) {
    try {
      return new PredictionMarketV3Contract({
        ...this.contractDefaultParams(contractAddress),
        querierContractAddress,
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getPredictionMarketV3PlusContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3 Contract
   */
  getPredictionMarketV3PlusContract({ contractAddress = null, querierContractAddress = null } = {}) {
    try {
      return new PredictionMarketV3PlusContract({
        ...this.contractDefaultParams(contractAddress),
        querierContractAddress,
      });
    } catch (err) {
      throw err;
    }
  };


  /**
   * @name getPredictionMarketV3FactoryContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3Factory Contract
   */
  getPredictionMarketV3FactoryContract({ contractAddress = null } = {}) {
    try {
      return new PredictionMarketV3FactoryContract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name PredictionMarketV3ControllerContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3ControllerContract Contract
   */
  getPredictionMarketV3ControllerContract({ contractAddress = null } = {}) {
    try {
      return new PredictionMarketV3ControllerContract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getPredictionMarketV3ManagerContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3Manager Contract
   */
  getPredictionMarketV3ManagerContract({ contractAddress = null } = {}) {
    try {
      return new PredictionMarketV3ManagerContract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getAchievementsContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarket Contract
   */
  getAchievementsContract({
    contractAddress = null,
    predictionMarketContractAddress = null,
    realitioERC20ContractAddress = null
  } = {}) {
    try {
      return new AchievementsContract({
        ...this.contractDefaultParams(contractAddress),
        predictionMarketContractAddress,
        realitioERC20ContractAddress,
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getVotingContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a Voting Contract
   */
  getVotingContract({ contractAddress = null } = {}) {
    try {
      return new VotingContract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getFantasyERC20Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a Fantasy ERC20 Contract
   */
  getFantasyERC20Contract({ contractAddress = null } = {}) {
    try {
      return new FantasyERC20Contract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getRealitioERC20Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a RealitioERC20 Contract
   */
  getRealitioERC20Contract({ contractAddress = null } = {}) {
    try {
      return new RealitioERC20Contract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getERC20Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a ERC20 Contract
   */
  getERC20Contract({ contractAddress = null }) {
    try {
      return new ERC20Contract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getWETH9Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a WETH9 Contract
   */
  getWETH9Contract({ contractAddress = null }) {
    try {
      return new WETH9Contract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getArbitrationContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a Arbitration Contract
   */
  getArbitrationContract({ contractAddress = null }) {
    try {
      return new ArbitrationContract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getArbitrationProxyContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a Arbitration Proxy Contract
   */
  getArbitrationProxyContract({ contractAddress = null }) {
    try {
      return new ArbitrationProxyContract({
        ...this.contractDefaultParams(contractAddress)
      });
    } catch (err) {
      throw err;
    }
  };

  /***********/
  /** UTILS **/
  /***********/

  /**
   * @name getETHNetwork
   * @description Access current ETH Network used
   * @returns {String} Eth Network
   */
  async getETHNetwork() {
    const netId = await this.web3.eth.net.getId();
    const networkName = networksEnum.hasOwnProperty(netId)
      ? networksEnum[netId]
      : "Unknown";
    return networkName;
  };

  /**
   * @name getAddress
   * @description Access current Address Being Used under Web3 Injector (ex : Metamask)
   * @returns {Address} Address
   */
  async getAddress() {
    if (this.isSocialLogin) {
      if (this.smartAccount && this.smartAccount.provider) {
        return await this.smartAccount.getAddress();
      }
      return '';
    } else {
      const accounts = await this.web3.eth.getAccounts();
      return accounts[0];
    }
  };

  /**
   * @name getETHBalance
   * @description Access current ETH Balance Available for the Injected Web3 Address
   * @returns {Integer} Balance
   */
  async getETHBalance() {
    const address = await this.getAddress();
    let wei = await window.web3.eth.getBalance(address);
    return this.web3.utils.fromWei(wei, "ether");
  };

  async socialLoginWithJWT(id, jwtToken) {
    throw new Error("Not implemented");
  }

  async socialLoginLogout() {
    if (this.smartAccount) {
      PolkamarketsSmartAccount.singleton.clearInstance();
      this.smartAccount = null;
    }
  }
}

module.exports = Application;
