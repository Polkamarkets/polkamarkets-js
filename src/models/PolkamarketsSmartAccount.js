const { SmartAccount } = require('@particle-network/aa');
const ethers = require('ethers').ethers;

const { ENTRYPOINT_ADDRESS_V06, providerToSmartAccountSigner } = require('permissionless');
const { createPublicClient, http } = require('viem');
const { signerToSimpleSmartAccount } = require('permissionless/accounts');

class PolkamarketsSmartAccount {

  static PIMLICO_FACTORY_ADDRESS = '0x9406Cc6185a346906296840746125a0E44976454';

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

      const instance = new PolkamarketsSmartAccount();
      instance.networkConfig = networkConfig;
      instance.provider = provider
      instance.isConnectedWallet = isConnectedWallet
      if (!networkConfig.usePimlico) {
        instance.smartAccount = new SmartAccount(provider, options);
        instance.smartAccount.setSmartAccountContract({ name: 'SIMPLE', version: '1.0.0' })
      }
      return instance;
    }

    return {
      getInstance: (provider, networkConfig, isConnectedWallet) => {
        if (!smartAccount) {
          smartAccount = createInstance(provider, networkConfig, isConnectedWallet);
        }
        return smartAccount;
      },
      getInstanceIfExists: () => smartAccount,
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

    if (this.networkConfig.usePimlico) {
      const publicClient = createPublicClient({
        chain: this.networkConfig.viemChain,
        transport: http(this.networkConfig.rpcUrl)
      });

      const smartAccountSigner = await providerToSmartAccountSigner(this.provider);

      const smartAccount = await signerToSimpleSmartAccount(publicClient, {
        signer: smartAccountSigner,
        factoryAddress: PIMLICO_FACTORY_ADDRESS,
        entryPoint: ENTRYPOINT_ADDRESS_V06,
      })

      return smartAccount.address;
    }
    return this.smartAccount.getAddress();
  }
}

module.exports = PolkamarketsSmartAccount;
