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

  async getMarketUsersData({ marketId, users }) {
    return await this.params.contract.getContract().methods.getMarketUsersData(marketId, users).call();
  }

  async getMarketPrices({ marketId }) {
    return await this.params.contract.getContract().methods.getMarketPrices(marketId).call();
  }

  async getMarketsPrices({ marketIds }) {
    return await this.params.contract.getContract().methods.getMarketsPrices(marketIds).call();
  }

  async getMarketERC20Decimals({ marketId }) {
    return await this.params.contract.getContract().methods.getMarketERC20Decimals(marketId).call();
  }

  async getMarketsERC20Decimals({ marketIds }) {
    return await this.params.contract.getContract().methods.getMarketsERC20Decimals(marketIds).call();
  }
}

module.exports = PredictionMarketV3QuerierContract;
