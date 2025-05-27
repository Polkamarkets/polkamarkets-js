import { expect } from "chai";
import { mochaAsync } from "./utils";
import { Application } from "..";

context("ReferralReward Contract", async () => {
  require("dotenv").config();

  let app;
  let accountAddress;
  let otherAccount;
  let referralRewardContract;

  // Test data
  let epoch = 0;
  let merkleRoot =
    "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"; // dummy root
  let index = 1;
  let amount = "1000000000000000000"; // 1 token in wei
  let merkleProof = [
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
  ];

  context("Contract Deployment", async () => {
    it(
      "should start the Application",
      mochaAsync(async () => {
        app = new Application({
          web3Provider: process.env.WEB3_PROVIDER,
          web3PrivateKey: process.env.WEB3_PRIVATE_KEY,
        });
        expect(app).to.not.equal(null);
      })
    );

    it(
      "should deploy ReferralReward Contract",
      mochaAsync(async () => {
        accountAddress = await app.getAddress();
        referralRewardContract = app.getReferralRewardContract({});
        await referralRewardContract.deploy({});
        const contractAddress = referralRewardContract.getAddress();
        expect(contractAddress).to.not.equal(null);

        // get another account for unauthorized testing
        otherAccount = await app.getOtherAccount();
      })
    );
  });

  context("Merkle Root & Claim Logic", async () => {
    it(
      "should update Merkle Root by owner",
      mochaAsync(async () => {
        const res = await referralRewardContract.updateMerkleRoot({
          epoch,
          merkleRoot,
        });
        expect(res.status).to.equal(true);

        // verify updated root
        const root = await referralRewardContract
          .getContract()
          .methods.merkleRoots(epoch)
          .call();
        expect(root).to.equal(merkleRoot);
      })
    );

    it(
      "should fail if non-owner tries to update Merkle Root",
      mochaAsync(async () => {
        const unauthorizedContract = app.getReferralRewardContract({
          from: otherAccount,
        });

        await expect(
          unauthorizedContract.updateMerkleRoot({
            epoch: epoch + 1,
            merkleRoot:
              "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
          })
        ).to.be.rejectedWith(/Ownable: caller is not the owner/);
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
        ).to.be.rejectedWith(/Merkle root already set/);
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
        const unauthorizedClaimContract = app.getReferralRewardContract({
          from: otherAccount,
        });

        await expect(
          unauthorizedClaimContract.claim({
            epoch,
            index,
            account: accountAddress,
            amount,
            merkleProof,
          })
        ).to.be.rejectedWith(/Not authorized to claim/);
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
        ).to.be.rejectedWith(/Invalid proof/);
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
      "should fail if already claimed",
      mochaAsync(async () => {
        await expect(
          referralRewardContract.claim({
            epoch,
            index,
            account: accountAddress,
            amount,
            merkleProof,
          })
        ).to.be.rejectedWith(/Already claimed/);
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
});
