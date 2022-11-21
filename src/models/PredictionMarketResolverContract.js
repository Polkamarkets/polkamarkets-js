const IContract = require('./IContract');
const predictionResolver = require("../interfaces").predictionResolver;

/**
 * Fantasy ERC20 Contract Object
 * @constructor predictionResolverContract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class PredictionMarketResolverContract extends IContract {
  constructor(params) {
    super({ ...params, abi: predictionResolver });
    this.contractName = 'predictionMarketResolver';
  }

  async hasUserClaimedMarket({ marketId, user }) {
    return await this.getContract().methods.hasUserClaimedMarket(marketId, user).call();
  }

  async getMarketsResolved() {
    const events = await this.getEvents('MarketResolved');

    return events.map(event => ({
      marketId: event.returnValues.marketId,
      outcomeId: event.returnValues.outcomeId,
    }));
  }
}

module.exports = PredictionMarketResolverContract;
