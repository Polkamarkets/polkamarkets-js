const _ =  require("lodash");
const moment = require("moment");

const ppmm = require("../interfaces").ppmm;
const ierc20 = require("../interfaces").ierc20;

const Numbers = require( "../utils/Numbers");
const IContract = require( './IContract');

const ERC20Contract = require('./ERC20Contract');

const realitioLib = require('@reality.eth/reality-eth-lib/formatters/question');

const actions = {
  0: 'Buy',
  1: 'Sell',
  4: 'Claim Winnings',
  7: 'Claim Voided',
}

/**
 * PPMMarket Contract Object
 * @constructor PPMMarketContract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class PPMMarketContract extends IContract {
  constructor(params) {
    super({...params, abi: params.abi || ppmm});
    this.contractName = 'PPMMarket';
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
    const outcomeIds = await this.params.contract.getContract().methods.getMarketOutcomeIds(marketId).call();
    const decimals = await this.getMarketDecimals({marketId});
    const state = parseInt(marketData[0]);
    const resolvedOutcomeId = parseInt(marketData[5]);

    return {
      closeDateTime: moment.unix(marketData[1]).format("YYYY-MM-DD HH:mm"),
      state,
      oracleAddress: '0x0000000000000000000000000000000000000000',
      liquidity: Numbers.fromDecimalsNumber(marketData[2], decimals),
      outcomeIds: outcomeIds.map((outcomeId) => Numbers.fromBigNumberToInteger(outcomeId, 18)),
      resolvedOutcomeId,
      voided: state === 2 && !outcomeIds.includes(resolvedOutcomeId)
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
    const decimals = await this.getMarketDecimals({marketId});

    return {
      name: '', // TODO: remove; deprecated
      price: Numbers.fromDecimalsNumber(outcomeData[0], 18),
      shares: Numbers.fromDecimalsNumber(outcomeData[1], decimals),
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
   * @function isMarketERC20TokenWrapped
   * @description Checks if market ERC20 token is wrapped
   * @param {Integer} marketId
   * @returns {Boolean} boolean
   */
  async isMarketERC20TokenWrapped({marketId}) {
    const WETHAddress = await this.params.contract.getContract().methods.WETH().call();
    const marketAltData = await this.params.contract.getContract().methods.getMarketAltData(marketId).call();

    return marketAltData[3] === WETHAddress;
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
    const allMarketIds = await this.getMarkets();
    let userMarketIds;
    let events = [];
    try {
      events = await this.getActions({ user });
      userMarketIds = events.map(e => e.marketId).filter((x, i, a) => a.indexOf(x) == i);
    } catch (err) {
      // defaulting to allMarketIds if query fails
      userMarketIds = allMarketIds;
    }

    let voidedMarketIds = [];
    // fetching voided markets
    try {
      // TODO: improve this
      const marketsCreated = await this.getEvents('MarketCreated');
      const marketsResolved = await this.getEvents('MarketResolved');

      voidedMarketIds = marketsResolved.filter((event) => {
        const resolvedOutcomeId = parseInt(event.returnValues.outcomeId);
        const outcomeCount = marketsCreated.find((market) =>  {
          return market.returnValues.marketId === event.returnValues.marketId
        }).returnValues.outcomes;

        return resolvedOutcomeId >= outcomeCount;
      }).map((event) => parseInt(event.returnValues.marketId));
    } catch (err) {
      // skipping voided markets if query fails
    }

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
            voidedWinningsToClaim: false,
            voidedWinningsClaimed: false,
            liquidityFees: 0
          }
        };
      } else {
        const decimals = await this.getMarketDecimals({marketId});
        const marketShares = await this.getContract().methods.getUserMarketShares(marketId, user).call();
        const claimStatus = await this.getContract().methods.getUserClaimStatus(marketId, user).call();

        const outcomeShares = Object.fromEntries(marketShares[1].map((item, index) => {
          return [
            index,
            {
              shares: Numbers.fromDecimalsNumber(item, decimals),
              price: this.getAverageOutcomeBuyPrice({events, marketId, outcomeId: index})
            }
          ];
        }));

        const voidedWinningsToClaim = voidedMarketIds.includes(marketId) && marketShares[1].some(item => item > 0);
        const voidedWinningsClaimed = voidedWinningsToClaim && events.some(event => event.action === 'Claim Voided' && event.marketId === marketId);

        portfolio = {
          liquidity: {
            shares: 0,
            price: 0,
          },
          outcomes: outcomeShares,
          claimStatus: {
            winningsToClaim: claimStatus[0],
            winningsClaimed: claimStatus[1],
            liquidityToClaim: claimStatus[2],
            liquidityClaimed: claimStatus[3],
            voidedWinningsToClaim,
            voidedWinningsClaimed,
            liquidityFees: Numbers.fromDecimalsNumber(claimStatus[4], decimals)
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

    const decimals = await this.getMarketDecimals({marketId});
    const marketShares = await this.getContract().methods.getUserMarketShares(marketId, account).call();
    const outcomeShares = Object.fromEntries(marketShares[1].map((item, index) => [index, Numbers.fromDecimalsNumber(item, decimals)] ));

    return  {
      liquidityShares: Numbers.fromDecimalsNumber(marketShares[0], decimals),
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

    // fetching decimals for each market (unique)
    const marketIds = events.map(event => event.returnValues.marketId).filter((x, i, a) => a.indexOf(x) == i);
    const marketDecimals = await Promise.all(marketIds.map(marketId => this.getMarketDecimals({marketId})));

    // filtering by address
    return events.map(event => {
      const decimals = marketDecimals[marketIds.indexOf(event.returnValues.marketId)];

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
      liquidity: 0,
      outcomes: Object.fromEntries(marketPrices.map((item, index) => [index, Numbers.fromDecimalsNumber(item, 18)] ))
    };
  }

  /**
   * @function getMarketShares
   * @description Get Market Shares
   * @param {Integer} marketId
   * @return {Object} shares
   */
  async getMarketShares({marketId}) {
    const decimals = await this.getMarketDecimals({marketId});
    const marketShares = await this.getContract().methods.getMarketShares(marketId).call();

    return {
      liquidity: Numbers.fromDecimalsNumber(marketShares[0], decimals),
      outcomes: Object.fromEntries(marketShares[1].map((item, index) => [index, Numbers.fromDecimalsNumber(item, decimals)] ))
    };
  }

  /**
   * @function getTokenDecimals
   * @description Get Token Decimals
   * @param {address} contractAddress
   * @return {Integer} decimals
   */
  async getTokenDecimals({contractAddress}) {
    try {
      const erc20Contract = new ERC20Contract({ ...this.params, contractAddress, abi: ierc20 });

      return await erc20Contract.getDecimalsAsync();
    } catch (err) {
      // defaulting to 18 decimals
      return 18;
    }
  }

  /**
   * @function getMarketDecimals
   * @description Get Market Decimals
   * @param {Integer} marketId
   * @return {Integer} decimals
   */
  async getMarketDecimals({marketId}) {
    if (this.defaultDecimals) {
      return this.defaultDecimals;
    }

    const marketAltData = await this.params.contract.getContract().methods.getMarketAltData(marketId).call();
    const contractAddress = marketAltData[3];

    return await this.getTokenDecimals({ contractAddress });
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
    fee = 0,
    treasuryFee = 0,
    treasury = '0x0000000000000000000000000000000000000000',
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
      fee,
      treasuryFee,
      treasury,
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
    fee = 0,
    treasuryFee = 0,
    treasury = '0x0000000000000000000000000000000000000000',
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
      this.getContract().methods.createMarketWithETH(desc),
      false,
      desc.value
    );
  };

  /**
   * @function buy
   * @description Buy Shares of a Market Outcome
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @param {Integer} value
   */
  async buy ({ marketId, outcomeId, value, minOutcomeSharesToBuy, wrapped = false}) {
    const decimals = await this.getMarketDecimals({marketId});
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);
    minOutcomeSharesToBuy = Numbers.toSmartContractDecimals(minOutcomeSharesToBuy, decimals);

    if (wrapped) {
      return await this.__sendTx(
        this.getContract().methods.buyWithETH(marketId, outcomeId, minOutcomeSharesToBuy),
        false,
        valueToWei,
      );
    }

    return await this.__sendTx(
      this.getContract().methods.buy(marketId, outcomeId, minOutcomeSharesToBuy, valueToWei),
    );
  };

  /**
   * @function sell
   * @description Sell Shares of a Market Outcome
   * @param {Integer} marketId
   * @param {Integer} outcomeId
   * @param {Integer} shares
   */
  async sell({marketId, outcomeId, value, maxOutcomeSharesToSell, wrapped = false}) {
    const decimals = await this.getMarketDecimals({marketId});
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);
    maxOutcomeSharesToSell = Numbers.toSmartContractDecimals(maxOutcomeSharesToSell, decimals);

    if (wrapped) {
      return await this.__sendTx(
        this.getContract().methods.sellToETH(marketId, outcomeId, valueToWei, maxOutcomeSharesToSell),
        false,
      );
    }

    return await this.__sendTx(
      this.getContract().methods.sell(marketId, outcomeId, valueToWei, maxOutcomeSharesToSell),
    );
  };

  async resolveMarketOutcome({marketId}) {
    return await this.__sendTx(
      this.getContract().methods.resolveMarketOutcome(marketId),
      false,
    );
  };

  async claimWinnings({marketId, wrapped = false}) {
    if (wrapped) {
      return await this.__sendTx(
        this.getContract().methods.claimWinningsToETH(marketId),
        false,
      );
    }

    return await this.__sendTx(
      this.getContract().methods.claimWinnings(marketId),
      false,
    );
  };

  async claimVoidedOutcomeShares({marketId, outcomeId, wrapped = false}) {
    if (wrapped) {
      return await this.__sendTx(
        this.getContract().methods.claimVoidedOutcomeSharesToETH(marketId, outcomeId),
        false,
      );
    }

    return await this.__sendTx(
      this.getContract().methods.claimVoidedOutcomeShares(marketId, outcomeId),
      false,
    );
  };

  async calcBuyAmount({ marketId, outcomeId, value }) {
    const decimals = await this.getMarketDecimals({marketId});
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);

    const amount = await this.getContract()
      .methods.calcBuyAmount(
        valueToWei,
        marketId,
        outcomeId
      )
      .call();

    return Numbers.fromDecimalsNumber(amount, decimals);
  }

  async calcSellAmount({ marketId, outcomeId, value }) {
    const decimals = await this.getMarketDecimals({marketId});
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);

    const amount = await this.getContract()
      .methods.calcSellAmount(
        valueToWei,
        marketId,
        outcomeId
      )
      .call();

    return Numbers.fromDecimalsNumber(amount, decimals);
  }

  calcDistribution({ odds }) {
    const distribution = [];
    const prod = odds.reduce((a, b) => a * b, 1);

    for (let i = 0; i < odds.length; i++) {
      distribution.push((Math.round(prod / odds[i] * 1000000)).toString());
    }

    return distribution;
  }
}

module.exports = PPMMarketContract;
