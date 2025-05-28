import { expect } from "chai";
import chaiAsPromised from "chai-as-promised";
import { ethers } from "ethers";
import { MerkleTree } from "merkletreejs";
import keccak256 from "keccak256";
import { mochaAsync } from "./utils";
import { Application } from "..";
import chai from "chai";
const ReferralRewardAbi = require("../src/interfaces").referralReward.abi;

require("dotenv").config();

chai.use(chaiAsPromised);

context("ReferralReward Contract", async () => {
  let app;
  let accountAddress;
  let otherAccount;
  let referralRewardContract;
  let WETH9Contract;
  let ptsERC20Contract;

  let epoch = 0;
  let amount = "1000000000000000000"; // 1 token in wei
  let index = 0;
  let merkleRoot;
  let merkleProof;

  before(
    mochaAsync(async () => {
      app = new Application({
        web3Provider: process.env.WEB3_PROVIDER,
        web3PrivateKey: process.env.WEB3_PRIVATE_KEY,
      });

      accountAddress = await app.getAddress();
      otherAccount = await app.getOtherAccount();

      console.log("accountAddress", accountAddress);
      console.log("otherAccount", otherAccount);

      WETH9Contract = app.getWETH9Contract({});
      await WETH9Contract.deploy({});
      const tokenAddress = WETH9Contract.getAddress();
      console.log("tokenAddress", tokenAddress);

      ptsERC20Contract = app.getERC20Contract({});
      const erc20Address = ptsERC20Contract.getAddress();
      console.log("erc20Address", erc20Address);

      referralRewardContract = app.getReferralRewardContract({
        tokenAddress: tokenAddress,
      });
      await referralRewardContract.deploy({
        params: [tokenAddress],
      });

      const referralRewardAddress = referralRewardContract.getAddress();

      console.log("referral reward address", referralRewardAddress);

      const leaf = ethers.utils.solidityKeccak256(
        ["uint256", "address", "uint256"],
        [index, accountAddress, amount]
      );
      const leafBuffer = Buffer.from(leaf.slice(2), "hex");

      const dummyLeaf = ethers.utils.solidityKeccak256(
        ["uint256", "address", "uint256"],
        [1, accountAddress, amount]
      );
      const dummyLeafBuffer = Buffer.from(dummyLeaf.slice(2), "hex");

      const leaves = [leafBuffer, dummyLeafBuffer];
      const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });

      merkleRoot = tree.getHexRoot();
      merkleProof = tree.getHexProof(leafBuffer);

      const res = await referralRewardContract.updateMerkleRoot({
        epoch,
        merkleRoot,
      });
      expect(res.status).to.equal(true);

      // ptsERC20Contract.mint({
      //   address: referralRewardAddress,
      //   amount: "1000",
      // });

      // log the balance of the contract
      // const balance = await ptsERC20Contract.balanceOf({
      //   address: referralRewardAddress,
      // });
      // console.log("balance of erc20 in contract:", balance);
    })
  );

  it(
    "should fail if non-owner tries to update Merkle Root",
    mochaAsync(async () => {
      const web3 = app.web3;
      const contractAddress = referralRewardContract.getAddress();
      const contractForOtherAccount = new web3.eth.Contract(
        ReferralRewardAbi,
        contractAddress,
        {
          from: otherAccount,
        }
      );

      await expect(
        contractForOtherAccount.methods
          .updateMerkleRoot(epoch + 1, merkleRoot)
          .send({ from: otherAccount, gas: 500000 })
      ).to.be.rejectedWith(/revert/);
    })
  );

  it(
    "should fail to update Merkle Root twice for the same epoch",
    mochaAsync(async () => {
      await expect(
        referralRewardContract.updateMerkleRoot({
          epoch,
          merkleRoot,
        })
      ).to.be.rejectedWith(/revert/);
    })
  );

  it(
    "should check isClaimed before claiming (expect false)",
    mochaAsync(async () => {
      const claimed = await referralRewardContract.isClaimed({
        epoch,
        index,
      });
      expect(claimed).to.equal(false);
    })
  );

  it(
    "should fail if another account tries to claim for someone else",
    mochaAsync(async () => {
      const unauthorizedContract = app.getReferralRewardContract({
        from: otherAccount,
      });
      await expect(
        unauthorizedContract.claim({
          epoch,
          index,
          account: accountAddress,
          amount,
          merkleProof,
        })
      ).to.be.rejectedWith(/revert/);
    })
  );

  it(
    "should fail with invalid Merkle proof",
    mochaAsync(async () => {
      const invalidProof = [
        "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
      ];
      await expect(
        referralRewardContract.claim({
          epoch,
          index,
          account: accountAddress,
          amount,
          merkleProof: invalidProof,
        })
      ).to.be.rejectedWith(/revert/);
    })
  );

  it(
    "should claim reward successfully",
    mochaAsync(async () => {
      const res = await referralRewardContract.claim({
        epoch,
        index,
        account: accountAddress,
        amount,
        merkleProof,
      });
      expect(res.status).to.equal(true);
    })
  );

  it(
    "should fail if claiming twice (already claimed)",
    mochaAsync(async () => {
      await expect(
        referralRewardContract.claim({
          epoch,
          index,
          account: accountAddress,
          amount,
          merkleProof,
        })
      ).to.be.rejectedWith(/revert/);
    })
  );

  it(
    "should check isClaimed after claiming (expect true)",
    mochaAsync(async () => {
      const claimed = await referralRewardContract.isClaimed({
        epoch,
        index,
      });
      expect(claimed).to.equal(true);
    })
  );
});
