const { default: SocialLogin } = require("@biconomy/web3-auth");
const PolkamarketsSmartAccount = require("./PolkamarketsSmartAccount");
const SafeEventEmitter = require('@metamask/safe-event-emitter').default;

class PolkamarketsSocialLogin extends SocialLogin {

  static initSocialLogin = async (socialLogin, urls, isTestnet) => {
    if (!socialLogin.isInit) {
      const whitelistUrls = {};

      const signaturePromises = [];
      urls.forEach(url => signaturePromises.push(socialLogin.whitelistUrl(url)));

      const signatures = await Promise.all(signaturePromises);

      signatures.forEach((signature, index) => whitelistUrls[urls[index]] = signature);

      await socialLogin.init({
        whitelistUrls,
        network: isTestnet ? 'testnet' : 'mainnet',
      });

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
          this.initSocialLogin(socialLogin, socialLoginParams.urls, socialLoginParams.isTestnet);
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
          if (resp) {
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

  async getAddress() {
    return new Promise((resolve, reject) => {
      try {
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
    return new Promise((resolve, reject) => {
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
