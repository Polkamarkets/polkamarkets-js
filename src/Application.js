const web3 = require("web3");

const polkamarketssmartaccount = require("./models/PolkamarketsSmartAccount");

const erc20contract = require("./models/index").erc20contract;
const predictionmarketcontract =
  require("./models/index").predictionmarketcontract;
const predictionmarketv2contract =
  require("./models/index").predictionmarketv2contract;
const predictionmarketv3contract =
  require("./models/index").predictionmarketv3contract;
const predictionmarketv3managercontract =
  require("./models/index").predictionmarketv3managercontract;
const predictionmarketv3controllercontract =
  require("./models/index").predictionmarketv3controllercontract;
const predictionmarketv3factorycontract =
  require("./models/index").predictionmarketv3factorycontract;
const achievementscontract = require("./models/index").achievementscontract;
const realitioerc20contract = require("./models/index").realitioerc20contract;
const votingcontract = require("./models/index").votingcontract;
const fantasyerc20contract = require("./models/index").fantasyerc20contract;
const weth9contract = require("./models/index").weth9contract;
const arbitrationcontract = require("./models/index").arbitrationcontract;
const arbitrationproxycontract =
  require("./models/index").arbitrationproxycontract;

const referralcontract = require("./models/index").referralrewardcontract;

const account = require("./utils/Account");

const networksenum = Object.freeze({
  1: "main",
  2: "morden",
  3: "ropsten",
  4: "rinkeby",
  42: "kovan",
});

class application {
  constructor({
    web3provider,
    web3privatekey,
    web3eventsprovider,
    gasprice,
    issociallogin = false,
    socialloginparams,
    startblock,
    defaultdecimals,
  }) {
    this.web3provider = web3provider;
    // evm logs http source (optional)
    this.web3eventsprovider = web3eventsprovider;
    // fixed gas price for txs (optional)
    this.gasprice = gasprice;
    this.issociallogin = issociallogin;
    this.startblock = startblock;
    this.defaultdecimals = defaultdecimals;

    if (this.issociallogin) {
      this.socialloginparams = socialloginparams;
    }

    // important: this parameter should only be used for testing purposes
    if (web3privatekey && !this.issociallogin) {
      this.start();
      this.login();
      this.account = new account(
        this.web3,
        this.web3.eth.accounts.privatekeytoaccount(web3privatekey)
      );
    }
  }

  /**********/
  /** core **/
  /**********/

  /**
   * @name start
   * @description start the application
   */
  start() {
    this.web3 = new web3(new web3.providers.httpprovider(this.web3provider));
    this.web3.eth.handlerevert = true;
    if (typeof window !== "undefined") {
      window.web3 = this.web3;
    }
  }

  /**
   * @name login
   * @description login with metamask or a web3 provider
   */
  async login(provider = null, isconnectedwallet = null) {
    if (this.issociallogin) {
      if (!this.provider) {
        this.smartaccount =
          polkamarketssmartaccount.singleton.getinstanceifexists();
      }

      if ((!this.smartaccount || !this.smartaccount.provider) && provider) {
        polkamarketssmartaccount.singleton.clearinstance();
        this.smartaccount = polkamarketssmartaccount.singleton.getinstance(
          provider,
          this.socialloginparams.networkconfig,
          isconnectedwallet
        );
      }

      return true;
    } else {
      try {
        if (typeof window === "undefined") {
          return false;
        }
        if (window.ethereum) {
          window.web3 = new web3(window.ethereum);
          this.web3 = window.web3;
          await window.ethereum.enable();
          return true;
        }
        return false;
      } catch (err) {
        throw err;
      }
    }
  }

  /**
   * @name isloggedin
   * @description returns wether metamask account is connected to service or not
   */
  async isloggedin() {
    if (this.issociallogin) {
      return !!(this.smartaccount && this.smartaccount.provider);
    } else {
      try {
        if (
          typeof window === "undefined" ||
          typeof window.ethereum === "undefined"
        ) {
          return false;
        }
        const accounts = await ethereum.request({ method: "eth_accounts" });

        return accounts.length > 0;
      } catch (err) {
        return false;
      }
    }
  }

  contractdefaultparams(contractaddress) {
    return {
      web3: this.web3,
      contractaddress,
      acc: this.account,
      web3eventsprovider: this.web3eventsprovider,
      gasprice: this.gasprice,
      issociallogin: this.issociallogin,
      startblock: this.startblock,
      defaultdecimals: this.defaultdecimals,
    };
  }

  /*************/
  /** getters **/
  /*************/

