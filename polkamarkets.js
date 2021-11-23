import * as realitioLib from '@reality.eth/reality-eth-lib/formatters/question';
import * as beprojs from 'bepro-js';

export default class Polkamarkets {
  constructor(web3Provider, web3EventsProvider = null) {
    // bepro app
    this.bepro = new beprojs.Application({ web3Provider, web3EventsProvider });
    this.bepro.start();

    // bepro smart contract instances
    this.contracts = {};

    // indicates if user has already done a successful metamask login
    this.loggedIn = false;

    // user eth address
    this.address = '';
  }

  getPredictionMarketContract(contractAddress) {
    this.contracts.pm = this.bepro.getPredictionMarketContract({ contractAddress });
  }

  getERC20Contract(contractAddress) {
    this.contracts.erc20 = this.bepro.getERC20Contract({ contractAddress });
  }

  getRealitioERC20Contract(contractAddress) {
    this.contracts.realitio = this.bepro.getRealitioERC20Contract({ contractAddress });
  }

  getContracts() {
    // re-fetching contracts
    if (this.contracts.pm && this.contracts.pm.params.contractAddress) {
      this.getPredictionMarketContract(this.contracts.pm.params.contractAddress);
    }
    if (this.contracts.realitio && this.contracts.realitio.params.contractAddress) {
      this.getRealitioERC20Contract(this.contracts.realitio.params.contractAddress);
    }
    if (this.contracts.erc20 && this.contracts.erc20.params.contractAddress) {
      this.getERC20Contract(this.contracts.erc20.params.contractAddress);
    }
  }

  // returns wether wallet is connected to service or not
  async isLoggedIn() {
    return this.bepro.isLoggedIn();
  }

  async login() {
    if (this.loggedIn) return true;

    try {
      this.loggedIn = await this.bepro.login();
      // successful login
      if (this.loggedIn) {
        this.address = await this.getAddress();
        // TODO: set this in bepro
        this.bepro.web3.eth.defaultAccount = this.address;
        // re-fetching contracts
        this.getContracts();
      }
    } catch (e) {
      // should be non-blocking
      return false;
    }

    return this.loggedIn;
  }

  async getAddress() {
    if (this.address) return this.address;

    return this.bepro.getAddress() || '';
  }

  async getBalance() {
    if (!this.address) return 0;

    // returns user balance in ETH
    const balance = await this.bepro.getETHBalance();

    return parseFloat(balance) || 0;
  }

  // PredictionMarket contract functions

  async getMinimumRequiredBalance() {
    const requiredBalance = await this.contracts.pm.getMinimumRequiredBalance();

    return requiredBalance;
  }

  async getMarketFee() {
    const fee = await this.contracts.pm.getFee();

    return fee;
  }

  async createMarket(
    name,
    image,
    duration,
    outcomes,
    category,
    ethAmount
  ) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.createMarket({
      name,
      image,
      duration,
      outcomes,
      category,
      ethAmount,
      oracleAddress: this.address
    });

