require('dotenv').config();


import { expect } from 'chai';

import { mochaAsync } from './utils';
import { Application } from '..';

const USER_ADDRESS = process.env.TEST_USER1_ADDRESS;
const USER_PRIVATE_KEY = process.env.TEST_USER1_PRIVATE_KEY;

context('Merkle Distributor Contract', async () => {

  let app;
  let merkleDistributorContract;
  let merkleDistributorContractAddress;
  let ERC20Contract;

  context('Contract Deployment', async () => {
    it('should start the Application', mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: USER_PRIVATE_KEY,
      });

      expect(app).to.not.equal(null);
    }));

    it('should deploy Merkle Distributor Contract', mochaAsync(async () => {
      // Create Contract
      merkleDistributorContract = app.getMerkleDistributorContract({});
      ERC20Contract = app.getERC20Contract({});

      // Deploy
      await ERC20Contract.deploy({ params: ['Polkamarkets', 'POLK'] });

      const ERC20ContractAddress = ERC20Contract.getAddress();

      await merkleDistributorContract.deploy({
        params: [
          ERC20ContractAddress,
          USER_ADDRESS,
          '0x05e857ad2627320294fdc1904372ccfbdae1f892dbfc6f3292d7647001d2306b',
        ]
      });

      merkleDistributorContractAddress = merkleDistributorContract.getAddress();

      expect(merkleDistributorContractAddress).to.not.equal(null);


      // minting for user
      await ERC20Contract.getContract().methods.mint(USER_ADDRESS, '100000000000000000000000000').send({ from: USER_ADDRESS });

      // transfer tokens to merkle distributor contract
      await ERC20Contract.getContract().methods.transfer(merkleDistributorContractAddress, '10000000000000000000000000').send({ from: USER_ADDRESS });


      expect(await ERC20Contract.balanceOf({ address: merkleDistributorContractAddress })).to.equal(10000000);
      expect(await ERC20Contract.balanceOf({ address: USER_ADDRESS })).to.equal(90000000);

    }));
  });

  context('Claim tokens', async () => {
    it('should claim an amount for an address on the merkle tree', mochaAsync(async () => {
      const addressToClaim = '0x6122252DC9BE4DBF4DF78C22E5348A12B1C77D61';

      expect(await ERC20Contract.balanceOf({ address: merkleDistributorContractAddress })).to.equal(10000000);
      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(0);

      expect(await merkleDistributorContract.isClaimed({index: 1})).to.equal(false);

      await merkleDistributorContract.claim(
        {
          index: 1,
          account: addressToClaim,
          amount: 5000,
          merkleProof: [
            '0x8ffa2c85501a8c34ac1e84f1ffbdcdba19f4967fa414cd8b4cd13b1598ff50d5',
            '0xcf793acd9b963171c2d69ac885b9fe144adf456f00936a23153df253d3620325'
          ],
        },
      );

      expect(await merkleDistributorContract.isClaimed({ index: 1 })).to.equal(true);
      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(5000);
      expect(await ERC20Contract.balanceOf({ address: merkleDistributorContractAddress })).to.equal(10000000-5000);
    }));

    it('should not allow to claim again after claimed', mochaAsync(async () => {
      const addressToClaim = '0x6122252DC9BE4DBF4DF78C22E5348A12B1C77D61';

      expect(await merkleDistributorContract.isClaimed({ index: 1 })).to.equal(true);
      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(5000);
      expect(await ERC20Contract.balanceOf({ address: merkleDistributorContractAddress })).to.equal(10000000 - 5000);

      let result;
      try {
        result = await merkleDistributorContract.claim(
          {
            index: 1,
            account: addressToClaim,
            amount: 5000,
            merkleProof: [
              '0x8ffa2c85501a8c34ac1e84f1ffbdcdba19f4967fa414cd8b4cd13b1598ff50d5',
              '0xcf793acd9b963171c2d69ac885b9fe144adf456f00936a23153df253d3620325'
            ],
          },
        );
      } catch (err) {
        result = err.reason;
      }

      expect(result).to.equal('MerkleDistributor: already claimed.');

      expect(await merkleDistributorContract.isClaimed({ index: 1 })).to.equal(true);
      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(5000);
      expect(await ERC20Contract.balanceOf({ address: merkleDistributorContractAddress })).to.equal(10000000 - 5000);

    }));

    it('should freeze and not allow to claim', mochaAsync(async () => {
      expect(await merkleDistributorContract.isClaimed({ index: 2 })).to.equal(false);

      await merkleDistributorContract.freeze();


      let result;
      try {
        result = await merkleDistributorContract.claim(
          {
            index: 2,
            account: '0xEF4D8DC13FDEB0F2B4784B1DAE743093C228A08A',
            amount: 5000,
            merkleProof: [
              '0x10b51283d1db97a125b2c4cf0a2b8a7475e5001ff53cf98871ab174cdc26baea',
              '0xcf793acd9b963171c2d69ac885b9fe144adf456f00936a23153df253d3620325'
            ],
          },
        );
      } catch (err) {
        result = err.reason;
      }

      expect(result).to.equal('MerkleDistributor: Claiming is frozen.');

      expect(await merkleDistributorContract.isClaimed({ index: 2 })).to.equal(false);
    }));

    it('should update the merkle root the contract', mochaAsync(async () => {
      expect(await merkleDistributorContract.isClaimed({ index: 1 })).to.equal(true);

      await merkleDistributorContract.updateMerkleRoot({ merkleRoot: '0x6061a4828c0ebd7d2404f4d2c17b37fa609a3bcf8460fb8d9ae461b03993f1b1' });

      expect(await merkleDistributorContract.isClaimed({ index: 1 })).to.equal(false);

    }));

    it('should unfreeze the merkle root of the contract and allow to claim', mochaAsync(async () => {
      const addressToClaim = '0x6122252DC9BE4DBF4DF78C22E5348A12B1C77D61';

      expect(await merkleDistributorContract.isClaimed({ index: 0 })).to.equal(false);
      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(5000);

      await merkleDistributorContract.unfreeze();

      expect(await merkleDistributorContract.isClaimed({ index: 0 })).to.equal(false);

      await merkleDistributorContract.claim(
        {
          index: 0,
          account: addressToClaim,
          amount: 3000,
          merkleProof: [
            '0xf0e76d51c54cd0c82bc2176b6bc7775b73a70c37e89814d3173b1b9193d80175'
          ],
        },
      );

      expect(await merkleDistributorContract.isClaimed({ index: 0 })).to.equal(true);

      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(5000+3000);

    }));

    it('should not allow to claim an invalid amount', mochaAsync(async () => {
      const addressToClaim = '0xEF4D8DC13FDEB0F2B4784B1DAE743093C228A08A';

      expect(await merkleDistributorContract.isClaimed({ index: 1 })).to.equal(false);
      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(0);

      let result;
      try {
        result = await merkleDistributorContract.claim(
          {
            index: 1,
            account: addressToClaim,
            amount: 10000, // invalid amount
            merkleProof: [
              '0x9989c6b890dfe76fc7e1ff4e8b24e6cd392df6086ce6e7b86c68fb19a3fa53e0',
            ],
          },
        );
      } catch (err) {
        result = err.reason;
      }

      expect(result).to.equal('MerkleDistributor: Invalid proof.');

      expect(await merkleDistributorContract.isClaimed({ index: 1 })).to.equal(false);
      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(0);

      // claim with valid amount
      await merkleDistributorContract.claim(
        {
          index: 1,
          account: addressToClaim,
          amount: 5000,
          merkleProof: [
            '0x9989c6b890dfe76fc7e1ff4e8b24e6cd392df6086ce6e7b86c68fb19a3fa53e0',
          ],
        },
      );

      expect(await merkleDistributorContract.isClaimed({ index: 1 })).to.equal(true);
      expect(await ERC20Contract.balanceOf({ address: addressToClaim })).to.equal(5000);

    }));
  });
});
