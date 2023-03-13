const SafeEventEmitter = require('@metamask/safe-event-emitter').default;
const ethers = require('ethers').ethers;
const SmartAccount = require('@biconomy/smart-account').default;
const ChainId = require('@biconomy/core-types').ChainId;

class PolkamarketsSmartAccount extends SmartAccount {

  static initSmartAccount = async (smartAccount) => {
    smartAccount.initEventEmitter = new SafeEventEmitter();

    if (!smartAccount.isInit) {
      await smartAccount.init();
      smartAccount.isInit = true;

      smartAccount.initEventEmitter.emit('init', true);
    }
  }

  static singleton = (() => {
    let smartAccount;

    function createInstance(provider) {
      const web3Provider = new ethers.providers.Web3Provider(provider);

      // FIXME how to pass this
      const options = {
        debug: false,
        activeNetworkId: ChainId.GOERLI,
        supportedNetworksIds: [ChainId.GOERLI],
        networkConfig: [
          {
            chainId: ChainId.GOERLI,
            // dappAPIKey: 'XXXXX'
            dappAPIKey: ''
          }
        ]
      };

      return new PolkamarketsSmartAccount(web3Provider, options);
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
