import Web3 from "web3";
import Account from "./utils/Account";

// Import contract classes
import {
  ERC20Contract,
  PredictionMarketContract,
  PredictionMarketV2Contract,
  PredictionMarketV3Contract,
  PredictionMarketV3_2Contract,
  PredictionMarketV3ManagerContract,
  PredictionMarketV3ControllerContract,
  PredictionMarketV3FactoryContract,
  AchievementsContract,
  RealitioERC20Contract,
  VotingContract,
  FantasyERC20Contract,
  WETH9Contract,
  ArbitrationContract,
  ArbitrationProxyContract,
} from "./models/index";

// Import PolkamarketsSmartAccount - using require until converted to TypeScript
const PolkamarketsSmartAccount = require("./models/PolkamarketsSmartAccount");

// Declare window for browser environment
declare global {
  interface Window {
    web3?: Web3;
    ethereum?: any;
  }
}

interface ApplicationConfig {
  web3Provider: string;
  web3PrivateKey?: string;
  web3EventsProvider?: string;
  gasPrice?: string;
  isSocialLogin?: boolean;
  socialLoginParams?: any;
  startBlock?: number;
  defaultDecimals?: number;
}

interface ContractParams {
  web3: Web3;
  contractAddress: string | null;
  acc: Account;
  web3EventsProvider?: string;
  gasPrice?: string;
  isSocialLogin?: boolean;
  startBlock?: number;
  defaultDecimals?: number;
}

interface PredictionMarketV3Params extends ContractParams {
  querierContractAddress?: string | null;
}

interface AchievementsParams extends ContractParams {
  predictionMarketContractAddress?: string | null;
  realitioERC20ContractAddress?: string | null;
}

const networksEnum = Object.freeze({
  1: "Main",
  2: "Morden",
  3: "Ropsten",
  4: "Rinkeby",
  42: "Kovan",
});

class Application {
  private web3Provider: string;
  private web3EventsProvider?: string;
  private gasPrice?: string;
  private isSocialLogin: boolean;
  private socialLoginParams?: any;
  private startBlock?: number;
  private defaultDecimals?: number;
  private web3?: Web3;
  private account?: Account;
  private smartAccount?: any;

