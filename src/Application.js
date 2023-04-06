const Web3 = require("web3");
const PolkamarketsSocialLogin = require("./models/PolkamarketsSocialLogin");

const ERC20Contract = require("./models/index").ERC20Contract;
const PredictionMarketContract = require("./models/index").PredictionMarketContract;
const PredictionMarketV2Contract = require("./models/index").PredictionMarketV2Contract;
const AchievementsContract = require("./models/index").AchievementsContract;
const RealitioERC20Contract = require("./models/index").RealitioERC20Contract;
const VotingContract = require("./models/index").VotingContract;
const FantasyERC20Contract = require("./models/index").FantasyERC20Contract;
const WETH9Contract = require("./models/index").WETH9Contract;
const ChainId = require('@biconomy/core-types').ChainId;

const Account = require('./utils/Account');
require('@biconomy/web3-auth/dist/src/style.css'); // needed for the modal styles


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
  }) {
    this.web3Provider = web3Provider;
    // evm logs http source (optional)
    this.web3EventsProvider = web3EventsProvider;
    // fixed gas price for txs (optional)
    this.gasPrice = gasPrice;

    this.isSocialLogin = isSocialLogin;

    if (this.isSocialLogin) {
      if (!socialLoginParams) {
        // create defaults
        socialLoginParams = {
          urls: ['http://localhost:3000'],
          isTestnet: false,
          networkConfig: [
            {
              chainId: ChainId.GOERLI,
              dappAPIKey: '',
            }
          ],
        }
      }
      this.socialLoginParams = socialLoginParams;
      this.socialLogin = PolkamarketsSocialLogin.singleton.getInstance(this.socialLoginParams);
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
  async login() {
    if (this.isSocialLogin) {
      return this.socialLogin.login();
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
      return await this.socialLogin?.isLoggedIn();
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
        web3: this.web3,
        contractAddress,
        acc: this.account,
        web3EventsProvider: this.web3EventsProvider,
        gasPrice: this.gasPrice,
        isSocialLogin: this.isSocialLogin,
      });
    } catch (err) {
      throw err;
    }
  };

  /**
   * @name getPredictionMarketV2Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarket Contract
   */
  getPredictionMarketV2Contract({ contractAddress = null } = {}) {
    try {
      return new PredictionMarketV2Contract({
        web3: this.web3,
        contractAddress,
        acc: this.account,
        web3EventsProvider: this.web3EventsProvider,
        gasPrice: this.gasPrice,
        isSocialLogin: this.isSocialLogin,
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
        web3: this.web3,
        contractAddress,
        predictionMarketContractAddress,
        realitioERC20ContractAddress,
        acc: this.account,
        web3EventsProvider: this.web3EventsProvider,
        gasPrice: this.gasPrice,
        isSocialLogin: this.isSocialLogin,
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
        web3: this.web3,
        contractAddress,
        acc: this.account,
        web3EventsProvider: this.web3EventsProvider,
        gasPrice: this.gasPrice,
        isSocialLogin: this.isSocialLogin,
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
        web3: this.web3,
        contractAddress,
        acc: this.account,
        web3EventsProvider: this.web3EventsProvider,
        gasPrice: this.gasPrice,
        isSocialLogin: this.isSocialLogin,
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
        web3: this.web3,
        contractAddress,
        acc: this.account,
        web3EventsProvider: this.web3EventsProvider,
        gasPrice: this.gasPrice,
        isSocialLogin: this.isSocialLogin,
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
        web3: this.web3,
        contractAddress: contractAddress,
        acc: this.account,
        web3EventsProvider: this.web3EventsProvider,
        gasPrice: this.gasPrice,
        isSocialLogin: this.isSocialLogin,
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
        web3: this.web3,
        contractAddress: contractAddress,
        acc: this.account,
        web3EventsProvider: this.web3EventsProvider,
        gasPrice: this.gasPrice,
        isSocialLogin: this.isSocialLogin,
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
      return await this.socialLogin.getAddress();
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

  async socialLoginGoogle() {
    await this.socialLogin.directLogin('google');
  }

  async socialLoginFacebook() {
    await this.socialLogin.directLogin('facebook');
  }

  async socialLoginEmail(email) {
    await this.socialLogin.directLogin('email', email);
  }

  async socialLoginMetamask() {
    await this.socialLogin.directLogin('metamask');
  }

  async socialLoginWalletConnect() {
    await this.socialLogin.directLogin('walletconnect');
  }

  async socialLoginLogout() {
    if (this.socialLogin?.provider) {
      this.socialLogin.logout();
    }
  }
}

module.exports = Application;
