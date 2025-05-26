import { expect } from "chai";
import { mochaAsync } from "./utils";
import { Application } from "..";

context("ReferralReward Contract", async () => {
  require("dotenv").config();

  let app;
  let accountAddress;
  let referralRewardContract;

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

        const referralRewardContractAddress =
          referralRewardContract.getAddress();
        expect(referralRewardContractAddress).to.not.equal(null);
      })
    );
  });

  context("Merkle Root & Claim Logic", async () => {
    let epoch = 0;
    let merkleRoot =
      "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"; // dummy root
    let index = 1;
    let amount = "1000000000000000000"; // 1 token in wei
    let merkleProof = [
      "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
    ];

    it(
      "should update Merkle Root",
      mochaAsync(async () => {
        const res = await referralRewardContract.updateMerkleRoot({
          epoch,
          merkleRoot,
        });
        expect(res.status).to.equal(true);

        // fetch Merkle root on-chain to confirm
        const root = await referralRewardContract
          .getContract()
          .methods.merkleRoots(epoch)
          .call();
        expect(root).to.equal(merkleRoot);
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
      "should claim reward",
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
