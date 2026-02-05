const IContract = require("./IContract");

const conditionalTokens = require("../interfaces").conditionalTokens;

class ConditionalTokensContract extends IContract {
  constructor(params) {
    super({ abi: conditionalTokens, ...params });
    this.contractName = "ConditionalTokens";
  }

  async splitPosition({ marketId, amount }) {
    return await this.__sendTx(this.getContract().methods.splitPosition(marketId, amount));
  }

  async mergePositions({ marketId, amount }) {
    return await this.__sendTx(this.getContract().methods.mergePositions(marketId, amount));
  }

  async redeemPositions({ marketId }) {
    return await this.__sendTx(this.getContract().methods.redeemPositions(marketId));
  }

  async setExchange({ exchange }) {
    return await this.__sendTx(this.getContract().methods.setExchange(exchange));
  }

  async getTokenId({ marketId, outcome }) {
    return await this.getContract().methods.getTokenId(marketId, outcome).call();
  }
}

module.exports = ConditionalTokensContract;
