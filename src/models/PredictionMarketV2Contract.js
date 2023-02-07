const _ =  require("lodash");
const moment = require("moment");

const prediction = require("../interfaces").predictionV2;

const Numbers = require( "../utils/Numbers");
const IContract = require( './IContract');

const realitioLib = require('@reality.eth/reality-eth-lib/formatters/question');

const actions = {
  0: 'Buy',
  1: 'Sell',
  2: 'Add Liquidity',
  3: 'Remove Liquidity',
  4: 'Claim Winnings',
  5: 'Claim Liquidity',
  6: 'Claim Fees',
  7: 'Claim Voided',
}

/**
 * PredictionMarket Contract Object
 * @constructor PredictionMarketContract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class PredictionMarketV2Contract extends IContract {
  constructor(params) {
    super({...params, abi: prediction});
    this.contractName = 'predictionMarket';
  }

  /* Get Functions */
  /**
   * @function getMinimumRequiredBalance
   * @description Returns minimum required ERC20 balance to create markets
   * @returns {Integer} requiredBalance
   */
  async getMinimumRequiredBalance() {
    const requiredBalance = await this.params.contract
      .getContract()
      .methods
      .requiredBalance()
      .call();

    return Numbers.fromDecimalsNumber(requiredBalance, 18)
  }

  /* Get Functions */
  /**
   * @function getFee
   * @description Returns fee taken from every transaction to liquidity providers
   * @returns {Integer} fee
   */
  async getFee() {
    const fee = await this.params.contract
      .getContract()
      .methods
      .fee()
      .call();

    return Numbers.fromDecimalsNumber(fee, 18)
  }

    /**
   * @function getWETHAddress
   * @description Returns WETH Address
   * @returns {address}
   */
  async getWETHAddress() {
    const WETHAddress = await this.params.contract.getContract().methods.WETH().call();

    return WETHAddress;
  }

  /* Get Functions */
  /**
   * @function getMarkets
   * @description Get Markets
   * @returns {Integer | Array} Get Market Ids
   */
  async getMarkets() {
    let res = await this.params.contract
      .getContract()
      .methods
      .getMarkets()
      .call();
    return res.map((marketId) => Number(Numbers.fromHex(marketId)));
  }

  /**
   * @function getMarketData
   * @description Get getMarketData
   * @param {Integer} marketId
   * @returns {String} Market Name
   * @returns {Integer} closeDateTime
   * @returns {Integer} state
   * @returns {Address} Oracle Address
   * @returns {Integer} liquidity
   * @returns {Array} outcomeIds
   */
  async getMarketData({marketId}) {
    const marketData = await this.params.contract.getContract().methods.getMarketData(marketId).call();
    const outcomeIds = await this.__sendTx(this.getContract().methods.getMarketOutcomeIds(marketId), true);

    return {
      name: '', // TODO: remove; deprecated
      closeDateTime: moment.unix(marketData[1]).format("YYYY-MM-DD HH:mm"),
      state: parseInt(marketData[0]),
      oracleAddress: '0x0000000000000000000000000000000000000000',
      liquidity: Numbers.fromDecimalsNumber(marketData[2], 18),
      outcomeIds: outcomeIds.map((outcomeId) => Numbers.fromBigNumberToInteger(outcomeId, 18))
    };
  }

  /**
   * @function getOutcomeData
   * @description Get Market Outcome Data
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @returns {String} name
   * @returns {Integer} price
   * @returns {Integer} sahres
   */
  async getOutcomeData({marketId, outcomeId}) {
    const outcomeData = await this.params.contract.getContract().methods.getMarketOutcomeData(marketId, outcomeId).call();

    return {
      name: '', // TODO: remove; deprecated
      price: Numbers.fromDecimalsNumber(outcomeData[0], 18),
      shares: Numbers.fromDecimalsNumber(outcomeData[1], 18),
    };
  }

  /**
   * @function getMarketDetails
   * @description getMarketDetails
   * @param {Integer} marketId
   * @returns {String} name
   * @returns {String} category
   * @returns {String} subcategory
   * @returns {String} image
   * @returns {Array} outcomes
   */
  async getMarketDetails({marketId}) {
    const marketData = await this.params.contract.getContract().methods.getMarketData(marketId).call();
    const outcomeIds = await this.__sendTx(this.getContract().methods.getMarketOutcomeIds(marketId), true);

    const events = await this.getEvents('MarketCreated', { marketId });

    if (events.length === 0) {
      // legacy record, returning empty data
      return { name: '', category: '', subcategory: '', image: '', outcomes: [] };
    }

    // parsing question with realitio standard
    const question = realitioLib.populatedJSONForTemplate(
      '{"title": "%s", "type": "single-select", "outcomes": [%s], "category": "%s", "lang": "%s"}',
      events[0].returnValues.question
    );

    // splitting name and description with the first occurrence of ';' character
    const name = question.title.split(';')[0];
    const description = question.title.split(';').slice(1).join(';');

    return {
      name,
      description,
      category: question.category.split(';')[0],
      subcategory: question.category.split(';')[1],
      outcomes: question.outcomes,
      image: events[0].returnValues.image
    };
  }

  async getMarketIdsFromQuestions({questions}) {
    const events = await this.getEvents('MarketCreated');

    return events.filter((event) => {
      return questions.includes(event.returnValues.question);
    }).map((event) => event.returnValues.marketId);
  }

  /**
   * @function getMarketQuestionId
   * @description getMarketQuestionId
   * @param {Integer} marketId
   * @returns {Bytes32} questionId
   */
  async getMarketQuestionId({marketId}) {
    const marketAltData = await this.params.contract.getContract().methods.getMarketAltData(marketId).call();

    return marketAltData[1];
  }

  /**
   * @function getAverageOutcomeBuyPrice
   * @description Calculates average buy price of market outcome based on user events
   * @param {Array} events
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @returns {Integer} price
   */
  getAverageOutcomeBuyPrice({events, marketId, outcomeId}) {
    // filtering by marketId + outcomeId + buy action
    events = events.filter(event => {
      return (
        event.action === 'Buy' &&
        event.marketId === marketId &&
        event.outcomeId === outcomeId
      );
    });

    if (events.length === 0) return 0;

    const totalShares = events.map(item => item.shares).reduce((prev, next) => prev + next);
    const totalAmount = events.map(item => item.value).reduce((prev, next) => prev + next);

    return totalAmount / totalShares;
  }

  /**
   * @function getAverageAddLiquidityPrice
   * @description Calculates average add liquidity of market outcome based on user events
   * @param {Array} events
   * @param {Integer} marketId
   * @returns {Integer} price
   */
   getAverageAddLiquidityPrice({events, marketId}) {
    // filtering by marketId + add liquidity action
    events = events.filter(event => {
      return (
        event.action === 'Add Liquidity' &&
        event.marketId === marketId
      );
    });

    if (events.length === 0) return 0;

    const totalShares = events.map(item => item.shares).reduce((prev, next) => prev + next);
    const totalAmount = events.map(item => item.value).reduce((prev, next) => prev + next);

    return totalAmount / totalShares;
  }

  /**
   * @function getMyPortfolio
   * @description Get My Porfolio
   * @returns {Array} Outcome Shares
   */
  async getMyPortfolio() {
    const account = await this.getMyAccount();
    if (!account) return [];

    return this.getPortfolio({ user: account });
  }

  /**
   * @function getPortfolio
   * @description Get My Porfolio
   * @param {Address} user
   * @returns {Array} Outcome Shares
   */
  async getPortfolio({ user }) {
    const events = await this.getActions({ user });
    const allMarketIds = await this.getMarkets();
    const userMarketIds = events.map(e => e.marketId).filter((x, i, a) => a.indexOf(x) == i);

    return await allMarketIds.reduce(async (obj, marketId) => {
      let portfolio;
      if (!userMarketIds.includes(marketId)) {
        // user did not interact with market, no need to fetch holdings
        portfolio = {
          liquidity: { shares: 0, price: 0 },
          outcomes: {
            0: { shares: 0, price: 0 },
            1: { shares: 0, price: 0 },
          },
          claimStatus: {
            winningsToClaim: false,
            winningsClaimed: false,
            liquidityToClaim: false,
            liquidityClaimed: false,
            liquidityFees: 0
          }
        };
      } else {
        const marketShares = await this.getContract().methods.getUserMarketShares(marketId, user).call();
        let claimStatus;
        try {
          claimStatus = await this.getContract().methods.getUserClaimStatus(marketId, user).call();
        } catch (err) {
          // SafeMath subtraction overflow error from Moonriver deployment
          if (err.message.includes('SafeMath: subtraction overflow')) {
            claimStatus = [false, false, false, false, 0];

            const marketData = await this.params.contract.getContract().methods.getMarketData(marketId).call();
            if (parseInt(marketData[0]) === 2) {
              // market resolved, computing if user has winnings to claim
              claimStatus[0] = marketShares[1][parseInt(marketData[5])] > 0;
              if (claimStatus[0]) {
                const events = await this.getEvents('MarketActionTx', { marketId, user, action: 4 });
                claimStatus[1] = events.length > 0;
              }
              claimStatus[2] = marketShares[0] > 0;
              claimStatus[3] = claimStatus[2];
            }
          } else {
            throw err;
          }
        }

        const outcomeShares = Object.fromEntries(marketShares[1].map((item, index) => {
          return [
            index,
            {
              shares: Numbers.fromDecimalsNumber(item, 18),
              price: this.getAverageOutcomeBuyPrice({events, marketId, outcomeId: index})
            }
          ];
        }));

        portfolio = {
          liquidity: {
            shares: Numbers.fromDecimalsNumber(marketShares[0], 18),
            price: this.getAverageAddLiquidityPrice({events, marketId}),
          },
          outcomes: outcomeShares,
          claimStatus: {
            winningsToClaim: claimStatus[0],
            winningsClaimed: claimStatus[1],
            liquidityToClaim: claimStatus[2],
            liquidityClaimed: claimStatus[3],
            liquidityFees: Numbers.fromDecimalsNumber(claimStatus[4], 18)
          }
        };
      }

      return await {
        ...(await obj),
        [marketId]: portfolio,
      };
    }, {});
  }

  /**
   * @function getMyMarketShares
   * @description Get My Market Shares
   * @param {Integer} marketId
   * @returns {Integer} Liquidity Shares
   * @returns {Array} Outcome Shares
   */
  async getMyMarketShares({marketId}) {
    const account = await this.getMyAccount();
    if (!account) return [];

    const marketShares = await this.getContract().methods.getUserMarketShares(marketId, account).call();
    const outcomeShares = Object.fromEntries(marketShares[1].map((item, index) => [index, Numbers.fromDecimalsNumber(item, 18)] ));

    return  {
      liquidityShares: Numbers.fromDecimalsNumber(marketShares[0], 18),
      outcomeShares
    };
  }

  async getMyActions() {
    const account = await this.getMyAccount();
    if (!account) return [];

    return this.getActions({ user: account });
  }

  async getActions({ user }) {
    const events = await this.getEvents('MarketActionTx', { user });

    // filtering by address
    return events.map(event => {
      return {
        action: actions[Numbers.fromBigNumberToInteger(event.returnValues.action, 18)],
        marketId: Numbers.fromBigNumberToInteger(event.returnValues.marketId, 18),
        outcomeId: Numbers.fromBigNumberToInteger(event.returnValues.outcomeId, 18),
        shares: Numbers.fromDecimalsNumber(event.returnValues.shares, 18),
        value: Numbers.fromDecimalsNumber(event.returnValues.value, 18),
        timestamp: Numbers.fromBigNumberToInteger(event.returnValues.timestamp, 18),
        transactionHash: event.transactionHash,
      }
    });
  }

  /**
   * @function getMarketOutcomePrice
   * @description Get Market Price
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @return {Integer} price
   */
  async getMarketOutcomePrice({marketId, outcomeId}) {
    return Numbers.fromDecimals(
      await this.__sendTx(
        this.getContract().methods.getMarketOutcomePrice(marketId, outcomeId),
        true
      ),
      18
    );
  }

  /**
   * @function getMarketPrices
   * @description Get Market Price
   * @param {Integer} marketId
   * @return {Object} prices
   */
  async getMarketPrices({marketId}) {
    const marketPrices = await this.getContract().methods.getMarketPrices(marketId).call();

    return {
      liquidity: Numbers.fromDecimalsNumber(marketPrices[0], 18),
      outcomes: Object.fromEntries(marketPrices[1].map((item, index) => [index, Numbers.fromDecimalsNumber(item, 18)] ))
    };
  }

  /**
   * @function getMarketShares
   * @description Get Market Shares
   * @param {Integer} marketId
   * @return {Object} shares
   */
  async getMarketShares({marketId}) {
    const marketShares = await this.getContract().methods.getMarketShares(marketId).call();

    return {
      liquidity: Numbers.fromDecimalsNumber(marketShares[0], 18),
      outcomes: Object.fromEntries(marketShares[1].map((item, index) => [index, Numbers.fromDecimalsNumber(item, 18)] ))
    };
  }

  /* POST User Functions */
  /**
   * @function createMarket
   * @description Create a µarket
   * @param {Integer} value
   * @param {String} name
   * @param {Integer} duration
   * @param {Address} oracleAddress
   * @param {Array} outcomes
   */
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
  }) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);
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

    return await this.__sendTx(
      this.getContract().methods.createMarket({
        value: valueToWei,
        closesAt: duration,
        outcomes: outcomes.length,
        token,
        distribution,
        question,
        image,
        arbitrator: oracleAddress,
      })
    );
  };

