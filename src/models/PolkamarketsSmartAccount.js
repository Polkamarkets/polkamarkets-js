const SafeEventEmitter = require('@metamask/safe-event-emitter').default;
const ethers = require('ethers').ethers;
const SmartAccount = require('@biconomy/smart-account').default;

class PolkamarketsSmartAccount extends SmartAccount {

  static initSmartAccount = async (smartAccount) => {
    if (!smartAccount.isInit) {
      await smartAccount.init();
      smartAccount.isInit = true;

      smartAccount.eventEmitter.emit('init', true);
    }
  }

  static singleton = (() => {
    let smartAccount;

    function createInstance(provider, networkConfig) {
      const web3Provider = new ethers.providers.Web3Provider(provider);

      const options = {
        // debug: true,
        activeNetworkId: networkConfig.chainId,
        supportedNetworksIds: [networkConfig.chainId],
        networkConfig: [networkConfig]
      };

      const instance = new PolkamarketsSmartAccount(web3Provider, options);
      instance.eventEmitter = new SafeEventEmitter();
      return instance;
    }

    return {
      getInstance: (provider, networkConfig) => {
        if (!smartAccount) {
          smartAccount = createInstance(provider, networkConfig);
          this.initSmartAccount(smartAccount);
        }
        return smartAccount;
      },
      clearInstance: () => {
        smartAccount = null;
      }
    };
  })();
}

module.exports = PolkamarketsSmartAccount;
