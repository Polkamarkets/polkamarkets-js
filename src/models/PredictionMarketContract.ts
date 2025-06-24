import moment from "moment";

import realitioLib from "@reality.eth/reality-eth-lib";
import Numbers from "../utils/Numbers";
import IContract from "./IContract";

const actions: { [key: number]: string } = {
  0: "Buy",
  1: "Sell",
  2: "Add Liquidity",
  3: "Remove Liquidity",
  4: "Claim Winnings",
  5: "Claim Liquidity",
  6: "Claim Fees",
  7: "Claim Voided",
};

class PredictionMarketContract extends IContract {
  constructor(params: any) {
    super({ ...params, abi: params.contract.abi });
    this.contractName = "predictionMarket";
  }

  async getMinimumRequiredBalance(): Promise<number> {
    const requiredBalance = await this.params.contract
      .getContract()
      .methods.requiredBalance()
      .call();
    return Numbers.fromDecimalsNumber(requiredBalance, 18);
  }

  async getFee(): Promise<number> {
    const fee = await this.params.contract.getContract().methods.fee().call();
    return Numbers.fromDecimalsNumber(fee, 18);
  }

  async getMarkets(): Promise<number[]> {
    const res = await this.params.contract
      .getContract()
      .methods.getMarkets()
      .call();
    return res.map((marketId: any) => Number(Numbers.fromHex(marketId)));
  }

  async getMarketData({ marketId }: { marketId: number }): Promise<any> {
    const marketData = await this.params.contract
      .getContract()
      .methods.getMarketData(marketId)
      .call();
    const outcomeIds = await this.__sendTx(
      this.getContract().methods.getMarketOutcomeIds(marketId),
      true,
    );
    return {
      name: "", // TODO: remove; deprecated
      closeDateTime: moment.unix(marketData[1]).format("YYYY-MM-DD HH:mm"),
      state: parseInt(marketData[0]),
      oracleAddress: "0x0000000000000000000000000000000000000000",
      liquidity: Numbers.fromDecimalsNumber(marketData[2], 18),
      outcomeIds: outcomeIds.map((outcomeId: any) =>
        Numbers.fromBigNumberToInteger(outcomeId, 18),
      ),
    };
  }

  async getOutcomeData({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }): Promise<any> {
    const outcomeData = await this.params.contract
      .getContract()
      .methods.getMarketOutcomeData(marketId, outcomeId)
      .call();
    return {
      name: "", // TODO: remove; deprecated
      price: Numbers.fromDecimalsNumber(outcomeData[0], 18),
      shares: Numbers.fromDecimalsNumber(outcomeData[1], 18),
    };
  }

  async getMarketDetails({ marketId }: { marketId: number }): Promise<any> {
    const events = await this.getEvents("MarketCreated", { marketId });
    if (events.length === 0) {
      return {
        name: "",
        category: "",
        subcategory: "",
        image: "",
        outcomes: [],
      };
    }
    const question = realitioLib.populatedJSONForTemplate(
      '{"title": "%s", "type": "single-select", "outcomes": [%s], "category": "%s", "lang": "%s"}',
      events[0].returnValues.question,
    );
    return {
      name: question.title,
      category: question.category.split(";")[0],
      subcategory: question.category.split(";")[1],
      outcomes: question.outcomes,
      image: events[0].returnValues.image,
    };
  }

  async getMarketIdsFromQuestions({
    questions,
  }: {
    questions: string[];
  }): Promise<any[]> {
    const events = await this.getEvents("MarketCreated");
    return events
      .filter((event: any) => questions.includes(event.returnValues.question))
      .map((event: any) => event.returnValues.marketId);
  }

  async getMarketQuestionId({
    marketId,
  }: {
    marketId: number;
  }): Promise<string> {
    const marketAltData = await this.params.contract
      .getContract()
      .methods.getMarketAltData(marketId)
      .call();
    return marketAltData[1];
  }

  getAverageOutcomeBuyPrice({
    events,
    marketId,
    outcomeId,
  }: {
    events: any[];
    marketId: number;
    outcomeId: number;
  }): number {
    const filteredEvents = events.filter((event) => {
      return (
        event.action === "Buy" &&
        event.marketId === marketId &&
        event.outcomeId === outcomeId
      );
    });

    if (filteredEvents.length === 0) return 0;

    const totalShares = filteredEvents
      .map((item) => item.shares)
      .reduce((prev, next) => prev + next);
    const totalAmount = filteredEvents
      .map((item) => item.value)
      .reduce((prev, next) => prev + next);

    return totalAmount / totalShares;
  }

