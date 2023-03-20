const SafeEventEmitter = require('@metamask/safe-event-emitter').default;
const ethers = require('ethers').ethers;
const SmartAccount = require('@biconomy/smart-account').default;
const ChainId = require('@biconomy/core-types').ChainId;

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

    function createInstance(provider) {
      const web3Provider = new ethers.providers.Web3Provider(provider);
      // FIXME how to pass this
      const options = {
        debug: true,
        activeNetworkId: ChainId.GOERLI,
        supportedNetworksIds: [ChainId.GOERLI],
        networkConfig: [
          {
            chainId: ChainId.GOERLI,
            dappAPIKey: '',
          }
        ]
      };

      const instance = new PolkamarketsSmartAccount(web3Provider, options);
      instance.eventEmitter = new SafeEventEmitter();
      return instance;
    }

    return {
      getInstance: (provider) => {
        if (!smartAccount) {
          smartAccount = createInstance(provider);
          this.initSmartAccount(smartAccount);
        }
        return smartAccount;
      }
    };
  })();
}

module.exports = PolkamarketsSmartAccount;
