const SocialLogin = require('@biconomy/web3-auth').default;

const PolkamarketsSmartAccount = require("./PolkamarketsSmartAccount");
const SafeEventEmitter = require('@metamask/safe-event-emitter').default;
const ethers = require('ethers').ethers;
const { OpenloginAdapter } = require('@web3auth/openlogin-adapter');
const Web3AuthCore = require('@web3auth/core').Web3AuthCore;
const { WALLET_ADAPTERS, CHAIN_NAMESPACES } = require('@web3auth/base');
const { MetamaskAdapter } = require('@web3auth/metamask-adapter');
const { WalletConnectV1Adapter } = require('@web3auth/wallet-connect-v1-adapter');
const { QRCodeModal } = require('@walletconnect/qrcode-modal');

class PolkamarketsSocialLogin extends SocialLogin {

  static initSocialLogin = async (socialLogin, urls, isTestnet, whiteLabelData, networkConfig) => {
    if (!socialLogin.isInit) {
      const whitelistUrls = {};

      const signaturePromises = [];
      urls.forEach(url => signaturePromises.push(socialLogin.whitelistUrl(url)));

      const signatures = await Promise.all(signaturePromises);

      signatures.forEach((signature, index) => whitelistUrls[urls[index]] = signature);

      // convert int to hex
      const chainId = networkConfig.chainId.toString(16);

      const initData = {
        whitelistUrls,
        network: isTestnet ? 'testnet' : 'mainnet',
        chainId: `0x${chainId}`,
      };

      if (whiteLabelData) {
        // yes it's really without the i and with the l misplaced
        initData.whteLableData = whiteLabelData;
      }

      await socialLogin.init(initData);

      if (socialLogin?.provider) {
        socialLogin.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(socialLogin.provider, socialLogin.socialLoginParams.networkConfig);
      }

      socialLogin.eventEmitter.emit('init');
    }
  }

  static singleton = (() => {
    let socialLogin;

    function createInstance(web3AuthConfig, useCustomModal) {
      const instance = new PolkamarketsSocialLogin(web3AuthConfig, useCustomModal);
      instance.eventEmitter = new SafeEventEmitter();
      return instance;
    }

    return {
      getInstance: (socialLoginParams) => {
        if (!socialLogin) {
          socialLogin = createInstance(socialLoginParams.web3AuthConfig, socialLoginParams.useCustomModal);
          socialLogin.socialLoginParams = socialLoginParams;
          this.initSocialLogin(socialLogin, socialLoginParams.urls, socialLoginParams.isTestnet, socialLoginParams.whiteLabelData, socialLoginParams.networkConfig);
        }
        return socialLogin;
      }
    };
  })();

  constructor(web3AuthConfig = null, useCustomModal = false) {
    super();

    this.useCustomModal = useCustomModal;
    this.web3AuthConfig = web3AuthConfig;

    if (this.web3AuthConfig && this.web3AuthConfig.clientId) {
      this.clientId = this.web3AuthConfig.clientId;
    }
  }

  async init(socialLoginDTO) {
    const finalDTO = {
      chainId: '0x1',
      whitelistUrls: {},
      network: 'mainnet',
      whteLableData: this.whiteLabel
    }
    if (socialLoginDTO) {
      if (socialLoginDTO.chainId) finalDTO.chainId = socialLoginDTO.chainId
      if (socialLoginDTO.network) finalDTO.network = socialLoginDTO.network
      if (socialLoginDTO.whitelistUrls) finalDTO.whitelistUrls = socialLoginDTO.whitelistUrls
      if (socialLoginDTO.whteLableData) this.whiteLabel = socialLoginDTO.whteLableData
    }
    try {
      const web3AuthCore = new Web3AuthCore({
        clientId: this.clientId,
        chainConfig: {
          chainNamespace: CHAIN_NAMESPACES.EIP155,
          chainId: finalDTO.chainId
        }
      })

      const loginConfig = {};

      if (this.web3AuthConfig && this.web3AuthConfig.discord) {
        loginConfig.discordcustom = {
          name: 'Discord',
          verifier: this.web3AuthConfig.discord.customVerifier,
          typeOfLogin: 'discord',
          clientId: this.web3AuthConfig.discord.clientId,
        };
      }

      const openloginAdapter = new OpenloginAdapter({
        adapterSettings: {
          clientId: this.clientId,
          network: finalDTO.network,
          uxMode: 'popup',
          loginConfig,
          whiteLabel: {
            name: this.whiteLabel.name,
            logoLight: this.whiteLabel.logo,
            logoDark: this.whiteLabel.logo,
            defaultLanguage: 'en',
            dark: true
          },
          originData: finalDTO.whitelistUrls
        }
      })
      const metamaskAdapter = new MetamaskAdapter({
        clientId: this.clientId
      })
      const wcAdapter = new WalletConnectV1Adapter({
        adapterSettings: {
          qrcodeModal: QRCodeModal
        }
      })

      web3AuthCore.configureAdapter(openloginAdapter)
      web3AuthCore.configureAdapter(metamaskAdapter)
      web3AuthCore.configureAdapter(wcAdapter)
      await web3AuthCore.init()
      this.web3auth = web3AuthCore
      if (web3AuthCore && web3AuthCore.provider) {
        this.provider = web3AuthCore.provider
      }

      this.isInit = true
    } catch (error) {
      console.error(error)
    }
  }

