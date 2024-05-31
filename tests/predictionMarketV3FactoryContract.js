

import { expect } from 'chai';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Prediction Market Factory V3 Contract', async () => {
  require('dotenv').config();

  const TOKEN_AMOUNT_TO_CLAIM = 10;
  const LOCK_AMOUNT = 5;
  const NEW_LOCK_AMOUNT = 1;

  const USER1_ADDRESS = process.env.TEST_USER1_ADDRESS;
  const USER1_PRIVATE_KEY = process.env.TEST_USER1_PRIVATE_KEY;
  const USER2_ADDRESS = process.env.TEST_USER2_ADDRESS;

  let app;
  let accountAddress;
  let predictionMarketFactoryContract;
  let predictionMarketContract;
  let pmfTokenContract;
  let realitioERC20Contract;

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
      pmfTokenContract = app.getERC20Contract({});
      realitioERC20Contract = app.getRealitioERC20Contract({});

      await realitioERC20Contract.deploy({});

      // Deploy
      await pmfTokenContract.deploy({ params: ['Polkamarkets', 'POLK'] });
      const pmfTokenContractAddress = pmfTokenContract.getAddress();

      predictionMarketFactoryContract = app.getPredictionMarketV3FactoryContract({});
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
      expect(pmfTokenContractAddress).to.not.equal(null);
    }));
  });

  context('Prediction Controller Management', async () => {
    context('Create Controller', async () => {
      it('should create a Prediciton Controller', mochaAsync(async () => {
        const currentControllerIndex = await predictionMarketFactoryContract.getControllersLength();
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketFactoryContract.createPMController({
          PMV3: predictionMarketContract.getAddress(),
          WETH: '0x0000000000000000000000000000000000000000',
          realitioLibraryAddress: realitioERC20Contract.getAddress(),
        });

        const pmController = await predictionMarketFactoryContract.getPMControllerById({ id: currentControllerIndex });
        const newControllerIndex = await predictionMarketFactoryContract.getControllersLength();
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance - LOCK_AMOUNT);
        expect(newControllerIndex).to.equal(currentControllerIndex + 1);
        expect(pmController.active).to.equal(true);
        expect(pmController.lockAmount).to.equal(LOCK_AMOUNT);
        expect(pmController.lockUser).to.equal(accountAddress);

        const pmControllerAddress = await predictionMarketFactoryContract.getPMControllerAddressById({ id: currentControllerIndex });

        expect(pmControllerAddress).not.to.equal('0x0000000000000000000000000000000000000000');

        const predictionMarketControllerContract = app.getPredictionMarketV3ControllerContract({ contractAddress: pmControllerAddress});
        const landTokensLenght = await predictionMarketControllerContract.getLandTokensLength();

        expect(landTokensLenght).to.equal(0);
      }));

      it('should create another Controller', mochaAsync(async () => {
        const currentControllerIndex = await predictionMarketFactoryContract.getControllersLength();
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketFactoryContract.createPMController({
          PMV3: predictionMarketContract.getAddress(),
          WETH: '0x0000000000000000000000000000000000000000',
          realitioLibraryAddress: realitioERC20Contract.getAddress(),
        });

        const pmController = await predictionMarketFactoryContract.getPMControllerById({ id: currentControllerIndex });
        const newControllerIndex = await predictionMarketFactoryContract.getControllersLength();
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance - LOCK_AMOUNT);
        expect(newControllerIndex).to.equal(currentControllerIndex + 1);
        expect(pmController.active).to.equal(true);
        expect(pmController.lockAmount).to.equal(LOCK_AMOUNT);
        expect(pmController.lockUser).to.equal(accountAddress);

        const pmControllerAddress = await predictionMarketFactoryContract.getPMControllerAddressById({ id: currentControllerIndex });

        expect(pmControllerAddress).not.to.equal('0x0000000000000000000000000000000000000000');

        const predictionMarketControllerContract = app.getPredictionMarketV3ControllerContract({ contractAddress: pmControllerAddress });
        const landTokensLenght = await predictionMarketControllerContract.getLandTokensLength();

        expect(landTokensLenght).to.equal(0);
      }));
    });

    context('Controller Admins', async () => {
      let controllerId = 0;
      let controllerAddress;

      const user1 = USER1_ADDRESS;
      const user2 = USER2_ADDRESS;

      let user1App;
      let user1PredictionMarketFactoryContract;

      before(mochaAsync(async () => {
        controllerAddress = await predictionMarketFactoryContract.getPMControllerAddressById({ id: controllerId });

        user1App = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: USER1_PRIVATE_KEY
        });

        user1PredictionMarketFactoryContract = user1App.getPredictionMarketV3FactoryContract({
          contractAddress: predictionMarketFactoryContract.getAddress()
        });
      }));

      it('should add an admin to a Controller', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });

        await predictionMarketFactoryContract.addAdminToPMController({
          controllerAddress,
          user: user2
        });

        const newIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(true);
      }));

      it('should remove an admin from a Controller', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });
        await predictionMarketFactoryContract.removeAdminFromPMController({
          controllerAddress,
          user: user2
        });
        const newIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });

        expect(currentIsAdmin).to.equal(true);
        expect(newIsAdmin).to.equal(false);
      }));

      it('should not remove from admin the user that locked the tokens from a Controller', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: accountAddress });
        try {
          await predictionMarketFactoryContract.removeAdminFromPMController({
            controllerAddress,
            user: accountAddress
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }
        const newIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: accountAddress });

        expect(currentIsAdmin).to.equal(true);
        expect(newIsAdmin).to.equal(true);
      }));

      it('should not be able to add an admin to a Controller if not an admin making the call', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });
        try {
          await user1PredictionMarketFactoryContract.addAdminToPMController({
            controllerAddress,
            user: user2
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }
        const newIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(false);
      }));

      it('should be able to add/remove an admin to a Controller after being made admin', mochaAsync(async () => {
        await predictionMarketFactoryContract.addAdminToPMController({
          controllerAddress,
          user: user1
        });

        const currentIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });
        await user1PredictionMarketFactoryContract.addAdminToPMController({
          controllerAddress,
          user: user2
        });
        const newIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(true);

        await user1PredictionMarketFactoryContract.removeAdminFromPMController({
          controllerAddress,
          user: user2
        });
        const lastNewIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user2 });

        expect(lastNewIsAdmin).to.equal(false);

        // resetting user1 admin status
        await predictionMarketFactoryContract.removeAdminFromPMController({
          controllerAddress,
          user: user1
        });
      }));



      it('should be able to create a land if admin of a Controller', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: accountAddress });

        const predictionMarketControllerContract = app.getPredictionMarketV3ControllerContract({ contractAddress: controllerAddress });

        const currentLandIndex = await predictionMarketControllerContract.getLandTokensLength();

        await predictionMarketControllerContract.createLand({
          name: 'Token',
          symbol: 'TOKEN',
          tokenAmountToClaim: TOKEN_AMOUNT_TO_CLAIM,
          tokenToAnswer: pmfTokenContract.getAddress(),
          everyoneCanCreateMarkets: false,
        });

        const land = await predictionMarketControllerContract.getLandById({ id: currentLandIndex });
        const newLandIndex = await predictionMarketControllerContract.getLandTokensLength();

        expect(currentIsAdmin).to.equal(true);
        expect(newLandIndex).to.equal(currentLandIndex + 1);
        expect(land.token).to.not.equal('0x0000000000000000000000000000000000000000');
        expect(land.active).to.equal(true);
        expect(land.realitio).to.not.equal('0x0000000000000000000000000000000000000000');
      }));

      it('should not be able to create a land if not admin of a Controller', mochaAsync(async () => {
        const predictionMarketControllerContract = user1App.getPredictionMarketV3ControllerContract({ contractAddress: controllerAddress });
        const currentIsAdmin = await predictionMarketFactoryContract.isPMControllerAdmin({ controllerAddress, user: user1 });


        const currentLandIndex = await predictionMarketControllerContract.getLandTokensLength();

        try {
          await predictionMarketControllerContract.createLand({
            name: 'Token',
            symbol: 'TOKEN',
            tokenAmountToClaim: TOKEN_AMOUNT_TO_CLAIM,
            tokenToAnswer: pmfTokenContract.getAddress(),
            everyoneCanCreateMarkets: false,
          });
        } catch (e) {
          // not logging error, as tx is expected to fail
        }
        const newLandIndex = await predictionMarketControllerContract.getLandTokensLength();

        expect(currentIsAdmin).to.equal(false);
        expect(newLandIndex).to.equal(currentLandIndex);
      }));
    });

    context('Controller Disabling + Enabling + Offset', async () => {
      let controllerId = 0;
      let controller;
      let controllerAddress;

      let user1App;
      let user1PredictionMarketFactoryContract;

      let landTokenContract;

      before(mochaAsync(async () => {
        controllerAddress = await predictionMarketFactoryContract.getPMControllerAddressById({ id: controllerId });
        controller = await predictionMarketFactoryContract.getPMControllerByAddress({ controllerAddress });

        user1App = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: USER1_PRIVATE_KEY
        });
        user1PredictionMarketFactoryContract = user1App.getPredictionMarketV3FactoryContract({
          contractAddress: predictionMarketFactoryContract.getAddress()
        });

        const pmControllerAddress = await predictionMarketFactoryContract.getPMControllerAddressById({ id: controllerId });
        const predictionMarketControllerContract = app.getPredictionMarketV3ControllerContract({ contractAddress: pmControllerAddress });
        const land = await predictionMarketControllerContract.getLandById({ id: 0 });
        landTokenContract = app.getFantasyERC20Contract({ contractAddress: land.token });
      }));

      it('should not be able to disable a Controller if not an admin making the call', mochaAsync(async () => {
        try {
          await user1PredictionMarketFactoryContract.disablePMController({
            controllerAddress
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedController = await user1PredictionMarketFactoryContract.getPMControllerByAddress({ controllerAddress });

        expect(controller.active).to.equal(true);
        expect(refreshedController.active).to.equal(true);
      }));

      it('should disable a Controller', mochaAsync(async () => {
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        const currentPaused = await landTokenContract.paused();
        await predictionMarketFactoryContract.disablePMController({
          controllerAddress
        });

        const refreshedController = await user1PredictionMarketFactoryContract.getPMControllerByAddress({ controllerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        const newPaused = await landTokenContract.paused();

        expect(controller.active).to.equal(true);
        expect(currentPaused).to.equal(false);
        expect(newPaused).to.equal(true);
        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance + LOCK_AMOUNT);
        expect(refreshedController.token).to.equal(controller.token);
        expect(refreshedController.active).to.equal(false);
        expect(refreshedController.lockAmount).to.equal(0);
        expect(refreshedController.lockUser).to.equal('0x0000000000000000000000000000000000000000');
      }));

      it('should not be able to disable a Controller if already disabled', mochaAsync(async () => {
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        try {
          await predictionMarketFactoryContract.disablePMController({
            controllerAddress
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedController = await user1PredictionMarketFactoryContract.getPMControllerByAddress({ controllerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(refreshedController.active).to.equal(false);
        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance);
      }));

      it('should enable a Controller', mochaAsync(async () => {
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        const currentPaused = await landTokenContract.paused();
        await predictionMarketFactoryContract.enablePMController({
          controllerAddress
        });

        const refreshedController = await user1PredictionMarketFactoryContract.getPMControllerByAddress({ controllerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });
        const newPaused = await landTokenContract.paused();

        expect(currentPaused).to.equal(true);
        expect(newPaused).to.equal(false);
        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance - LOCK_AMOUNT);
        expect(refreshedController.token).to.equal(controller.token);
        expect(refreshedController.active).to.equal(true);
        expect(refreshedController.lockAmount).to.equal(LOCK_AMOUNT);
        expect(refreshedController.lockUser).to.equal(accountAddress);
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

      it('should not be able to unlock offset from Controller if not an admin', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketFactoryContract.lockAmount();
        expect(currentLockAmount).to.equal(NEW_LOCK_AMOUNT);
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        try {
          await user1PredictionMarketFactoryContract.unlockOffsetFromPMController({
            controllerAddress
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedController = await user1PredictionMarketFactoryContract.getPMControllerByAddress({ controllerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance);
        expect(refreshedController.lockAmount).to.equal(LOCK_AMOUNT);
      }));

      it('should be able to unlock offset from Controller', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketFactoryContract.lockAmount();
        expect(currentLockAmount).to.equal(NEW_LOCK_AMOUNT);
        const currentPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketFactoryContract.unlockOffsetFromPMController({
          controllerAddress
        });

        const refreshedController = await user1PredictionMarketFactoryContract.getPMControllerByAddress({ controllerAddress });
        const newPmfTokenBalance = await pmfTokenContract.balanceOf({ address: accountAddress });

        expect(newPmfTokenBalance).to.equal(currentPmfTokenBalance + LOCK_AMOUNT - NEW_LOCK_AMOUNT);
        expect(refreshedController.lockAmount).to.equal(NEW_LOCK_AMOUNT);
      }));
    });
  });
});
