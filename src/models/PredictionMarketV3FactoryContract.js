const IContract = require('./IContract');

const predictionMarketFactory = require("../interfaces").predictionMarketV3Factory;

const Numbers = require('../utils/Numbers');

class PredictionMarketV3FactoryContract extends IContract {
  constructor(params) {
    super({ abi: predictionMarketFactory, ...params });
    this.contractName = 'PredictionMarketFactory';
  }

  async getPMControllerById({ id }) {
    const controllerAddress = await this.getPMControllerAddressById({ id });

    return await this.getPMControllerByAddress({ controllerAddress });
  }

  async getPMControllerAddressById({ id }) {
    return this.getContract().methods.controllersAddresses(id).call();
  }

  async getPMControllerByAddress({ controllerAddress }) {
    const res = await this.getContract().methods.controllers(controllerAddress).call();

    return {
      active: res.active,
      lockAmount: Numbers.fromDecimalsNumber(res.lockAmount, 18),
      lockUser: res.lockUser,
    }
  }

  async getControllersLength() {
    const index = await this.getContract().methods.controllersLength().call();

    return parseInt(index);
  }

  async isPMControllerAdmin({ controllerAddress, user }) {
    return await this.params.contract.getContract().methods.isPMControllerAdmin(controllerAddress, user).call();
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

  async createPMController({
    PMV3,
    WETH,
    realitioLibraryAddress
  }) {
    return await this.__sendTx(
      this.getContract().methods.createPMController(
        PMV3,
        WETH,
        realitioLibraryAddress,
      )
    );
  };

  async disablePMController({ controllerAddress }) {
    return await this.__sendTx(
      this.getContract().methods.disablePMController(controllerAddress)
    );
  }

  async enablePMController({ controllerAddress }) {
    return await this.__sendTx(
      this.getContract().methods.enablePMController(controllerAddress)
    );
  }

  async unlockOffsetFromPMController({ controllerAddress }) {
    return await this.__sendTx(
      this.getContract().methods.unlockOffsetFromPMController(controllerAddress)
    );
  }

  async addAdminToPMController({ controllerAddress, user }) {
    return await this.__sendTx(
      this.getContract().methods.addAdminToPMController(controllerAddress, user)
    );
  }

  async removeAdminFromPMController({ controllerAddress, user }) {
    return await this.__sendTx(
      this.getContract().methods.removeAdminFromPMController(controllerAddress, user)
    );
  }
}

module.exports = PredictionMarketV3FactoryContract;
