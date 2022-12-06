const achievements = require("../interfaces").achievements;

const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');
const PredictionMarketContract = require('./PredictionMarketV2Contract');
const PredictionMarketResolverContract = require('./PredictionMarketResolverContract');
const RealitioERC20Contract = require('./RealitioERC20Contract');

const axios = require('axios');

const actions = {
  0: 'Buy',
  1: 'Add Liquidity',
  2: 'Bond',
  3: 'Claim Winnings',
  4: 'Create Market',
}

/**
 * PredictionMarket Contract Object
 * @constructor PredictionMarketContract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class AchievementsContract extends IContract {
  constructor(params) {
    super({ abi: achievements, ...params });
    this.contractName = 'achievements';
  }

  async getUserStats({ user }) {
    await this.initializePredictionMarketContract();
    await this.initializePredictionMarketResolverContract();
    await this.initializeRealitioERC20Contract();

    const portfolio = await this.predictionMarket.getPortfolio({ user });
    const marketIds = Object.keys(portfolio);

    // fetching unique buy actions per market
    const buyMarkets = marketIds.filter(marketId => {
      return portfolio[marketId].outcomes[0].shares > 0 || portfolio[marketId].outcomes[1].shares > 0
    });
    // fetching unique liquidity actions per market
    const liquidityMarkets = marketIds.filter(marketId => portfolio[marketId].liquidity.shares > 0);
    // fetching unique claim winnings actions per market
    const marketClaims = await marketIds.reduce(async (obj, marketId) => {
      const hasClaimed = await this.predictionMarketResolver.hasUserClaimedMarket({ marketId, user });

      return await {
        ...(await obj),
        [marketId]: hasClaimed,
      };
    }, {});

    const winningsMarkets = marketIds.filter(marketId => marketClaims[marketId]);

    // fetching create market actions
    const createMarketEvents = await this.predictionMarket.getEvents('MarketCreated', { user });

    // fetching unique bonds actions per market
    const bondsEvents = await this.realitioERC20.getEvents('LogNewAnswer', { user });
    const bondsQuestions = bondsEvents.map(e => e.returnValues.question_id).filter((x, i, a) => a.indexOf(x) == i);
    let bondsMarkets = [];

    if (bondsQuestions.length > 0) {
      // filtering by bonds placed in PredictionMarket contract
      // TODO: optimize this
      const allMarketIds = await this.predictionMarket.getMarkets();
      const allMarketQuestions = await Promise.all(allMarketIds.map(async marketId => {
        const questionId = await this.predictionMarket.getMarketQuestionId({ marketId });
        return questionId;
      }));

      const marketQuestions = bondsQuestions.filter(questionId => allMarketQuestions.includes(questionId));
      bondsMarkets = marketQuestions.map(questionId => allMarketQuestions.indexOf(questionId));
    }

    // returning stats mapped by action id
    return {
      0: { markets: buyMarkets, occurrences: buyMarkets.length },
      1: { markets: liquidityMarkets, occurrences: liquidityMarkets.length },
      2: { markets: bondsMarkets, occurrences: bondsMarkets.length },
      3: { markets: winningsMarkets, occurrences: winningsMarkets.length },
      4: { markets: createMarketEvents.map(e => e.returnValues.marketId), occurrences: createMarketEvents.length },
    }
  }

  async getAchievementIds() {
    const achievementIndex = await this.getContract().methods.achievementIndex().call();

    return [...Array(parseInt(achievementIndex)).keys()];
  }

  async getAchievement({ achievementId }) {
    const achievement = await this.getContract().methods.achievements(achievementId).call();

    return {
      action: actions[Numbers.fromBigNumberToInteger(achievement[0], 18)],
      actionId: Numbers.fromBigNumberToInteger(achievement[0], 18),
      occurrences: Numbers.fromBigNumberToInteger(achievement[1], 18)
    };
  }

  async getUserAchievements({ user }) {
    const achievementIds = await this.getAchievementIds();
    const userStats = await this.getUserStats({ user });
    let userTokens;
    try {
      userTokens = await this.getUserTokens({ user });
    } catch (err) {
      // should be non-blocking
    }

    return await achievementIds.reduce(async (obj, achievementId) => {
      const achievement = await this.getAchievement({ achievementId });

      let stats = {...userStats[achievement.actionId]};
      // for achievements with id >= 9, filtering occurences and markets by markets with id >= 57
      if (achievementId >= 9 && achievement.action === 'Claim Winnings') {
        stats = {
          ...stats,
          markets: stats.markets.filter(marketId => marketId >= 57),
          occurrences: stats.markets.filter(marketId => marketId >= 57).length,
        }
      }

      const canClaim = stats.occurrences >= achievement.occurrences;
      const claimed = canClaim && (await this.getContract().methods.hasUserClaimedAchievement(user, achievementId).call());
      const token = userTokens && userTokens.find(token => token.achievementId == achievementId);

      const status = {
        canClaim,
        claimed,
        token
      }

      return await {
        ...(await obj),
        [achievementId]: status,
      };
    }, {});
  }

  async getUserTokens({ user }) {
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

  async claimAchievement({ achievementId }) {
    const user = await this.getMyAccount();
    if (!user) return false;

    const achievement = await this.getAchievement({ achievementId });
    const userStats = await this.getUserStats({ user });

    // for achievements with id >= 9, filtering occurences and markets by markets with id >= 57
    if (achievementId >= 9 && achievement.action === 'Claim Winnings') {
      userStats[achievement.actionId] = {
        ...userStats[achievement.actionId],
        markets: userStats[achievement.actionId].markets.filter(marketId => marketId >= 57),
        occurrences: userStats[achievement.actionId].markets.filter(marketId => marketId >= 57).length,
      }
    }

    // user not eligible to claim
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

        hhashes.push(...events.map((event) => event.returnValues.history_hash).slice(0, -1).reverse());
        // adding an empty hash to the history hashes
        hhashes.push(Numbers.nullHash());

        addrs.push(...events.map((event) => event.returnValues.user).reverse());
        bonds.push(...events.map((event) => event.returnValues.bond).reverse());
        answers.push(...events.map((event) => event.returnValues.answer).reverse());
        lengths.push(events.length);
      }

      return await this.__sendTx(
        this.getContract().methods.claimAchievement(
          achievementId,
          marketIds,
          lengths,
          hhashes,
          addrs,
          bonds,
          answers
        ),
        false
      );
    } else {
      return await this.__sendTx(
        this.getContract().methods.claimAchievement(
          achievementId,
          userStats[achievement.actionId].markets.slice(0, achievement.occurrences)
        ),
        false,
      );
    }
  }

  async initializePredictionMarketContract() {
    // predictionMarket already initialized
    if (this.predictionMarket) return;

    const contractAddress = await this.getContract().methods.predictionMarket().call();

    this.predictionMarket = new PredictionMarketContract({ ...this.params, contractAddress });
  }

  async initializePredictionMarketResolverContract() {
    // predictionMarketResolver already initialized
    if (this.predictionMarketResolver) return;

    const contractAddress = await this.getContract().methods.predictionMarketResolver().call();

    this.predictionMarketResolver = new PredictionMarketResolverContract({ ...this.params, contractAddress });
  }

  async initializeRealitioERC20Contract() {
    // predictionMarket already initialized
    if (this.realitioERC20) return;

    const contractAddress = await this.getContract().methods.realitioERC20().call();

    this.realitioERC20 = new RealitioERC20Contract({ ...this.params, contractAddress });
  }
}

module.exports = AchievementsContract;
