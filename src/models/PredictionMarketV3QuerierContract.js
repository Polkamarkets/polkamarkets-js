const IContract = require('./IContract');

const predictionV3Querier = require("../interfaces").predictionV3Querier;

class PredictionMarketV3QuerierContract extends IContract {
  constructor(params) {
    super({ ...params, abi: predictionV3Querier });
    this.contractName = 'PredictionMarketV3Querier';
  }

  async getUserMarketData({ user, marketId }) {
    return await this.params.contract.getContract().methods.getUserMarketData(marketId, user).call();
  }

  async getUserMarketsData({ user, marketIds }) {
    return await this.params.contract.getContract().methods.getUserMarketsData(marketIds, user).call();
  }

  async getUserAllMarketsData({ user }) {
    return await this.params.contract.getContract().methods.getUserAllMarketsData(user).call();
  }
}

module.exports = PredictionMarketV3QuerierContract;
