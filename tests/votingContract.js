

import { expect } from 'chai';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Voting Contract', async () => {
  require('dotenv').config();

  let app;
  let votingContract;
  let ERC20Contract;

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

      expect(votingContractAddress).to.not.equal(null);
    }));
  });

  context('Voting Items', async () => {
    it('should upvote an Item', mochaAsync(async () => {
      let itemId = 0;

      // chek if there are no votes
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);

      const res = await votingContract.upvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(1);
      expect(userVotes[0].upvoted).to.equal(true);
      expect(userVotes[0].downvoted).to.equal(false);
    }));

    it('should downvote an Item', mochaAsync(async () => {
      let itemId = 1;

      // chek if there are no votes
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);

      const res = await votingContract.downvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);

      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(true);
      expect(userVotes[0].downvoted).to.equal(false);
      expect(userVotes[1].upvoted).to.equal(false);
      expect(userVotes[1].downvoted).to.equal(true);
    }));

    it('should upvote an Item when there is already a downvote', mochaAsync(async () => {
      let itemId = 1;

      // check first if user has a downvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);


      const res = await votingContract.upvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(true);
      expect(userVotes[0].downvoted).to.equal(false);
      expect(userVotes[1].upvoted).to.equal(true);
      expect(userVotes[1].downvoted).to.equal(false);
    }));

    it('should downvote an Item when there is already an upvote', mochaAsync(async () => {
      let itemId = 0;

      // check first if user has an upvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);


      const res = await votingContract.downvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(false);
      expect(userVotes[0].downvoted).to.equal(true);
      expect(userVotes[1].upvoted).to.equal(true);
      expect(userVotes[1].downvoted).to.equal(false);
    }));

    it('should not allow to upvote an already upvoted item', mochaAsync(async () => {
      let itemId = 1;

      // check first if user has an upvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

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


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(false);
      expect(userVotes[0].downvoted).to.equal(true);
      expect(userVotes[1].upvoted).to.equal(true);
      expect(userVotes[1].downvoted).to.equal(false);
    }));

    it('should not allow to downvote an already downvoted item', mochaAsync(async () => {
      let itemId = 0;

      // check first if user has a downvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

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


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(false);
      expect(userVotes[0].downvoted).to.equal(true);
      expect(userVotes[1].upvoted).to.equal(true);
      expect(userVotes[1].downvoted).to.equal(false);
    }));

    it('should allow to remove upvote of an already upvoted item', mochaAsync(async () => {
      let itemId = 1;

      // check first if user has an upvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(1);
      expect(itemVotes.downvotes).to.equal(0);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(true);
      expect(userVoted.downvoted).to.equal(false);


      const res = await votingContract.removeUpvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(false);
      expect(userVotes[0].downvoted).to.equal(true);
      expect(userVotes[1].upvoted).to.equal(false);
      expect(userVotes[1].downvoted).to.equal(false);
    }));

    it('should allow to remove downvote of an already downvoted item', mochaAsync(async () => {
      let itemId = 0;

      // check first if user has a downvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(1);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(true);


      const res = await votingContract.removeDownvoteItem({
        itemId,
      });

      expect(res.status).to.equal(true);

      itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(false);
      expect(userVotes[0].downvoted).to.equal(false);
      expect(userVotes[1].upvoted).to.equal(false);
      expect(userVotes[1].downvoted).to.equal(false);
    }));

    it('should not allow to remove upvote of an item not upvoted', mochaAsync(async () => {
      let itemId = 1;

      // check first if user does not have an upvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

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


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(false);
      expect(userVotes[0].downvoted).to.equal(false);
      expect(userVotes[1].upvoted).to.equal(false);
      expect(userVotes[1].downvoted).to.equal(false);
    }));

    it('should not allow to remove downvote of an item not downvoted', mochaAsync(async () => {
      let itemId = 0;

      // check first if user does not have a downvote
      let itemVotes = await votingContract.getItemVotes({ itemId });

      expect(itemVotes.upvotes).to.equal(0);
      expect(itemVotes.downvotes).to.equal(0);

      const user = await votingContract.getMyAccount();

      let userVoted = await votingContract.hasUserVotedItem({ itemId, user });

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


      userVoted = await votingContract.hasUserVotedItem({ itemId, user });

      expect(userVoted.upvoted).to.equal(false);
      expect(userVoted.downvoted).to.equal(false);

      // Validate User Votes
      const userVotes = await votingContract.getUserVotes({ user });
      expect(Object.keys(userVotes).length).to.equal(2);
      expect(userVotes[0].upvoted).to.equal(false);
      expect(userVotes[0].downvoted).to.equal(false);
      expect(userVotes[1].upvoted).to.equal(false);
      expect(userVotes[1].downvoted).to.equal(false);
    }));
  });
});