  hideWallet() {
    super.hideWallet();
    this.eventEmitter.emit('finishLogin', false);
  }

  async showWallet() {
    return new Promise((resolve, reject) => {
      try {
        this.eventEmitter.on('finishLogin', (resp) => {
          if (resp && this.provider) {
            this.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(this.provider, this.socialLoginParams.networkConfig);
          }
          resolve(resp)
        });
        super.showWallet();
      } catch (error) {
        reject(error);
      }
    })
  }

  async login() {
    if (this.isInit) {
      if (this.provider) {
        return true;
      }
      if (this.useCustomModal) {
        return false;
      }
      return this.showWallet();
    } else {
      return new Promise((resolve, reject) => {
        try {
          this.eventEmitter.on('init', async () => {
            if (this.provider) {
              resolve(true);
              return
            }
            if (this.useCustomModal) {
              resolve(false)
              return;
            }
            resolve(await this.showWallet());
          });
        } catch (error) {
          reject(error);
        }
      })
    }
  }

  // function called to login withotu showing the biconomy model
  async directLogin(provider, email = null) {
    if (this.isInit) {
      if (this.provider) {
        return true;
      }
      return this.callLoginProvider(provider, email);
    } else {
      return new Promise((resolve, reject) => {
        try {
          this.eventEmitter.on('init', async () => {
            if (this.provider) {
              resolve(true);
            }
            resolve(await this.callLoginProvider(provider, email));
          });
        } catch (error) {
          reject(error);
        }
      })
    }
  }

  async callLoginProvider(provider, email = null) {
    switch (provider) {
      case 'metamask':
        return this.metamaskLogin();
      case 'walletconnect':
        return this.walletConnectLogin();
      case 'email':
        return this.emailLogin(email);
      default:
        return this.socialLogin(provider);
    }
  }

  async afterSocialLogin(resp) {
    let success = true;
    if (resp instanceof Error) {
      success = false;
    }

    this.eventEmitter.emit('finishLogin', success);

    if (success) {
      this.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(this.provider, this.socialLoginParams.networkConfig);
      this.hideWallet();
    }

    return success;
  }

  getConnectToOptions(loginProvider) {
    let connectToOptions = {
      loginProvider,
      extraLoginOptions: {
        scope: 'email'
      }
    }

    if (loginProvider === 'discord' && this.web3AuthConfig && this.web3AuthConfig.discord) {
      connectToOptions = {
        loginProvider: 'discordcustom',
        extraLoginOptions: {
          scope: 'identify email guilds',
        }
      };
    }

    return connectToOptions;
  }

  async biconomySocialLogin(loginProvider) {
    if (!this.web3auth) {
      console.info('web3auth not initialized yet')
      return
    }
    try {

      const web3authProvider = await this.web3auth.connectTo(
        WALLET_ADAPTERS.OPENLOGIN,
        this.getConnectToOptions(loginProvider)
      );

      if (!web3authProvider) {
        console.error('web3authProvider is null')
        return null
      }

      this.provider = web3authProvider
      return web3authProvider
    } catch (error) {
      console.error(error)
      return error
    }
  }

  async socialLogin(loginProvider) {
    const resp = await this.biconomySocialLogin(loginProvider);

    return this.afterSocialLogin(resp);
  }

  async emailLogin(email) {
    const resp = await super.emailLogin(email);

    return this.afterSocialLogin(resp);
  }

  async metamaskLogin() {
    const resp = await super.metamaskLogin();

    return this.afterSocialLogin(resp);
  }

  async walletConnectLogin() {
    const resp = await super.walletConnectLogin();

    return this.afterSocialLogin(resp);
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
    return new Promise(async (resolve, reject) => {
      try {
        const { isMetamask, address } = await this.providerIsMetamask();
        if (isMetamask) {
          resolve(address);
          return;
        }

        if (this.smartAccount.isInit) {
          resolve(this.smartAccount.address);
        } else {
          this.smartAccount.eventEmitter.on('init', (resp) => {
            resolve(this.smartAccount.address);
          });
        }
      } catch (error) {
        reject(error);
      }
    })
  }

  async isLoggedIn() {
    return new Promise(async (resolve, reject) => {
      try {
        if (this.isInit) {
          resolve(!!this.provider);
        } else {
          this.eventEmitter.on('init', (resp) => {
            resolve(!!this.provider);
          });
        }
      } catch (error) {
        reject(error);
      }
    })
  }

}

module.exports = PolkamarketsSocialLogin;
