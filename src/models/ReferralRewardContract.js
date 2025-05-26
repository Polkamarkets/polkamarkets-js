const referralReward = require("./interfaces").referralReward;
const IContract = require("./IContract");

class ReferralRewardContract extends IContract {
  constructor(params) {
    super({
      abi: require("../interfaces").referralReward,
      ...params,
    });
  }

  async isClaimed({ epoch, index }) {
    return await this.getContract().methods.isClaimed(epoch, index).call();
  }

  async claim({ epoch, index, account, amount, merkleProof }) {
    return await this.__sendTx(
      this.getContract().methods.claim(
        epoch,
        index,
        account,
        amount,
        merkleProof
      )
    );
  }

  async updateMerkleRoot({ epoch, merkleRoot }) {
    return await this.__sendTx(
      this.getContract().methods.updateMerkleRoot(epoch, merkleRoot)
    );
  }
}

module.exports = ReferralRewardContract;