  constructor({
    web3Provider,
    web3PrivateKey,
    web3EventsProvider,
    gasPrice,
    isSocialLogin = false,
    socialLoginParams,
    startBlock,
    defaultDecimals,
  }: ApplicationConfig) {
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
      this.account = new Account(
        this.web3!,
        this.web3!.eth.accounts.privateKeyToAccount(web3PrivateKey),
      );
    }
  }

  /**********/
  /** CORE **/
  /**********/

  /**
   * @name start
   * @description Start the Application
   */
  start(): void {
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
  async login(
    provider: any = null,
    isConnectedWallet: boolean | null = null,
  ): Promise<boolean> {
    if (this.isSocialLogin) {
      if (!this.smartAccount) {
        this.smartAccount =
          PolkamarketsSmartAccount.singleton.getInstanceIfExists();
      }

      if ((!this.smartAccount || !this.smartAccount.provider) && provider) {
        PolkamarketsSmartAccount.singleton.clearInstance();
        this.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(
          provider,
          this.socialLoginParams.networkConfig,
          isConnectedWallet,
        );
      }

      return true;
    } else {
      try {
        if (typeof window === "undefined") {
          return false;
        }
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
  }

  /**
   * @name isLoggedIn
   * @description Returns wether metamask account is connected to service or not
   */
  async isLoggedIn(): Promise<boolean> {
    if (this.isSocialLogin) {
      return !!(this.smartAccount && this.smartAccount.provider);
    } else {
      try {
        if (
          typeof window === "undefined" ||
          typeof window.ethereum === "undefined"
        ) {
          return false;
        }
        const accounts = await window.ethereum.request({
          method: "eth_accounts",
        });

        return accounts.length > 0;
      } catch (err) {
        return false;
      }
    }
  }

  private contractDefaultParams(
    contractAddress: string | null,
  ): ContractParams {
    return {
      web3: this.web3!,
      contractAddress,
      acc: this.account!,
      web3EventsProvider: this.web3EventsProvider,
      gasPrice: this.gasPrice,
      isSocialLogin: this.isSocialLogin,
      startBlock: this.startBlock,
      defaultDecimals: this.defaultDecimals,
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
  getPredictionMarketContract({
    contractAddress = null,
  }: { contractAddress?: string | null } = {}): any {
    try {
      return new PredictionMarketContract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getPredictionMarketV2Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV2 Contract
   */
  getPredictionMarketV2Contract({
    contractAddress = null,
  }: { contractAddress?: string | null } = {}): any {
    try {
      return new PredictionMarketV2Contract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getPredictionMarketV3Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3 Contract
   */
  getPredictionMarketV3Contract({
    contractAddress = null,
    querierContractAddress = null,
  }: {
    contractAddress?: string | null;
    querierContractAddress?: string | null;
  } = {}): any {
    try {
      return new PredictionMarketV3Contract({
        ...this.contractDefaultParams(contractAddress),
        querierContractAddress,
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getPredictionMarketV3_2Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3 Contract
   */
  getPredictionMarketV3_2Contract({
    contractAddress = null,
    querierContractAddress = null,
  }: {
    contractAddress?: string | null;
    querierContractAddress?: string | null;
  } = {}): any {
    try {
      return new PredictionMarketV3_2Contract({
        ...this.contractDefaultParams(contractAddress),
        querierContractAddress,
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getPredictionMarketV3FactoryContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3Factory Contract
   */
  getPredictionMarketV3FactoryContract({
    contractAddress = null,
  }: { contractAddress?: string | null } = {}): any {
    try {
      return new PredictionMarketV3FactoryContract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name PredictionMarketV3ControllerContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3ControllerContract Contract
   */
  getPredictionMarketV3ControllerContract({
    contractAddress = null,
  }: { contractAddress?: string | null } = {}): any {
    try {
      return new PredictionMarketV3ControllerContract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getPredictionMarketV3ManagerContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarketV3Manager Contract
   */
  getPredictionMarketV3ManagerContract({
    contractAddress = null,
  }: { contractAddress?: string | null } = {}): any {
    try {
      return new PredictionMarketV3ManagerContract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getAchievementsContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a PredictionMarket Contract
   */
  getAchievementsContract({
    contractAddress = null,
    predictionMarketContractAddress = null,
    realitioERC20ContractAddress = null,
  }: {
    contractAddress?: string | null;
    predictionMarketContractAddress?: string | null;
    realitioERC20ContractAddress?: string | null;
  } = {}): any {
    try {
      return new AchievementsContract({
        ...this.contractDefaultParams(contractAddress),
        predictionMarketContractAddress,
        realitioERC20ContractAddress,
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getVotingContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a Voting Contract
   */
  getVotingContract({
    contractAddress = null,
  }: { contractAddress?: string | null } = {}): any {
    try {
      return new VotingContract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getFantasyERC20Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a Fantasy ERC20 Contract
   */
  getFantasyERC20Contract({
    contractAddress = null,
  }: { contractAddress?: string | null } = {}): any {
    try {
      return new FantasyERC20Contract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getRealitioERC20Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a RealitioERC20 Contract
   */
  getRealitioERC20Contract({
    contractAddress = null,
  }: { contractAddress?: string | null } = {}): any {
    try {
      return new RealitioERC20Contract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getERC20Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a ERC20 Contract
   */
  getERC20Contract({
    contractAddress = null,
  }: {
    contractAddress?: string | null;
  }): any {
    try {
      return new ERC20Contract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getWETH9Contract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a WETH9 Contract
   */
  getWETH9Contract({
    contractAddress = null,
  }: {
    contractAddress?: string | null;
  }): any {
    try {
      return new WETH9Contract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getArbitrationContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a Arbitration Contract
   */
  getArbitrationContract({
    contractAddress = null,
  }: {
    contractAddress?: string | null;
  }): any {
    try {
      return new ArbitrationContract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /**
   * @name getArbitrationProxyContract
   * @param {Address} ContractAddress (Opt) If it is deployed
   * @description Create a Arbitration Proxy Contract
   */
  getArbitrationProxyContract({
    contractAddress = null,
  }: {
    contractAddress?: string | null;
  }): any {
    try {
      return new ArbitrationProxyContract({
        ...this.contractDefaultParams(contractAddress),
      });
    } catch (err) {
      throw err;
    }
  }

  /***********/
  /** UTILS **/
  /***********/

  /**
   * @name getETHNetwork
   * @description Access current ETH Network used
   * @returns {String} Eth Network
   */
  async getETHNetwork(): Promise<string> {
    const netId = await this.web3!.eth.net.getId();
    const networkName = networksEnum.hasOwnProperty(netId)
      ? (networksEnum as any)[netId]
      : "Unknown";
    return networkName;
  }

  /**
   * @name getAddress
   * @description Access current Address Being Used under Web3 Injector (ex : Metamask)
   * @returns {Address} Address
   */
  async getAddress(): Promise<string> {
    if (this.isSocialLogin) {
      if (this.smartAccount && this.smartAccount.provider) {
        return await this.smartAccount.getAddress();
      }
      return "";
    } else {
      const accounts = await this.web3!.eth.getAccounts();
      return accounts[0];
    }
  }

  /**
   * @name getETHBalance
   * @description Access current ETH Balance Available for the Injected Web3 Address
   * @returns {Integer} Balance
   */
  async getETHBalance(): Promise<string> {
    const address = await this.getAddress();
    if (typeof window !== "undefined" && window.web3) {
      const wei = await window.web3.eth.getBalance(address);
      return this.web3!.utils.fromWei(wei, "ether");
    }
    throw new Error("Window or web3 not available");
  }

  async socialLoginWithJWT(id: string, jwtToken: string): Promise<void> {
    throw new Error("Not implemented");
  }

  async socialLoginLogout(): Promise<void> {
    if (this.smartAccount) {
      PolkamarketsSmartAccount.singleton.clearInstance();
      this.smartAccount = null;
    }
  }
}

export default Application;
