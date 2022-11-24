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

  async resolveMarket({ marketId, outcomeId }) {
    return await this.__sendTx(
      this.getContract().methods.resolveMarket(marketId, outcomeId)
    );
  }

  async claimMultiple({ marketId, users }) {
    return await this.__sendTx(
      this.getContract().methods.claimMultiple(marketId, users)
    );
  }
}

module.exports = PredictionMarketResolverContract;
