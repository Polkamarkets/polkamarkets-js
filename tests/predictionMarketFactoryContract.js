

import { expect } from 'chai';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Prediction Market Factory Contract', async () => {
  require('dotenv').config();

  const TOKEN_AMOUNT_TO_CLAIM = 10;
  const LOCK_AMOUNT = 5;
  const NEW_LOCK_AMOUNT = 1;

  const USER1_ADDRESS = process.env.TEST_USER1_ADDRESS;
  const USER1_PRIVATE_KEY = process.env.TEST_USER1_PRIVATE_KEY;
  const USER2_ADDRESS = process.env.TEST_USER2_ADDRESS;
  const USER2_PRIVATE_KEY = process.env.TEST_USER2_PRIVATE_KEY;

  let app;
  let accountAddress;
  let predictionMarketFactoryContract;
  let predictionMarketContract;
  let pmmTokenContract;
  let pmfTokenContract;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: process.env.WEB3_PRIVATE_KEY
      });
      expect(app).to.not.equal(null);
    }));

    it('should deploy Prediction Market Factory Contract', mochaAsync(async () => {
      accountAddress = await app.getAddress();

      // Create Contract
      predictionMarketContract = app.getPredictionMarketV3Contract({});
      pmmTokenContract = app.getERC20Contract({});
      pmfTokenContract = app.getERC20Contract({});


      // Deploy
      await pmfTokenContract.deploy({ params: ['Polkamarkets', 'POLK'] });
      const pmfTokenContractAddress = pmfTokenContract.getAddress();

      await pmmTokenContract.deploy({ params: ['ManagerToken', 'MNGT'] });
      const pmmTokenContractAddress = pmmTokenContract.getAddress();


      predictionMarketFactoryContract = app.getPredictionMarketFactoryContract({});
      // Deploy
      await predictionMarketFactoryContract.deploy({params:
      [
        pmfTokenContractAddress,
        (LOCK_AMOUNT * 10**18).toString(), // TODO: improve this
      ]});
      const predictionMarketFactoryContractAddress = predictionMarketFactoryContract.getAddress();

      await predictionMarketContract.deploy({
        params: [
          '0x0000000000000000000000000000000000000000'
        ]
      });
      const predictionMarketContractAddress = predictionMarketContract.getAddress();

      await pmfTokenContract.mint({
        address: accountAddress,
        amount: '1000'
      });
      await pmfTokenContract.approve({
        address: predictionMarketFactoryContractAddress,
        amount: '1000000'
      });

      expect(predictionMarketContractAddress).to.not.equal(null);
      expect(pmmTokenContractAddress).to.not.equal(null);
      expect(pmfTokenContractAddress).to.not.equal(null);
    }));
  });

  context('Prediction Manager Management', async () => {
    context('Create Manager', async () => {
      it('should create a Prediciton Manager', mochaAsync(async () => {
        const currentManagerIndex = await predictionMarketFactoryContract.getManagersLength();
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketFactoryContract.createPMManager({
          lockAmountLand: LOCK_AMOUNT,
          lockAmountIsland: LOCK_AMOUNT*2,
          PMV3: predictionMarketContract.getAddress(),
          WETH: '0x0000000000000000000000000000000000000000',
          realitioLibraryAddress: '0x0000000000000000000000000000000000000001',
          lockableToken: pmmTokenContract.getAddress()
        });

        const pmManager = await predictionMarketFactoryContract.getPMManagerById({ id: currentManagerIndex });
        const newManagerIndex = await predictionMarketFactoryContract.getManagersLength();
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance - LOCK_AMOUNT);
        expect(newManagerIndex).to.equal(currentManagerIndex + 1);
        expect(pmManager.token).to.equal(pmmTokenContract.getAddress());
        expect(pmManager.active).to.equal(true);
        expect(pmManager.lockAmount).to.equal(LOCK_AMOUNT);
        expect(pmManager.lockUser).to.equal(accountAddress);

        const pmManagerAddress = await predictionMarketFactoryContract.getPMManagerAddressById({ id: currentManagerIndex });

        expect(pmManagerAddress).not.to.equal('0x0000000000000000000000000000000000000000');

        const predictionMarketManagerContract = app.getPredictionMarketV3ManagerContract({ contractAddress: pmManagerAddress});
        const lockAmountLand = await predictionMarketManagerContract.lockAmountLand();
        const lockAmountIsland = await predictionMarketManagerContract.lockAmountIsland();
        const lockToken = await predictionMarketManagerContract.lockToken();

        expect(lockAmountLand).to.equal(LOCK_AMOUNT);
        expect(lockAmountIsland).to.equal(LOCK_AMOUNT*2);
        expect(lockToken).to.equal(pmmTokenContract.getAddress());
      }));

      it('should create another Manager', mochaAsync(async () => {
        const currentManagerIndex = await predictionMarketFactoryContract.getManagersLength();
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketFactoryContract.createPMManager({
          lockAmountLand: LOCK_AMOUNT*2,
          lockAmountIsland: LOCK_AMOUNT * 4,
          PMV3: predictionMarketContract.getAddress(),
          WETH: '0x0000000000000000000000000000000000000000',
          realitioLibraryAddress: '0x0000000000000000000000000000000000000001',
          lockableToken: pmmTokenContract.getAddress()
        });

        const pmManager = await predictionMarketFactoryContract.getPMManagerById({ id: currentManagerIndex });
        const newManagerIndex = await predictionMarketFactoryContract.getManagersLength();
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance - LOCK_AMOUNT);
        expect(newManagerIndex).to.equal(currentManagerIndex + 1);
        expect(pmManager.token).to.equal(pmmTokenContract.getAddress());
        expect(pmManager.active).to.equal(true);
        expect(pmManager.lockAmount).to.equal(LOCK_AMOUNT);
        expect(pmManager.lockUser).to.equal(accountAddress);

        const pmManagerAddress = await predictionMarketFactoryContract.getPMManagerAddressById({ id: currentManagerIndex });

        expect(pmManagerAddress).not.to.equal('0x0000000000000000000000000000000000000000');

        const predictionMarketManagerContract = app.getPredictionMarketV3ManagerContract({ contractAddress: pmManagerAddress });
        const lockAmountLand = await predictionMarketManagerContract.lockAmountLand();
        const lockAmountIsland = await predictionMarketManagerContract.lockAmountIsland();
        const lockToken = await predictionMarketManagerContract.lockToken();

        expect(lockAmountLand).to.equal(LOCK_AMOUNT * 2);
        expect(lockAmountIsland).to.equal(LOCK_AMOUNT * 4);
        expect(lockToken).to.equal(pmmTokenContract.getAddress());
      }));
    });
    context('Manager Admins', async () => {
      let managerId = 0;
      let managerAddress;

      const user1 = USER1_ADDRESS;
      const user2 = USER2_ADDRESS;

      let user1App;
      let user1PredictionMarketFactoryContract;

      before(mochaAsync(async () => {
        managerAddress = await predictionMarketFactoryContract.getPMManagerAddressById({ id: managerId });

        user1App = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: USER1_PRIVATE_KEY
        });

        user1PredictionMarketFactoryContract = user1App.getPredictionMarketFactoryContract({
          contractAddress: predictionMarketFactoryContract.getAddress()
        });
      }));

      it('should add an admin to a Manager', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });

        await predictionMarketFactoryContract.addAdminToPMManager({
          managerAddress,
          user: user2
        });

        const newIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(true);
      }));

      it('should remove an admin from a Manager', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });
        await predictionMarketFactoryContract.removeAdminFromPMManager({
          managerAddress,
          user: user2
        });
        const newIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });

        expect(currentIsAdmin).to.equal(true);
        expect(newIsAdmin).to.equal(false);
      }));

      it('should not be able to add an admin to a Manager if not an admin making the call', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });
        try {
          await user1PredictionMarketFactoryContract.addAdminToPMManager({
            managerAddress,
            user: user2
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }
        const newIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(false);
      }));

      it('should be able to add/remove an admin to a Manager after being made admin', mochaAsync(async () => {
        await predictionMarketFactoryContract.addAdminToPMManager({
          managerAddress,
          user: user1
        });

        const currentIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });
        await user1PredictionMarketFactoryContract.addAdminToPMManager({
          managerAddress,
          user: user2
        });
        const newIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(true);

        await user1PredictionMarketFactoryContract.removeAdminFromPMManager({
          managerAddress,
          user: user2
        });
        const lastNewIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user2 });

        expect(lastNewIsAdmin).to.equal(false);

        // resetting user1 admin status
        await predictionMarketFactoryContract.removeAdminFromPMManager({
          managerAddress,
          user: user1
        });
      }));

      it('should be able to create a land without locking tokens if admin of a manager', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: accountAddress });
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        const predictionMarketManagerContract = app.getPredictionMarketV3ManagerContract({ contractAddress: managerAddress });

        const currentLandIndex = await predictionMarketManagerContract.getLandTokensLength();

        await predictionMarketManagerContract.createLand({
          name: 'Token',
          symbol: 'TOKEN',
          tokenAmountToClaim: TOKEN_AMOUNT_TO_CLAIM,
          tokenToAnswer: '0x0000000000000000000000000000000000000001',
          isIsland: false,
        });

        const land = await predictionMarketManagerContract.getLandById({ id: currentLandIndex });
        const newLandIndex = await predictionMarketManagerContract.getLandTokensLength();
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        expect(currentIsAdmin).to.equal(true);
        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance);
        expect(newLandIndex).to.equal(currentLandIndex + 1);
        expect(land.token).to.not.equal('0x0000000000000000000000000000000000000000');
        expect(land.active).to.equal(true);
        expect(land.lockAmount).to.equal(0);
        expect(land.lockUser).to.equal(accountAddress);
        // expect(land.realitio).to.not.equal('0x0000000000000000000000000000000000000000');
      }));

      it('should not be able to create a land without locking tokens if not admin of a manager', mochaAsync(async () => {
        const predictionMarketManagerContract = user1App.getPredictionMarketV3ManagerContract({ contractAddress: managerAddress });

        await pmmTokenContract.mint({
          address: user1,
          amount: '1000'
        });

        const user1pmmTokenContract = user1App.getERC20Contract({ contractAddress: pmmTokenContract.getAddress() });
        await user1pmmTokenContract.approve({
          address: predictionMarketManagerContract.getAddress(),
          amount: '1000000'
        });

        const currentIsAdmin = await predictionMarketFactoryContract.isPMManagerAdmin({ managerAddress, user: user1 });
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: user1 });
        console.log('currentPmmTokenBalance:', currentPmmTokenBalance);



        const currentLandIndex = await predictionMarketManagerContract.getLandTokensLength();

        await predictionMarketManagerContract.createLand({
          name: 'Token',
          symbol: 'TOKEN',
          tokenAmountToClaim: TOKEN_AMOUNT_TO_CLAIM,
          tokenToAnswer: '0x0000000000000000000000000000000000000001',
          isIsland: false,
        });

        const land = await predictionMarketManagerContract.getLandById({ id: currentLandIndex });
        const newLandIndex = await predictionMarketManagerContract.getLandTokensLength();
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: user1 });

        expect(currentIsAdmin).to.equal(false);
        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance - LOCK_AMOUNT);
        expect(newLandIndex).to.equal(currentLandIndex + 1);
        expect(land.token).to.not.equal('0x0000000000000000000000000000000000000000');
        expect(land.active).to.equal(true);
        expect(land.lockAmount).to.equal(LOCK_AMOUNT);
        expect(land.lockUser).to.equal(user1);
        // expect(land.realitio).to.not.equal('0x0000000000000000000000000000000000000000');
      }));
    });

    context('Manager Disabling + Enabling + Offset', async () => {
      let managerId = 0;
      let manager;
      let managerAddress;

      let user1App;
      let user1PredictionMarketFactoryContract;

      // let landTokenContract;

      before(mochaAsync(async () => {
        managerAddress = await predictionMarketFactoryContract.getPMManagerAddressById({ id: managerId });
        manager = await predictionMarketFactoryContract.getPMManagerByAddress({ managerAddress });
        // landTokenContract = app.getFantasyERC20Contract({contractAddress: manager.token});

        user1App = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: USER1_PRIVATE_KEY
        });
        user1PredictionMarketFactoryContract = user1App.getPredictionMarketFactoryContract({
          contractAddress: predictionMarketFactoryContract.getAddress()
        });
      }));

      it('should not be able to disable a Manager if not an admin making the call', mochaAsync(async () => {
        try {
          await user1PredictionMarketFactoryContract.disablePMManager({
            managerAddress
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedManager = await user1PredictionMarketFactoryContract.getPMManagerByAddress({ managerAddress });

        expect(manager.active).to.equal(true);
        expect(refreshedManager.active).to.equal(true);
      }));

      it('should disable a Manager', mochaAsync(async () => {
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        // const currentPaused = await landTokenContract.paused(); // FIXME when I update the fantasy token to take into account PMF
        await predictionMarketFactoryContract.disablePMManager({
          managerAddress
        });

        const refreshedManager = await user1PredictionMarketFactoryContract.getPMManagerByAddress({ managerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        // const newPaused = await landTokenContract.paused();

        expect(manager.active).to.equal(true);
        // expect(currentPaused).to.equal(false);
        // expect(newPaused).to.equal(true);
        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance + LOCK_AMOUNT);
        expect(refreshedManager.token).to.equal(manager.token);
        expect(refreshedManager.active).to.equal(false);
        expect(refreshedManager.lockAmount).to.equal(0);
        expect(refreshedManager.lockUser).to.equal('0x0000000000000000000000000000000000000000');
      }));

      it('should not be able to disable a Manager if already disabled', mochaAsync(async () => {
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        try {
          await predictionMarketFactoryContract.disablePMManager({
            managerAddress
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedManager = await user1PredictionMarketFactoryContract.getPMManagerByAddress({ managerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(refreshedManager.active).to.equal(false);
        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance);
      }));

      it('should enable a Manager', mochaAsync(async () => {
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        // const currentPaused = await landTokenContract.paused(); // FIXME when I update the fantasy token to take into account PMF
        await predictionMarketFactoryContract.enablePMManager({
          managerAddress
        });

        const refreshedManager = await user1PredictionMarketFactoryContract.getPMManagerByAddress({ managerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        // const newPaused = await landTokenContract.paused();

        // expect(currentPaused).to.equal(true);
        // expect(newPaused).to.equal(false);
        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance - LOCK_AMOUNT);
        expect(refreshedManager.token).to.equal(manager.token);
        expect(refreshedManager.active).to.equal(true);
        expect(refreshedManager.lockAmount).to.equal(LOCK_AMOUNT);
        expect(refreshedManager.lockUser).to.equal(accountAddress);
      }));

      it('should not be able to update lock amount if not the contract owner', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketFactoryContract.lockAmount();
        expect(currentLockAmount).to.equal(LOCK_AMOUNT);

        try {
          await user1PredictionMarketFactoryContract.updateLockAmount({
            amount: NEW_LOCK_AMOUNT,
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const newLockAmount = await predictionMarketFactoryContract.lockAmount();
        expect(newLockAmount).to.equal(LOCK_AMOUNT);
      }));

      it('should be able to update lock amount', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketFactoryContract.lockAmount();
        expect(currentLockAmount).to.equal(LOCK_AMOUNT);

        await predictionMarketFactoryContract.updateLockAmount({
          amount: NEW_LOCK_AMOUNT,
        });

        const newLockAmount = await predictionMarketFactoryContract.lockAmount();
        expect(newLockAmount).to.equal(NEW_LOCK_AMOUNT);
      }));

      it('should not be able to unlock offset from manager if not an admin', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketFactoryContract.lockAmount();
        expect(currentLockAmount).to.equal(NEW_LOCK_AMOUNT);
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        try {
          await user1PredictionMarketFactoryContract.unlockOffsetFromPMManager({
            managerAddress
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedManager = await user1PredictionMarketFactoryContract.getPMManagerByAddress({ managerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance);
        expect(refreshedManager.lockAmount).to.equal(LOCK_AMOUNT);
      }));

      it('should be able to unlock offset from manager', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketFactoryContract.lockAmount();
        expect(currentLockAmount).to.equal(NEW_LOCK_AMOUNT);
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketFactoryContract.unlockOffsetFromPMManager({
          managerAddress
        });

        const refreshedManager = await user1PredictionMarketFactoryContract.getPMManagerByAddress({ managerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance + LOCK_AMOUNT - NEW_LOCK_AMOUNT);
        expect(refreshedManager.lockAmount).to.equal(NEW_LOCK_AMOUNT);
      }));
    });
  });
});
