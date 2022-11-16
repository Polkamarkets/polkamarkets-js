

import { expect } from 'chai';

import { mochaAsync } from './utils';
import { Application } from '..';
const Numbers = require("../src/utils/Numbers");

context('FantasyERC20 Contract', async () => {
  require('dotenv').config();

  const TOKEN_AMOUNT_TO_CLAIM = '10000';


  const USER1_ADDRESS = process.env.TEST_USER1_ADDRESS;
  const USER1_PRIVATE_KEY = process.env.TEST_USER1_PRIVATE_KEY;
  const USER2_ADDRESS = process.env.TEST_USER2_ADDRESS;
  const USER2_PRIVATE_KEY = process.env.TEST_USER2_PRIVATE_KEY;
  const TOKEN_MANAGER_ADDRESS = process.env.TEST_USER3_ADDRESS;
  const TOKEN_MANAGER_PRIVATE_KEY = process.env.TEST_USER3_PRIVATE_KEY;

  let app;
  let fantasyERC20ContractAddress;

  let user1FantasyERC20Contract;
  let user2FantasyERC20Contract2;
  let tokenManagerfantasyERC20Contract;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: USER1_PRIVATE_KEY,
      });

      expect(app).to.not.equal(null);
    }));

    it('should deploy FantasyERC20 Contract', mochaAsync(async () => {
      // Create Contract
      user1FantasyERC20Contract = app.getFantasyERC20Contract({});
      // Deploy
      await user1FantasyERC20Contract.deploy({
        params: [
          'Fantasy',
          'FNTS',
          Numbers.toSmartContractDecimals(TOKEN_AMOUNT_TO_CLAIM, 18),
          TOKEN_MANAGER_ADDRESS
        ]
      });

      fantasyERC20ContractAddress = user1FantasyERC20Contract.getAddress();

      expect(fantasyERC20ContractAddress).to.not.equal(null);
    }));
  });

  context('Claim Tokens', async () => {
    it('should claim tokens for address', mochaAsync(async () => {

      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: USER2_PRIVATE_KEY,
      });

      user2FantasyERC20Contract2 = app.getFantasyERC20Contract({ contractAddress: fantasyERC20ContractAddress });
      await user2FantasyERC20Contract2.__init__();

      let user2HasClaimedTokens;
      let user2TokenAmount;
      let totalSupply;
      let isApproved;

      // check if address hasn't claimed tokens
      user2HasClaimedTokens = await user2FantasyERC20Contract2.hasUserClaimedTokens({ address: USER2_ADDRESS });
      expect(user2HasClaimedTokens).to.equal(false);

      user2TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER2_ADDRESS);
      expect(user2TokenAmount).to.equal('0');

      totalSupply = await user2FantasyERC20Contract2.totalSupply();
      expect(totalSupply).to.equal('0');

      isApproved = await user2FantasyERC20Contract2.isApproved({ address: USER2_ADDRESS, amount: TOKEN_AMOUNT_TO_CLAIM, spenderAddress: TOKEN_MANAGER_ADDRESS });
      expect(isApproved).to.equal(false);

      // claim tokens
      const res = await user2FantasyERC20Contract2.claimAndApproveTokens();
      expect(res.status).to.equal(true);

      // check if address hasn't claimed tokens
      user2HasClaimedTokens = await user2FantasyERC20Contract2.hasUserClaimedTokens({ address: USER2_ADDRESS });
      expect(user2HasClaimedTokens).to.equal(true);

      user2TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER2_ADDRESS);
      expect(user2TokenAmount).to.equal(
        TOKEN_AMOUNT_TO_CLAIM
      );

      totalSupply = await user2FantasyERC20Contract2.totalSupply();
      expect(totalSupply).to.equal(TOKEN_AMOUNT_TO_CLAIM);

      isApproved = await user2FantasyERC20Contract2.isApproved({ address: USER2_ADDRESS, amount: TOKEN_AMOUNT_TO_CLAIM, spenderAddress: TOKEN_MANAGER_ADDRESS });
      expect(isApproved).to.equal(true);
    }));

    it('should not claim tokens for address that has already claimed tokens', mochaAsync(async () => {
      let user2HasClaimedTokens;
      let user2TokenAmount;

      // check if address has already claimed tokens
      user2HasClaimedTokens = await user2FantasyERC20Contract2.hasUserClaimedTokens({ address: USER2_ADDRESS });
      expect(user2HasClaimedTokens).to.equal(true);

      user2TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER2_ADDRESS);
      expect(user2TokenAmount).to.equal(TOKEN_AMOUNT_TO_CLAIM);

      // claim tokens
      let res;
      try {
        res = await user2FantasyERC20Contract2.claimAndApproveTokens();
      } catch (error) {
        res = { status: false };
      }

      expect(res.status).to.equal(false);
      // TODO: check if error is correct
      // expect(res.reason).to.equal('FantasyERC20: address already claimed the tokens');

      user2HasClaimedTokens = await user2FantasyERC20Contract2.hasUserClaimedTokens({ address: USER2_ADDRESS });
      expect(user2HasClaimedTokens).to.equal(true);

      user2TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER2_ADDRESS);
      expect(user2TokenAmount).to.equal(TOKEN_AMOUNT_TO_CLAIM);

    }));
  });

  context('Transfer Tokens', async () => {
    it('should allow to transfer tokens between an address and the token manager', mochaAsync(async () => {
      // transfer from address to token manager
      const tokenAmountToTransfer = 500;
      let user2TokenAmount;
      let managerTokenAmount;

      user2TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER2_ADDRESS);
      expect(user2TokenAmount).to.equal(TOKEN_AMOUNT_TO_CLAIM);

      managerTokenAmount = await user2FantasyERC20Contract2.getTokenAmount(TOKEN_MANAGER_ADDRESS);
      expect(managerTokenAmount).to.equal('0');

      let res = await user2FantasyERC20Contract2.transferTokenAmount({
        toAddress: TOKEN_MANAGER_ADDRESS,
        tokenAmount: tokenAmountToTransfer,
      });

      expect(res.status).to.equal(true);

      user2TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER2_ADDRESS);
      expect(parseFloat(user2TokenAmount).toFixed(0)).to.equal((TOKEN_AMOUNT_TO_CLAIM - tokenAmountToTransfer).toFixed(0));

      managerTokenAmount = await user2FantasyERC20Contract2.getTokenAmount(TOKEN_MANAGER_ADDRESS);
      expect(managerTokenAmount).to.equal(tokenAmountToTransfer.toFixed(0));

      // transfer back from manager to address
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: TOKEN_MANAGER_PRIVATE_KEY,
      });

      tokenManagerfantasyERC20Contract = app.getFantasyERC20Contract({ contractAddress: fantasyERC20ContractAddress });
      await tokenManagerfantasyERC20Contract.__init__();

      res = await tokenManagerfantasyERC20Contract.transferTokenAmount({
        toAddress: USER2_ADDRESS,
        tokenAmount: tokenAmountToTransfer,
      });

      expect(res.status).to.equal(true);

      user2TokenAmount = await tokenManagerfantasyERC20Contract.getTokenAmount(USER2_ADDRESS);
      expect(user2TokenAmount).to.equal(TOKEN_AMOUNT_TO_CLAIM);

      managerTokenAmount = await tokenManagerfantasyERC20Contract.getTokenAmount(TOKEN_MANAGER_ADDRESS);
      expect(managerTokenAmount).to.equal('0');

    }));

    it('should not allow to transfer tokens between 2 addresses that are not the token manager', mochaAsync(async () => {

      const tokenAmountToTransfer = 500;
      let user1TokenAmount;
      let user2TokenAmount;

      user2TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER2_ADDRESS);
      expect(user2TokenAmount).to.equal(TOKEN_AMOUNT_TO_CLAIM);

      user1TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER1_ADDRESS);
      expect(user1TokenAmount).to.equal('0');

      let res;

      try {
        res = await user2FantasyERC20Contract2.transferTokenAmount({
          toAddress: USER1_ADDRESS,
          tokenAmount: tokenAmountToTransfer,
        });
      } catch (error) {
        res = { status: false };
      }

      expect(res.status).to.equal(false);
      // TODO: check if error is correct
      // expect(res.reason).to.equal('FantasyERC20: token transfer not allowed between the addresses');

      user2TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER2_ADDRESS);
      expect(parseFloat(user2TokenAmount).toFixed(0)).to.equal(TOKEN_AMOUNT_TO_CLAIM);

      user1TokenAmount = await user2FantasyERC20Contract2.getTokenAmount(USER1_ADDRESS);
      expect(user1TokenAmount).to.equal('0');
    }));
  });
});
