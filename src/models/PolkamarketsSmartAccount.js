const { SmartAccount } = require('@particle-network/aa');
const ethers = require('ethers').ethers;

class PolkamarketsSmartAccount extends SmartAccount {

  static singleton = (() => {
    let smartAccount;

    function createInstance(provider, networkConfig) {
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
      instance.setSmartAccountContract({ name: 'SIMPLE', version: '1.0.0' })
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

    return super.getAddress();
  }
}

module.exports = PolkamarketsSmartAccount;
