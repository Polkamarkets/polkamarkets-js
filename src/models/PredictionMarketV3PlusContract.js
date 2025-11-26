const predictionV3_2 = require("../interfaces").predictionV3_2;
const predictionV3_3 = require("../interfaces").predictionV3_3;
const predictionV3Plus = require("../interfaces").predictionV3Plus;
const PredictionMarketV3Contract = require("./PredictionMarketV3Contract");
const PredictionMarketV3QuerierContract = require("./PredictionMarketV3QuerierContract");

const Numbers = require('../utils/Numbers');

const realitioLib = require('@reality.eth/reality-eth-lib/formatters/question');

class PredictionMarketV3PlusContract extends PredictionMarketV3Contract {
  constructor(params) {
    let abi = predictionV3Plus;
    if (params.contractVersion && params.contractVersion < 3.4) {
      abi = params.contractVersion === 3.3 ? predictionV3_3 : predictionV3_2;
    }
    super({ abi, ...params });
    this.contractName = 'predictionMarketV3';
    if (params.defaultDecimals) {
      this.defaultDecimals = params.defaultDecimals;
    }
    if (params.querierContractAddress) {
      this.querier = new PredictionMarketV3QuerierContract({
        ...this.params,
        contractAddress: params.querierContractAddress
      });
    }
    if (params.contractVersion) {
      this.contractVersion = params.contractVersion;
    }
    this.marketDecimals = {};
  }

  /**
   * @function prepareCreateMarketDescription
   * @description Prepare createMarket function call args
   */
  async prepareCreateMarketDescription({
    value,
    name,
    description = '',
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds = [],
    buyFees = [0, 0, 0],
    sellFees = [0, 0, 0],
    treasury = '0x0000000000000000000000000000000000000000',
    distributor = '0x0000000000000000000000000000000000000000',
  }) {
    const decimals = await this.getTokenDecimals({ contractAddress: token });
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);
    const buyFeesToWei = buyFees.map(fee => Numbers.toSmartContractDecimals(fee, 18));
    const sellFeesToWei = sellFees.map(fee => Numbers.toSmartContractDecimals(fee, 18));
    const title = `${name};${description}`;
    const question = realitioLib.encodeText('single-select', title, outcomes, category);
    let distribution = [];

    if (odds.length > 0) {
      if (odds.length !== outcomes.length) {
        throw new Error('Odds and outcomes must have the same length');
      }

      const oddsSum = odds.reduce((a, b) => a + b, 0);
      // odds must match 100 (0.1 margin)
      if (oddsSum < 99.9 || oddsSum > 100.1) {
        throw new Error('Odds must sum 100');
      }

      distribution = this.calcDistribution({ odds });
    }

    return {
      value: valueToWei,
      closesAt: duration,
      outcomes: outcomes.length,
      token,
      distribution,
      question,
      image,
      arbitrator: oracleAddress,
      buyFees: buyFeesToWei,
      sellFees: sellFeesToWei,
      treasury,
      distributor
    };
  }

  async mintAndCreateMarket({
    value,
    name,
    description = '',
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds = [],
    buyFees = [0, 0, 0],
    sellFees = [0, 0, 0],
    treasury = '0x0000000000000000000000000000000000000000',
    distributor = '0x0000000000000000000000000000000000000000',
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress
  }) {
    const desc = await this.prepareCreateMarketDescription({
      value,
      name,
      description,
      image,
      duration,
      oracleAddress,
      outcomes,
      category,
      token,
      odds,
      buyFees,
      sellFees,
      treasury,
      distributor,
    });

    return await this.__sendTx(this.getContract().methods.mintAndCreateMarket({
      ...desc,
      realitio: realitioAddress,
      realitioTimeout,
      manager: PM3ManagerAddress
    }));
  };

  async createMarket ({
    value,
    name,
    description = '',
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds = [],
    buyFees = [0, 0, 0],
    sellFees = [0, 0, 0],
    treasury = '0x0000000000000000000000000000000000000000',
    distributor = '0x0000000000000000000000000000000000000000',
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress
  }) {
    const desc = await this.prepareCreateMarketDescription({
      value,
      name,
      description,
      image,
      duration,
      oracleAddress,
      outcomes,
      category,
      token,
      odds,
      buyFees,
      sellFees,
      treasury,
      distributor,
    });

    return await this.__sendTx(this.getContract().methods.createMarket({
      ...desc,
      realitio: realitioAddress,
      realitioTimeout,
      manager: PM3ManagerAddress
    }));
  };

  async adminPauseMarket({marketId}) {
    return await this.__sendTx(
      this.getContract().methods.adminPauseMarket(marketId),
      false,
    );
  };

  async adminUnpauseMarket({marketId}) {
    return await this.__sendTx(
      this.getContract().methods.adminUnpauseMarket(marketId),
      false,
    );
  };

  async getMarketFees({marketId}) {
    return (await this.getContract().methods.getMarketFees(marketId).call());
  }

  async referralBuy({ marketId, outcomeId, value, minOutcomeSharesToBuy, code }) {
    const decimals = await this.getMarketDecimals({marketId});
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);
    minOutcomeSharesToBuy = Numbers.toSmartContractDecimals(minOutcomeSharesToBuy, decimals);

    return await this.__sendTx(
      this.getContract().methods.referralBuy(marketId, outcomeId, minOutcomeSharesToBuy, valueToWei, code),
    );
  };

  async referralSell({marketId, outcomeId, value, maxOutcomeSharesToSell, code}) {
    const decimals = await this.getMarketDecimals({marketId});
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);
    maxOutcomeSharesToSell = Numbers.toSmartContractDecimals(maxOutcomeSharesToSell, decimals);

    return await this.__sendTx(
      this.getContract().methods.referralSell(marketId, outcomeId, valueToWei, maxOutcomeSharesToSell, code),
    );
  };

  async addLiquidity({marketId, value, wrapped = false, minSharesIn = null}) {
    if (!this.contractVersion || this.contractVersion < 3.4) {
      return super.addLiquidity({marketId, value, wrapped});
    }

    const decimals = await this.getMarketDecimals({marketId});
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);
    const minSharesInToWei = minSharesIn === null ? 0 : Numbers.toSmartContractDecimals(minSharesIn, decimals);

    return await this.__sendTx(
      this.getContract().methods.addLiquidity(marketId, valueToWei, minSharesInToWei)
    );
  };

  async removeLiquidity({marketId, shares, wrapped = false, minValueOut = null}) {
    if (!this.contractVersion || this.contractVersion < 3.4) {
      return super.removeLiquidity({marketId, shares, wrapped});
    }

    const decimals = await this.getMarketDecimals({marketId});
    const sharesToWei = Numbers.toSmartContractDecimals(shares, decimals);
    const minValueOutToWei = minValueOut === null ? sharesToWei : Numbers.toSmartContractDecimals(minValueOut, decimals);

    return await this.__sendTx(
      this.getContract().methods.removeLiquidity(marketId, sharesToWei, minValueOutToWei)
    );
  }
}

module.exports = PredictionMarketV3PlusContract;
