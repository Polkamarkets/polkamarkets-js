const { default: SocialLogin } = require("@biconomy/web3-auth");
const PolkamarketsSmartAccount = require("./PolkamarketsSmartAccount");
const SafeEventEmitter = require('@metamask/safe-event-emitter').default;

class PolkamarketsSocialLogin extends SocialLogin {

  static initSocialLogin = async (socialLogin, url) => {
    socialLogin.loginEventEmitter = new SafeEventEmitter();

    if (!socialLogin.isInit) {
      url = url || 'http://localhost:3000';
      // get signature that corresponds to your website domains
      const signature1 = await socialLogin.whitelistUrl(url);
      // pass the signatures, you can pass one or many signatures you want to whitelist
      // FIXME pass generic urls
      await socialLogin.init({
        whitelistUrls: {
          [url]: signature1
        },
        network: 'testnet',
        chainId: '0x5',
      });

      if (socialLogin?.provider) {
        socialLogin.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(socialLogin?.provider);
      }
    }
  }

  static singleton = (() => {
    let socialLogin;

    function createInstance() {
      return new PolkamarketsSocialLogin();
    }

    return {
      getInstance: () => {
        if (!socialLogin) {
          socialLogin = createInstance();
          this.initSocialLogin(socialLogin);
        }
        return socialLogin;
      }
    };
  })();

  hideWallet() {
    super.hideWallet();
    this.loginEventEmitter.emit('finishLogin', false);
  }

  async showWallet() {
    return new Promise((resolve, reject) => {
      try {
        this.loginEventEmitter.on('finishLogin', (resp) => {
          if (resp) {
            this.smartAccount = PolkamarketsSmartAccount.singleton.getInstance(this.provider);
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

    this.loginEventEmitter.emit('finishLogin', !!resp);

    this.hideWallet();

    return resp;
  }

  async emailLogin(email) {
    const resp = await super.emailLogin(email);

    this.loginEventEmitter.emit('finishLogin', !!resp);

    this.hideWallet();

    return resp;
  }

  async metamaskLogin() {
    const resp = await super.metamaskLogin();

    this.loginEventEmitter.emit('finishLogin', !!resp);

    this.hideWallet();

    return resp;
  }

  async walletConnectLogin() {
    const resp = await super.walletConnectLogin();

    this.loginEventEmitter.emit('finishLogin', !!resp);

    this.hideWallet();

    return resp;
  }

  async getAddress() {
    return new Promise((resolve, reject) => {
      try {
        console.log('this.smartAccount.isInit:', this.smartAccount.isInit);
        if (this.smartAccount.isInit) {
          resolve(this.smartAccount.address);
        } else {
          this.smartAccount.initEventEmitter.on('init', (resp) => resolve(resp));
        }
      } catch (error) {
        reject(error);
      }
    })
  }

}

module.exports = PolkamarketsSocialLogin;
