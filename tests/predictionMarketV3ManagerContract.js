

import { expect } from 'chai';
import moment from 'moment';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Prediction Market Contract V3 Manager', async () => {
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
  let predictionMarketContract;
  let predictionMarketManagerContract;
  let realitioERC20Contract
  let pmmTokenContract;

  // market / outcome ids we'll make unit tests with
  let outcomeIds = [0, 1];
  const value = 0.01;
  let landId;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: process.env.WEB3_PRIVATE_KEY
      });
      expect(app).to.not.equal(null);
    }));

    it('should deploy Prediction Market Contract', mochaAsync(async () => {
      accountAddress = await app.getAddress();

      // Create Contract
      predictionMarketContract = app.getPredictionMarketV3Contract({});
      predictionMarketManagerContract = app.getPredictionMarketV3ManagerContract({});
      realitioERC20Contract = app.getRealitioERC20Contract({});
      pmmTokenContract = app.getERC20Contract({});

      // Deploy
      await pmmTokenContract.deploy({params: ['Polkamarkets', 'POLK']});
      const pmmTokenContractAddress = pmmTokenContract.getAddress();

      await realitioERC20Contract.deploy({});
      let realitioContractAddress = realitioERC20Contract.getAddress();

      await predictionMarketContract.deploy({
        params: [
          '0x0000000000000000000000000000000000000000'
        ]
      });
      const predictionMarketContractAddress = predictionMarketContract.getAddress();

      await predictionMarketManagerContract.deploy({
        params: [
          predictionMarketContractAddress,
          pmmTokenContractAddress,
          (LOCK_AMOUNT * 10**18).toString(), // TODO: improve this
          realitioContractAddress
        ]
      });
      const predictionMarketManagerContractAddress = predictionMarketManagerContract.getAddress();
      // minting and approving pmmTokenContract to spend tokens
      await pmmTokenContract.mint({
        address: accountAddress,
        amount: '1000'
      });
      await pmmTokenContract.approve({
        address: predictionMarketManagerContractAddress,
        amount: '1000000'
      });

      expect(predictionMarketContractAddress).to.not.equal(null);
      expect(predictionMarketManagerContractAddress).to.not.equal(null);
      expect(realitioContractAddress).to.not.equal(null);
      expect(pmmTokenContractAddress).to.not.equal(null);
    }));
  });

  context('Land Management', async () => {
    context('Land Creation', async () => {
      it('should create a Land', mochaAsync(async () => {
        const currentLandIndex = await predictionMarketManagerContract.getLandTokensLength();
        landId = currentLandIndex;
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketManagerContract.createLand({
          name: 'Token',
          symbol: 'TOKEN',
          tokenAmountToClaim: TOKEN_AMOUNT_TO_CLAIM,
          tokenToAnswer: '0x0000000000000000000000000000000000000000'
        });
        const land = await predictionMarketManagerContract.getLandById({ id: currentLandIndex });
        const newLandIndex = await predictionMarketManagerContract.getLandTokensLength();
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance - LOCK_AMOUNT);
        expect(newLandIndex).to.equal(currentLandIndex + 1);
        expect(land.token).to.not.equal('0x0000000000000000000000000000000000000000');
        expect(land.active).to.equal(true);
        expect(land.lockAmount).to.equal(LOCK_AMOUNT);
        expect(land.lockUser).to.equal(accountAddress);
        expect(land.realitio).to.not.equal('0x0000000000000000000000000000000000000000');
      }));

      it('should create another Land', mochaAsync(async () => {
        const currentLandIndex = await predictionMarketManagerContract.getLandTokensLength();
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketManagerContract.createLand({
          name: 'Token 2',
          symbol: 'TOKEN2',
          tokenAmountToClaim: TOKEN_AMOUNT_TO_CLAIM,
          tokenToAnswer: '0x0000000000000000000000000000000000000000'
        });
        const land = await predictionMarketManagerContract.getLandById({ id: currentLandIndex });
        const newLandIndex = await predictionMarketManagerContract.getLandTokensLength();
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance - LOCK_AMOUNT);
        expect(newLandIndex).to.equal(currentLandIndex + 1);
        expect(land.token).to.not.equal('0x0000000000000000000000000000000000000000');
        expect(land.active).to.equal(true);
        expect(land.lockAmount).to.equal(LOCK_AMOUNT);
        expect(land.lockUser).to.equal(accountAddress);
        expect(land.realitio).to.not.equal('0x0000000000000000000000000000000000000000');
      }));
    });

    context('Land Admins', async () => {
      let landId = 0;
      let token;

      const user1 = USER1_ADDRESS;
      const user2 = USER2_ADDRESS;

      let user1App;
      let user1PredictionMarketManagerContract;

      before(mochaAsync(async () => {
        const land = await predictionMarketManagerContract.getLandById({ id: landId });
        token = land.token;

        user1App = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: USER1_PRIVATE_KEY
        });
        user1PredictionMarketManagerContract = user1App.getPredictionMarketV3ManagerContract({
          contractAddress: predictionMarketManagerContract.getAddress()
        });
      }));

      it('should add an admin to a Land', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });
        await predictionMarketManagerContract.addAdminToLand({
          token,
          user: user2
        });
        const newIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(true);
      }));

      it('should remove an admin from a Land', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });
        await predictionMarketManagerContract.removeAdminFromLand({
          token,
          user: user2
        });
        const newIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });

        expect(currentIsAdmin).to.equal(true);
        expect(newIsAdmin).to.equal(false);
      }));

      it('should not be able to add an admin to a Land if not an admin making the call', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });
        try {
          await user1PredictionMarketManagerContract.addAdminToLand({
            token,
            user: user2
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }
        const newIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(false);
      }));

      it('should be able to add/remove an admin to a Land after being made admin', mochaAsync(async () => {
        await predictionMarketManagerContract.addAdminToLand({
          token,
          user: user1
        });

        const currentIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });
        await user1PredictionMarketManagerContract.addAdminToLand({
          token,
          user: user2
        });
        const newIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(true);

        await user1PredictionMarketManagerContract.removeAdminFromLand({
          token,
          user: user2
        });
        const lastNewIsAdmin = await predictionMarketManagerContract.isLandAdmin({ token, user: user2 });

        expect(lastNewIsAdmin).to.equal(false);

        // resetting user1 admin status
        await predictionMarketManagerContract.removeAdminFromLand({
          token,
          user: user1
        });
      }));
    });

    context('Land Disabling + Enabling + Offset', async () => {
      let landId = 0;
      let land;
      let token;

      let user1App;
      let user1PredictionMarketManagerContract;

      let landTokenContract;

      before(mochaAsync(async () => {
        land = await predictionMarketManagerContract.getLandById({ id: landId });
        landTokenContract = app.getFantasyERC20Contract({contractAddress: land.token});
        token = land.token;

        user1App = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: USER1_PRIVATE_KEY
        });
        user1PredictionMarketManagerContract = user1App.getPredictionMarketV3ManagerContract({
          contractAddress: predictionMarketManagerContract.getAddress()
        });
      }));

      it('should not be able to disable a Land if not an admin making the call', mochaAsync(async () => {
        try {
          await user1PredictionMarketManagerContract.disableLand({
            token
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedLand = await predictionMarketManagerContract.getLandById({ id: landId });
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        expect(land.active).to.equal(true);
        expect(refreshedLand.active).to.equal(true);
      }));

      it('should disable a Land', mochaAsync(async () => {
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });
        const currentPaused = await landTokenContract.paused();
        await predictionMarketManagerContract.disableLand({
          token: land.token
        });

        const refreshedLand = await predictionMarketManagerContract.getLandById({ id: landId });
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });
        const newPaused = await landTokenContract.paused();

        expect(land.active).to.equal(true);
        expect(currentPaused).to.equal(false);
        expect(newPaused).to.equal(true);
        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance + LOCK_AMOUNT);
        expect(refreshedLand.token).to.equal(land.token);
        expect(refreshedLand.active).to.equal(false);
        expect(refreshedLand.lockAmount).to.equal(0);
        expect(refreshedLand.lockUser).to.equal('0x0000000000000000000000000000000000000000');
        expect(refreshedLand.realitio).to.equal(land.realitio);
      }));

      it('should not be able to disable a Land if already disabled', mochaAsync(async () => {
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });
        try {
          await predictionMarketManagerContract.disableLand({
            token
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedLand = await predictionMarketManagerContract.getLandById({ id: landId });
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        expect(refreshedLand.active).to.equal(false);
        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance);
      }));

      it('should enable a Land', mochaAsync(async () => {
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });
        const currentPaused = await landTokenContract.paused();
        await predictionMarketManagerContract.enableLand({
          token: land.token
        });

        const refreshedLand = await predictionMarketManagerContract.getLandById({ id: landId });
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });
        const newPaused = await landTokenContract.paused();

        expect(currentPaused).to.equal(true);
        expect(newPaused).to.equal(false);
        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance - LOCK_AMOUNT);
        expect(refreshedLand.token).to.equal(land.token);
        expect(refreshedLand.active).to.equal(true);
        expect(refreshedLand.lockAmount).to.equal(LOCK_AMOUNT);
        expect(refreshedLand.lockUser).to.equal(accountAddress);
        expect(refreshedLand.realitio).to.equal(land.realitio);
      }));

      it('should be able to update lock amount if not the contract owner', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketManagerContract.lockAmount();
        expect(currentLockAmount).to.equal(LOCK_AMOUNT);

        try {
          await user1PredictionMarketManagerContract.updateLockAmount({
            amount: NEW_LOCK_AMOUNT
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const newLockAmount = await predictionMarketManagerContract.lockAmount();
        expect(newLockAmount).to.equal(LOCK_AMOUNT);
      }));

      it('should be able to update lock amount', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketManagerContract.lockAmount();
        expect(currentLockAmount).to.equal(LOCK_AMOUNT);

        await predictionMarketManagerContract.updateLockAmount({
          amount: NEW_LOCK_AMOUNT
        });

        const newLockAmount = await predictionMarketManagerContract.lockAmount();
        expect(newLockAmount).to.equal(NEW_LOCK_AMOUNT);
      }));

      it('should not be able to unlock offset from land if not an admin', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketManagerContract.lockAmount();
        expect(currentLockAmount).to.equal(NEW_LOCK_AMOUNT);
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        try {
          await user1PredictionMarketManagerContract.unlockOffsetFromLand({
            token: land.token
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedLand = await predictionMarketManagerContract.getLandById({ id: landId });
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance);
        expect(refreshedLand.lockAmount).to.equal(LOCK_AMOUNT);
      }));

      it('should be able to unlock offset from land', mochaAsync(async () => {
        const currentLockAmount = await predictionMarketManagerContract.lockAmount();
        expect(currentLockAmount).to.equal(NEW_LOCK_AMOUNT);
        const currentPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketManagerContract.unlockOffsetFromLand({
          token: land.token
        });

        const refreshedLand = await predictionMarketManagerContract.getLandById({ id: landId });
        const newPmmTokenBalance = await pmmTokenContract.balanceOf({ address: accountAddress });

        expect(newPmmTokenBalance).to.equal(currentPmmTokenBalance + LOCK_AMOUNT - NEW_LOCK_AMOUNT);
        expect(refreshedLand.lockAmount).to.equal(NEW_LOCK_AMOUNT);
      }));
    });
  });

  // context('Market Creation', async () => {
  //   let marketId;

  //   it('should create a Market', mochaAsync(async () => {
  //     try {
  //       const res = await predictionMarketContract.mintAndCreateMarket({
  //         value,
  //         name: 'Will BTC price close above 100k$ on May 1st 2024',
  //         description: 'This is a description',
  //         image: 'foo-bar',
  //         category: 'Foo;Bar',
  //         oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
  //         duration: moment('2024-05-01').unix(),
  //         outcomes: ['Yes', 'No'],
  //         token: tokenERC20Contract.getAddress(),
  //         realitioAddress: realitioERC20Contract.getAddress(),
  //         realitioTimeout: 300,
  //         PM3ManagerAddress: predictionMarketManagerContract.getAddress()
  //       });
  //       expect(res.status).to.equal(true);
  //     } catch(e) {
  //       console.log(e);
  //     }

  //     const marketIds = await predictionMarketContract.getMarkets();
  //     marketId = marketIds[marketIds.length - 1];
  //     expect(marketIds.length).to.equal(1);
  //     expect(marketIds[marketIds.length - 1]).to.equal(marketId);
  //   }));

  //   it('should create another Market', mochaAsync(async () => {
  //     const res = await predictionMarketContract.mintAndCreateMarket({
  //       name: 'Will ETH price close above 10k$ on May 1st 2024',
  //       image: 'foo-bar',
  //       category: 'Foo;Bar',
  //       oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
  //       duration: moment('2024-05-01').unix(),
  //       outcomes: ['Yes', 'No'],
  //       value: 0.001,
  //       token: tokenERC20Contract.getAddress(),
  //       realitioAddress: realitioERC20Contract.getAddress(),
  //       realitioTimeout: 300,
  //       PM3ManagerAddress: predictionMarketManagerContract.getAddress()
  //     });
  //     expect(res.status).to.equal(true);

  //     const marketIds = await predictionMarketContract.getMarkets();
  //     expect(marketIds.length).to.equal(2);
  //   }));
  // });
});
