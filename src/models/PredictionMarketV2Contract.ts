import moment from "moment";
import { BigNumber } from "ethers";

import Numbers from "../utils/Numbers";
import IContract from "./IContract";
import realitioLib from "@reality.eth/reality-eth-lib";
import ERC20Contract from "./ERC20Contract";

class PredictionMarketV2Contract extends IContract {
  static ACTIONS: { [key: number]: string } = {
    0: "Buy",
    1: "Sell",
    2: "Add Liquidity",
    3: "Remove Liquidity",
    4: "Claim Winnings",
    5: "Claim Liquidity",
    6: "Claim Fees",
    7: "Claim Voided",
  };

  constructor(params: any) {
    super({ ...params, abi: params.contract.abi });
    this.contractName = "predictionMarketV2";
  }

  async getMinimumRequiredBalance(): Promise<number> {
    const requiredBalance = await this.params.contract
      .getContract()
      .methods.requiredBalance()
      .call();

    const requiredBalanceToken = await this.params.contract
      .getContract()
      .methods.requiredBalanceToken()
      .call();

    const decimals = await this.getTokenDecimals({
      contractAddress: requiredBalanceToken,
    });

    return Numbers.fromDecimalsNumber(requiredBalance, decimals);
  }

  async getWETHAddress(): Promise<string> {
    return await this.params.contract.getContract().methods.WETH().call();
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
    const outcomeIds = await this.params.contract
      .getContract()
      .methods.getMarketOutcomeIds(marketId)
      .call();
    const decimals = await this.getMarketDecimals({ marketId });
    const state = parseInt(marketData[0]);
    const resolvedOutcomeId = parseInt(marketData[5]);

    return {
      closeDateTime: moment.unix(marketData[1]).format("YYYY-MM-DD HH:mm"),
      state,
      oracleAddress: "0x0000000000000000000000000000000000000000",
      liquidity: Numbers.fromDecimalsNumber(marketData[2], decimals),
      outcomeIds: outcomeIds.map((outcomeId: any) =>
        Numbers.fromBigNumberToInteger(outcomeId, 18),
      ),
      resolvedOutcomeId,
      voided: state === 2 && !outcomeIds.includes(resolvedOutcomeId.toString()),
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
    const decimals = await this.getMarketDecimals({ marketId });

    return {
      name: "", // TODO: remove; deprecated
      price: Numbers.fromDecimalsNumber(outcomeData[0], 18),
      shares: Numbers.fromDecimalsNumber(outcomeData[1], decimals),
    };
  }

  async getMarketDetails({ marketId }: { marketId: number }): Promise<any> {
    const events = await this.getEvents("MarketCreated", { marketId });

    if (events.length === 0) {
      // legacy record, returning empty data
      return {
        name: "",
        category: "",
        subcategory: "",
        image: "",
        outcomes: [],
      };
    }

    // parsing question with realitio standard
    const question = realitioLib.populatedJSONForTemplate(
      '{"title": "%s", "type": "single-select", "outcomes": [%s], "category": "%s", "lang": "%s"}',
      events[0].returnValues.question,
    );

    // splitting name and description with the first occurrence of ';' character
    const name = question.title.split(";")[0];
    const description = question.title.split(";").slice(1).join(";");

    return {
      name,
      description,
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
    let totalShares = 0;
    let totalAmount = 0;

    events.forEach((event) => {
      if (event.marketId === marketId && event.outcomeId === outcomeId) {
        if (event.action === "Buy") {
          totalShares += event.shares;
          totalAmount += event.value;
        } else if (event.action === "Sell") {
          const proportion = event.shares / totalShares;
          totalShares -= event.shares;
          totalAmount *= 1 - proportion;
        }
      }
    });

    return totalShares && totalAmount ? totalAmount / totalShares : 0;
  }

  getAverageAddLiquidityPrice({
    events,
    marketId,
  }: {
    events: any[];
    marketId: number;
  }): number {
    let totalShares = 0;
    let totalAmount = 0;

    events.forEach((event) => {
      if (event.marketId === marketId) {
        if (event.action === "Add Liquidity") {
          totalShares += event.shares;
          totalAmount += event.value;
        } else if (event.action === "Remove Liquidity") {
          const proportion = event.shares / totalShares;
          totalShares -= event.shares;
          totalAmount *= 1 - proportion;
        }
      }
    });

    return totalShares && totalAmount ? totalAmount / totalShares : 0;
  }

  async isMarketERC20TokenWrapped({
    marketId,
  }: {
    marketId: number;
  }): Promise<boolean> {
    const tokenAddress = await this.params.contract
      .getContract()
      .methods.getMarketToken(marketId)
      .call();
    const wethAddress = await this.getWETHAddress();
    return tokenAddress === wethAddress;
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
    const decimals = await this.getMarketDecimals({
      marketId: marketIds[0],
    });

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
            shares: Numbers.fromDecimals(shares, decimals),
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
          shares: Numbers.fromDecimals(liquidityShares, decimals),
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
          PredictionMarketV2Contract.ACTIONS[
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

  async getMarketShares({ marketId }: { marketId: number }) {
    const marketData = await this.getMarketData({ marketId });
    const { outcomeIds } = marketData;
    const shares: { [key: number]: any } = {};

    for (const outcomeId of outcomeIds) {
      const outcomeData = await this.getOutcomeData({ marketId, outcomeId });
      shares[outcomeId] = outcomeData.shares;
    }
    return shares;
  }

  async getTokenDecimals({
    contractAddress,
  }: {
    contractAddress: string;
  }): Promise<number> {
    const tokenContract = new ERC20Contract({
      web3: this.web3,
      contractAddress,
      acc: this.acc,
    });
    return await tokenContract.getDecimals();
  }

  async getMarketDecimals({ marketId }: { marketId: number }): Promise<number> {
    const tokenAddress = await this.params.contract
      .getContract()
      .methods.getMarketToken(marketId)
      .call();
    return await this.getTokenDecimals({ contractAddress: tokenAddress });
  }

  async prepareCreateMarketDescription({
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
  }: {
    value: number;
    name: string;
    description: string;
    image: string;
    duration: number;
    oracleAddress: string;
    outcomes: string[];
    category: string;
    token: string;
    odds: number[];
    fee: number;
    treasuryFee: number;
    treasury: string;
  }): Promise<any> {
    const decimals = await this.getTokenDecimals({ contractAddress: token });
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);
    const feeToWei = Numbers.toSmartContractDecimals(fee, 18);
    const treasuryFeeToWei = Numbers.toSmartContractDecimals(treasuryFee, 18);
    const title = `${name};${description}`;
    const question = realitioLib.encodeText(
      "single-select",
      title,
      outcomes,
      category,
    );
    let distribution: BigNumber[] = [];

    if (odds.length > 0) {
      if (odds.length !== outcomes.length) {
        throw new Error("Odds and outcomes must have the same length");
      }

      const oddsSum = odds.reduce((a, b) => a + b, 0);
      if (oddsSum < 99.9 || oddsSum > 100.1) {
        throw new Error("Odds must sum 100");
      }

      distribution = this.calcDistribution({ odds });
    }

    return {
      value: valueToWei,
      closesAt: duration,
      outcomes: outcomes.length,
      token,
      question,
      image,
      arbitrator: oracleAddress,
      fee: feeToWei,
      treasuryFee: treasuryFeeToWei,
      treasury,
      distribution,
    };
  }

  async createMarket(params: any) {
    const desc = await this.prepareCreateMarketDescription(params);
    return await this.__sendTx(
      this.getContract().methods.createMarket(
        desc.closesAt,
        desc.token,
        desc.question,
        desc.image,
        desc.arbitrator,
        desc.fee,
        desc.treasuryFee,
        desc.treasury,
        desc.outcomes,
        desc.distribution,
      ),
      false,
      desc.value,
    );
  }

  async createMarketWithETH(params: any) {
    const token = await this.getWETHAddress();
    const desc = await this.prepareCreateMarketDescription({ ...params, token });
    return await this.__sendTx(
      this.getContract().methods.createMarket(
        desc.closesAt,
        desc.token,
        desc.question,
        desc.image,
        desc.arbitrator,
        desc.fee,
        desc.treasuryFee,
        desc.treasury,
        desc.outcomes,
        desc.distribution,
      ),
      false,
      desc.value,
    );
  }

  async addLiquidity({
    marketId,
    value,
    wrapped = false,
  }: {
    marketId: number;
    value: number;
    wrapped: boolean;
  }) {
    const decimals = await this.getMarketDecimals({ marketId });
    const amount = Numbers.toSmartContractDecimals(value, decimals);
    if (wrapped) {
      return await this.__sendTx(
        this.getContract().methods.addLiquidity(marketId),
        false,
        amount,
      );
    }
    return await this.__sendTx(
      this.getContract().methods.addLiquidity(marketId, amount),
    );
  }

  async removeLiquidity({
    marketId,
    shares,
    wrapped = false,
  }: {
    marketId: number;
    shares: number;
    wrapped: boolean;
  }) {
    const decimals = await this.getMarketDecimals({ marketId });
    const amount = Numbers.toSmartContractDecimals(shares, decimals);
    if (wrapped) {
      return await this.__sendTx(
        this.getContract().methods.removeLiquidity(marketId),
        false,
        amount,
      );
    }
    return await this.__sendTx(
      this.getContract().methods.removeLiquidity(marketId, amount),
    );
  }

  async buy({
    marketId,
    outcomeId,
    value,
    minOutcomeSharesToBuy,
    wrapped = false,
  }: {
    marketId: number;
    outcomeId: number;
    value: number;
    minOutcomeSharesToBuy: number;
    wrapped: boolean;
  }) {
    const decimals = await this.getMarketDecimals({ marketId });
    const amount = Numbers.toSmartContractDecimals(value, decimals);
    const minShares = Numbers.toSmartContractDecimals(
      minOutcomeSharesToBuy,
      decimals,
    );
    if (wrapped) {
      return await this.__sendTx(
        this.getContract().methods.buy(marketId, outcomeId, minShares),
        false,
        amount,
      );
    }
    return await this.__sendTx(
      this.getContract().methods.buy(marketId, outcomeId, amount, minShares),
    );
  }

  async sell({
    marketId,
    outcomeId,
    value,
    maxOutcomeSharesToSell,
    wrapped = false,
  }: {
    marketId: number;
    outcomeId: number;
    value: number;
    maxOutcomeSharesToSell: number;
    wrapped: boolean;
  }) {
    const decimals = await this.getMarketDecimals({ marketId });
    const amount = Numbers.toSmartContractDecimals(value, decimals);
    const maxShares = Numbers.toSmartContractDecimals(
      maxOutcomeSharesToSell,
      decimals,
    );
    if (wrapped) {
      return await this.__sendTx(
        this.getContract().methods.sell(marketId, outcomeId, maxShares),
        false,
        amount,
      );
    }
    return await this.__sendTx(
      this.getContract().methods.sell(marketId, outcomeId, amount, maxShares),
    );
  }

  async resolveMarketOutcome({ marketId }: { marketId: number }) {
    return await this.__sendTx(
      this.getContract().methods.resolveMarket(marketId),
    );
  }

  async claimWinnings({
    marketId,
    wrapped = false,
  }: {
    marketId: number;
    wrapped: boolean;
  }) {
    if (wrapped) {
      const user = await this.getMyAccount();
      return await this.__sendTx(
        this.getContract().methods.claimWinnings(marketId, user),
      );
    }
    return await this.__sendTx(
      this.getContract().methods.claimWinnings(marketId),
    );
  }

  async claimVoidedOutcomeShares({
    marketId,
    outcomeId,
    wrapped = false,
  }: {
    marketId: number;
    outcomeId: number;
    wrapped: boolean;
  }) {
    if (wrapped) {
      const user = await this.getMyAccount();
      return await this.__sendTx(
        this.getContract().methods.claimVoidedOutcomeShares(
          marketId,
          outcomeId,
          user,
        ),
      );
    }
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
    value,
  }: {
    marketId: number;
    outcomeId: number;
    value: number;
  }) {
    const decimals = await this.getMarketDecimals({ marketId });
    const amount = Numbers.toSmartContractDecimals(value, decimals);
    const buyAmount = await this.getContract()
      .methods.calcBuyAmount(marketId, outcomeId, amount)
      .call();
    return Numbers.fromDecimals(buyAmount, decimals);
  }

  async calcSellAmount({
    marketId,
    outcomeId,
    value,
  }: {
    marketId: number;
    outcomeId: number;
    value: number;
  }) {
    const decimals = await this.getMarketDecimals({ marketId });
    const amount = Numbers.toSmartContractDecimals(value, decimals);
    const sellAmount = await this.getContract()
      .methods.calcSellAmount(marketId, outcomeId, amount)
      .call();
    return Numbers.fromDecimals(sellAmount, decimals);
  }

  async getMarketResolutionDate({ marketId }: { marketId: number }) {
    const marketData = await this.getMarketData({ marketId });
    return moment.unix(marketData.closesAt).utc();
  }

  async getMarketPrice({ marketId }: { marketId: number }) {
    const marketData = await this.getMarketData({ marketId });
    const decimals = await this.getMarketDecimals({ marketId });
    return parseFloat(Numbers.fromDecimals(marketData.price, decimals));
  }

  async isMarketClosed({ marketId }: { marketId: number }) {
    const marketData = await this.getMarketData({ marketId });
    return marketData.state > 1;
  }

  calcDistribution({ odds }: { odds: number[] }): BigNumber[] {
    const totalInverse = odds.reduce((acc, o) => acc + 1 / o, 0);
    const distribution = odds.map(
      (o) =>
        Numbers.toSmartContractDecimals(
          (1 / o / totalInverse) * 100,
          18,
        ) as unknown as BigNumber,
    );
    return distribution;
  }
}

export default PredictionMarketV2Contract;
