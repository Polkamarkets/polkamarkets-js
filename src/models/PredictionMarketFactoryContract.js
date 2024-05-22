const IContract = require('./IContract');

const predictionMarketFactory = require("../interfaces").predictionMarketFactory;

const Numbers = require('../utils/Numbers');

class PredictionMarketFactoryContract extends IContract {
  constructor(params) {
    super({ abi: predictionMarketFactory, ...params });
    this.contractName = 'PredictionMarketFactory';
  }

  async getPMManagerById({ id }) {
    const managerAddress = await this.getPMManagerAddressById({ id });

    return await this.getPMManagerByAddress({ managerAddress });
  }

  async getPMManagerAddressById({ id }) {
    return this.getContract().methods.managersAddresses(id).call();
  }

  async getPMManagerByAddress({ managerAddress }) {
    const res = await this.getContract().methods.managers(managerAddress).call();

    return {
      token: res.token,
      active: res.active,
      lockAmount: Numbers.fromDecimalsNumber(res.lockAmount, 18),
      lockUser: res.lockUser,
    }
  }

  async getManagersLength() {
    const index = await this.getContract().methods.managersLength().call();

    return parseInt(index);
  }

  async isPMManagerAdmin({ managerAddress, user }) {
    return await this.params.contract.getContract().methods.isPMManagerAdmin(managerAddress, user).call();
  }

  async lockAmount() {
    const amount = await this.params.contract.getContract().methods.lockAmount().call();
    // TODO: fetch ERC20 decimals
    return Numbers.fromDecimalsNumber(amount, 18);
  }

  async updateLockAmount({ amount }) {
    return await this.__sendTx(
      this.getContract().methods.updateLockAmount(Numbers.toSmartContractDecimals(amount, 18))
    );
  }

  async createPMManager({ lockAmountLand,
    lockAmountIsland,
    PMV3,
    WETH,
    realitioLibraryAddress,
    lockableToken }) {
    return await this.__sendTx(
      this.getContract().methods.createPMManager(
        Numbers.toSmartContractDecimals(lockAmountLand, 18),
        Numbers.toSmartContractDecimals(lockAmountIsland, 18),
        PMV3,
        WETH,
        realitioLibraryAddress,
        lockableToken
      )
    );
  };

  async disablePMManager({ managerAddress }) {
    return await this.__sendTx(
      this.getContract().methods.disablePMManager(managerAddress)
    );
  }

  async enablePMManager({ managerAddress }) {
    return await this.__sendTx(
      this.getContract().methods.enablePMManager(managerAddress)
    );
  }

  async unlockOffsetFromPMManager({ managerAddress }) {
    return await this.__sendTx(
      this.getContract().methods.unlockOffsetFromPMManager(managerAddress)
    );
  }

  async addAdminToPMManager({ managerAddress, user }) {
    return await this.__sendTx(
      this.getContract().methods.addAdminToPMManager(managerAddress, user)
    );
  }

  async removeAdminFromPMManager({ managerAddress, user }) {
    return await this.__sendTx(
      this.getContract().methods.removeAdminFromPMManager(managerAddress, user)
    );
  }
}

module.exports = PredictionMarketFactoryContract;
