import interfaces from "../interfaces/index";
import Numbers from "../utils/Numbers";
import PredictionMarketV2Contract from "./PredictionMarketV2Contract";
import PredictionMarketV3QuerierContract from "./PredictionMarketV3QuerierContract";

class PredictionMarketV3Contract extends PredictionMarketV2Contract {
  querier?: PredictionMarketV3QuerierContract;
  marketDecimals: any = {};
  defaultDecimals: any;

  constructor(params: any) {
    super({ abi: interfaces.predictionV3, ...params });
    this.contractName = "predictionMarketV3";
    if (params.defaultDecimals) {
      this.defaultDecimals = params.defaultDecimals;
    }
    if (params.querierContractAddress) {
      this.querier = new PredictionMarketV3QuerierContract({
        ...this.params,
        contractAddress: params.querierContractAddress,
      });
    }
    this.marketDecimals = {};
  }

  override async prepareCreateMarketDescription(options: any): Promise<any> {
    return options;
  }

  override async getWETHAddress(): Promise<string> {
    return '';
  }

  async mintAndCreateMarket({
    value,
    name,
    description = "",
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds = [],
    fee = 0,
    treasuryFee = 0,
    treasury = "0x0000000000000000000000000000000000000000",
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress,
  }: any) {
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
      this.getContract().methods.mintAndCreateMarket({
        ...desc,
        realitio: realitioAddress,
        realitioTimeout,
        manager: PM3ManagerAddress,
      }),
    );
  }

  override async createMarket({
    value,
    name,
    description = "",
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds = [],
    fee = 0,
    treasuryFee = 0,
    treasury = "0x0000000000000000000000000000000000000000",
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress,
  }: any) {
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
      this.getContract().methods.createMarket({
        ...desc,
        realitio: realitioAddress,
        realitioTimeout,
        manager: PM3ManagerAddress,
      }),
    );
  }

  override async createMarketWithETH({
    value,
    name,
    description = "",
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    odds = [],
    fee = 0,
    treasuryFee = 0,
    treasury = "0x0000000000000000000000000000000000000000",
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress,
  }: any) {
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
        manager: PM3ManagerAddress,
      }),
      false,
      (desc as any).value,
    );
  }

  async adminResolveMarketOutcome({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }) {
    return await this.__sendTx(
      this.getContract().methods.adminResolveMarketOutcome(marketId, outcomeId),
      false,
    );
  }

  override async getPortfolio({ user }: { user: string }) {
    if (!this.querier) {
      return super.getPortfolio({ user });
    }

    let events: any[] = [];
    try {
      events = await this.getActions({ user });
    } catch (_err) {
      // should be non-blocking
    }

    const chunkSize = 250;
    let userMarketsData: any[];

    // chunking data to avoid out of gas errors
    const marketIndex = await this.getMarketIndex();

    if (marketIndex > chunkSize) {
      const chunks = Math.ceil(marketIndex / chunkSize);
      const promises = Array.from({ length: chunks }, async (_, i) => {
        const marketIds = Array.from(
          { length: chunkSize },
          (_, j) => i * chunkSize + j,
        ).filter((id) => id < marketIndex);
        const chunkMarketData = await this.querier!.getUserMarketsData({
          user,
          marketIds,
        });
        return chunkMarketData;
      });
      const chunksData = await Promise.all(promises);
      // concatenating all arrays into a single one
      userMarketsData = chunksData.reduce(
        (obj, chunk) => [...obj, ...chunk],
        [],
      );
    } else {
      userMarketsData = await this.querier.getUserAllMarketsData({ user });
    }

    const marketIds = Object.keys(userMarketsData).map(Number);
    // fetching all markets decimals asynchrounously
    const marketDecimals = await this.getMarketsERC20Decimals({ marketIds });

    const portfolio = marketIds.reduce((obj: any, marketId: number) => {
      const marketData = userMarketsData[marketId];
      const decimals = (marketDecimals as any)[marketId];

      const outcomeShares = Object.fromEntries(
        marketData.outcomeShares.map((item: any, index: number) => {
          const shares = Numbers.fromDecimalsNumber(item, decimals);
          const price = this.getAverageOutcomeBuyPrice({
            events,
            marketId,
            outcomeId: index,
          });
          const voidedWinningsToClaim =
            marketData.voidedSharesToClaim && shares > 0;
          const voidedWinningsClaimed =
            voidedWinningsToClaim &&
            events.some((event: any) => {
              return (
                event.action === "Claim Voided" &&
                event.marketId === marketId &&
                event.outcomeId === index
              );
            });
          return [
            index,
            {
              shares,
              price,
              voidedWinningsToClaim,
              voidedWinningsClaimed,
            },
          ];
        }),
      );

      const item = {
        liquidity: {
          shares: Numbers.fromDecimalsNumber(
            marketData.liquidityShares,
            decimals,
          ),
          price: this.getAverageAddLiquidityPrice({ events, marketId }),
          fees: Numbers.fromDecimalsNumber(marketData.liquidityFees, decimals),
        },
        outcomes: outcomeShares,
        claimStatus: {
          winningsToClaim: marketData.winningsToClaim,
          winningsClaimed: events.some(
            (event: any) =>
              event.action === "Claim Winnings" && event.marketId === marketId,
          ),
        },
      };

      return {
        ...obj,
        [marketId]: item,
      };
    }, {});

    return portfolio;
  }

  async getMarketIndex() {
    return await this.getContract().methods.marketIndex().call();
  }

  async getMarketsPrices({ marketIds }: { marketIds: number[] }) {
    if (!this.querier) return {};

    const marketsPrices = await this.querier.getMarketsPrices({ marketIds });
    const marketDecimals = await this.getMarketsERC20Decimals({ marketIds });

    return marketsPrices.reduce((obj: any, marketPrice: any, index: number) => {
      const marketId = marketIds[index];
      const decimals = (marketDecimals as any)[marketId];

      const prices = marketPrice.prices.map((price: any) =>
        Numbers.fromDecimalsNumber(price, 18),
      );
      const liquidity = Numbers.fromDecimalsNumber(
        marketPrice.liquidity,
        decimals,
      );

      return {
        ...obj,
        [marketId]: {
          prices,
          liquidity,
        },
      };
    }, {});
  }

  async getMarketsERC20Decimals({ marketIds }: { marketIds: number[] }) {
    // fetching from cache in case
    const localMarketIds = marketIds.filter(
      (marketId) => !!this.marketDecimals[marketId],
    );
    const remoteMarketIds = marketIds.filter(
      (marketId) => !this.marketDecimals[marketId],
    );

    let remoteMarketsDecimals: { [key: number]: any } = {};
    if (remoteMarketIds.length > 0) {
      if (!this.querier) {
        // no querier contract, fetching decimals one by one
        remoteMarketsDecimals = {};
        await Promise.all(
          remoteMarketIds.map(async (marketId) => {
            (remoteMarketsDecimals as any)[marketId] =
              await this.getMarketDecimals({
                marketId,
              });
          }),
        );
      } else {
        const marketsDecimals = await this.querier.getMarketsERC20Decimals({
          marketIds: remoteMarketIds,
        });
        remoteMarketsDecimals = marketsDecimals.reduce(
          (obj: any, decimals: any, index: number) => {
            return {
              ...obj,
              [remoteMarketIds[index]]: decimals,
            };
          },
          {},
        );
      }
    }

    const localMarketsDecimals = localMarketIds.reduce(
      (obj: { [key: number]: any }, marketId) => {
        return {
          ...obj,
          [marketId]: this.marketDecimals[marketId],
        };
      },
      {},
    );

    const allMarketsDecimals = {
      ...localMarketsDecimals,
      ...remoteMarketsDecimals,
    };

    // updating cache
    this.marketDecimals = { ...this.marketDecimals, ...allMarketsDecimals };

    return allMarketsDecimals;
  }

  override async getActions({ user }: { user: string }) {
    const rawEvents = await this.getEvents("MarketAction", { user });
    if (rawEvents.length === 0) return [];
    // getting all markets from events
    const marketIds = [
      ...new Set(rawEvents.map((event) => event.returnValues.marketId)),
    ].map((marketId) => Numbers.fromBigNumberToInteger(marketId, 18));
    // fetching all markets decimals asynchrounously
    const marketDecimals = await this.getMarketsERC20Decimals({ marketIds });

    const events = rawEvents.map((event) => {
      const marketId = Numbers.fromBigNumberToInteger(
        event.returnValues.marketId,
        18,
      );
      const decimals =
        (marketDecimals as any)[marketId] || this.defaultDecimals || 18;

      return {
        action:
          PredictionMarketV3Contract.ACTIONS[
            Numbers.fromBigNumberToInteger(event.returnValues.action, 18)
          ],
        marketId,
        outcomeId: Numbers.fromBigNumberToInteger(
          event.returnValues.outcomeId,
          18,
        ),
        shares: Numbers.fromDecimals(event.returnValues.shares, decimals),
        value: Numbers.fromDecimals(event.returnValues.value, decimals),
        timestamp: Numbers.fromBigNumberToInteger(
          event.returnValues.timestamp,
          18,
        ),
        transactionHash: event.transactionHash,
      };
    });

    return events.reverse();
  }
}

export default PredictionMarketV3Contract;
