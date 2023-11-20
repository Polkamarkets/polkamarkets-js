const { SmartAccount } = require('@particle-network/aa');

class PolkamarketsSmartAccount extends SmartAccount {

  static singleton = (() => {
    let smartAccount;

    function createInstance(provider, networkConfig) {
      const options = {
        projectId: networkConfig.particleProjectId,
        clientKey: networkConfig.particleClientKey,
        appId: networkConfig.particleAppId,
        aaOptions: {
          simple: [{
            chainId: networkConfig.chainId,
            version: '1.0.0',
          }],
        },
      };

      const instance = new PolkamarketsSmartAccount(provider, options);
      return instance;
    }

    return {
      getInstance: (provider, networkConfig) => {
        if (!smartAccount) {
          smartAccount = createInstance(provider, networkConfig);
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
