const IContract = require("./IContract");

const feeModule = require("../interfaces").feeModule;

class FeeModuleContract extends IContract {
  constructor(params) {
    super({ abi: feeModule, ...params });
    this.contractName = "FeeModule";
  }

  async setMarketFees({ marketId, makerFeeBps, takerFeeBps }) {
    return await this.__sendTx(this.getContract().methods.setMarketFees(marketId, makerFeeBps, takerFeeBps));
  }

  async setFeeRecipients({ treasury, distributor, network }) {
    return await this.__sendTx(this.getContract().methods.setFeeRecipients(treasury, distributor, network));
  }

  async setTakerFeeSplit({ treasuryBps, distributorBps, networkBps }) {
    return await this.__sendTx(
      this.getContract().methods.setTakerFeeSplit(treasuryBps, distributorBps, networkBps)
    );
  }

  async matchOrdersWithFees({ maker, makerSig, taker, takerSig }) {
    return await this.__sendTx(this.getContract().methods.matchOrdersWithFees(maker, makerSig, taker, takerSig));
  }
}

module.exports = FeeModuleContract;
