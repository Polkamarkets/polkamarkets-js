

import { expect } from 'chai';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Rewards Distributor Contract', async () => {
  require('dotenv').config();

  const USER1_ADDRESS = process.env.TEST_USER1_ADDRESS;
  const USER1_PRIVATE_KEY = process.env.TEST_USER1_PRIVATE_KEY;
  const USER2_ADDRESS = process.env.TEST_USER2_ADDRESS;
  const USER2_PRIVATE_KEY = process.env.TEST_USER2_PRIVATE_KEY;
  const USER3_ADDRESS = process.env.TEST_USER3_ADDRESS;

  let app;
  let rewardsDistributorContract;
  let rewardsDistributorContractAddress;
  let rewardsDistributorContractForUser1;
  let rewardsDistributorContractForUser2;
  let ERC20Contract;
  let ERC20ContractAddress;
  let deployerAddress;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: process.env.WEB3_PRIVATE_KEY,
      });

      expect(app).to.not.equal(null);
    }));

    it('should deploy Rewards Distributor Contract', mochaAsync(async () => {
      // Create Contract
      rewardsDistributorContract = app.getRewardsDistributorContract({});
      ERC20Contract = app.getERC20Contract({});
      // // Deploy
      await ERC20Contract.deploy({ params: ['Polkamarkets', 'POLK'] });

      ERC20ContractAddress = ERC20Contract.getAddress();

      await rewardsDistributorContract.deploy({});
      rewardsDistributorContractAddress = rewardsDistributorContract.getAddress();

      expect(rewardsDistributorContractAddress).to.not.equal(null);

      await ERC20Contract.mint({
        address: rewardsDistributorContractAddress,
        amount: 100000
      });
      // await ERC20Contract.approve({
      //   address: predictionMarketFactoryContractAddress,
      //   amount: '1000000'
      // });

      const appUser1 = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: USER1_PRIVATE_KEY,
      });

      rewardsDistributorContractForUser1 = appUser1.getRewardsDistributorContract({ contractAddress: rewardsDistributorContractAddress });

      const appUser2 = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: USER2_PRIVATE_KEY,
      });

      rewardsDistributorContractForUser2 = appUser2.getRewardsDistributorContract({ contractAddress: rewardsDistributorContractAddress });

      deployerAddress = app.web3.eth.accounts.privateKeyToAccount(process.env.WEB3_PRIVATE_KEY).address
      const deployerIsAdmin = await rewardsDistributorContract.isAdmin({ user: deployerAddress });

      expect(deployerIsAdmin).to.equal(true);
    }));
  });

  context('Claiming amounts', async () => {
    it('should add correct amount to claim for user', mochaAsync(async () => {

      let amountToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.equal(0);

      const res = await rewardsDistributorContract.increaseUserClaimAmount({
        user: USER1_ADDRESS,
        amount: 1000,
        tokenAddress: ERC20ContractAddress
      });

      expect(res.status).to.equal(true);

      amountToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.equal(1000);
    }));

    it('should user 2 claim amount of user 1', mochaAsync(async () => {
      const currentContractBalance = await ERC20Contract.balanceOf({ address: rewardsDistributorContractAddress });
      const currentUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const currentUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(currentContractBalance).to.greaterThan(0);
      expect(currentUser1Balance).to.equal(0);
      expect(currentUser2Balance).to.equal(0);

      const amountToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress }) / 2;

      expect(amountToClaim).to.greaterThan(0);

      // sign message with user1, the owner of the amounts
      const distributionData = await rewardsDistributorContractForUser1.signMessageToClaim(
        {
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: amountToClaim,
          tokenAddress: ERC20ContractAddress,
        });

      // claim with user2
      const res = await rewardsDistributorContractForUser2.claim({
        user: USER1_ADDRESS,
        receiver: USER2_ADDRESS,
        amount: amountToClaim,
        tokenAddress: ERC20ContractAddress,
        nonce: distributionData.nonce,
        signature: distributionData.signature
      });

      expect(res.status).to.equal(true);

      const newContractOwnerBalance = await ERC20Contract.balanceOf({ address: rewardsDistributorContractAddress });
      const newUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const newUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(newContractOwnerBalance).to.equal(Math.round(currentContractBalance - amountToClaim));
      expect(newUser1Balance).to.equal(0);
      expect(newUser2Balance).to.equal(amountToClaim);
    }));

    it('should user 1 claim its own amount without signature', mochaAsync(async () => {
      const currentContractBalance = await ERC20Contract.balanceOf({ address: rewardsDistributorContractAddress });
      const currentUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });

      expect(currentContractBalance).to.greaterThan(0);
      expect(currentUser1Balance).to.equal(0);

      const amountToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.greaterThan(0);

      // claim with user2
      const res = await rewardsDistributorContractForUser1.claimWithoutSignature({
        user: USER1_ADDRESS,
        receiver: USER2_ADDRESS,
        amount: amountToClaim,
        tokenAddress: ERC20ContractAddress,
      });

      expect(res.status).to.equal(true);

      const amountLeftToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountLeftToClaim).to.equal(0);

      const newContractOwnerBalance = await ERC20Contract.balanceOf({ address: rewardsDistributorContractAddress });
      const newUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const newUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(newContractOwnerBalance).to.equal(Math.round(currentContractBalance - amountToClaim));
      expect(newUser1Balance).to.equal(0);
      expect(newUser2Balance).to.equal(amountToClaim * 2);

    }));

    it('should not claim amount of user 1 if there is no amount to claim', mochaAsync(async () => {
      const currentUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const currentUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(currentUser1Balance).to.equal(0);
      expect(currentUser2Balance).to.greaterThan(0);

      const amountToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.equal(0);

      // sign message with user1, the owner of the amounts
      const distributionData = await rewardsDistributorContractForUser1.signMessageToClaim(
        {
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: 1000,
          tokenAddress: ERC20ContractAddress,
        });

      let res;
      try {
        // claim with user2
        res = await rewardsDistributorContractForUser2.claim({
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: 1000,
          tokenAddress: ERC20ContractAddress,
          nonce: distributionData.nonce,
          signature: distributionData.signature
        });
      } catch (error) {
        res = { status: false };
        expect(JSON.stringify(error)).to.include('RewardsDistributor: not enough tokens to claim');
      }

      expect(res.status).to.equal(false);

      const amountLeftToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountLeftToClaim).to.equal(0);

      const newUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const newUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(newUser1Balance).to.equal(currentUser1Balance);
      expect(newUser2Balance).to.equal(currentUser2Balance);
    }));

    it('should not allow user 3 to claim amount of user 1 if signed to be claimed by user 2', mochaAsync(async () => {

      // add amount to claim for user 1
      const resIncreaseAmount = await rewardsDistributorContract.increaseUserClaimAmount({
        user: USER1_ADDRESS,
        amount: 1000,
        tokenAddress: ERC20ContractAddress
      });

      expect(resIncreaseAmount.status).to.equal(true);

      const currentUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const currentUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });
      const currentUser3Balance = await ERC20Contract.balanceOf({ address: USER3_ADDRESS });

      expect(currentUser1Balance).to.equal(0);
      expect(currentUser2Balance).to.greaterThan(0);
      expect(currentUser3Balance).to.equal(0);

      const amountToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.greaterThan(0);

      // sign message with user1, the owner of the amounts
      const distributionData = await rewardsDistributorContractForUser1.signMessageToClaim(
        {
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: amountToClaim,
          tokenAddress: ERC20ContractAddress,
        });

      let res;
      // try to claim with user3
      try {
        res = await rewardsDistributorContractForUser2.claim({
          user: USER1_ADDRESS,
          receiver: USER3_ADDRESS,
          amount: amountToClaim,
          tokenAddress: ERC20ContractAddress,
          nonce: distributionData.nonce,
          signature: distributionData.signature
        });
      } catch (error) {
        res = { status: false };
        expect(JSON.stringify(error)).to.include('RewardsDistributor: invalid signature');
      }

      expect(res.status).to.equal(false);

      const amountLeftToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountLeftToClaim).to.equal(amountToClaim);

      const newUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const newUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });
      const newUser3Balance = await ERC20Contract.balanceOf({ address: USER3_ADDRESS });

      expect(newUser1Balance).to.equal(currentUser1Balance);
      expect(newUser2Balance).to.equal(currentUser2Balance);
      expect(newUser3Balance).to.equal(currentUser3Balance);
    }));

    it('should not claim a different amount of the one signed', mochaAsync(async () => {
      const currentUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const currentUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(currentUser1Balance).to.equal(0);
      expect(currentUser2Balance).to.greaterThan(0);

      const amountToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.greaterThan(0);

      // sign message with user1, the owner of the amounts
      const distributionData = await rewardsDistributorContractForUser1.signMessageToClaim(
        {
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: Math.floor(amountToClaim / 2),
          tokenAddress: ERC20ContractAddress,
        });

      let res;
      try {
        // claim with user2
        res = await rewardsDistributorContractForUser2.claim({
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: amountToClaim,
          tokenAddress: ERC20ContractAddress,
          nonce: distributionData.nonce,
          signature: distributionData.signature
        });
      } catch (error) {
        res = { status: false };
        expect(JSON.stringify(error)).to.include('RewardsDistributor: invalid signature');
      }

      expect(res.status).to.equal(false);

      const amountLeftToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountLeftToClaim).to.equal(amountToClaim);

      const newUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const newUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(newUser1Balance).to.equal(currentUser1Balance);
      expect(newUser2Balance).to.equal(currentUser2Balance);
    }));

    it('should not claim using an old nonce and signature', mochaAsync(async () => {
      const currentUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const currentUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(currentUser1Balance).to.equal(0);
      expect(currentUser2Balance).to.greaterThan(0);

      let amountToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.greaterThan(0);

      amountToClaim = Math.floor(amountToClaim / 2);

      // sign message with user1, the owner of the amounts
      const distributionData = await rewardsDistributorContractForUser1.signMessageToClaim(
        {
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: amountToClaim,
          tokenAddress: ERC20ContractAddress,
        });

      // claim with user2
      let res = await rewardsDistributorContractForUser2.claim({
        user: USER1_ADDRESS,
        receiver: USER2_ADDRESS,
        amount: amountToClaim,
        tokenAddress: ERC20ContractAddress,
        nonce: distributionData.nonce,
        signature: distributionData.signature
      });

      expect(res.status).to.equal(true);

      const amountLeftToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountLeftToClaim).to.greaterThan(0);

      let newUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      let newUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(newUser1Balance).to.equal(currentUser1Balance);
      expect(newUser2Balance).to.equal(currentUser2Balance + amountToClaim);

      // try to claim with same signature
      try {
        res = await rewardsDistributorContractForUser2.claim({
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: amountToClaim,
          tokenAddress: ERC20ContractAddress,
          nonce: distributionData.nonce,
          signature: distributionData.signature
        });
      } catch (error) {
        res = { status: false };
      }

      expect(res.status).to.equal(false);

      newUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      newUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(newUser1Balance).to.equal(currentUser1Balance);
      expect(newUser2Balance).to.equal(currentUser2Balance + amountToClaim);

    }));
  });

  context('Admin permission', async () => {

    it('should not add amount to claim if not admin', mochaAsync(async () => {
      let amountToClaim = await rewardsDistributorContractForUser2.getAmountToClaim({ user: USER2_ADDRESS, tokenAddress: ERC20ContractAddress });

      let isAdmin = await rewardsDistributorContractForUser2.isAdmin({ user: USER2_ADDRESS });

      expect(amountToClaim).to.equal(0);
      expect(isAdmin).to.equal(false);

      let res;
      try {
        res = await rewardsDistributorContractForUser2.increaseUserClaimAmount({
          user: USER2_ADDRESS,
          amount: 1000,
          tokenAddress: ERC20ContractAddress
        });
      } catch (error) {
        res = { status: false };
        expect(JSON.stringify(error)).to.include('RewardsDistributor: must have admin role');
      }

      expect(res.status).to.equal(false);

      amountToClaim = await rewardsDistributorContractForUser2.getAmountToClaim({ user: USER2_ADDRESS, tokenAddress: ERC20ContractAddress });
      isAdmin = await rewardsDistributorContractForUser2.isAdmin({ user: USER2_ADDRESS });

      expect(amountToClaim).to.equal(0);
      expect(isAdmin).to.equal(false);
    }));

    it('should not add user as admin if not admin', mochaAsync(async () => {

      let isAdmin = await rewardsDistributorContractForUser2.isAdmin({ user: USER1_ADDRESS });
      expect(isAdmin).to.equal(false);

      let res;
      try {
        res = await rewardsDistributorContractForUser2.addAdmin({user: USER1_ADDRESS});
      } catch (error) {
        res = { status: false };
        expect(JSON.stringify(error)).to.include('RewardsDistributor: must have admin role');
      }

      expect(res.status).to.equal(false);

      isAdmin = await rewardsDistributorContractForUser2.isAdmin({ user: USER1_ADDRESS });

      expect(isAdmin).to.equal(false);
    }));

    it('should not remove user as admin if not admin', mochaAsync(async () => {

        let isAdmin = await rewardsDistributorContractForUser2.isAdmin({ user: deployerAddress });
        expect(isAdmin).to.equal(true);

        let res;
        try {
          res = await rewardsDistributorContractForUser2.removeAdmin({ user: deployerAddress });
        } catch (error) {
          res = { status: false };
          expect(JSON.stringify(error)).to.include('RewardsDistributor: must have admin role');
        }

        expect(res.status).to.equal(false);

        isAdmin = await rewardsDistributorContractForUser2.isAdmin({ user: deployerAddress });

        expect(isAdmin).to.equal(true);
    }));

    it('should add user 1 as admin and be able to add amount to claim', mochaAsync(async () => {

      let isAdmin = await rewardsDistributorContract.isAdmin({ user: USER1_ADDRESS });

      expect(isAdmin).to.equal(false);

      let res = await rewardsDistributorContract.addAdmin({ user: USER1_ADDRESS });

      expect(res.status).to.equal(true);

      isAdmin = await rewardsDistributorContract.isAdmin({ user: USER1_ADDRESS });

      expect(isAdmin).to.equal(true);

      let amountToClaim = await rewardsDistributorContractForUser1.getAmountToClaim({ user: USER2_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.equal(0);

      res = await rewardsDistributorContractForUser1.increaseUserClaimAmount({
        user: USER2_ADDRESS,
        amount: 1000,
        tokenAddress: ERC20ContractAddress
      });

      expect(res.status).to.equal(true);

      amountToClaim = await rewardsDistributorContractForUser1.getAmountToClaim({ user: USER2_ADDRESS, tokenAddress: ERC20ContractAddress });

      expect(amountToClaim).to.equal(1000);
    }));

    it('should remove user 1 as admin and not be able to add amount to claim', mochaAsync(async () => {

        let isAdmin = await rewardsDistributorContract.isAdmin({ user: USER1_ADDRESS });

        expect(isAdmin).to.equal(true);

        let res = await rewardsDistributorContract.removeAdmin({ user: USER1_ADDRESS });

        expect(res.status).to.equal(true);

        isAdmin = await rewardsDistributorContract.isAdmin({ user: USER1_ADDRESS });

        expect(isAdmin).to.equal(false);

        let amountToClaim = await rewardsDistributorContractForUser1.getAmountToClaim({ user: USER3_ADDRESS, tokenAddress: ERC20ContractAddress });

        expect(amountToClaim).to.equal(0);

        try {
          res = await rewardsDistributorContractForUser1.increaseUserClaimAmount({
            user: USER2_ADDRESS,
            amount: 1000,
            tokenAddress: ERC20ContractAddress
          });
        } catch (error) {
          res = { status: false };
          expect(JSON.stringify(error)).to.include('RewardsDistributor: must have admin role');
        }

        expect(res.status).to.equal(false);

        amountToClaim = await rewardsDistributorContractForUser1.getAmountToClaim({ user: USER3_ADDRESS, tokenAddress: ERC20ContractAddress });

        expect(amountToClaim).to.equal(0);
    }));

    it('should be able to witdraw tokens from contract if admin', mochaAsync(async () => {

      const currentContractBalance = await ERC20Contract.balanceOf({ address: rewardsDistributorContractAddress });
      const currentAdminBalance = await ERC20Contract.balanceOf({ address: deployerAddress });

      expect(currentContractBalance).to.greaterThan(0);
      expect(currentAdminBalance).to.equal(0);

      let res = await rewardsDistributorContract.withdrawTokens({ amount: currentContractBalance, tokenAddress: ERC20ContractAddress });

      expect(res.status).to.equal(true);

      const newContractBalance = await ERC20Contract.balanceOf({ address: rewardsDistributorContractAddress });
      const newAdminBalance = await ERC20Contract.balanceOf({ address: deployerAddress });

      expect(newContractBalance).to.equal(0);
      expect(newAdminBalance).to.equal(currentContractBalance);
    }));

  });

  context ('Alias permission', async () => {
    it('should not add alias if not admin', mochaAsync(async () => {
      let isAlias = await rewardsDistributorContractForUser2.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(false);

      let res;
      try {
        res = await rewardsDistributorContractForUser2.addAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });
      } catch (error) {
        res = { status: false };
        expect(JSON.stringify(error)).to.include('RewardsDistributor: must have admin role');
      }

      expect(res.status).to.equal(false);

      isAlias = await rewardsDistributorContractForUser2.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(false);
    }));

    it('should add alias if admin', mochaAsync(async () => {
      let isAlias = await rewardsDistributorContract.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(false);

      let res = await rewardsDistributorContract.addAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(res.status).to.equal(true);

      isAlias = await rewardsDistributorContract.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(true);
    }));

    it('should remove alias if admin', mochaAsync(async () => {
      let isAlias = await rewardsDistributorContract.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(true);

      let res = await rewardsDistributorContract.removeAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(res.status).to.equal(true);

      isAlias = await rewardsDistributorContract.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(false);
    }));

    it('should not remove alias if not admin', mochaAsync(async () => {
      let isAlias = await rewardsDistributorContract.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(false);

      let res = await rewardsDistributorContract.addAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(res.status).to.equal(true);

      isAlias = await rewardsDistributorContract.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(true);

      let resRemove;
      try {
        resRemove = await rewardsDistributorContractForUser2.removeAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });
      } catch (error) {
        resRemove = { status: false };
        expect(JSON.stringify(error)).to.include('RewardsDistributor: must have admin role');
      }

      expect(resRemove.status).to.equal(false);

      isAlias = await rewardsDistributorContract.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });

      expect(isAlias).to.equal(true);
    }));

    it('should be able to claim as alias', mochaAsync(async () => {
      const currentUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const currentUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      const amountToClaim = 1000;

      // add amount to claim for user 1
      const resIncreaseAmount = await rewardsDistributorContract.increaseUserClaimAmount({
        user: USER1_ADDRESS,
        amount: amountToClaim,
        tokenAddress: ERC20ContractAddress
      });

      expect(resIncreaseAmount.status).to.equal(true);

      const amountLeftToClaim = await rewardsDistributorContract.getAmountToClaim({ user: USER1_ADDRESS, tokenAddress: ERC20ContractAddress });
      expect(amountLeftToClaim).to.greaterThan(0);


      await ERC20Contract.mint({
        address: rewardsDistributorContractAddress,
        amount: amountLeftToClaim
      });

      // add alias
      let res = await rewardsDistributorContract.addAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });
      expect(res.status).to.equal(true);

      let isAlias = await rewardsDistributorContract.isAlias({ owner: USER1_ADDRESS, target: USER2_ADDRESS });
      expect(isAlias).to.equal(true);

      const distributionData = await rewardsDistributorContractForUser2.signMessageToClaim(
        {
          user: USER1_ADDRESS,
          receiver: USER2_ADDRESS,
          amount: amountLeftToClaim,
          tokenAddress: ERC20ContractAddress,
        });

      // claim with user2
      res = await rewardsDistributorContractForUser2.claim({
        user: USER1_ADDRESS,
        receiver: USER2_ADDRESS,
        amount: amountLeftToClaim,
        tokenAddress: ERC20ContractAddress,
        nonce: distributionData.nonce,
        signature: distributionData.signature
      });

      expect(res.status).to.equal(true);

      const newContractOwnerBalance = await ERC20Contract.balanceOf({ address: rewardsDistributorContractAddress });
      const newUser1Balance = await ERC20Contract.balanceOf({ address: USER1_ADDRESS });
      const newUser2Balance = await ERC20Contract.balanceOf({ address: USER2_ADDRESS });

      expect(newContractOwnerBalance).to.equal(0);
      expect(newUser1Balance).to.equal(currentUser1Balance);
      expect(newUser2Balance).to.equal(currentUser2Balance + amountLeftToClaim);
    }));
  });

});
