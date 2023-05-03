const { default: SocialLogin } = require("@biconomy/web3-auth");
const PolkamarketsSmartAccount = require("./PolkamarketsSmartAccount");
const SafeEventEmitter = require('@metamask/safe-event-emitter').default;
const ethers = require('ethers').ethers;

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

    function createInstance() {
      const instance = new PolkamarketsSocialLogin();
      instance.eventEmitter = new SafeEventEmitter();
      return instance;
    }

    return {
      getInstance: (socialLoginParams) => {
        if (!socialLogin) {
          socialLogin = createInstance();
          socialLogin.socialLoginParams = socialLoginParams;
          this.initSocialLogin(socialLogin, socialLoginParams.urls, socialLoginParams.isTestnet, socialLoginParams.whiteLabelData, socialLoginParams.networkConfig);
        }
        return socialLogin;
      }
    };
  })();

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
      return this.showWallet();
    } else {
      return new Promise((resolve, reject) => {
        try {
          this.eventEmitter.on('init', async () => {
            if (this.provider) {
              resolve(true);
              return
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


  async socialLogin(loginProvider) {
    const resp = await super.socialLogin(loginProvider);

    this.eventEmitter.emit('finishLogin', !!resp);

    this.hideWallet();

    return resp;
  }

  async emailLogin(email) {
    const resp = await super.emailLogin(email);

    this.eventEmitter.emit('finishLogin', !!resp);

    this.hideWallet();

    return resp;
  }

  async metamaskLogin() {
    const resp = await super.metamaskLogin();

    this.eventEmitter.emit('finishLogin', !!resp);

    this.hideWallet();

    return resp;
  }

  async walletConnectLogin() {
    const resp = await super.walletConnectLogin();

    this.eventEmitter.emit('finishLogin', !!resp);

    this.hideWallet();

    return resp;
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