  /**
   * @name getpredictionmarketcontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a predictionmarket contract
   */
  getpredictionmarketcontract({ contractaddress = null } = {}) {
    try {
      return new predictionmarketcontract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getpredictionmarketv2contract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a predictionmarketv2 contract
   */
  getpredictionmarketv2contract({ contractaddress = null } = {}) {
    try {
      return new predictionmarketv2contract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getpredictionmarketv3contract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a predictionmarketv3 contract
   */
  getpredictionmarketv3contract({
    contractaddress = null,
    queriercontractaddress = null,
  } = {}) {
    try {
      return new predictionmarketv3contract({
        ...this.contractdefaultparams(contractaddress),
        queriercontractaddress,
      });
    } catch (err) {
      throw err;
    }
  }
  /**
   * @name getpredictionmarketv3factorycontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a predictionmarketv3factory contract
   */
  getpredictionmarketv3factorycontract({ contractaddress = null } = {}) {
    try {
      return new predictionmarketv3factorycontract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name predictionmarketv3controllercontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a predictionmarketv3controllercontract contract
   */
  getpredictionmarketv3controllercontract({ contractaddress = null } = {}) {
    try {
      return new predictionmarketv3controllercontract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getpredictionmarketv3managercontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a predictionmarketv3manager contract
   */
  getpredictionmarketv3managercontract({ contractaddress = null } = {}) {
    try {
      return new predictionmarketv3managercontract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getachievementscontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a predictionmarket contract
   */
  getachievementscontract({
    contractaddress = null,
    predictionmarketcontractaddress = null,
    realitioerc20contractaddress = null,
  } = {}) {
    try {
      return new achievementscontract({
        ...this.contractdefaultparams(contractaddress),
        predictionmarketcontractaddress,
        realitioerc20contractaddress,
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getvotingcontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a voting contract
   */
  getvotingcontract({ contractaddress = null } = {}) {
    try {
      return new votingcontract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getfantasyerc20contract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a fantasy erc20 contract
   */
  getfantasyerc20contract({ contractaddress = null } = {}) {
    try {
      return new fantasyerc20contract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getrealitioerc20contract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a realitioerc20 contract
   */
  getrealitioerc20contract({ contractaddress = null } = {}) {
    try {
      return new realitioerc20contract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name geterc20contract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a erc20 contract
   */
  geterc20contract({ contractaddress = null }) {
    try {
      return new erc20contract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getweth9contract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a weth9 contract
   */
  getweth9contract({ contractaddress = null }) {
    try {
      return new weth9contract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getarbitrationcontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a arbitration contract
   */
  getarbitrationcontract({ contractaddress = null }) {
    try {
      return new arbitrationcontract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getarbitrationproxycontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a arbitration proxy contract
   */
  getarbitrationproxycontract({ contractaddress = null }) {
    try {
      return new arbitrationproxycontract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getreferralrewardcontract
   * @param {address} contractaddress (opt) if it is deployed
   * @description create a referralreward contract
   */
  getreferralrewardcontract({ contractaddress = null } = {}) {
    try {
      return new referralcontract({
        ...this.contractdefaultparams(contractaddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /***********/
  /** utils **/
  /***********/

  /**
   * @name getethnetwork
   * @description access current eth network used
   * @returns {string} eth network
   */
  async getethnetwork() {
    const netid = await this.web3.eth.net.getid();
    const networkname = networksenum.hasownproperty(netid)
      ? networksenum[netid]
      : "unknown";
    return networkname;
  }

  /**
   * @name getaddress
   * @description access current address being used under web3 injector (ex : metamask)
   * @returns {address} address
   */
  async getaddress() {
    if (this.issociallogin) {
      if (this.smartaccount && this.smartaccount.provider) {
        return await this.smartaccount.getaddress();
      }
      return "";
    } else {
      const accounts = await this.web3.eth.getaccounts();
      return accounts[0];
    }
  }

  /**
   * @name getethbalance
   * @description access current eth balance available for the injected web3 address
   * @returns {integer} balance
   */
  async getethbalance() {
    const address = await this.getaddress();
    let wei = await window.web3.eth.getbalance(address);
    return this.web3.utils.fromwei(wei, "ether");
  }

  async socialloginwithjwt(id, jwttoken) {
    throw new error("not implemented");
  }

  async socialloginlogout() {
    if (this.smartaccount) {
      polkamarketssmartaccount.singleton.clearinstance();
      this.smartaccount = null;
    }
  }
}

module.exports = application;