/**
   * @function createMarketWithETH
   * @description Create a market
   * @param {Integer} value
   * @param {String} name
   * @param {Integer} duration
   * @param {Address} oracleAddress
   * @param {Array} outcomes
   */
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
  }) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);
    const title = `${name};${description}`;
    const question = realitioLib.encodeText('single-select', title, outcomes, category);
    let distribution = [];
    const token = await this.getWETHAddress();

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

    return await this.__sendTx(
      this.getContract().methods.createMarketWithETH(
        {
          value: valueToWei,
          closesAt: duration,
          outcomes: outcomes.length,
          token,
          distribution,
          question,
          image,
          arbitrator: oracleAddress,
        }
      ),
      false,
      valueToWei
    );
  };

  /**
   * @function addLiquidity
   * @description Add Liquidity from Market
   * @param {Integer} marketId
   * @param {Integer} value
   */
  async addLiquidity({marketId, value}) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);
    return await this.__sendTx(
      this.getContract().methods.addLiquidity(marketId, valueToWei),
    );
  };

  /**
   * @function addLiquidityWithETH
   * @description Add Liquidity from Market
   * @param {Integer} marketId
   * @param {Integer} value
   */
  async addLiquidityWithETH({marketId, value}) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);
    return await this.__sendTx(
      this.getContract().methods.addLiquidityWithETH(marketId),
      false,
      valueToWei
    );
  };

  /**
   * @function removeLiquidity
   * @description Remove Liquidity from Market
   * @param {Integer} marketId
   * @param {Integer} shares
   */
  async removeLiquidity({marketId, shares}) {
    shares = Numbers.toSmartContractDecimals(shares, 18);
    return await this.__sendTx(
      this.getContract().methods.removeLiquidity(marketId, shares)
    );
  };

  /**
   * @function removeLiquidityToETH
   * @description Remove Liquidity from Market
   * @param {Integer} marketId
   * @param {Integer} shares
   */
  async removeLiquidityToETH({marketId, shares}) {
    shares = Numbers.toSmartContractDecimals(shares, 18);
    return await this.__sendTx(
      this.getContract().methods.removeLiquidityToETH(marketId, shares),
      null
    );
  };

  /**
   * @function buy
   * @description Buy Shares of a Market Outcome
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @param {Integer} value
   */
  async buy ({ marketId, outcomeId, value, minOutcomeSharesToBuy}) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);
    minOutcomeSharesToBuy = Numbers.toSmartContractDecimals(minOutcomeSharesToBuy, 18);

    return await this.__sendTx(
      this.getContract().methods.buy(marketId, outcomeId, minOutcomeSharesToBuy, valueToWei),
    );
  };

  /**
   * @function buyWithETH
   * @description Buy Shares of a Market Outcome
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @param {Integer} value
   */
  async buyWithETH ({ marketId, outcomeId, value, minOutcomeSharesToBuy}) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);
    minOutcomeSharesToBuy = Numbers.toSmartContractDecimals(minOutcomeSharesToBuy, 18);

    return await this.__sendTx(
      this.getContract().methods.buyWithETH(marketId, outcomeId, minOutcomeSharesToBuy),
      false,
      valueToWei,
    );
  };

  /**
   * @function sell
   * @description Sell Shares of a Market Outcome
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @param {Integer} shares
   */
  async sell({marketId, outcomeId, value, maxOutcomeSharesToSell}) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);
    maxOutcomeSharesToSell = Numbers.toSmartContractDecimals(maxOutcomeSharesToSell, 18);
    return await this.__sendTx(
      this.getContract().methods.sell(marketId, outcomeId, valueToWei, maxOutcomeSharesToSell),
    );
  };

  /**
   * @function sellToETH
   * @description Sell Shares of a Market Outcome
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @param {Integer} shares
   */
  async sellToETH({marketId, outcomeId, value, maxOutcomeSharesToSell}) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);
    maxOutcomeSharesToSell = Numbers.toSmartContractDecimals(maxOutcomeSharesToSell, 18);
    return await this.__sendTx(
      this.getContract().methods.sellToETH(marketId, outcomeId, valueToWei, maxOutcomeSharesToSell),
      false,
    );
  };

  async resolveMarketOutcome({marketId}) {
    return await this.__sendTx(
      this.getContract().methods.resolveMarketOutcome(marketId),
      false,
    );
  };

  async claimWinnings({marketId}) {
    return await this.__sendTx(
      this.getContract().methods.claimWinnings(marketId),
      false,
    );
  };

  async claimWinningsToETH({marketId}) {
    return await this.__sendTx(
      this.getContract().methods.claimWinningsToETH(marketId),
      false,
    );
  };

  async claimVoidedOutcomeShares({marketId, outcomeId}) {
    return await this.__sendTx(
      this.getContract().methods.claimVoidedOutcomeShares(marketId, outcomeId),
      false,
    );
  };

  async claimVoidedOutcomeSharesToETH({marketId, outcomeId}) {
    return await this.__sendTx(
      this.getContract().methods.claimVoidedOutcomeSharesToETH(marketId, outcomeId),
      false,
    );
  };

  async claimLiquidity({marketId}) {
    return await this.__sendTx(
      this.getContract().methods.claimLiquidity(marketId),
      false,
    );
  };

  async calcBuyAmount({ marketId, outcomeId, value }) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);

    const amount = await this.getContract()
      .methods.calcBuyAmount(
        valueToWei,
        marketId,
        outcomeId
      )
      .call();

    return Numbers.fromDecimalsNumber(amount, 18);
  }

  async calcSellAmount({ marketId, outcomeId, value }) {
    const valueToWei = Numbers.toSmartContractDecimals(value, 18);

    const amount = await this.getContract()
      .methods.calcSellAmount(
        valueToWei,
        marketId,
        outcomeId
      )
      .call();

    return Numbers.fromDecimalsNumber(amount, 18);
  }

  calcDistribution({ odds }) {
    const distribution = [];
    const prod = odds.reduce((a, b) => a * b, 1);

    for (let i = 0; i < odds.length; i++) {
      distribution.push(Math.round(prod / odds[i] * 1000000));
    }

    return distribution;
  }
}

module.exports = PredictionMarketV2Contract;
