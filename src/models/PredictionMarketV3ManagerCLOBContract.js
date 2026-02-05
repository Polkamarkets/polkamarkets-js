const IContract = require("./IContract");

const predictionV3ManagerCLOB = require("../interfaces").predictionV3ManagerCLOB;

class PredictionMarketV3ManagerCLOBContract extends IContract {
  constructor(params) {
    super({ abi: predictionV3ManagerCLOB, ...params });
    this.contractName = "PredictionMarketV3ManagerCLOB";
  }

  async createMarket({
    closesAt,
    question,
    image,
    arbitrator,
    realitioTimeout,
    executionMode,
    feeModule
  }) {
    return await this.__sendTx(
      this.getContract().methods.createMarket({
        closesAt,
        question,
        image,
        arbitrator,
        realitioTimeout,
        executionMode,
        feeModule
      })
    );
  }

  async resolveMarket({ marketId }) {
    return await this.__sendTx(this.getContract().methods.resolveMarket(marketId));
  }

  async adminResolveMarket({ marketId, outcomeId }) {
    return await this.__sendTx(this.getContract().methods.adminResolveMarket(marketId, outcomeId));
  }

  async pauseMarket({ marketId, paused }) {
    return await this.__sendTx(this.getContract().methods.pauseMarket(marketId, paused));
  }

  async getMarket({ marketId }) {
    return await this.getContract().methods.getMarket(marketId).call();
  }

  async getOutcomeTokenIds({ marketId }) {
    return await this.getContract().methods.getOutcomeTokenIds(marketId).call();
  }

  async getMarketCollateral({ marketId }) {
    return await this.getContract().methods.getMarketCollateral(marketId).call();
  }

  async getMarketOutcome({ marketId }) {
    return await this.getContract().methods.getMarketOutcome(marketId).call();
  }

  async getMarketState({ marketId }) {
    return await this.getContract().methods.getMarketState(marketId).call();
  }

  async isMarketPaused({ marketId }) {
    return await this.getContract().methods.isMarketPaused(marketId).call();
  }

  async getMarketExecutionMode({ marketId }) {
    return await this.getContract().methods.getMarketExecutionMode(marketId).call();
  }
}

module.exports = PredictionMarketV3ManagerCLOBContract;
