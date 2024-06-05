const predictionV3 = require("../interfaces").predictionV3;
const PredictionMarketV2Contract = require("./PredictionMarketV2Contract");
const PredictionMarketV3QuerierContract = require("./PredictionMarketV3QuerierContract");

const Numbers = require('../utils/Numbers');

class PredictionMarketV3Contract extends PredictionMarketV2Contract {
  constructor(params) {
    super({ abi: predictionV3, ...params });
    this.contractName = 'predictionMarketV3';
    if (params.isSocialLogin) {
      // social login tokens are standard ERC20 tokens
      this.marketDecimals = 18;
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

    const userMarketsData = await this.querier.getUserAllMarketsData({ user });
    const marketIds = Object.keys(userMarketsData).map(Number);
    const decimals = 18;

    const portfolio = marketIds.reduce((obj, marketId) => {
      const marketData = userMarketsData[marketId];

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
    Object.keys(portfolio).forEach(marketId => {
      const item = portfolio[marketId];
      if (item.claimStatus.voidedWinningsToClaim) {
        item.claimStatus.voidedWinningsClaimed =
          events.some(event => event.action === 'Claim Voided' && event.marketId === marketId);
      }
    });

    return portfolio;
  };
}

module.exports = PredictionMarketV3Contract;
