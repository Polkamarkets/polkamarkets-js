

import { expect } from 'chai';
import moment from 'moment';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Voting Contract', async () => {
  require('dotenv').config();

  let app;
  let votingContract;
  let ERC20Contract;

  // market / outcome ids we'll make unit tests with
  let outcomeIds = [0, 1];
  const ethAmount = 0.01;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: process.env.WEB3_PRIVATE_KEY,
      });

      expect(app).to.not.equal(null);
    }));

    it('should deploy Voting Contract', mochaAsync(async () => {
      // Create Contract
      votingContract = app.getVotingContract({});
      ERC20Contract = app.getERC20Contract({});
      // // Deploy
      await ERC20Contract.deploy({ params: ['Polkamarkets', 'POLK'] });

      const ERC20ContractAddress = ERC20Contract.getAddress();

      await votingContract.deploy({
        params: [
          ERC20ContractAddress,
          0
        ]
      });
      const votingContractAddress = votingContract.getAddress();

      console.log('votingContractAddress:', votingContractAddress);

      expect(votingContractAddress).to.not.equal(null);
    }));
  });

  context('Voting Items', async () => {
    it('should upvote an Item', mochaAsync(async () => {
      let itemId = 0;
      const res = await votingContract.upvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      const itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);


      const userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);
    }));

    it('should downvote an Item', mochaAsync(async () => {
      let itemId = 1;
      const res = await votingContract.downvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      const itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);
    }));

    it('should upvote an Item when there is already a downvote', mochaAsync(async () => {
      let itemId = 1;

      // check first if user has a downvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);

      let userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);


      const res = await votingContract.upvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);
    }));

    it('should downvote an Item when there is already an upvote', mochaAsync(async () => {
      let itemId = 0;

      // check first if user has an upvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);

      let userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);


      const res = await votingContract.downvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);


      userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);
    }));

    it('should not allow to upvote an already upvoted item', mochaAsync(async () => {
      let itemId = 1;

      // check first if user has an upvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);

      let userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);

      let res
      try {
        res = await votingContract.upvoteItem({
          itemId,
        });
      } catch (error) {
        res = { status: false };
      }

      expect(res.status).to.equal(false);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);
    }));

    it('should not allow to downvote an already downvoted item', mochaAsync(async () => {
      let itemId = 0;

      // check first if user has a downvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);

      let userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);

      let res
      try {
        res = await votingContract.downvoteItem({
          itemId,
        });
      } catch (error) {
        res = { status: false };
      }

      expect(res.status).to.equal(false);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);


      userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);
    }));

    it('should allow to remove upvote of an already upvoted item', mochaAsync(async () => {
      let itemId = 1;

      // check first if user has an upvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);

      let userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);


      const res = await votingContract.removeUpvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);
    }));

    it('should allow to remove downvote of an already downvoted item', mochaAsync(async () => {
      let itemId = 0;

      // check first if user has a downvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);

      let userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);


      const res = await votingContract.removeDownvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);
    }));

    it('should not allow to remove upvote of an item not upvoted', mochaAsync(async () => {
      let itemId = 1;

      // check first if user does not have an upvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);

      let userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);


      let res
      try {
        res = await votingContract.removeUpvoteItem({
          itemId,
        });
      } catch (error) {
        res = { status: false };
      }

      expect(res.status).to.equal(false);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);
    }));

    it('should not allow to remove downvote of an item not downvoted', mochaAsync(async () => {
      let itemId = 0;

      // check first if user does not have a downvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);

      let userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);


      let res
      try {
        res = await votingContract.removeDownvoteItem({
          itemId,
        });
      } catch (error) {
        res = { status: false };
      }

      expect(res.status).to.equal(false);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.haveIVotedItem({ itemId });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);
    }));
  });

  // context('Market Data', async () => {
  //   it('should get Market data', mochaAsync(async () => {
  //     const res = await predictionMarketContract.getMarketData({ marketId: 0 });
  //     expect(res).to.eql({
  //       name: '',
  //       closeDateTime: '2022-05-01 00:00',
  //       state: 0,
  //       oracleAddress: '0x0000000000000000000000000000000000000000',
  //       liquidity: 0.01,
  //       outcomeIds: [0, 1],
  //     });
  //   }));

  //   it('should get Market details', mochaAsync(async () => {
  //     const res = await predictionMarketContract.getMarketDetails({ marketId: 0 });
  //     expect(res).to.eql({
  //       name: 'Will BTC price close above 100k$ on May 1st 2022',
  //       category: 'Foo',
  //       subcategory: 'Bar',
  //       outcomes: ['Yes', 'No'],
  //       image: 'foo-bar'
  //     });
  //   }));

  //   it('should get Market Outcomes data', mochaAsync(async () => {
  //     const outcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     expect(outcome1Data).to.include({
  //       price: 0.5,
  //       shares: 0.01
  //     });

  //     const outcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     expect(outcome2Data).to.include({
  //       price: 0.5,
  //       shares: 0.01
  //     });

  //     // outcomes share prices should sum to 1
  //     expect(outcome1Data.price + outcome2Data.price).to.equal(1);
  //     // outcomes number of shares should dum to ethAmount * 2
  //     expect(outcome1Data.shares + outcome2Data.shares).to.equal(ethAmount * 2);
  //   }));
  // });

  // context('Market Interaction - Balanced Market (Same Outcome Odds)', async () => {
  //   it('should add liquidity without changing shares balance', mochaAsync(async () => {
  //     const myShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     const marketData = await predictionMarketContract.getMarketData({ marketId });
  //     const outcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const outcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });

  //     // balanced market - same price in all outcomoes
  //     expect(outcome1Data.price).to.equal(outcome2Data.price);

  //     try {
  //       const res = await predictionMarketContract.addLiquidity({ marketId, ethAmount })
  //       expect(res.status).to.equal(true);
  //     } catch (e) {
  //       // TODO: review this
  //     }

  //     const myNewShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     const newMarketData = await predictionMarketContract.getMarketData({ marketId });
  //     const newOutcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const newOutcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });

  //     expect(newMarketData.liquidity).to.above(marketData.liquidity);
  //     expect(newMarketData.liquidity).to.equal(marketData.liquidity + ethAmount);

  //     // Outcome prices shoud remain the same after providing liquidity
  //     expect(newOutcome1Data.price).to.equal(outcome1Data.price);
  //     expect(newOutcome2Data.price).to.equal(outcome2Data.price);

  //     // Price balances are 0.5-0.5, liquidity will be added solely through liquidity shares
  //     expect(myNewShares.liquidityShares).to.above(myShares.liquidityShares);
  //     expect(myNewShares.liquidityShares).to.equal(myShares.liquidityShares + ethAmount);
  //     // shares balance remains the same
  //     expect(myNewShares.outcomeShares[0]).to.equal(myShares.outcomeShares[0]);
  //     expect(myNewShares.outcomeShares[1]).to.equal(myShares.outcomeShares[1]);
  //   }));

  //   it('should remove liquidity without changing shares balance', mochaAsync(async () => {
  //     const myShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     const marketData = await predictionMarketContract.getMarketData({ marketId });
  //     const outcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const outcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     const contractBalance = Number(await predictionMarketContract.getBalance());

  //     // balanced market - same price in all outcomoes
  //     expect(outcome1Data.price).to.equal(outcome2Data.price);

  //     try {
  //       const res = await predictionMarketContract.removeLiquidity({ marketId, shares: ethAmount })
  //       expect(res.status).to.equal(true);
  //     } catch (e) {
  //       // TODO: review this
  //     }

  //     const myNewShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     const newMarketData = await predictionMarketContract.getMarketData({ marketId });
  //     const newOutcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const newOutcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     const newContractBalance = Number(await predictionMarketContract.getBalance());

  //     expect(newMarketData.liquidity).to.below(marketData.liquidity);
  //     expect(newMarketData.liquidity).to.equal(marketData.liquidity - ethAmount);

  //     // Outcome prices shoud remain the same after providing liquidity
  //     expect(newOutcome1Data.price).to.equal(outcome1Data.price);
  //     expect(newOutcome2Data.price).to.equal(outcome2Data.price);

  //     // Price balances are 0.5-0.5, liquidity will be added solely through liquidity shares
  //     expect(myNewShares.liquidityShares).to.below(myShares.liquidityShares);
  //     expect(myNewShares.liquidityShares).to.equal(myShares.liquidityShares - ethAmount);
  //     // shares balance remains the same
  //     expect(myNewShares.outcomeShares[0]).to.equal(myShares.outcomeShares[0]);
  //     expect(myNewShares.outcomeShares[1]).to.equal(myShares.outcomeShares[1]);

  //     // User gets liquidity tokens back in ETH
  //     expect(newContractBalance).to.below(contractBalance);
  //     // TODO: check amountTransferred from internal transactions
  //     const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));
  //     expect(amountTransferred).to.equal(ethAmount);
  //   }));
  // });

  // context('Market Interaction - Unbalanced Market (Different Outcome Odds)', async () => {
  //   it('should display my shares', mochaAsync(async () => {
  //     const res = await predictionMarketContract.getMyMarketShares({ marketId });
  //     // currently holding liquidity tokens from market creation
  //     expect(res).to.eql({
  //       liquidityShares: 0.01,
  //       outcomeShares: {
  //         0: 0.00,
  //         1: 0.00,
  //       }
  //     });
  //   }));

  //   it('should buy outcome shares', mochaAsync(async () => {
  //     const outcomeId = 0;
  //     const minOutcomeSharesToBuy = 0.015;

  //     const marketData = await predictionMarketContract.getMarketData({ marketId });
  //     const outcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const outcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     const contractBalance = Number(await predictionMarketContract.getBalance());

  //     try {
  //       const res = await predictionMarketContract.buy({ marketId, outcomeId, ethAmount, minOutcomeSharesToBuy });
  //       expect(res.status).to.equal(true);
  //     } catch (e) {
  //       // TODO: review this
  //     }

  //     const newMarketData = await predictionMarketContract.getMarketData({ marketId });
  //     const newOutcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const newOutcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     const newContractBalance = Number(await predictionMarketContract.getBalance());

  //     // outcome price should increase
  //     expect(newOutcome1Data.price).to.above(outcome1Data.price);
  //     expect(newOutcome1Data.price).to.equal(0.8);
  //     // opposite outcome price should decrease
  //     expect(newOutcome2Data.price).to.below(outcome2Data.price);
  //     expect(newOutcome2Data.price).to.equal(0.2);
  //     // Prices sum = 1
  //     // 0.05 + 0.05 = 1
  //     expect(newOutcome1Data.price + newOutcome2Data.price).to.equal(1);

  //     // Liquidity value remains the same
  //     expect(newMarketData.liquidity).to.equal(marketData.liquidity);

  //     // outcome shares should decrease
  //     expect(newOutcome1Data.shares).to.below(outcome1Data.shares);
  //     expect(newOutcome1Data.shares).to.equal(0.005);
  //     // opposite outcome shares should increase
  //     expect(newOutcome2Data.shares).to.above(outcome2Data.shares);
  //     expect(newOutcome2Data.shares).to.equal(0.02);
  //     // # Shares Product = Liquidity^2
  //     // 0.005 * 0.02 = 0.01^2
  //     expect(outcome1Data.shares * outcome2Data.shares).to.equal(newMarketData.liquidity ** 2);
  //     expect(newOutcome1Data.shares * newOutcome2Data.shares).to.equal(newMarketData.liquidity ** 2);

  //     const myShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     expect(myShares).to.eql({
  //       liquidityShares: 0.01,
  //       outcomeShares: {
  //         0: 0.015,
  //         1: 0.00,
  //       }
  //     });

  //     // Contract adds ethAmount to balance
  //     expect(newContractBalance).to.above(contractBalance);
  //     // TODO: check amountReceived from internal transactions
  //     const amountReceived = Number((newContractBalance - contractBalance).toFixed(5));
  //     expect(amountReceived).to.equal(ethAmount);
  //   }));

  //   it('should add liquidity', mochaAsync(async () => {
  //     const myShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     const marketData = await predictionMarketContract.getMarketData({ marketId });
  //     const outcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const outcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });

  //     try {
  //       const res = await predictionMarketContract.addLiquidity({ marketId, ethAmount })
  //       expect(res.status).to.equal(true);
  //     } catch (e) {
  //       // TODO: review this
  //     }

  //     const myNewShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     const newMarketData = await predictionMarketContract.getMarketData({ marketId });
  //     const newOutcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const newOutcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });

  //     // Outcome prices shoud remain the same after providing liquidity
  //     expect(newOutcome1Data.price).to.equal(outcome1Data.price);
  //     expect(newOutcome2Data.price).to.equal(outcome2Data.price);

  //     // # Shares Product = Liquidity^2
  //     // 0.0075 * 0.03 = 0.015^2
  //     expect(newMarketData.liquidity).to.above(marketData.liquidity);
  //     expect(newMarketData.liquidity).to.equal(0.015);
  //     expect(newOutcome1Data.shares).to.above(outcome1Data.shares);
  //     expect(newOutcome1Data.shares).to.equal(0.0075);
  //     expect(newOutcome2Data.shares).to.above(outcome2Data.shares);
  //     expect(newOutcome2Data.shares).to.equal(0.03);
  //     expect(newOutcome1Data.shares * newOutcome2Data.shares).to.equal(newMarketData.liquidity ** 2);

  //     // Price balances are not 0.5-0.5, liquidity will be added through shares + liquidity
  //     expect(myNewShares.liquidityShares).to.above(myShares.liquidityShares);
  //     expect(myNewShares.liquidityShares).to.equal(0.015);
  //     // shares balance of higher odd outcome increases
  //     expect(myNewShares.outcomeShares[0]).to.above(myShares.outcomeShares[0]);
  //     expect(myNewShares.outcomeShares[0]).to.equal(0.0225);
  //     // shares balance of lower odd outcome remains
  //     expect(myNewShares.outcomeShares[1]).to.equal(myShares.outcomeShares[1]);
  //     expect(myNewShares.outcomeShares[1]).to.equal(0);
  //   }));

  //   it('should remove liquidity', mochaAsync(async () => {
  //     const myShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     const marketData = await predictionMarketContract.getMarketData({ marketId });
  //     const outcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const outcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     const contractBalance = Number(await predictionMarketContract.getBalance());
  //     const liquiditySharesToRemove = 0.005;

  //     try {
  //       const res = await predictionMarketContract.removeLiquidity({ marketId, shares: liquiditySharesToRemove });
  //       expect(res.status).to.equal(true);
  //     } catch (e) {
  //       // TODO: review this
  //     }

  //     const myNewShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     const newMarketData = await predictionMarketContract.getMarketData({ marketId });
  //     const newOutcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const newOutcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     const newContractBalance = Number(await predictionMarketContract.getBalance());

  //     // Outcome prices shoud remain the same after removing liquidity
  //     expect(newOutcome1Data.price).to.equal(outcome1Data.price);
  //     expect(newOutcome2Data.price).to.equal(outcome2Data.price);

  //     // # Shares Product = Liquidity^2
  //     // 0.005 * 0.02 = 0.01^2
  //     expect(newMarketData.liquidity).to.below(marketData.liquidity);
  //     expect(newMarketData.liquidity).to.equal(0.01);
  //     expect(newOutcome1Data.shares).to.below(outcome1Data.shares);
  //     expect(newOutcome1Data.shares).to.equal(0.005);
  //     expect(newOutcome2Data.shares).to.below(outcome2Data.shares);
  //     expect(newOutcome2Data.shares).to.equal(0.02);
  //     expect(newOutcome1Data.shares * newOutcome2Data.shares).to.equal(newMarketData.liquidity ** 2);

  //     // Price balances are not 0.5-0.5, liquidity will be added through shares + liquidity
  //     expect(myNewShares.liquidityShares).to.below(myShares.liquidityShares);
  //     expect(myNewShares.liquidityShares).to.equal(0.01);
  //     // shares balance of higher odd outcome remains
  //     expect(myNewShares.outcomeShares[0]).to.equal(myShares.outcomeShares[0]);
  //     expect(myNewShares.outcomeShares[0]).to.equal(0.0225);
  //     // shares balance of lower odd outcome increases
  //     expect(myNewShares.outcomeShares[1]).to.above(myShares.outcomeShares[1]);
  //     expect(myNewShares.outcomeShares[1]).to.equal(0.0075);

  //     // User gets part of the liquidity tokens back in ETH
  //     expect(newContractBalance).to.below(contractBalance);
  //     // TODO: check amountTransferred from internal transactions
  //     const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));
  //     expect(amountTransferred).to.equal(0.0025);
  //   }));

  //   it('should sell outcome shares', mochaAsync(async () => {
  //     const outcomeId = 0;
  //     const maxOutcomeSharesToSell = 0.015;

  //     const marketData = await predictionMarketContract.getMarketData({ marketId });
  //     const outcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const outcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     const contractBalance = Number(await predictionMarketContract.getBalance());

  //     try {
  //       const res = await predictionMarketContract.sell({ marketId, outcomeId, ethAmount, maxOutcomeSharesToSell });
  //       expect(res.status).to.equal(true);
  //     } catch (e) {
  //       // TODO: review this
  //     }

  //     const newMarketData = await predictionMarketContract.getMarketData({ marketId });
  //     const newOutcome1Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[0] });
  //     const newOutcome2Data = await predictionMarketContract.getOutcomeData({ marketId, outcomeId: outcomeIds[1] });
  //     const newContractBalance = Number(await predictionMarketContract.getBalance());

  //     // outcome price should decrease
  //     expect(newOutcome1Data.price).to.below(outcome1Data.price);
  //     expect(newOutcome1Data.price).to.equal(0.5);
  //     // opposite outcome price should increase
  //     expect(newOutcome2Data.price).to.above(outcome2Data.price);
  //     expect(newOutcome2Data.price).to.equal(0.5);
  //     // Prices sum = 1
  //     // 0.05 + 0.05 = 1
  //     expect(newOutcome1Data.price + newOutcome2Data.price).to.equal(1);

  //     // Liquidity value remains the same
  //     expect(newMarketData.liquidity).to.equal(marketData.liquidity);

  //     // outcome shares should increase
  //     expect(newOutcome1Data.shares).to.above(outcome1Data.shares);
  //     expect(newOutcome1Data.shares).to.equal(0.01);
  //     // opposite outcome shares should increase
  //     expect(newOutcome2Data.shares).to.below(outcome2Data.shares);
  //     expect(newOutcome2Data.shares).to.equal(0.01);
  //     // # Shares Product = Liquidity^2
  //     // 0.01 * 0.01 = 0.01^2
  //     expect(outcome1Data.shares * outcome2Data.shares).to.equal(newMarketData.liquidity ** 2);
  //     expect(newOutcome1Data.shares * newOutcome2Data.shares).to.equal(newMarketData.liquidity ** 2);

  //     const myShares = await predictionMarketContract.getMyMarketShares({ marketId });
  //     expect(myShares).to.eql({
  //       liquidityShares: 0.01,
  //       outcomeShares: {
  //         0: 0.0075,
  //         1: 0.0075,
  //       }
  //     });

  //     // User gets shares value back in ETH
  //     expect(newContractBalance).to.below(contractBalance);
  //     // TODO: check amountTransferred from internal transactions
  //     const amountTransferred = Number((contractBalance - newContractBalance).toFixed(5));
  //     expect(amountTransferred).to.equal(0.01);
  //   }));
  // });
});
