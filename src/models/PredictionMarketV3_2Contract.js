const predictionV3 = require("../interfaces").predictionV3_2;
const PredictionMarketV3Contract = require("./PredictionMarketV3Contract");
const PredictionMarketV3QuerierContract = require("./PredictionMarketV3QuerierContract");

const Numbers = require('../utils/Numbers');

const realitioLib = require('@reality.eth/reality-eth-lib/formatters/question');

class PredictionMarketV3_2Contract extends PredictionMarketV3Contract {
  constructor(params) {
    super({ abi: predictionV3, ...params });
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
      buyFees,
      sellFees,
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

  async createMarketWithETH ({
    value,
    name,
    description = '',
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    odds = [],
    buyFees = [0, 0, 0],
    sellFees = [0, 0, 0],
    treasury = '0x0000000000000000000000000000000000000000',
    distributor = '0x0000000000000000000000000000000000000000',
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress
  }) {
    const token = await this.getWETHAddress();
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

    return await this.__sendTx(
        this.getContract().methods.createMarketWithETH({
          ...desc,
          realitio: realitioAddress,
          realitioTimeout,
          manager: PM3ManagerAddress
        }),
        false,
        desc.value
      );
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
}

module.exports = PredictionMarketV3_2Contract;