  getAverageAddLiquidityPrice({
    events,
    marketId,
  }: {
    events: any[];
    marketId: number;
  }): number {
    const filteredEvents = events.filter((event) => {
      return event.action === "Add Liquidity" && event.marketId === marketId;
    });

    if (filteredEvents.length === 0) return 0;

    const totalShares = filteredEvents
      .map((item) => item.shares)
      .reduce((prev, next) => prev + next);
    const totalAmount = filteredEvents
      .map((item) => item.value)
      .reduce((prev, next) => prev + next);

    return totalAmount / totalShares;
  }

  async getMyPortfolio() {
    const user = await this.getMyAccount();
    if (!user) return {};
    return await this.getPortfolio({ user });
  }

  async getPortfolio({ user }: { user: string }) {
    const events = await this.getActions({ user });
    const marketIds = [...new Set(events.map((event) => event.marketId))];
    const portfolio: { [key: string]: any } = {};

    for (const marketId of marketIds) {
      const marketData = await this.getMarketData({ marketId });
      const outcomeIds = marketData.outcomeIds;
      const outcomeShares: { [key: string]: any } = {};

      for (const outcomeId of outcomeIds) {
        const shares = await this.__sendTx(
          this.getContract().methods.getShares(marketId, outcomeId, user),
          true,
        );

        if (shares > 0) {
          outcomeShares[outcomeId] = {
            shares: Numbers.fromDecimals(shares, 18),
            price: this.getAverageOutcomeBuyPrice({
              events,
              marketId,
              outcomeId,
            }),
          };
        }
      }

      const liquidityShares = await this.__sendTx(
        this.getContract().methods.getLiquidityShares(marketId, user),
        true,
      );

      const claimStatus = {
        winningsToClaim: false,
        winningsClaimed: false,
      };

      if (marketData.state === 2) {
        // resolved market
        const winnings = await this.__sendTx(
          this.getContract().methods.getWinnings(marketId, user),
          true,
        );
        claimStatus.winningsToClaim = winnings > 0;
        claimStatus.winningsClaimed = events.some((event) => {
          return (
            event.action === "Claim Winnings" && event.marketId === marketId
          );
        });
      }

      portfolio[marketId] = {
        outcomes: outcomeShares,
        liquidity: {
          shares: Numbers.fromDecimals(liquidityShares, 18),
          price: this.getAverageAddLiquidityPrice({ events, marketId }),
        },
        claimStatus,
      };
    }

    return portfolio;
  }

  async getMyMarketShares({ marketId }: { marketId: number }) {
    const user = await this.getMyAccount();
    if (!user) {
      return {};
    }

    const marketData = await this.getMarketData({ marketId });
    const outcomeIds = marketData.outcomeIds;
    const outcomeShares: { [key: string]: any } = {};

    for (const outcomeId of outcomeIds) {
      const shares = await this.__sendTx(
        this.getContract().methods.getShares(marketId, outcomeId, user),
        true,
      );
      outcomeShares[outcomeId] = {
        shares: Numbers.fromDecimals(shares, 18),
      };
    }
    return outcomeShares;
  }

  async getMyActions() {
    const user = await this.getMyAccount();
    if (!user) return [];
    return await this.getActions({ user });
  }

  async getActions({ user }: { user: string }): Promise<any[]> {
    const events = await this.getEvents("MarketAction", { user });
    const parsedEvents = events.map((event) => {
      return {
        action:
          actions[
            Numbers.fromBigNumberToInteger(event.returnValues.action, 18)
          ],
        marketId: Numbers.fromBigNumberToInteger(
          event.returnValues.marketId,
          18,
        ),
        outcomeId: Numbers.fromBigNumberToInteger(
          event.returnValues.outcomeId,
          18,
        ),
        shares: Numbers.fromDecimalsNumber(event.returnValues.shares, 18),
        value: Numbers.fromDecimalsNumber(event.returnValues.value, 18),
        timestamp: Numbers.fromBigNumberToInteger(
          event.returnValues.timestamp,
          18,
        ),
        transactionHash: event.transactionHash,
      };
    });

    // reverse to get chronological order
    return parsedEvents.reverse();
  }

  async getMarketOutcomePrice({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }) {
    const outcomeData = await this.getOutcomeData({ marketId, outcomeId });
    return outcomeData.price;
  }

  async getMarketPrices({ marketId }: { marketId: number }) {
    const marketData = await this.getMarketData({ marketId });
    const { outcomeIds } = marketData;
    const prices: { [key: number]: any } = {};

    for (const outcomeId of outcomeIds) {
      prices[outcomeId] = await this.getMarketOutcomePrice({
        marketId,
        outcomeId,
      });
    }
    return prices;
  }

