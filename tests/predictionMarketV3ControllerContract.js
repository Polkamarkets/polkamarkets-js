

import { expect } from 'chai';
import moment from 'moment';

import { mochaAsync } from './utils';
import { Application } from '..';

context('Prediction Market Contract V3 Controller', async () => {
  require('dotenv').config();

  const TOKEN_AMOUNT_TO_CLAIM = 10;
  const LOCK_AMOUNT = 5;

  const USER1_ADDRESS = process.env.TEST_USER1_ADDRESS;
  const USER1_PRIVATE_KEY = process.env.TEST_USER1_PRIVATE_KEY;
  const USER2_ADDRESS = process.env.TEST_USER2_ADDRESS;

  let app;
  let accountAddress;
  let predictionMarketContract;
  let predictionMarketFactoryContract;
  let predictionMarketControllerContract;
  let realitioERC20Contract
  let pmfTokenContract;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: process.env.WEB3_PRIVATE_KEY
      });
      expect(app).to.not.equal(null);
    }));

    it('should deploy Prediction Market Controller Contract', mochaAsync(async () => {
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
      await predictionMarketFactoryContract.deploy({
        params:
          [
            pmfTokenContractAddress,
            (LOCK_AMOUNT * 10 ** 18).toString(), // TODO: improve this
          ]
      });
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

      await predictionMarketFactoryContract.createPMController({
        PMV3: predictionMarketContract.getAddress(),
        WETH: '0x0000000000000000000000000000000000000000',
        realitioLibraryAddress: realitioERC20Contract.getAddress(),
      });

      const predictionMarketControllerAddress = await predictionMarketFactoryContract.getPMControllerAddressById({
        id: 0
      });

      expect(predictionMarketControllerAddress).to.not.equal(null);

      predictionMarketControllerContract = app.getPredictionMarketV3ControllerContract({ contractAddress: predictionMarketControllerAddress });

      expect(predictionMarketControllerContract).to.not.equal(null);
      expect(predictionMarketContractAddress).to.not.equal(null);
      expect(pmfTokenContractAddress).to.not.equal(null);
    }));
  });

  context('Land Management', async () => {
    context('Land Creation', async () => {
      it('should create a Land', mochaAsync(async () => {
        const currentLandIndex = await predictionMarketControllerContract.getLandTokensLength();

        await predictionMarketControllerContract.createLand({
          name: 'Token',
          symbol: 'TOKEN',
          tokenAmountToClaim: TOKEN_AMOUNT_TO_CLAIM,
          tokenToAnswer: pmfTokenContract.getAddress(),
          everyoneCanCreateMarkets: false
        });

        const land = await predictionMarketControllerContract.getLandById({ id: currentLandIndex });
        const newLandIndex = await predictionMarketControllerContract.getLandTokensLength();

        expect(newLandIndex).to.equal(currentLandIndex + 1);
        expect(land.token).to.not.equal('0x0000000000000000000000000000000000000000');
        expect(land.active).to.equal(true);
        expect(land.everyoneCanCreateMarkets).to.equal(false);
        expect(land.realitio).to.not.equal('0x0000000000000000000000000000000000000000');
      }));

      it('should create another Land', mochaAsync(async () => {
        const currentLandIndex = await predictionMarketControllerContract.getLandTokensLength();

        await predictionMarketControllerContract.createLand({
          name: 'Token 2',
          symbol: 'TOKEN2',
          tokenAmountToClaim: TOKEN_AMOUNT_TO_CLAIM,
          tokenToAnswer: pmfTokenContract.getAddress(),
          everyoneCanCreateMarkets: true
        });
        const land = await predictionMarketControllerContract.getLandById({ id: currentLandIndex });
        const newLandIndex = await predictionMarketControllerContract.getLandTokensLength();

        expect(newLandIndex).to.equal(currentLandIndex + 1);
        expect(land.token).to.not.equal('0x0000000000000000000000000000000000000000');
        expect(land.active).to.equal(true);
        expect(land.everyoneCanCreateMarkets).to.equal(true);
        expect(land.realitio).to.not.equal('0x0000000000000000000000000000000000000000');
      }));
    });

    context('Land Admins', async () => {
      let landId = 0;
      let token;

      const user1 = USER1_ADDRESS;
      const user2 = USER2_ADDRESS;

      let user1App;
      let user1PredictionMarketControllerContract;

      before(mochaAsync(async () => {
        const land = await predictionMarketControllerContract.getLandById({ id: landId });
        token = land.token;

        user1App = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: USER1_PRIVATE_KEY
        });
        user1PredictionMarketControllerContract = user1App.getPredictionMarketV3ControllerContract({
          contractAddress: predictionMarketControllerContract.getAddress()
        });
      }));

      it('should add an admin to a Land', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });
        await predictionMarketControllerContract.addAdminToLand({
          token,
          user: user2
        });
        const newIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(true);
      }));

      it('should remove an admin from a Land', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });
        await predictionMarketControllerContract.removeAdminFromLand({
          token,
          user: user2
        });
        const newIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });

        expect(currentIsAdmin).to.equal(true);
        expect(newIsAdmin).to.equal(false);
      }));

      it('should not be able to add an admin to a Land if not an admin making the call', mochaAsync(async () => {
        const currentIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });
        try {
          await user1PredictionMarketControllerContract.addAdminToLand({
            token,
            user: user2
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }
        const newIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(false);
      }));

      it('should be able to add/remove an admin to a Land after being made admin', mochaAsync(async () => {
        await predictionMarketControllerContract.addAdminToLand({
          token,
          user: user1
        });

        const currentIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });
        await user1PredictionMarketControllerContract.addAdminToLand({
          token,
          user: user2
        });
        const newIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });

        expect(currentIsAdmin).to.equal(false);
        expect(newIsAdmin).to.equal(true);

        await user1PredictionMarketControllerContract.removeAdminFromLand({
          token,
          user: user2
        });
        const lastNewIsAdmin = await predictionMarketControllerContract.isLandAdmin({ token, user: user2 });

        expect(lastNewIsAdmin).to.equal(false);

        // resetting user1 admin status
        await predictionMarketControllerContract.removeAdminFromLand({
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
      let user1PredictionMarketControllerContract;

      let landTokenContract;

      before(mochaAsync(async () => {
        land = await predictionMarketControllerContract.getLandById({ id: landId });
        landTokenContract = app.getFantasyERC20Contract({contractAddress: land.token});
        token = land.token;

        user1App = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: USER1_PRIVATE_KEY
        });
        user1PredictionMarketControllerContract = user1App.getPredictionMarketV3ControllerContract({
          contractAddress: predictionMarketControllerContract.getAddress()
        });
      }));

      it('should not be able to disable a Land if not an admin making the call', mochaAsync(async () => {
        try {
          await user1PredictionMarketControllerContract.disableLand({
            token
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedLand = await predictionMarketControllerContract.getLandById({ id: landId });

        expect(land.active).to.equal(true);
        expect(refreshedLand.active).to.equal(true);
      }));

      it('should disable a Land', mochaAsync(async () => {
        const currentPaused = await landTokenContract.paused();
        await predictionMarketControllerContract.disableLand({
          token: land.token
        });

        const refreshedLand = await predictionMarketControllerContract.getLandById({ id: landId });
        const newPaused = await landTokenContract.paused();

        expect(land.active).to.equal(true);
        expect(currentPaused).to.equal(false);
        expect(newPaused).to.equal(true);
        expect(refreshedLand.token).to.equal(land.token);
        expect(refreshedLand.active).to.equal(false);
        expect(refreshedLand.realitio).to.equal(land.realitio);
      }));

      it('should not be able to disable a Land if already disabled', mochaAsync(async () => {
        try {
          await predictionMarketControllerContract.disableLand({
            token
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const refreshedLand = await predictionMarketControllerContract.getLandById({ id: landId });

        expect(refreshedLand.active).to.equal(false);
      }));

      it('should enable a Land', mochaAsync(async () => {
        const currentPaused = await landTokenContract.paused();
        await predictionMarketControllerContract.enableLand({
          token: land.token
        });

        const refreshedLand = await predictionMarketControllerContract.getLandById({ id: landId });
        const newPaused = await landTokenContract.paused();

        expect(currentPaused).to.equal(true);
        expect(newPaused).to.equal(false);
        expect(refreshedLand.token).to.equal(land.token);
        expect(refreshedLand.active).to.equal(true);
        expect(refreshedLand.realitio).to.equal(land.realitio);
      }));
    });
  });

  context('Land Markets', async () => {
    let landId = 0;
    let marketId = 0;
    let outcomeId = 0;
    let value = 0.01;
    let land;
    let land2;

    let user1;
    let user1App;
    let user1PredictionMarketContract;

    let landTokenContract;
    let land2TokenContract;
    let user1LandTokenContract;
    let user1Land2TokenContract;

    before(mochaAsync(async () => {
      land = await predictionMarketControllerContract.getLandById({ id: landId });
      land2 = await predictionMarketControllerContract.getLandById({ id: landId + 1});

      user1 = USER1_ADDRESS;
      user1App = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: USER1_PRIVATE_KEY
      });
      user1PredictionMarketContract = user1App.getPredictionMarketV3Contract({
        contractAddress: predictionMarketContract.getAddress()
      });

      landTokenContract = app.getFantasyERC20Contract({contractAddress: land.token});
      land2TokenContract = app.getFantasyERC20Contract({contractAddress: land2.token});
      user1LandTokenContract = user1App.getFantasyERC20Contract({contractAddress: land.token});
      user1Land2TokenContract = user1App.getFantasyERC20Contract({contractAddress: land2.token});
      // approving land token to spend tokens
      await landTokenContract.claimAndApproveTokens();
      await land2TokenContract.claimAndApproveTokens();
      await user1LandTokenContract.claimAndApproveTokens();
      await user1Land2TokenContract.claimAndApproveTokens();
    }));

    context('Market Creation', async () => {
      it('should not be able to create a Market if not an admin making the call and everyoneCanCreateMarkets is not active', mochaAsync(async () => {
        const currentMarketIds = await predictionMarketContract.getMarkets();
        const currentLandTokenBalance = await landTokenContract.balanceOf({ address: user1 });
        expect(currentLandTokenBalance).to.equal(TOKEN_AMOUNT_TO_CLAIM);
        expect(land.everyoneCanCreateMarkets).to.equal(false);

        try {
          await user1PredictionMarketContract.mintAndCreateMarket({
            value,
            name: 'Will BTC price close above 100k$ on May 1st 2025',
            description: 'This is a description',
            image: 'foo-bar',
            category: 'Foo;Bar',
            oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
            duration: moment('2025-05-01').unix(),
            outcomes: ['Yes', 'No'],
            token: landTokenContract.getAddress(),
            realitioAddress: land.realitio,
            realitioTimeout: 300,
            PM3ManagerAddress: predictionMarketControllerContract.getAddress()
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const newMarketIds = await predictionMarketContract.getMarkets();
        expect(newMarketIds.length).to.equal(currentMarketIds.length);
      }));

      it('should create a Market if admin', mochaAsync(async () => {
        const currentMarketIds = await predictionMarketContract.getMarkets();
        const currentLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });
        expect(currentLandTokenBalance).to.equal(TOKEN_AMOUNT_TO_CLAIM);


        const res = await predictionMarketContract.mintAndCreateMarket({
          value,
          name: 'Will BTC price close above 100k$ on May 1st 2025',
          description: 'This is a description',
          image: 'foo-bar',
          category: 'Foo;Bar',
          oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
          duration: moment('2025-05-01').unix(),
          outcomes: ['Yes', 'No'],
          token: landTokenContract.getAddress(),
          realitioAddress: land.realitio,
          realitioTimeout: 300,
          PM3ManagerAddress: predictionMarketControllerContract.getAddress()
        });
        expect(res.status).to.equal(true);


        const newLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });
        const newMarketIds = await predictionMarketContract.getMarkets();
        expect(newMarketIds.length).to.equal(currentMarketIds.length + 1);
        // balance remains the same since tokens were minted
        expect(newLandTokenBalance).to.equal(currentLandTokenBalance);
      }));

      it('should be able to create a Market if not an admin making the call and everyoneCanCreateMarkets is active', mochaAsync(async () => {
        const currentMarketIds = await predictionMarketContract.getMarkets();
        const currentLandTokenBalance = await land2TokenContract.balanceOf({ address: user1 });
        expect(currentLandTokenBalance).to.equal(TOKEN_AMOUNT_TO_CLAIM);
        expect(await predictionMarketControllerContract.isLandAdmin({ token: land2TokenContract.getAddress(), user: user1 })).to.equal(false);
        expect(land2.everyoneCanCreateMarkets).to.equal(true);

        const res = await predictionMarketContract.mintAndCreateMarket({
          value,
          name: 'Will Something Happen tomorrow?',
          description: 'This is a description',
          image: 'foo-bar',
          category: 'Foo;Bar',
          oracleAddress: '0x0000000000000000000000000000000000000001', // TODO
          duration: moment('2026-05-01').unix(),
          outcomes: ['Yes', 'No'],
          token: land2TokenContract.getAddress(),
          realitioAddress: land2.realitio,
          realitioTimeout: 300,
          PM3ManagerAddress: predictionMarketControllerContract.getAddress()
        });
        expect(res.status).to.equal(true);

        const newLandTokenBalance = await land2TokenContract.balanceOf({ address: accountAddress });
        const newMarketIds = await predictionMarketContract.getMarkets();
        expect(newMarketIds.length).to.equal(currentMarketIds.length + 1);
        // balance remains the same since tokens were minted
        expect(newLandTokenBalance).to.equal(currentLandTokenBalance);
      }));
    });

    context('Market Interaction', async () => {
      it('should be able to buy shares when land enabled', mochaAsync(async () => {
        const minOutcomeSharesToBuy = 0.015;
        const currentLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });

        try {
          const res = await predictionMarketContract.buy({marketId, outcomeId, value, minOutcomeSharesToBuy});
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const newLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });
        const amountTransferred = Number((currentLandTokenBalance - newLandTokenBalance).toFixed(5));

        expect(amountTransferred).to.equal(value);
      }));

      it('should sell outcome shares', mochaAsync(async () => {
        const outcomeId = 0;
        const maxOutcomeSharesToSell = 0.015;

        const currentLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });

        try {
          const res = await predictionMarketContract.sell({marketId, outcomeId, value, maxOutcomeSharesToSell});
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const newLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });
        const amountTransferred = Number((newLandTokenBalance - currentLandTokenBalance).toFixed(5));

        expect(amountTransferred).to.equal(value);
      }));

      it('should not be able to buy shares when land disabled', mochaAsync(async () => {
        const minOutcomeSharesToBuy = 0.015;
        const currentLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketControllerContract.disableLand({
          token: land.token
        });

        try {
          const res = await predictionMarketContract.buy({marketId, outcomeId, value, minOutcomeSharesToBuy});
          expect(res.status).to.equal(true);
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const newLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });
        const amountTransferred = currentLandTokenBalance - newLandTokenBalance;

        expect(amountTransferred).to.equal(0);
      }));

      it('should be able to buy shares when land enabled again', mochaAsync(async () => {
        const minOutcomeSharesToBuy = 0.015;
        const currentLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });

        await predictionMarketControllerContract.enableLand({
          token: land.token
        });

        try {
          const res = await predictionMarketContract.buy({marketId, outcomeId, value, minOutcomeSharesToBuy});
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        const newLandTokenBalance = await landTokenContract.balanceOf({ address: accountAddress });
        const amountTransferred = Number((currentLandTokenBalance - newLandTokenBalance).toFixed(5));

        expect(amountTransferred).to.equal(value);
      }));
    });

    context('Market Resolution', async () => {
      let outcomeId = 1;

      it('should not be able to resolve a Market if not an admin making the call', mochaAsync(async () => {
        try {
          await user1PredictionMarketContract.adminResolveMarketOutcome({
            marketId,
            outcomeId
          });
        } catch(e) {
          // not logging error, as tx is expected to fail
        }

        const market = await predictionMarketContract.getMarketData({ marketId });
        expect(market.state).to.equal(0);
      }));

      it('should be able to resolve a Market', mochaAsync(async () => {
        try {
          const res = await predictionMarketContract.adminResolveMarketOutcome({
            marketId,
            outcomeId
          });
          expect(res.status).to.equal(true);
        } catch(e) {
          console.log(e);
        }

        // doing dummy transaction to get the latest block
        await landTokenContract.approve({ address: '0x000000000000000000000000000000000000dead', amount: 0 });

        const market = await predictionMarketContract.getMarketData({ marketId });
        expect(market.state).to.equal(2);
      }));
    });
  });
});
