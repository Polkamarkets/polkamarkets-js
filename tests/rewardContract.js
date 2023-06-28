

import { expect } from 'chai';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Reward Contract', async () => {
  require('dotenv').config();

  let app;
  let rewardContract;
  let ERC20Contract;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: process.env.WEB3_PRIVATE_KEY,
      });

      expect(app).to.not.equal(null);
    }));

    it('should deploy Reward Contract', mochaAsync(async () => {
      // Create Contract
      rewardContract = app.getRewardContract({});
      ERC20Contract = app.getERC20Contract({});
      // // Deploy
      await ERC20Contract.deploy({ params: ['Polkamarkets', 'POLK'] });

      const ERC20ContractAddress = ERC20Contract.getAddress();

      await rewardContract.deploy({
        params: [
          ERC20ContractAddress,
          [
            {
              minAmount: 0,
              multiplier: 1,
            },
            {
              minAmount: 1000,
              multiplier: 1.3,
            },
            {
              minAmount: 5000,
              multiplier: 1.5,
            },
            {
              minAmount: 10000,
              multiplier: 1.7,
            },
            {
              minAmount: 20000,
              multiplier: 2.1,
            },
          ]
        ]
      });
      const rewardContractAddress = rewardContract.getAddress();

      expect(rewardContractAddress).to.not.equal(null);
    }));
  });

  context('Lock Items', async () => {
    it('should lock an Item', mochaAsync(async () => {
      // TODO: implement
    }));

    it('should unlock an Item', mochaAsync(async () => {
      // TODO: implement
    }));

    it('should unlock multiple items', mochaAsync(async () => {
      // TODO: implement
    }));
  });
});