  async createMarket({
    name,
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    ethAmount,
  }: {
    name: string;
    image: string;
    duration: number;
    oracleAddress: string;
    outcomes: string[];
    category: string;
    ethAmount: number;
  }) {
    const marketResolutionDate = moment().add(duration, "days");
    const question = realitioLib.questionToJSON(
      "single-select",
      name,
      outcomes,
      category,
    );
    const outcomesShares = [
      Numbers.toSmartContractDecimals(ethAmount * 0.5, 18),
      Numbers.toSmartContractDecimals(ethAmount * 0.5, 18),
    ];
    const liquidityAmount = Numbers.toSmartContractDecimals(ethAmount, 18);

    return await this.__sendTx(
      this.getContract().methods.createMarket(
        question,
        image,
        outcomesShares,
        marketResolutionDate.unix(),
        oracleAddress,
      ),
      false,
      liquidityAmount,
    );
  }

  async addLiquidity({
    marketId,
    ethAmount,
  }: {
    marketId: number;
    ethAmount: number;
  }) {
    const amount = Numbers.toSmartContractDecimals(ethAmount, 18);

    return await this.__sendTx(
      this.getContract().methods.addLiquidity(marketId),
      false,
      amount,
    );
  }

  async removeLiquidity({
    marketId,
    shares,
  }: {
    marketId: number;
    shares: number;
  }) {
    const amount = Numbers.toSmartContractDecimals(shares, 18);

    return await this.__sendTx(
      this.getContract().methods.removeLiquidity(marketId, amount),
    );
  }

  async buy({
    marketId,
    outcomeId,
    ethAmount,
    minOutcomeSharesToBuy,
  }: {
    marketId: number;
    outcomeId: number;
    ethAmount: number;
    minOutcomeSharesToBuy: number;
  }) {
    const amount = Numbers.toSmartContractDecimals(ethAmount, 18);
    const minShares = Numbers.toSmartContractDecimals(
      minOutcomeSharesToBuy,
      18,
    );

    return await this.__sendTx(
      this.getContract().methods.buy(marketId, outcomeId, minShares),
      false,
      amount,
    );
  }

  async sell({
    marketId,
    outcomeId,
    ethAmount,
    maxOutcomeSharesToSell,
  }: {
    marketId: number;
    outcomeId: number;
    ethAmount: number;
    maxOutcomeSharesToSell: number;
  }) {
    const amount = Numbers.toSmartContractDecimals(ethAmount, 18);
    const maxShares = Numbers.toSmartContractDecimals(
      maxOutcomeSharesToSell,
      18,
    );

    return await this.__sendTx(
      this.getContract().methods.sell(marketId, outcomeId, amount, maxShares),
    );
  }

  async resolveMarketOutcome({ marketId }: { marketId: number }) {
    return await this.__sendTx(
      this.getContract().methods.resolveMarket(marketId),
    );
  }

  async claimWinnings({ marketId }: { marketId: number }) {
    return await this.__sendTx(
      this.getContract().methods.claimWinnings(marketId),
    );
  }

  async claimVoidedOutcomeShares({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }) {
    return await this.__sendTx(
      this.getContract().methods.claimVoidedOutcomeShares(marketId, outcomeId),
    );
  }

  async claimLiquidity({ marketId }: { marketId: number }) {
    return await this.__sendTx(
      this.getContract().methods.claimLiquidity(marketId),
    );
  }

  async calcBuyAmount({
    marketId,
    outcomeId,
    ethAmount,
  }: {
    marketId: number;
    outcomeId: number;
    ethAmount: number;
  }) {
    const amount = Numbers.toSmartContractDecimals(ethAmount, 18);
    const buyAmount = await this.getContract()
      .methods.calcBuyAmount(marketId, outcomeId, amount)
      .call();
    return Numbers.fromDecimals(buyAmount, 18);
  }

  async calcSellAmount({
    marketId,
    outcomeId,
    ethAmount,
  }: {
    marketId: number;
    outcomeId: number;
    ethAmount: number;
  }) {
    const amount = Numbers.toSmartContractDecimals(ethAmount, 18);
    const sellAmount = await this.getContract()
      .methods.calcSellAmount(marketId, outcomeId, amount)
      .call();
    return Numbers.fromDecimals(sellAmount, 18);
  }

  override async getEvents(eventName: string, filter?: any): Promise<any[]> {
    const events = await super.getEvents(eventName, filter);
    // TODO: parse events
    return events;
  }
}

export default PredictionMarketContract;
