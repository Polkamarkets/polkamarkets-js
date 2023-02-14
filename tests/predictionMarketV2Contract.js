

import { expect } from 'chai';
import moment from 'moment';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Prediction Market Contract V2', async () => {
  require('dotenv').config();

  let app;
  let accountAddress;
  let predictionMarketContract;
  let realitioERC20Contract
  let requiredBalanceERC20Contract;
  let tokenERC20Contract;
  let WETH9Contract;

  // market / outcome ids we'll make unit tests with
  let outcomeIds = [0, 1];
  const value = 0.01;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: process.env.WEB3_PRIVATE_KEY
      });
      expect(app).to.not.equal(null);
    }));

    it('should deploy Prediction Market Contract', mochaAsync(async () => {
      // Create Contract
      predictionMarketContract = app.getPredictionMarketV2Contract({});
      realitioERC20Contract = app.getRealitioERC20Contract({});
      requiredBalanceERC20Contract = app.getERC20Contract({});
      tokenERC20Contract = app.getERC20Contract({});
      WETH9Contract = app.getWETH9Contract({});

      // Deploy
      await realitioERC20Contract.deploy({});
      await requiredBalanceERC20Contract.deploy({params: ['Polkamarkets', 'POLK']});
      await WETH9Contract.deploy({});

      const realitioContractAddress = realitioERC20Contract.getAddress();
      const requiredBalanceERC20ContractAddress = requiredBalanceERC20Contract.getAddress();
      accountAddress = await predictionMarketContract.getMyAccount();
      const WETH9ContractAddress = WETH9Contract.getAddress();

      await predictionMarketContract.deploy({
        params: [
          0,
          requiredBalanceERC20ContractAddress,
          0,
          realitioContractAddress,
          86400,
          WETH9ContractAddress
        ]
      });
      const predictionMarketContractAddress = predictionMarketContract.getAddress();

      expect(predictionMarketContractAddress).to.not.equal(null);
      expect(realitioContractAddress).to.not.equal(null);

      await tokenERC20Contract.deploy({params: ['Test Token', 'TEST']});

      // minting tokens for market interaction
      await tokenERC20Contract.getContract().methods.mint(accountAddress, '100000000000000000000000000').send({ from: accountAddress });

      const balance = await tokenERC20Contract.getContract().methods.balanceOf(accountAddress).call();
      const supply = await tokenERC20Contract.getContract().methods.totalSupply().call();

      expect(balance).to.equal('100000000000000000000000000');
      expect(balance).to.equal(supply);

      // approve tokens for market interaction
      await tokenERC20Contract.getContract().methods.approve(predictionMarketContractAddress, '100000000000000000000000000').send({ from: accountAddress });

      // setting predictionMarket ownable vars
      // await predictionMarketContract.getContract().methods.initialize().send({ from: accountAddress });
      // // setting realitioERC20 governance vars
      // await predictionMarketContract.getContract().methods.setRealitioERC20(realitioContractAddress).send({ from: accountAddress });
      // await predictionMarketContract.getContract().methods.setRealitioTimeout(86400).send({ from: accountAddress });
      // await predictionMarketContract.getContract().methods.setToken(ERC20ContractAddress).send({ from: accountAddress });
      // await predictionMarketContract.getContract().methods.setRequiredBalance(0).send({ from: accountAddress });
    }));
  });

  context('Market Creation', async () => {
    let marketId;

    it('should create a Market', mochaAsync(async () => {
      try {
        const res = await predictionMarketContract.createMarket({
          value,
          name: 'Will BTC price close above 100k$ on May 1st 2024',
          description: 'This is a description',
          image: 'foo-bar',
          category: 'Foo;Bar',
          oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
          duration: moment('2024-05-01').unix(),
          outcomes: ['Yes', 'No'],
          token: tokenERC20Contract.getAddress(),
        });
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const marketIds = await predictionMarketContract.getMarkets();
      marketId = marketIds[marketIds.length - 1];
      expect(marketIds.length).to.equal(1);
      expect(marketIds[marketIds.length - 1]).to.equal(marketId);
    }));

    it('should create another Market', mochaAsync(async () => {
      const res = await predictionMarketContract.createMarket({
        name: 'Will ETH price close above 10k$ on May 1st 2024',
        image: 'foo-bar',
        category: 'Foo;Bar',
        oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
        duration: moment('2024-05-01').unix(),
        outcomes: ['Yes', 'No'],
        value: 0.001,
        token: tokenERC20Contract.getAddress(),
      });
      expect(res.status).to.equal(true);

      const marketIds = await predictionMarketContract.getMarkets();
      expect(marketIds.length).to.equal(2);
    }));
  });

  context('Market Data', async () => {
    let marketId = 0;
    it('should get Market data', mochaAsync(async () => {
      const res = await predictionMarketContract.getMarketData({marketId});
      expect(res).to.eql({
        name: '',
        closeDateTime: '2024-05-01 00:00',
        state: 0,
        oracleAddress: '0x0000000000000000000000000000000000000000',
        liquidity: 0.01,
        outcomeIds: [0, 1],
      });
    }));

    it('should get Market details', mochaAsync(async () => {
      const res = await predictionMarketContract.getMarketDetails({marketId});
      expect(res).to.eql({
        name: 'Will BTC price close above 100k$ on May 1st 2024',
        description: 'This is a description',
        category: 'Foo',
        subcategory: 'Bar',
        outcomes: ['Yes', 'No'],
        image: 'foo-bar'
      });
    }));

    it('should get Market Outcomes data', mochaAsync(async () => {
      const outcome1Data = await predictionMarketContract.getOutcomeData({marketId, outcomeId: outcomeIds[0]});
      expect(outcome1Data).to.include({
        price: 0.5,
        shares: 0.01
      });

      const outcome2Data = await predictionMarketContract.getOutcomeData({marketId, outcomeId: outcomeIds[1]});
      expect(outcome2Data).to.include({
        price: 0.5,
        shares: 0.01
      });

      // outcomes share prices should sum to 1
      expect(outcome1Data.price + outcome2Data.price).to.equal(1);
      // outcomes number of shares should dum to value * 2
      expect(outcome1Data.shares + outcome2Data.shares).to.equal(value * 2);
    }));
  });

  context('Market Interaction - WETH Market', async () => {
    let marketId;
    const wrapped = true;

    before(mochaAsync(async () => {
      try {
        const res = await predictionMarketContract.createMarketWithETH({
          value,
          name: 'WETH Market',
          image: 'foo-bar',
          category: 'Foo;Bar',
          oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
          duration: moment('2024-05-01').unix(),
          outcomes: ['A', 'B']
        });
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const marketIds = await predictionMarketContract.getMarkets();
      marketId = marketIds[marketIds.length - 1];
    }));

    it('should match WETH supply', mochaAsync(async () => {
      const ETHBalance = Number(await WETH9Contract.getBalance());
      expect(Number(ETHBalance)).to.equal(value);

      const WETHSupply = await WETH9Contract.totalSupply();
      expect(Number(WETHSupply)).to.equal(value);
    }));

    it('should match market WETH balance', mochaAsync(async () => {
      const contractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      expect(contractBalance).to.equal(value);
    }));

    it('should add liquidity', mochaAsync(async () => {
      const contractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const WETHBalance = Number(await WETH9Contract.getBalance());

      try {
        const res = await predictionMarketContract.addLiquidity({marketId, value, wrapped})
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const newContractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const NewWETHBalance = Number(await WETH9Contract.getBalance());
      const amountTransferred = Number((newContractBalance - contractBalance).toFixed(5));

      expect(amountTransferred).to.equal(value);
      expect(NewWETHBalance).to.equal(WETHBalance + value);
    }));

    it('should remove liquidity', mochaAsync(async () => {
      const contractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const WETHBalance = Number(await WETH9Contract.getBalance());

      try {
        const res = await predictionMarketContract.removeLiquidity({marketId, shares: value, wrapped})
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const newContractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const NewWETHBalance = Number(await WETH9Contract.getBalance());
      const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));

      expect(amountTransferred).to.equal(value);
      expect(NewWETHBalance).to.equal(WETHBalance - value);
    }));

    it('should buy outcome shares', mochaAsync(async () => {
      const outcomeId = 0;
      const minOutcomeSharesToBuy = 0.015;

      const contractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const WETHBalance = Number(await WETH9Contract.getBalance());

      try {
        const res = await predictionMarketContract.buy({marketId, outcomeId, value, minOutcomeSharesToBuy, wrapped});
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const newContractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const NewWETHBalance = Number(await WETH9Contract.getBalance());
      const amountTransferred = Number((newContractBalance - contractBalance).toFixed(5));

      expect(amountTransferred).to.equal(value);
      expect(NewWETHBalance).to.equal(WETHBalance + value);
    }));

    it('should sell outcome shares', mochaAsync(async () => {
      const outcomeId = 0;
      const maxOutcomeSharesToSell = 0.015;

      const contractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const WETHBalance = Number(await WETH9Contract.getBalance());

      try {
        const res = await predictionMarketContract.sell({marketId, outcomeId, value, maxOutcomeSharesToSell, wrapped});
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const newContractBalance = await WETH9Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const NewWETHBalance = Number(await WETH9Contract.getBalance());
      const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));

      expect(amountTransferred).to.equal(value);
      expect(NewWETHBalance).to.equal(WETHBalance - value);
    }));
  });

  context('Market Interaction - Balanced Market (Same Outcome Odds)', async () => {
    let marketId = 0;
    it('should add liquidity without changing shares balance', mochaAsync(async () => {
      const myShares = await predictionMarketContract.getMyMarketShares({marketId});
      const marketData = await predictionMarketContract.getMarketData({marketId});
      const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});

      // balanced market - same price in all outcomoes
      expect(outcomePrices.outcomes[0]).to.equal(outcomePrices.outcomes[1]);

      try {
        const res = await predictionMarketContract.addLiquidity({marketId, value})
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const myNewShares = await predictionMarketContract.getMyMarketShares({marketId});
      const newMarketData = await predictionMarketContract.getMarketData({marketId});
      const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});

      expect(newMarketData.liquidity).to.above(marketData.liquidity);
      expect(newMarketData.liquidity).to.equal(marketData.liquidity + value);

      // Outcome prices shoud remain the same after providing liquidity
      expect(newOutcomePrices.outcomes[0]).to.equal(outcomePrices.outcomes[0]);
      expect(newOutcomePrices.outcomes[1]).to.equal(outcomePrices.outcomes[1]);

      // Price balances are 0.5-0.5, liquidity will be added solely through liquidity shares
      expect(myNewShares.liquidityShares).to.above(myShares.liquidityShares);
      expect(myNewShares.liquidityShares).to.equal(myShares.liquidityShares + value);
      // shares balance remains the same
      expect(myNewShares.outcomeShares[0]).to.equal(myShares.outcomeShares[0]);
      expect(myNewShares.outcomeShares[1]).to.equal(myShares.outcomeShares[1]);
    }));

    it('should remove liquidity without changing shares balance', mochaAsync(async () => {
      const myShares = await predictionMarketContract.getMyMarketShares({marketId});
      const marketData = await predictionMarketContract.getMarketData({marketId});
      const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const contractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

      // balanced market - same price in all outcomoes
      expect(outcomePrices.outcomes[0]).to.equal(outcomePrices.outcomes[1]);

      try {
        const res = await predictionMarketContract.removeLiquidity({marketId, shares: value})
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const myNewShares = await predictionMarketContract.getMyMarketShares({marketId});
      const newMarketData = await predictionMarketContract.getMarketData({marketId});
      const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const newContractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

      expect(newMarketData.liquidity).to.below(marketData.liquidity);
      expect(newMarketData.liquidity).to.equal(marketData.liquidity - value);

      // Outcome prices shoud remain the same after providing liquidity
      expect(newOutcomePrices.outcomes[0]).to.equal(outcomePrices.outcomes[0]);
      expect(newOutcomePrices.outcomes[1]).to.equal(outcomePrices.outcomes[1]);

      // Price balances are 0.5-0.5, liquidity will be added solely through liquidity shares
      expect(myNewShares.liquidityShares).to.below(myShares.liquidityShares);
      expect(myNewShares.liquidityShares).to.equal(myShares.liquidityShares - value);
      // shares balance remains the same
      expect(myNewShares.outcomeShares[0]).to.equal(myShares.outcomeShares[0]);
      expect(myNewShares.outcomeShares[1]).to.equal(myShares.outcomeShares[1]);

      // User gets liquidity tokens back in ETH
      expect(newContractBalance).to.below(contractBalance);
      const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));
      expect(amountTransferred).to.equal(value);
    }));
  });

  context('Market Interaction - Unbalanced Market (Different Outcome Odds)', async () => {
    let marketId = 0;
    it('should display my shares', mochaAsync(async () => {
      const res = await predictionMarketContract.getMyMarketShares({marketId});
      // currently holding liquidity tokens from market creation
      expect(res).to.eql({
        liquidityShares: 0.01,
        outcomeShares: {
          0: 0.00,
          1: 0.00,
        }
      });
    }));

    it('should buy outcome shares', mochaAsync(async () => {
      const outcomeId = 0;
      const minOutcomeSharesToBuy = 0.015;

      const marketData = await predictionMarketContract.getMarketData({marketId});
      const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const outcomeShares = await predictionMarketContract.getMarketShares({marketId});
      const contractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

      try {
        const res = await predictionMarketContract.buy({marketId, outcomeId, value, minOutcomeSharesToBuy});
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const newMarketData = await predictionMarketContract.getMarketData({marketId});
      const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const newOutcomeShares = await predictionMarketContract.getMarketShares({marketId});
      const newContractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

      // outcome price should increase
      expect(newOutcomePrices.outcomes[0]).to.above(outcomePrices.outcomes[0]);
      expect(newOutcomePrices.outcomes[0]).to.equal(0.8);
      // opposite outcome price should decrease
      expect(newOutcomePrices.outcomes[1]).to.below(outcomePrices.outcomes[1]);
      expect(newOutcomePrices.outcomes[1]).to.equal(0.2);
      // Prices sum = 1
      // 0.5 + 0.5 = 1
      expect(newOutcomePrices.outcomes[0] + newOutcomePrices.outcomes[1]).to.equal(1);

      // Liquidity value remains the same
      expect(newMarketData.liquidity).to.equal(marketData.liquidity);

      // outcome shares should decrease
      expect(newOutcomeShares.outcomes[0]).to.below(outcomeShares.outcomes[0]);
      expect(newOutcomeShares.outcomes[0]).to.equal(0.005);
      // opposite outcome shares should increase
      expect(newOutcomeShares.outcomes[1]).to.above(outcomeShares.outcomes[1]);
      expect(newOutcomeShares.outcomes[1]).to.equal(0.02);
      // # Shares Product = Liquidity^2
      // 0.005 * 0.02 = 0.01^2
      expect(outcomeShares.outcomes[0] * outcomeShares.outcomes[1]).to.equal(newMarketData.liquidity**2);
      expect(newOutcomeShares.outcomes[0] * newOutcomeShares.outcomes[1]).to.equal(newMarketData.liquidity**2);

      const myShares = await predictionMarketContract.getMyMarketShares({marketId});
      expect(myShares).to.eql({
        liquidityShares: 0.01,
        outcomeShares: {
          0: 0.015,
          1: 0.00,
        }
      });

      // Contract adds value to balance
      expect(newContractBalance).to.above(contractBalance);
      // TODO: check amountReceived from internal transactions
      const amountReceived = Number((newContractBalance - contractBalance).toFixed(5));
      expect(amountReceived).to.equal(value);
    }));

    it('should add liquidity', mochaAsync(async () => {
      const myShares = await predictionMarketContract.getMyMarketShares({marketId});
      const marketData = await predictionMarketContract.getMarketData({marketId});
      const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const outcomeShares = await predictionMarketContract.getMarketShares({marketId});

      try {
        const res = await predictionMarketContract.addLiquidity({marketId, value})
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const myNewShares = await predictionMarketContract.getMyMarketShares({marketId});
      const newMarketData = await predictionMarketContract.getMarketData({marketId});
      const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const newOutcomeShares = await predictionMarketContract.getMarketShares({marketId});

      // Outcome prices shoud remain the same after providing liquidity
      expect(newOutcomePrices.outcomes[0]).to.equal(outcomePrices.outcomes[0]);
      expect(newOutcomePrices.outcomes[1]).to.equal(outcomePrices.outcomes[1]);

      // # Shares Product = Liquidity^2
      // 0.0075 * 0.03 = 0.015^2
      expect(newMarketData.liquidity).to.above(marketData.liquidity);
      expect(newMarketData.liquidity).to.equal(0.015);
      expect(newOutcomeShares.outcomes[0]).to.above(outcomeShares.outcomes[0]);
      expect(newOutcomeShares.outcomes[0]).to.equal(0.0075);
      expect(newOutcomeShares.outcomes[1]).to.above(outcomeShares.outcomes[1]);
      expect(newOutcomeShares.outcomes[1]).to.equal(0.03);
      expect(newOutcomeShares.outcomes[0] * newOutcomeShares.outcomes[1]).to.equal(newMarketData.liquidity**2);

      // Price balances are not 0.5-0.5, liquidity will be added through shares + liquidity
      expect(myNewShares.liquidityShares).to.above(myShares.liquidityShares);
      expect(myNewShares.liquidityShares).to.equal(0.015);
      // shares balance of higher odd outcome increases
      expect(myNewShares.outcomeShares[0]).to.above(myShares.outcomeShares[0]);
      expect(myNewShares.outcomeShares[0]).to.equal(0.0225);
      // shares balance of lower odd outcome remains
      expect(myNewShares.outcomeShares[1]).to.equal(myShares.outcomeShares[1]);
      expect(myNewShares.outcomeShares[1]).to.equal(0);
    }));

    it('should remove liquidity', mochaAsync(async () => {
      const myShares = await predictionMarketContract.getMyMarketShares({marketId});
      const marketData = await predictionMarketContract.getMarketData({marketId});
      const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const outcomeShares = await predictionMarketContract.getMarketShares({marketId});
      const contractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});
      const liquiditySharesToRemove = 0.005;

      try {
        const res = await predictionMarketContract.removeLiquidity({marketId, shares: liquiditySharesToRemove});
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const myNewShares = await predictionMarketContract.getMyMarketShares({marketId});
      const newMarketData = await predictionMarketContract.getMarketData({marketId});
      const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const newOutcomeShares = await predictionMarketContract.getMarketShares({marketId});
      const newContractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

      // Outcome prices shoud remain the same after removing liquidity
      expect(newOutcomePrices.outcomes[0]).to.equal(outcomePrices.outcomes[0]);
      expect(newOutcomePrices.outcomes[1]).to.equal(outcomePrices.outcomes[1]);

      // # Shares Product = Liquidity^2
      // 0.005 * 0.02 = 0.01^2
      expect(newMarketData.liquidity).to.below(marketData.liquidity);
      expect(newMarketData.liquidity).to.equal(0.01);
      expect(newOutcomeShares.outcomes[0]).to.below(outcomeShares.outcomes[0]);
      expect(newOutcomeShares.outcomes[0]).to.equal(0.005);
      expect(newOutcomeShares.outcomes[1]).to.below(outcomeShares.outcomes[1]);
      expect(newOutcomeShares.outcomes[1]).to.equal(0.02);
      expect(newOutcomeShares.outcomes[0] * newOutcomeShares.outcomes[1]).to.equal(newMarketData.liquidity**2);

      // Price balances are not 0.5-0.5, liquidity will be added through shares + liquidity
      expect(myNewShares.liquidityShares).to.below(myShares.liquidityShares);
      expect(myNewShares.liquidityShares).to.equal(0.01);
      // shares balance of higher odd outcome remains
      expect(myNewShares.outcomeShares[0]).to.equal(myShares.outcomeShares[0]);
      expect(myNewShares.outcomeShares[0]).to.equal(0.0225);
      // shares balance of lower odd outcome increases
      expect(myNewShares.outcomeShares[1]).to.above(myShares.outcomeShares[1]);
      expect(myNewShares.outcomeShares[1]).to.equal(0.0075);

      // User gets part of the liquidity tokens back in ETH
      expect(newContractBalance).to.below(contractBalance);
      const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));
      expect(amountTransferred).to.equal(0.0025);
    }));

    it('should sell outcome shares', mochaAsync(async () => {
      const outcomeId = 0;
      const maxOutcomeSharesToSell = 0.015;

      const marketData = await predictionMarketContract.getMarketData({marketId});
      const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const outcomeShares = await predictionMarketContract.getMarketShares({marketId});
      const contractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

      try {
        const res = await predictionMarketContract.sell({marketId, outcomeId, value, maxOutcomeSharesToSell});
        expect(res.status).to.equal(true);
      } catch(e) {
        console.log(e);
      }

      const newMarketData = await predictionMarketContract.getMarketData({marketId});
      const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
      const newOutcomeShares = await predictionMarketContract.getMarketShares({marketId});
      const newContractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

      // outcome price should decrease
      expect(newOutcomePrices.outcomes[0]).to.below(outcomePrices.outcomes[0]);
      expect(newOutcomePrices.outcomes[0]).to.equal(0.5);
      // opposite outcome price should increase
      expect(newOutcomePrices.outcomes[1]).to.above(outcomePrices.outcomes[1]);
      expect(newOutcomePrices.outcomes[1]).to.equal(0.5);
      // Prices sum = 1
      // 0.5 + 0.5 = 1
      expect(newOutcomePrices.outcomes[0] + newOutcomePrices.outcomes[1]).to.equal(1);

      // Liquidity value remains the same
      expect(newMarketData.liquidity).to.equal(marketData.liquidity);

      // outcome shares should increase
      expect(newOutcomeShares.outcomes[0]).to.above(outcomeShares.outcomes[0]);
      expect(newOutcomeShares.outcomes[0]).to.equal(0.01);
      // opposite outcome shares should increase
      expect(newOutcomeShares.outcomes[1]).to.below(outcomeShares.outcomes[1]);
      expect(newOutcomeShares.outcomes[1]).to.equal(0.01);
      // # Shares Product = Liquidity^2
      // 0.01 * 0.01 = 0.01^2
      expect(outcomeShares.outcomes[0] * outcomeShares.outcomes[1]).to.equal(newMarketData.liquidity**2);
      expect(newOutcomeShares.outcomes[0] * newOutcomeShares.outcomes[1]).to.equal(newMarketData.liquidity**2);

      const myShares = await predictionMarketContract.getMyMarketShares({marketId});
      expect(myShares).to.eql({
        liquidityShares: 0.01,
        outcomeShares: {
          0: 0.0075,
          1: 0.0075,
        }
      });

      // User gets shares value back in ETH
      expect(newContractBalance).to.below(contractBalance);
      const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));
      expect(amountTransferred).to.equal(0.01);
    }));
  });

  context('Multiple Outcomes', async () => {
    let marketId = 0;
    context('Market Creation', async () => {
      it('should create a Market with 3 outcomes', mochaAsync(async () => {
        try {
          const res = await predictionMarketContract.createMarket({
            value,
            name: 'Market with 3 outcomes',
            image: 'foo-bar',
            category: 'Foo;Bar',
            oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
            duration: moment('2024-05-01').unix(),
            outcomes: ['A', 'B', 'C'],
            token: tokenERC20Contract.getAddress(),
          });
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const marketIds = await predictionMarketContract.getMarkets();
        marketId = marketIds[marketIds.length - 1];

        const res = await predictionMarketContract.getMarketData({marketId});
        expect(res.outcomeIds.length).to.eql(3);
        expect(res.outcomeIds).to.eql([0, 1, 2]);
      }));

      it('should create a Market with 32 outcomes', mochaAsync(async () => {
        // Array with outcomes with outcome id as name
        // TODO: improve gas optimization for markets with 10+ outcomes
        const outcomeCount = 32;
        const outcomes = Array.from(Array(outcomeCount).keys());

        try {
          const res = await predictionMarketContract.createMarket({
            value,
            name: `Market with ${outcomeCount} outcomes`,
            image: 'foo-bar',
            category: 'Foo;Bar',
            oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
            duration: moment('2024-05-01').unix(),
            outcomes,
            token: tokenERC20Contract.getAddress(),
          });
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const marketIds = await predictionMarketContract.getMarkets();
        marketId = marketIds[marketIds.length - 1];

        const res = await predictionMarketContract.getMarketData({marketId});
        expect(res.outcomeIds.length).to.eql(outcomeCount);
        expect(res.outcomeIds).to.eql(outcomes);
      }));

      it('should not create a Market with more than 32 outcomes', mochaAsync(async () => {
        const oldMarketIds = await predictionMarketContract.getMarkets();
        try {
          const outcomes = Array.from(Array(33).keys());

          const res = await predictionMarketContract.createMarket({
            value,
            name: 'Market with 257 outcomes',
            image: 'foo-bar',
            category: 'Foo;Bar',
            oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
            duration: moment('2024-05-01').unix(),
            outcomes,
            token: tokenERC20Contract.getAddress(),
          });
          expect(res.status).to.equal(true);
        } catch(e) {
          // not logging error, as tx is expected to fail
          // console.log(e);
        }

        const currentMarketIds = await predictionMarketContract.getMarkets();

        expect(currentMarketIds.length).to.eql(oldMarketIds.length);
      }));
    });

    context('Market Interaction', async () => {
      let marketId;
      let outcomeIds = [0, 1, 2];

      before(mochaAsync(async () => {
        try {
          const res = await predictionMarketContract.createMarket({
            value,
            name: 'Market with 3 outcomes',
            image: 'foo-bar',
            category: 'Foo;Bar',
            oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
            duration: moment('2024-05-01').unix(),
            outcomes: ['D', 'E', 'F'],
            token: tokenERC20Contract.getAddress(),
          });
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const marketIds = await predictionMarketContract.getMarkets();
        marketId = marketIds[marketIds.length - 1];
      }));

      it('should buy outcome shares', mochaAsync(async () => {
        const outcomeId = 0;
        const minOutcomeSharesToBuy = 0.015;

        const marketData = await predictionMarketContract.getMarketData({marketId});
        const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
        const outcomeShares = await predictionMarketContract.getMarketShares({marketId});
        const contractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

        try {
          const res = await predictionMarketContract.buy({marketId, outcomeId, value, minOutcomeSharesToBuy});
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const newMarketData = await predictionMarketContract.getMarketData({marketId});
        const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
        const newOutcomeShares = await predictionMarketContract.getMarketShares({marketId});
        const newContractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

        // outcome price should increase
        expect(newOutcomePrices.outcomes[0]).to.above(outcomePrices.outcomes[0]);
        expect(newOutcomePrices.outcomes[0]).to.equal(0.8);
        // opposite outcome price should decrease
        expect(newOutcomePrices.outcomes[1]).to.below(outcomePrices.outcomes[1]);
        expect(newOutcomePrices.outcomes[1]).to.equal(0.1);
        expect(newOutcomePrices.outcomes[2]).to.below(outcomePrices.outcomes[2]);
        expect(newOutcomePrices.outcomes[2]).to.equal(0.1);
        // Prices sum = 1
        // 0.1 + 0.1 + 0.8 = 1
        expect(newOutcomePrices.outcomes[0] + newOutcomePrices.outcomes[1] + newOutcomePrices.outcomes[2]).to.equal(1);

        // Liquidity value remains the same
        expect(newMarketData.liquidity).to.equal(marketData.liquidity);

        // outcome shares should decrease
        expect(newOutcomeShares.outcomes[0]).to.below(outcomeShares.outcomes[0]);
        expect(newOutcomeShares.outcomes[0]).to.equal(0.0025);
        // opposite outcome shares should increase
        expect(newOutcomeShares.outcomes[1]).to.above(outcomeShares.outcomes[1]);
        expect(newOutcomeShares.outcomes[1]).to.equal(0.02);
        expect(newOutcomeShares.outcomes[2]).to.above(outcomeShares.outcomes[2]);
        expect(newOutcomeShares.outcomes[2]).to.equal(0.02);
        // # Shares Product = Liquidity^2
        // 0.0025 * 0.02 * 0.02 = 0.01^3
        expect(outcomeShares.outcomes[0] * outcomeShares.outcomes[1] * outcomeShares.outcomes[2]).to.equal(newMarketData.liquidity ** 3);
        expect(newOutcomeShares.outcomes[0] * newOutcomeShares.outcomes[1] * newOutcomeShares.outcomes[2]).to.equal(newMarketData.liquidity ** 3);

        const myShares = await predictionMarketContract.getMyMarketShares({marketId});
        expect(myShares).to.eql({
          liquidityShares: 0.01,
          outcomeShares: {
            0: 0.0175,
            1: 0.00,
            2: 0.00,
          }
        });

        // Contract adds value to balance
        expect(newContractBalance).to.above(contractBalance);
        // TODO: check amountReceived from internal transactions
        const amountReceived = Number((newContractBalance - contractBalance).toFixed(5));
        expect(amountReceived).to.equal(value);
      }));

      it('should add liquidity', mochaAsync(async () => {
        const myShares = await predictionMarketContract.getMyMarketShares({marketId});
        const marketData = await predictionMarketContract.getMarketData({marketId});
        const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
        const outcomeShares = await predictionMarketContract.getMarketShares({marketId});

        try {
          const res = await predictionMarketContract.addLiquidity({marketId, value})
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const myNewShares = await predictionMarketContract.getMyMarketShares({marketId});
        const newMarketData = await predictionMarketContract.getMarketData({marketId});
        const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
        const newOutcomeShares = await predictionMarketContract.getMarketShares({marketId});

        // Outcome prices shoud remain the same after providing liquidity
        expect(newOutcomePrices.outcomes[0]).to.equal(outcomePrices.outcomes[0]);
        expect(newOutcomePrices.outcomes[1]).to.equal(outcomePrices.outcomes[1]);
        expect(newOutcomePrices.outcomes[2]).to.equal(outcomePrices.outcomes[2]);

        // # Shares Product = Liquidity^2
        // 0.00375 * 0.03 * 0.03 = 0.015^3
        expect(newMarketData.liquidity).to.above(marketData.liquidity);
        expect(newMarketData.liquidity).to.equal(0.015);
        expect(newOutcomeShares.outcomes[0]).to.above(outcomeShares.outcomes[0]);
        expect(newOutcomeShares.outcomes[0]).to.equal(0.00375);
        expect(newOutcomeShares.outcomes[1]).to.above(outcomeShares.outcomes[1]);
        expect(newOutcomeShares.outcomes[1]).to.equal(0.03);
        expect(newOutcomeShares.outcomes[2]).to.above(outcomeShares.outcomes[2]);
        expect(newOutcomeShares.outcomes[2]).to.equal(0.03);
        expect(newOutcomeShares.outcomes[0] * newOutcomeShares.outcomes[1] * newOutcomeShares.outcomes[2]).to.be.closeTo(newMarketData.liquidity ** 3, 0.00000001);

        // Price balances are not 0.5-0.5, liquidity will be added through shares + liquidity
        expect(myNewShares.liquidityShares).to.above(myShares.liquidityShares);
        expect(myNewShares.liquidityShares).to.equal(0.015);
        // shares balance of higher odd outcome increases
        expect(myNewShares.outcomeShares[0]).to.above(myShares.outcomeShares[0]);
        expect(myNewShares.outcomeShares[0]).to.equal(0.02625);
        // shares balance of lower odd outcome remains
        expect(myNewShares.outcomeShares[1]).to.equal(myShares.outcomeShares[1]);
        expect(myNewShares.outcomeShares[1]).to.equal(0);
        expect(myNewShares.outcomeShares[2]).to.equal(myShares.outcomeShares[2]);
        expect(myNewShares.outcomeShares[2]).to.equal(0);
      }));

      it('should remove liquidity', mochaAsync(async () => {
        const myShares = await predictionMarketContract.getMyMarketShares({marketId});
        const marketData = await predictionMarketContract.getMarketData({marketId});
        const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
        const outcomeShares = await predictionMarketContract.getMarketShares({marketId});
        const contractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});
        const liquiditySharesToRemove = 0.005;

        try {
          const res = await predictionMarketContract.removeLiquidity({marketId, shares: liquiditySharesToRemove});
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const myNewShares = await predictionMarketContract.getMyMarketShares({marketId});
        const newMarketData = await predictionMarketContract.getMarketData({marketId});
        const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
        const newOutcomeShares = await predictionMarketContract.getMarketShares({marketId});
        const newContractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

        // Outcome prices shoud remain the same after removing liquidity
        expect(newOutcomePrices.outcomes[0]).to.equal(outcomePrices.outcomes[0]);
        expect(newOutcomePrices.outcomes[1]).to.equal(outcomePrices.outcomes[1]);
        expect(newOutcomePrices.outcomes[2]).to.equal(outcomePrices.outcomes[2]);

        // # Shares Product = Liquidity^3
        // 0.0025 * 0.02 * 0.02 = 0.01^3
        expect(newMarketData.liquidity).to.below(marketData.liquidity);
        expect(newMarketData.liquidity).to.equal(0.01);
        expect(newOutcomeShares.outcomes[0]).to.below(outcomeShares.outcomes[0]);
        expect(newOutcomeShares.outcomes[0]).to.equal(0.0025);
        expect(newOutcomeShares.outcomes[1]).to.below(outcomeShares.outcomes[1]);
        expect(newOutcomeShares.outcomes[1]).to.equal(0.02);
        expect(newOutcomeShares.outcomes[2]).to.below(outcomeShares.outcomes[2]);
        expect(newOutcomeShares.outcomes[2]).to.equal(0.02);
        expect(newOutcomeShares.outcomes[0] * newOutcomeShares.outcomes[1] * newOutcomeShares.outcomes[2]).to.equal(newMarketData.liquidity ** 3);

        // Price balances are not 0.5-0.5, liquidity will be added through shares + liquidity
        expect(myNewShares.liquidityShares).to.below(myShares.liquidityShares);
        expect(myNewShares.liquidityShares).to.equal(0.01);
        // shares balance of higher odd outcome remains
        expect(myNewShares.outcomeShares[0]).to.equal(myShares.outcomeShares[0]);
        expect(myNewShares.outcomeShares[0]).to.equal(0.02625);
        // shares balance of lower odd outcome increases
        expect(myNewShares.outcomeShares[1]).to.above(myShares.outcomeShares[1]);
        expect(myNewShares.outcomeShares[1]).to.equal(0.00875);
        expect(myNewShares.outcomeShares[2]).to.above(myShares.outcomeShares[2]);
        expect(myNewShares.outcomeShares[2]).to.equal(0.00875);

        // User gets part of the liquidity tokens back in ETH
        expect(newContractBalance).to.below(contractBalance);
        const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));
        expect(amountTransferred).to.equal(0.00125);
      }));

      it('should sell outcome shares', mochaAsync(async () => {
        const outcomeId = 0;
        const maxOutcomeSharesToSell = 0.0175;

        const marketData = await predictionMarketContract.getMarketData({marketId});
        const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});
        const outcomeShares = await predictionMarketContract.getMarketShares({marketId});
        const contractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

        try {
          const res = await predictionMarketContract.sell({marketId, outcomeId, value, maxOutcomeSharesToSell});
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const newMarketData = await predictionMarketContract.getMarketData({marketId});
        const newOutcomePrices = await predictionMarketContract.getMarketPrices({marketId});
        const newOutcomeShares = await predictionMarketContract.getMarketShares({marketId});
        const newContractBalance = await tokenERC20Contract.balanceOf({address: predictionMarketContract.getAddress()});

        // outcome price should decrease
        expect(newOutcomePrices.outcomes[0]).to.below(outcomePrices.outcomes[0]);
        expect(newOutcomePrices.outcomes[0]).to.equal(1/3);
        // opposite outcome price should increase
        expect(newOutcomePrices.outcomes[1]).to.above(outcomePrices.outcomes[1]);
        expect(newOutcomePrices.outcomes[1]).to.equal(1/3);
        expect(newOutcomePrices.outcomes[2]).to.above(outcomePrices.outcomes[2]);
        expect(newOutcomePrices.outcomes[2]).to.equal(1/3);
        // Prices sum = 1
        // 0.333 + 0.333 + 0.333 = 1
        expect(newOutcomePrices.outcomes[0] + newOutcomePrices.outcomes[1] + newOutcomePrices.outcomes[2]).to.equal(1);

        // Liquidity value remains the same
        expect(newMarketData.liquidity).to.equal(marketData.liquidity);

        // outcome shares should increase
        expect(newOutcomeShares.outcomes[0]).to.above(outcomeShares.outcomes[0]);
        expect(newOutcomeShares.outcomes[0]).to.equal(0.01);
        // opposite outcome shares should increase
        expect(newOutcomeShares.outcomes[1]).to.below(outcomeShares.outcomes[1]);
        expect(newOutcomeShares.outcomes[1]).to.equal(0.01);
        expect(newOutcomeShares.outcomes[2]).to.below(outcomeShares.outcomes[2]);
        expect(newOutcomeShares.outcomes[2]).to.equal(0.01);
        // # Shares Product = Liquidity^2
        // 0.01 * 0.01 = 0.01^2
        expect(outcomeShares.outcomes[0] * outcomeShares.outcomes[1] * outcomeShares.outcomes[2]).to.equal(newMarketData.liquidity ** 3);
        expect(newOutcomeShares.outcomes[0] * newOutcomeShares.outcomes[1] * newOutcomeShares.outcomes[2]).to.equal(newMarketData.liquidity ** 3);

        const myShares = await predictionMarketContract.getMyMarketShares({marketId});
        expect(myShares).to.eql({
          liquidityShares: 0.01,
          outcomeShares: {
            0: 0.00875,
            1: 0.00875,
            2: 0.00875,
          }
        });

        // User gets shares value back in ETH
        expect(newContractBalance).to.below(contractBalance);
        const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));
        expect(amountTransferred).to.equal(0.01);
      }));
    });
    context('Distributed probabilites', async () => {
      let marketId;
      let outcomeIds = [0, 1, 2];

      const initialOdds = [
        [
          [50, 50],
          [50000000, 50000000]
        ],
        [
          [40, 60],
          [60000000, 40000000]
        ],
        [
          [15, 20, 65],
          [1300000000, 975000000, 300000000]
        ],
        [
          [65, 15, 20],
          [300000000, 1300000000, 975000000]
        ],
        [
          [10, 20, 30, 40],
          [24000000000, 12000000000, 8000000000, 6000000000]
        ]
      ];

      for (const [odds, expectedDistribution] of initialOdds) {
        context(`Odds: ${odds}`, async () => {
          before(mochaAsync(async () => {
            const distribution = await predictionMarketContract.calcDistribution({odds});

            expect(distribution).to.eql(expectedDistribution);

            try {
              const res = await predictionMarketContract.createMarket({
                value,
                name: `Market with ${odds} odds`,
                image: 'foo-bar',
                category: 'Foo;Bar',
                oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
                duration: moment('2024-05-01').unix(),
                outcomes: ['A', 'B', 'C', 'D', 'E'].slice(0, odds.length),
                token: tokenERC20Contract.getAddress(),
                odds,
              });
              expect(res.status).to.equal(true);
            } catch(e) {
              console.log(e);
            }

            const marketIds = await predictionMarketContract.getMarkets();
            marketId = marketIds[marketIds.length - 1];
          }));

          it('market prices should match odds', mochaAsync(async () => {
            const outcomePrices = await predictionMarketContract.getMarketPrices({marketId});

            for (let i = 0; i < odds.length; i++) {
              const price = outcomePrices.outcomes[i];
              const expectedPrice = odds[i] / 100;

              expect(price).to.closeTo(expectedPrice, 0.00000001);
            }
          }));

          it('market shares should match shares', mochaAsync(async () => {
            const outcomeShares = await predictionMarketContract.getMarketShares({marketId});

            for (let i = 0; i < odds.length; i++) {
              const shares = outcomeShares.outcomes[i];
              const minOdds = Math.min(...odds);
              const expectedShares = value * minOdds / odds[i];

              expect(shares).to.closeTo(expectedShares, 0.00000001);
            }
          }));

          it('market liquidity should match liquidity', mochaAsync(async () => {
            const marketData = await predictionMarketContract.getMarketData({marketId});
            const expectedLiquidity = value;

            expect(marketData.liquidity).to.equal(expectedLiquidity);
          }));
        });
      }
    });
  });
});
