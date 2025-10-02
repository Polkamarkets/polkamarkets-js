// const _ =  require("lodash");

const merkleRewardsDistributor = require("../interfaces").merkleRewardsDistributor;

const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');

class MerkleRewardsDistributorContract extends IContract {
  constructor(params) {
    super({ abi: merkleRewardsDistributor, ...params });
    this.contractName = 'merkleRewardsDistributor';
  }

  // ----- Views -----
  async getRoot({ contestId, tokenAddress }) {
    return await this.params.contract
      .getContract()
      .methods
      .getRoot(contestId, tokenAddress)
      .call();
  }

  async isClaimed({ contestId, tokenAddress, index }) {
    return await this.params.contract
      .getContract()
      .methods
      .isClaimed(contestId, tokenAddress, index)
      .call();
  }

  async isClaimedMany({ contestIds, tokenAddresses, indices }) {
    return await this.params.contract
      .getContract()
      .methods
      .isClaimedMany(contestIds, tokenAddresses, indices)
      .call();
  }

  async isAdmin({ user }) {
    return await this.params.contract
      .getContract()
      .methods
      .isAdmin(user)
      .call();
  }

  // ----- Admin -----
  async publishRoot({ contestId, tokenAddress, root }) {
    return await this.__sendTx(
      this.getContract().methods.publishRoot(contestId, tokenAddress, root)
    );
  }

  async addAdmin({ user }) {
    return await this.__sendTx(
      this.getContract().methods.addAdmin(user)
    );
  }

  async removeAdmin({ user }) {
    return await this.__sendTx(
      this.getContract().methods.removeAdmin(user)
    );
  }

  async withdraw({ tokenAddress, amount }) {
    const amountDecimals = Numbers.toSmartContractDecimals(amount, 18);
    return await this.__sendTx(
      this.getContract().methods.withdraw(tokenAddress, amountDecimals)
    );
  }

  // ----- Claims -----
  async claim({ contestId, tokenAddress, index, account, amount, proof }) {
    const amountDecimals = Numbers.toSmartContractDecimals(amount, 18);
    return await this.__sendTx(
      this.getContract().methods.claim(contestId, tokenAddress, index, account, amountDecimals, proof)
    );
  }

  async claimMany({ entries }) {
    // entries: array of { contestId, tokenAddress, index, account, amount, proof }
    const contestIds = entries.map(e => e.contestId);
    const tokens = entries.map(e => e.tokenAddress);
    const indices = entries.map(e => e.index);
    const accounts = entries.map(e => e.account);
    const amounts = entries.map(e => Numbers.toSmartContractDecimals(e.amount, 18));
    const proofs = entries.map(e => e.proof);

    return await this.__sendTx(
      this.getContract().methods.claimMany(contestIds, tokens, indices, accounts, amounts, proofs)
    );
  }
}

module.exports = MerkleRewardsDistributorContract;
