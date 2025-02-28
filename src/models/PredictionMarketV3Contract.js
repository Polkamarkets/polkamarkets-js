const predictionV3 = require("../interfaces").predictionV3;
const PredictionMarketV2Contract = require("./PredictionMarketV2Contract");
const PredictionMarketV3QuerierContract = require("./PredictionMarketV3QuerierContract");

const Numbers = require('../utils/Numbers');

class PredictionMarketV3Contract extends PredictionMarketV2Contract {
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
  }

  async mintAndCreateMarket ({
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
    fee = 0,
    treasuryFee = 0,
    treasury = '0x0000000000000000000000000000000000000000',
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
      fee,
      treasuryFee,
      treasury,
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
    fee = 0,
    treasuryFee = 0,
    treasury = '0x0000000000000000000000000000000000000000',
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
      fee,
      treasuryFee,
      treasury,
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
    fee = 0,
    treasuryFee = 0,
    treasury = '0x0000000000000000000000000000000000000000',
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
      fee,
      treasuryFee,
      treasury,
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

  async adminResolveMarketOutcome({marketId, outcomeId}) {
    return await this.__sendTx(
      this.getContract().methods.adminResolveMarketOutcome(marketId, outcomeId),
      false,
    );
  };

  async getPortfolio({ user }) {
    if (!this.querier) {
      return super.getPortfolio({ user });
    }

    let events = [];
    try {
      events = await this.getActions({ user });
    } catch (err) {
      // should be non-blocking
    }

    const chunkSize = 250;
    let userMarketsData;

    // chunking data to avoid out of gas errors
    const marketIndex = await this.getMarketIndex();

    if (marketIndex > chunkSize) {
      const chunks = Math.ceil(marketIndex / chunkSize);
      const promises = Array.from({ length: chunks }, async (_, i) => {
        const marketIds = Array.from({ length: chunkSize }, (_, j) => i * chunkSize + j).filter(id => id < marketIndex);
        const chunkMarketData = await this.querier.getUserMarketsData({ user, marketIds });
        return chunkMarketData;
      });
      const chunksData = await Promise.all(promises);
      // concatenating all arrays into a single one
      userMarketsData = chunksData.reduce((obj, chunk) => [...obj, ...chunk], []);
    } else {
      userMarketsData = await this.querier.getUserAllMarketsData({ user });
    }

    const marketIds = Object.keys(userMarketsData).map(Number);
    // fetching all markets decimals asynchrounously
    const marketDecimals = await this.getMarketsERC20Decimals({ marketIds });

    const portfolio = marketIds.reduce((obj, marketId) => {
      const marketData = userMarketsData[marketId];
      const decimals = marketDecimals[marketId];

      const outcomeShares = Object.fromEntries(marketData.outcomeShares.map((item, index) => {
        return [
          index,
          {
            shares: Numbers.fromDecimalsNumber(item, decimals),
            price: this.getAverageOutcomeBuyPrice({events, marketId, outcomeId: index})
          }
        ];
      }));

      const item = {
        liquidity: {
          shares: Numbers.fromDecimalsNumber(marketData.liquidityShares, decimals),
          price: this.getAverageAddLiquidityPrice({events, marketId}),
        },
        outcomes: outcomeShares,
        claimStatus: {
          winningsToClaim: marketData.winningsToClaim,
          winningsClaimed: marketData.winningsClaimed,
          liquidityToClaim: marketData.liquidityToClaim,
          liquidityClaimed: marketData.liquidityClaimed,
          voidedWinningsToClaim: marketData.voidedSharesToClaim,
          voidedWinningsClaimed: false,
          liquidityFees: 0 // discontinued
        }
      };

      return {
        ...obj,
        [marketId]: item
      };
    }, {});

    // calculationg voidedWinningsClaimed, if there's any voidedWinningsToClaim
    Object.keys(portfolio).map(Number).forEach(marketId => {
      const item = portfolio[marketId];
      if (item.claimStatus.voidedWinningsToClaim) {
        item.claimStatus.voidedWinningsClaimed =
          events.some(event => event.action === 'Claim Voided' && event.marketId === marketId);
      }
    });

    return portfolio;
  };

  async adminResolveMarketOutcome({marketId, outcomeId}) {
    return await this.__sendTx(
      this.getContract().methods.adminResolveMarketOutcome(marketId, outcomeId),
      false,
    );
  }

  async getMarketIndex() {
    return parseInt(await this.getContract().methods.marketIndex().call());
  }

  async getMarketsPrices({ marketIds }) {
    if (!this.querier) {
      const marketPrices = await Promise.all(marketIds.map(marketId => this.getMarketPrices({ marketId })));

      return Object.fromEntries(marketIds.map((marketId, index) => [marketId, marketPrices[index]]));
    }

    const chunkSize = 250;
    let marketsPrices;

    // chunking data to avoid out of gas errors
    if (marketIds.length > chunkSize) {
      const chunks = Math.ceil(marketIds.length / chunkSize);
      const promises = Array.from({ length: chunks }, async (_, i) => {
        const chunkMarketIds = marketIds.slice(i * chunkSize, i * chunkSize + chunkSize);
        const chunkMarketPrices = await this.querier.getMarketsPrices({ marketIds: chunkMarketIds });
        return chunkMarketPrices;
      });
      const chunksData = await Promise.all(promises);
      // concatenating all arrays into a single one
      marketsPrices = chunksData.reduce((obj, chunk) => [...obj, ...chunk], []);
    } else {
      marketsPrices = await this.querier.getMarketsPrices({ marketIds });
    }

    // fetching all markets decimals asynchrounously
    const marketDecimals = await this.getMarketsERC20Decimals({ marketIds });

    return marketIds.reduce((obj, marketId) => {
      const index = marketIds.indexOf(marketId);
      const marketData = marketsPrices[index];
      const decimals = marketDecimals[marketId];

      return {
        ...obj,
        [marketId]: {
          liquidity: Numbers.fromDecimalsNumber(marketData.liquidityPrice, decimals),
          outcomes: Object.fromEntries(marketData.outcomePrices.map((item, index) => {
            return [index, Numbers.fromDecimalsNumber(item, decimals)];
          }))
        }
      };
    });
  }

  async getMarketsERC20Decimals({ marketIds }) {
    if (!this.querier) {
      let marketERC20Decimals = {};

      for(let i = 0; i < marketIds.length; i++) {
        const marketId = marketIds[i];
        const decimals = await this.getMarketERC20Decimals({ marketId });
        marketERC20Decimals[marketId] = decimals;
      }
      return marketERC20Decimals;
    }

    const chunkSize = 250;
    let marketsDecimals;

    // chunking data to avoid out of gas errors
    if (marketIds.length > chunkSize) {
      const chunks = Math.ceil(marketIds.length / chunkSize);
      const promises = Array.from({ length: chunks }, async (_, i) => {
        const chunkMarketIds = marketIds.slice(i * chunkSize, i * chunkSize + chunkSize);
        const chunkMarketDecimals = await this.querier.getMarketsERC20Decimals({ marketIds: chunkMarketIds });
        return chunkMarketDecimals;
      });
      const chunksData = await Promise.all(promises);
      // concatenating all arrays into a single one
      marketsDecimals = chunksData.reduce((obj, chunk) => [...obj, ...chunk], []);
    } else {
      marketsDecimals = await this.querier.getMarketsERC20Decimals({ marketIds });
    }

    return Object.fromEntries(marketIds.map((marketId, index) => [marketId, marketsDecimals[index]]));
  }

  async getActions({ user }) {
    if (!this.querier) {
      return super.getActions({ user });
    }

    const events = await this.getEvents('MarketActionTx', { user });

    // fetching decimals for each market (unique)
    const marketIds = events.map(event => event.returnValues.marketId).filter((x, i, a) => a.indexOf(x) == i);
    const marketDecimals = await this.getMarketsERC20Decimals({ marketIds });

    // filtering by address
    return events.map(event => {
      const decimals = marketDecimals[event.returnValues.marketId];

      return {
        action: actions[Numbers.fromBigNumberToInteger(event.returnValues.action, 18)],
        marketId: Numbers.fromBigNumberToInteger(event.returnValues.marketId, 18),
        outcomeId: Numbers.fromBigNumberToInteger(event.returnValues.outcomeId, 18),
        shares: Numbers.fromDecimalsNumber(event.returnValues.shares, decimals),
        value: Numbers.fromDecimalsNumber(event.returnValues.value, decimals),
        timestamp: Numbers.fromBigNumberToInteger(event.returnValues.timestamp, 18),
        transactionHash: event.transactionHash,
      }
    });
  }
}

module.exports = PredictionMarketV3Contract;
