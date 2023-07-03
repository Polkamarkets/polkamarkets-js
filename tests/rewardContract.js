

import { expect } from 'chai';

import { mochaAsync } from './utils';
import { Application } from '..';

const USER_ADDRESS = process.env.ERC20_USER;

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
          [0, 1000, 5000, 10000, 20000],
          [10, 13, 15, 17, 21],
        ]
      });
      const rewardContractAddress = rewardContract.getAddress();

      expect(rewardContractAddress).to.not.equal(null);
    }));
  });

  context('Lock Items', async () => {
    it('should lock an Item', mochaAsync(async () => {
      let itemId = 0;

      // chek if there are no lock amount
      let amountLocked = await rewardContract.getItemLockedAmount({ itemId });
      expect(amountLocked).to.equal(0);

      amountLocked = await rewardContract.getAmontUserLockedItem({ itemId, user: USER_ADDRESS });
      expect(amountLocked).to.equal(0);

      const beforeTokenAmount = await ERC20Contract.getTokenAmount(USER_ADDRESS);
      expect(beforeTokenAmount).to.greaterThan(0);

      const res = await rewardContract.lockItem({
        itemId,
        amount: 10,
      });

      expect(res.status).to.equal(true);

      amountLocked = await rewardContract.getItemLockedAmount({ itemId });
      expect(amountLocked).to.equal(10);

      amountLocked = await rewardContract.getAmontUserLockedItem({ itemId, user: USER_ADDRESS });
      expect(amountLocked).to.equal(10);

      const afterTokenAmount = await ERC20Contract.getTokenAmount(USER_ADDRESS);
      expect(afterTokenAmount).to.greaterThan(beforeTokenAmount - 10);

    }));

    it('should unlock an Item', mochaAsync(async () => {
      let itemId = 0;

      // chek if there are no lock amount
      let amountLocked = await rewardContract.getItemLockedAmount({ itemId });
      expect(amountLocked).to.equal(10);

      amountLocked = await rewardContract.getAmontUserLockedItem({ itemId, user: USER_ADDRESS });
      expect(amountLocked).to.equal(10);

      const beforeTokenAmount = await ERC20Contract.getTokenAmount(USER_ADDRESS);
      expect(beforeTokenAmount).to.greaterThan(0);

      const res = await rewardContract.unlockItem({
        itemId,
        amount: 5,
      });

      expect(res.status).to.equal(true);

      amountLocked = await rewardContract.getItemLockedAmount({ itemId });
      expect(amountLocked).to.equal(5);

      amountLocked = await rewardContract.getAmontUserLockedItem({ itemId, user: USER_ADDRESS });
      expect(amountLocked).to.equal(5);

      const afterTokenAmount = await ERC20Contract.getTokenAmount(USER_ADDRESS);
      expect(afterTokenAmount).to.greaterThan(beforeTokenAmount + 5);
    }));

    it('should unlock multiple items', mochaAsync(async () => {
      const itemId = 0;
      const itemId2 = 1;

      // lock itemId2
      let amountLocked = await rewardContract.getItemLockedAmount({ itemId: itemId2 });
      expect(amountLocked).to.equal(0);

      let res = await rewardContract.lockItem({
        itemId: itemId2,
        amount: 30,
      });

      amountLocked = await rewardContract.getItemLockedAmount({ itemId: itemId2 });
      expect(amountLocked).to.equal(30);

      // check amount locked for itemId
      amountLocked = await rewardContract.getItemLockedAmount({ itemId });
      expect(amountLocked).to.equal(5);

      // unlock both items
      res = await rewardContract.unlockMultipleItems({
        itemIds: [itemId, itemId2],
        amounts: [5, 30],
      });

      expect(res.status).to.equal(true);

      amountLocked = await rewardContract.getItemLockedAmount({ itemId });
      expect(amountLocked).to.equal(0);

      amountLocked = await rewardContract.getItemLockedAmount({ itemId: itemId2 });
      expect(amountLocked).to.equal(0);
    }));
  });
});
