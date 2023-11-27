
const PolkamarketsSmartAccount = require("./PolkamarketsSmartAccount");
const SafeEventEmitter = require('@metamask/safe-event-emitter').default;
const ethers = require('ethers').ethers;

const { EthereumPrivateKeyProvider } = require('@web3auth/ethereum-provider');
const { OpenloginAdapter } = require('@web3auth/openlogin-adapter');
const Web3AuthNoModal = require('@web3auth/no-modal').Web3AuthNoModal;
const { WALLET_ADAPTERS, CHAIN_NAMESPACES } = require('@web3auth/base');
const { MetamaskAdapter } = require('@web3auth/metamask-adapter');

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

        const loginConfig = {};

        if (this.web3AuthConfig && this.web3AuthConfig.jwt) {
          loginConfig.jwt = {
            verifier: this.web3AuthConfig.jwt.customVerifier, // name of the verifier created on Web3Auth Dashboard
            typeOfLogin: 'jwt',
            clientId: this.web3AuthConfig.clientId,
          };
        }

        if (this.web3AuthConfig && this.web3AuthConfig.discord) {
          loginConfig.discordcustom = {
            name: 'Discord',
            verifier: this.web3AuthConfig.discord.customVerifier,
            typeOfLogin: 'discord',
            clientId: this.web3AuthConfig.discord.clientId,
          };
        }

        const privateKeyProvider = new EthereumPrivateKeyProvider({
          config: { chainConfig },
        });

        const openloginAdapter = new OpenloginAdapter({
          adapterSettings: {
            clientId: this.web3AuthConfig.clientId,
            network: this.isTestnet ? 'testnet' : 'cyan',
            uxMode: 'redirect',
            loginConfig,
            whiteLabel: {
              name: this.whiteLabelData.name,
              logoLight: this.whiteLabelData.logo,
              logoDark: this.whiteLabelData.logo,
              defaultLanguage: 'en',
              dark: true
            },
            redirectUrl: typeof window !== 'undefined' ? window.location.href : '',
          },
          privateKeyProvider
        })

        const metamaskAdapter = new MetamaskAdapter({
          clientId: this.web3AuthConfig.clientId
        })

        const web3AuthCore = new Web3AuthNoModal({
          clientId: this.web3AuthConfig.clientId,
          chainConfig
        });

        web3AuthCore.configureAdapter(openloginAdapter)
        web3AuthCore.configureAdapter(metamaskAdapter)

        await web3AuthCore.init();
        this.web3auth = web3AuthCore;

        if (web3AuthCore && web3AuthCore.provider) {
          try {
            await this.web3auth.getUserInfo()
            this.provider = web3AuthCore.provider;
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

  async login(loginProvider, email = null, jwtToken = null) {
    await this.awaitForInit();

    if (this.provider) {
      return true;
    }

    try {
      const web3authProvider = await this.web3auth.connectTo(
        this.getWalletAdapter(loginProvider),
        this.getConnectToOptions(loginProvider, { email, jwtToken })
      );

      if (!web3authProvider) {
        throw new Error('web3authProvider is null');
      }

      this.provider = web3authProvider;

      this.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(this.provider, this.networkConfig);

      return true;
    } catch (error) {
      console.error(error)
      return false;
    }
  }

  getWalletAdapter(loginProvider) {
    switch (loginProvider) {
      case 'metamask':
        return WALLET_ADAPTERS.METAMASK;
      default:
        return WALLET_ADAPTERS.OPENLOGIN;
    }
  }

  getConnectToOptions(loginProvider, loginData = null) {
    switch (loginProvider) {
      case 'metamask':
        return {};
      case 'jwt':
        return {
          loginProvider: 'jwt',
          extraLoginOptions: {
            id_token: loginData.jwtToken,
            verifierIdField: 'sub',
          },
        }
      case 'email':
        return {
          loginProvider: 'email_passwordless',
          login_hint: loginData.email,
        };
      default:
        let connectToOptions = {
          loginProvider,
          mfaLevel: 'none',
          sessionTime: 86400 * 7,
          extraLoginOptions: {
            scope: 'email'
          }
        }
    
        if (loginProvider === 'discord' && this.web3AuthConfig && this.web3AuthConfig.discord) {
          connectToOptions = {
            loginProvider: 'discordcustom',
            mfaLevel: 'none',
            sessionTime: 86400 * 7,
            extraLoginOptions: {
              scope: 'identify email guilds',
            }
          };
        }
        return connectToOptions;
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
      const userInfo = await this.web3auth.getUserInfo()
      this.userInfo = userInfo
      return userInfo
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
    await this.web3auth.logout()
    this.web3auth.clearCache()
    this.provider = null
  }
}

module.exports = PolkamarketsSocialLogin;