    return response;
  }

  async buy(
    marketId,
    outcomeId,
    ethAmount,
    minOutcomeSharesToBuy
  ) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.buy({
      marketId,
      outcomeId,
      ethAmount,
      minOutcomeSharesToBuy
    });

    return response;
  }

  async sell(
    marketId,
    outcomeId,
    ethAmount,
    maxOutcomeSharesToSell
  ) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.sell({
      marketId,
      outcomeId,
      ethAmount,
      maxOutcomeSharesToSell
    });

    return response;
  }

  async addLiquidity(marketId, ethAmount) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.addLiquidity({
      marketId,
      ethAmount
    });

    return response;
  }

  async removeLiquidity(marketId, shares) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.removeLiquidity({
      marketId,
      shares
    });

    return response;
  }

  async claimWinnings(marketId) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.claimWinnings({
      marketId
    });

    return response;
  }

  async claimVoidedOutcomeShares(marketId, outcomeId) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.claimVoidedOutcomeShares({
      marketId,
      outcomeId
    });

    return response;
  }

  async claimLiquidity(marketId) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.claimLiquidity({
      marketId
    });

    return response;
  }

  async getMarketData(marketId) {
    // ensuring user has wallet connected
    await this.login();

    const marketData = await this.contracts.pm.getMarketData({ marketId });

    marketData.outcomes = await Promise.all(
      marketData.outcomeIds.map(async outcomeId => {
        const outcomeData = await this.contracts.pm.getOutcomeData({
          marketId,
          outcomeId
        });

        return outcomeData;
      })
    );

    return marketData;
  }

  async getMarketPrices(marketId) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.getMarketPrices({ marketId });

    return response;
  }

  async getPortfolio() {
    // ensuring user has wallet connected
    if (!this.address) return {};

    const response = await this.contracts.pm.getMyPortfolio();

    return response;
  }

  async getActions() {
    // ensuring user has wallet connected
    if (!this.address) return [];

    const response = await this.contracts.pm.getMyActions();

    return response;
  }

  async resolveMarket(marketId) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.pm.resolveMarketOutcome({
      marketId
    });

    return response;
  }

  // ERC20 contract functions

  async getERC20Balance() {
    if (!this.address) return 0;

    // TODO improve this: ensuring erc20 contract is initialized
    // eslint-disable-next-line no-underscore-dangle
    await this.contracts.erc20.__init__();

    // returns user balance in ETH
    const balance = await this.contracts.erc20.getTokenAmount(this.address);

    return parseFloat(balance) || 0;
  }

  async approveERC20(address, amount) {
    // ensuring user has wallet connected
    await this.login();

    // ensuring erc20 contract is initialized
    // eslint-disable-next-line no-underscore-dangle
    await this.contracts.erc20.__init__();

    const response = await this.contracts.erc20.approve({
      address,
      amount
    });

    return response;
  }

  async calcBuyAmount(marketId, outcomeId, ethAmount) {
    const response = await this.contracts.pm.calcBuyAmount({
      marketId,
      outcomeId,
      ethAmount
    });

    return response;
  }

  async calcSellAmount(
    marketId,
    outcomeId,
    ethAmount
  ) {
    const response = await this.contracts.pm.calcSellAmount({
      marketId,
      outcomeId,
      ethAmount
    });

    return response;
  }

  // Realitio contract functions

  async isRealitioERC20Approved() {
    if (!this.address) return false;

    // TODO improve this: ensuring erc20 contract is initialized
    // eslint-disable-next-line no-underscore-dangle
    await this.contracts.erc20.__init__();

    // returns user balance in ETH
    const isApproved = await this.contracts.erc20.isApproved({
      address: this.address,
      amount: 1,
      spenderAddress: this.contracts.realitio.getAddress()
    });

    return isApproved;
  }

  async approveRealitioERC20() {
    // ensuring user has wallet connected
    await this.login();

    if (!this.address) return false;

    // TODO improve this: ensuring erc20 contract is initialized
    // eslint-disable-next-line no-underscore-dangle
    await this.contracts.erc20.__init__();

    return this.approveERC20(
      this.contracts.realitio.getAddress(),
      2 ** 128 - 1
    );
  }

  async getQuestionBonds(questionId, user = null) {
    const bonds = await this.contracts.realitio.getQuestionBondsByAnswer({
      questionId,
      user
    });

    // mapping answer ids to outcome ids
    Object.keys(bonds).forEach(answerId => {
      const outcomeId = Number(
        realitioLib.bytes32ToString(answerId, { type: 'int' })
      );
      bonds[outcomeId] = bonds[answerId];
      delete bonds[answerId];
    });

    return bonds;
  }

  async placeBond(questionId, outcomeId, amount) {
    // ensuring user has wallet connected
    await this.login();

    // translating outcome id to answerId
    const answerId = realitioLib.answerToBytes32(outcomeId, { type: 'int' });

    const response = await this.contracts.realitio.submitAnswerERC20({
      questionId,
      answerId,
      amount
    });

    return response;
  }

  async claimWinningsAndWithdraw(questionId) {
    // ensuring user has wallet connected
    await this.login();

    const response = await this.contracts.realitio.claimWinningsAndWithdraw({
      questionId
    });

    return response;
  }

  async getBonds() {
    // ensuring user has wallet connected
    if (!this.address) return {};

    const bonds = await this.contracts.realitio.getMyBonds();

    return bonds;
  }

  async getBondActions() {
    // ensuring user has wallet connected
    if (!this.address) return [];

    const response = await this.contracts.realitio.getMyActions();

    return response;
  }

  async getQuestion(questionId) {
    const question = await this.contracts.realitio.getQuestion({ questionId });

    return question;
  }
}
