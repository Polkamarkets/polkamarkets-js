import IContract from "./IContract";
import Numbers from "../utils/Numbers";
import PredictionMarketContract from "./PredictionMarketContract";
import RealitioERC20Contract from "./RealitioERC20Contract";
import axios from "axios";
import interfaces from "../interfaces";

const actions: { [key: string]: string } = {
  "0": "Buy",
  "1": "Add Liquidity",
  "2": "Bond",
  "3": "Claim Winnings",
  "4": "Create Market",
};

type UserStats = {
  [key: string]: {
    markets: any[];
    occurrences: number;
  };
};

class AchievementsContract extends IContract {
  predictionMarket!: PredictionMarketContract;
  realitioERC20!: RealitioERC20Contract;

  constructor(params: any) {
    super({ abi: interfaces.achievements, ...params });
    this.contractName = "achievements";
  }

  async getUserStats({ user }: { user: string }): Promise<UserStats> {
    await this.initializePredictionMarketContract();
    await this.initializeRealitioERC20Contract();

    const portfolio = await this.predictionMarket.getPortfolio({ user });
    const buyMarkets = Object.keys(portfolio).filter(
      (marketId) =>
        portfolio[marketId].outcomes[0].shares > 0 ||
        portfolio[marketId].outcomes[1].shares > 0,
    );
    const liquidityMarkets = Object.keys(portfolio).filter(
      (marketId) => portfolio[marketId].liquidity.shares > 0,
    );
    const winningsMarkets = Object.keys(portfolio).filter(
      (marketId) => portfolio[marketId].claimStatus.winningsClaimed,
    );
    const createMarketEvents = await this.predictionMarket.getEvents(
      "MarketCreated",
      { user },
    );
    const bondsEvents = await this.realitioERC20.getEvents("LogNewAnswer", {
      user,
    });
    const bondsQuestions = bondsEvents
      .map((e) => e.returnValues.question_id)
      .filter((x, i, a) => a.indexOf(x) == i);
    let bondsMarkets: any[] = [];

    if (bondsQuestions.length > 0) {
      const allMarketIds = await this.predictionMarket.getMarkets();
      const allMarketQuestions = await Promise.all(
        allMarketIds.map(async (marketId) => {
          const questionId = await this.predictionMarket.getMarketQuestionId({
            marketId,
          });
          return questionId;
        }),
      );

      const marketQuestions = bondsQuestions.filter((questionId) =>
        allMarketQuestions.includes(questionId),
      );
      bondsMarkets = marketQuestions.map((questionId) =>
        allMarketQuestions.indexOf(questionId),
      );
    }

    return {
      0: { markets: buyMarkets, occurrences: buyMarkets.length },
      1: { markets: liquidityMarkets, occurrences: liquidityMarkets.length },
      2: { markets: bondsMarkets, occurrences: bondsMarkets.length },
      3: { markets: winningsMarkets, occurrences: winningsMarkets.length },
      4: {
        markets: createMarketEvents.map(e => e.returnValues.marketId),
        occurrences: createMarketEvents.length
      }
    };
  }

  async getAchievementIds() {
    const achievementIndex = await this.getContract()
      .methods.achievementIndex()
      .call();
    return [...Array(parseInt(achievementIndex)).keys()];
  }

  async getAchievement({ achievementId }: { achievementId: number }) {
    const achievement = await this.getContract()
      .methods.achievements(achievementId)
      .call();
    return {
      action: actions[Numbers.fromBigNumberToInteger(achievement[0], 18)],
      actionId: Numbers.fromBigNumberToInteger(achievement[0], 18),
      occurrences: Numbers.fromBigNumberToInteger(achievement[1], 18),
    };
  }

  async getUserAchievements({ user }: { user: string }) {
    const achievementIds = await this.getAchievementIds();
    const userStats: UserStats = await this.getUserStats({ user });
    let userTokens: any;
    try {
      userTokens = await this.getUserTokens({ user });
    } catch (_err) {
      // should be non-blocking
    }

    return await achievementIds.reduce(async (obj, achievementId) => {
      const achievement = await this.getAchievement({ achievementId });
      const canClaim =
        userStats[achievement.actionId].occurrences >=
        achievement.occurrences;
      const claimed =
        canClaim &&
        (await this.getContract()
          .methods.hasUserClaimedAchievement(user, achievementId)
          .call());
      const token =
        userTokens &&
        userTokens.find((token: any) => token.achievementId == achievementId);

      const status = {
        canClaim,
        claimed,
        token,
      };

      return await {
        ...(await obj),
        [achievementId]: status,
      };
    }, {});
  }

  async getUserTokens({ user }: { user: string }) {
    const tokenCount = await this.getContract().methods.balanceOf(user).call();
    const tokens = [];

    for (let i = 0; i < tokenCount; i++) {
      const tokenIndex = await this.getContract().methods.tokenOfOwnerByIndex(user, i).call();
      const tokenAchievement = await this.getContract().methods.tokens(tokenIndex).call();
      const tokenURI = await this.getContract().methods.tokenURI(tokenIndex).call();
      const { data } = await axios.get(tokenURI);

      tokens.push({
        id: tokenIndex,
        achievementId: tokenAchievement,
        uri: tokenURI,
        data
      });
    }

    return tokens;
  }

  async claimAchievement({ achievementId }: { achievementId: number }) {
    const user = await this.getMyAccount();
    if (!user) return false;

    const achievement = await this.getAchievement({ achievementId });
    const userStats = await this.getUserStats({ user });

    if (userStats[achievement.actionId].occurrences < achievement.occurrences) return false;

    if (achievement.actionId == 2) {
      const marketIds = userStats[achievement.actionId].markets.slice(0, achievement.occurrences);
      const lengths = [];
      const hhashes = [];
      const addrs = [];
      const bonds = [];
      const answers = [];

      for (const marketId of marketIds) {
        const questionId = await this.predictionMarket.getMarketQuestionId({ marketId });
        const events = await this.realitioERC20.getEvents('LogNewAnswer', { question_id: questionId });

        hhashes.push(...events.map(event => event.returnValues.history_hash).slice(0, -1).reverse());
        hhashes.push(Numbers.nullHash());
        addrs.push(...events.map(event => event.returnValues.user).reverse());
        bonds.push(...events.map(event => event.returnValues.bond).reverse());
        answers.push(...events.map(event => event.returnValues.answer).reverse());
        lengths.push(events.length);
      }

      return await this.__sendTx(
        this.getContract().methods.claimAchievement(achievementId, marketIds, lengths, hhashes, addrs, bonds, answers),
        false
      );
    } else {
      return await this.__sendTx(
        this.getContract().methods.claimAchievement(
          achievementId,
          userStats[achievement.actionId].markets.slice(0, achievement.occurrences)
        ),
        false
      );
    }
  }

  async initializePredictionMarketContract() {
    if (this.predictionMarket) return;

    this.predictionMarket = new PredictionMarketContract({
      web3: this.web3,
      contractAddress: await this.getContract().methods.predictionMarket().call(),
      acc: this.acc
    });
  }

  async initializeRealitioERC20Contract() {
    if (this.realitioERC20) return;

    this.realitioERC20 = new RealitioERC20Contract({
      web3: this.web3,
      contractAddress: await this.getContract().methods.realitio().call(),
      acc: this.acc
    });
  }
}

export default AchievementsContract;
