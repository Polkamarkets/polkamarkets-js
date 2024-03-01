
const PolkamarketsSmartAccount = require("./PolkamarketsSmartAccount");
const SafeEventEmitter = require('@metamask/safe-event-emitter').default;
const ethers = require('ethers').ethers;

const { EthereumPrivateKeyProvider } = require('@web3auth/ethereum-provider');
const { CHAIN_NAMESPACES } = require('@web3auth/base');

const { Web3Auth } = require('@web3auth/single-factor-auth');

class PolkamarketsSocialLogin {
  static singleton = (() => {
    let socialLogin;

    function createInstance(web3AuthConfig, web3Provider) {
      const instance = new PolkamarketsSocialLogin(web3AuthConfig, web3Provider);
      instance.eventEmitter = new SafeEventEmitter();
      return instance;
    }

    return {
      getInstance: (socialLoginParams, web3Provider) => {
        if (!socialLogin) {
          socialLogin = createInstance(socialLoginParams, web3Provider);
          socialLogin.init();
        }
        return socialLogin;
      }
    };
  })();

  constructor(socialLoginParams = null, web3Provider = null) {
    this.isInit = false
    this.web3auth = null
    this.web3Provider = web3Provider;
    this.provider = null;

    this.web3AuthConfig = socialLoginParams.web3AuthConfig;
    this.isTestnet = socialLoginParams.isTestnet;
    this.whiteLabelData = socialLoginParams.whiteLabelData;
    this.networkConfig = socialLoginParams.networkConfig;
  }

  async init() {
    if (!this.isInit) {
      // convert int to hex
      const chainId = `0x${this.networkConfig.chainId.toString(16)}`;

      try {
        const chainConfig = {
          chainNamespace: CHAIN_NAMESPACES.EIP155,
          chainId,
          rpcTarget: this.web3Provider,
        };


        const privateKeyProvider = new EthereumPrivateKeyProvider({
          config: { chainConfig },
        });

        const web3AuthCore = new Web3Auth({
          clientId: this.web3AuthConfig.clientId,
          web3AuthNetwork: this.isTestnet ? 'testnet' : 'sapphire_mainnet',
          enableLogging: true,
          sessionTime: 86400 * 7,
        });

        await web3AuthCore.init(privateKeyProvider);
        this.web3auth = web3AuthCore;

        if (web3AuthCore && web3AuthCore.provider.provider) {
          try {
            await this.web3auth.getUserInfo()
            this.provider = web3AuthCore.provider.provider;
            this.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(this.provider, this.networkConfig);
          } catch (error) {
            // ignore, provider is invalid
          }
        }

        this.isInit = true;
        this.eventEmitter.emit('init');
      } catch (error) {
        console.error(error)
      }
    }
  }

  async awaitForInit() {
    if (this.isInit) {
      return;
    } else {
      return new Promise((resolve, reject) => {
        try {
          this.eventEmitter.on('init', async () => {
            resolve();
          });
        } catch (error) {
          reject(error);
        }
      })
    }
  }

  async login(id = null, jwtToken = null) {
    await this.awaitForInit();

    if (this.provider) {
      return true;
    }

    try {
      const web3authProvider = await this.web3auth.connect({
        verifier: this.web3AuthConfig.jwt.customVerifier,
        verifierId: id,
        idToken: jwtToken,
      });

      if (!web3authProvider) {
        throw new Error('web3authProvider is null');
      }

      this.provider = web3authProvider.provider;

      this.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(this.provider, this.networkConfig);

      return true;
    } catch (error) {
      console.error(error)
      return false;
    }
  }

  async providerIsMetamask() {
    if (this.provider) {
      const web3Provider = new ethers.providers.Web3Provider(this.provider)
      if (web3Provider.connection.url === 'metamask') {
        const signer = web3Provider.getSigner()
        const address = await signer.getAddress();
        return { isMetamask: true, address, signer };
      }
    }

    return { isMetamask: false, address: null, signer: null };
  }

  async getAddress() {
    const { isMetamask, address } = await this.providerIsMetamask();
    if (isMetamask) {
      return address;
    }

    return this.smartAccount.getAddress();
  }

  async getUserInfo() {
    if (this.web3auth) {
      const [userInfo, {idToken}] = await Promise.all([
        this.web3auth.getUserInfo(),
        this.web3auth.authenticateUser(),
      ]);

      return {...userInfo, idToken};
    }
    return null
  }

  async isLoggedIn() {
    await this.awaitForInit();

    return !!this.provider;
  }

  async logout() {
    if (!this.web3auth) {
      console.log('web3auth not initialized yet')
      return
    }
    await this.web3auth.logout();
    this.provider = null
  }
}

module.exports = PolkamarketsSocialLogin;
