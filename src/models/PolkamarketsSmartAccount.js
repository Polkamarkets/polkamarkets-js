const { SmartAccount } = require('@particle-network/aa');
const ethers = require('ethers').ethers;

class PolkamarketsSmartAccount extends SmartAccount {

  static singleton = (() => {
    let smartAccount;

    function createInstance(provider, networkConfig, isConnectedWallet) {
      const options = {
        projectId: networkConfig.particleProjectId,
        clientKey: networkConfig.particleClientKey,
        appId: networkConfig.particleAppId,
        aaOptions: {
          accountContracts: {
            SIMPLE: [{
              version: '1.0.0',
              chainIds: [networkConfig.chainId],
            }],
          }
        },
      };

      const instance = new PolkamarketsSmartAccount(provider, options);
      instance.networkConfig = networkConfig;
      instance.provider = provider
      instance.isConnectedWallet = isConnectedWallet
      instance.setSmartAccountContract({ name: 'SIMPLE', version: '1.0.0' })
      return instance;
    }

    return {
      getInstance: (provider, networkConfig, isConnectedWallet) => {
        if (!smartAccount) {
          smartAccount = createInstance(provider, networkConfig, isConnectedWallet);
        }
        return smartAccount;
      },
      clearInstance: () => {
        smartAccount = null;
      }
    };
  })();

  async providerIsConnectedWallet() {
    if (this.isConnectedWallet) {
      const web3Provider = new ethers.providers.Web3Provider(this.provider)
      const signer = web3Provider.getSigner()
      const address = await signer.getAddress();

      return { isConnectedWallet: true, address, signer };
    }

    return { isConnectedWallet: false, address: null, signer: null };
  }

  async getAddress() {
    const { isConnectedWallet, address } = await this.providerIsConnectedWallet();
    if (isConnectedWallet) {
      return address;
    }

    return super.getAddress();
  }
}

module.exports = PolkamarketsSmartAccount;
