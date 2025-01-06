// const _ =  require("lodash");
// const moment = require("moment");

const rewardsDistributor = require("../interfaces").rewardsDistributor;

const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');


/**
 * Rewards Distributor Contract Object
 * @constructor RewardsDistributor
 * @param {Web3} web3
 * @param {Address} token
 */

class RewardsDistributorContract extends IContract {
  constructor(params) {
    super({ abi: rewardsDistributor, ...params });
    this.contractName = 'rewardsDistributor';
  }

  /* Get Functions */
  /**
   * @function getNonceForUser
   * @description Returns the next nonce for the user
   * @param {Address} user
   * @returns {Integer} nonce
   */
  async getNonceForUser({user}) {
    return await this.params.contract
      .getContract()
      .methods
      .nonces(user)
      .call();
  }

  /**
   * @function getAmountToClaim
   * @description Get amount left to claim for the user
   * @param {Address} user
   * @param {Address} tokenAddress
   * @returns {Integer} amountLeftToClaim
   */
  async getAmountToClaim({ user, tokenAddress }) {
    const amountLeftToClaim = await this.params.contract
      .getContract()
      .methods
      .amountToClaim(user, tokenAddress)
      .call();

    return Numbers.fromDecimalsNumber(amountLeftToClaim, 18)
  }

  async getClaimAmounts({ user, tokenAddress }) {
    const claimAmounts = await this.params.contract
      .getContract()
      .methods
      .claimAmounts(user, tokenAddress)
      .call();

    return {
      claimed: Numbers.fromDecimalsNumber(claimAmounts[0], 18),
      total: Numbers.fromDecimalsNumber(claimAmounts[1], 18),
      toClaim: Numbers.fromDecimalsNumber(claimAmounts[1], 18) - Numbers.fromDecimalsNumber(claimAmounts[0], 18)
    };
  }

  /**
   * @function isAdmin
   * @description Check if user is admin
   * @param {Address} user
   * @returns {Boolean} isAdmin
   */
  async isAdmin({ user }) {
    return await this.params.contract
      .getContract()
      .methods
      .isAdmin(user)
      .call();
  }

  /**
   * @function isAlias
   * @description Check if user is an alias
   * @param {Address} user
   * @returns {Boolean} isAlias
   */
  async isAlias({ owner, target }) {
    return await this.params.contract
      .getContract()
      .methods
      .isAlias(owner, target)
      .call();
  }

  /* POST Functions */

  /**
   * @function increaseUserClaimAmount
   * @description Increase User amount to claim
   * @param {Address} user
   * @param {Address} tokenAddress
   * @param {Integer} amount
   */
  async increaseUserClaimAmount({ user, amount, tokenAddress }) {
    const amountDecimals = Numbers.toSmartContractDecimals(amount, 18);

    return await this.__sendTx(
      this.getContract().methods.increaseUserClaimAmount(user, amountDecimals, tokenAddress)
    );
  };

  /**
   * @function claimWithoutSignature
   * @description Claim user amount
   * @param {Address} user
   * @param {Address} receiver
   * @param {Integer} amount
   * @param {Address} tokenAddress
   * @param {Integer} nonce
   * @param {String} signature
   */
  async claimWithoutSignature({ user, receiver, amount, tokenAddress }) {
    const amountDecimals = Numbers.toSmartContractDecimals(amount, 18);

    return await this.__sendTx(
      this.getContract().methods.claim(user, receiver, amountDecimals, tokenAddress)
    );
  }

  /**
   * @function claim
   * @description Claim user amount
   * @param {Address} user
   * @param {Address} receiver
   * @param {Integer} amount
   * @param {Address} tokenAddress
   * @param {Integer} nonce
   * @param {String} signature
   */
  async claim({ user, receiver, amount, tokenAddress, nonce, signature }) {
    const amountDecimals = Numbers.toSmartContractDecimals(amount, 18);

    return await this.__sendTx(
      this.getContract().methods.claim(user, receiver, amountDecimals, tokenAddress, nonce, signature)
    );
  }

  /**
   * @function signMessageToClaim
   * @description Sign the message to claim the amount
   * @param {Address} user
   * @param {Address} receiver
   * @param {Integer} amount
   * @param {Address} tokenAddress
   */
  async signMessageToClaim({ user, receiver, amount, tokenAddress }) {
    const nonce = await this.getNonceForUser({ user });

    const amountDecimals = Numbers.toSmartContractDecimals(amount, 18);

    const hash = await this.soliditySha3([user, receiver, amountDecimals, tokenAddress, nonce]);

    const signature = await this.signMessage(hash);

    return {signature, nonce};
  }

  /**
   * @function addAdmin
   * @description Add an admin to the contract
   * @param {Address} user
   */
  async addAdmin({ user }) {
    return await this.__sendTx(
      this.getContract().methods.addAdmin(user)
    );
  }

  /**
   * @function removeAdmin
   * @description Remove an admin from the contract
   * @param {Address} user
   */
  async removeAdmin({ user }) {
    return await this.__sendTx(
      this.getContract().methods.removeAdmin(user)
    );
  }

  /**
   * @function addAlias
   * @description Add an alias to a user
   * @param {Address} user
   */
  async addAlias({ owner, target }) {
    if (!owner) {
      return await this.__sendTx(
        this.getContract().methods.addAlias(target)
      );
    }
    return await this.__sendTx(
      this.getContract().methods.addAlias(owner, target)
    );
  }

  /**
   * @function removeAlias
   * @description Remove an alias from a user
   * @param {Address} user
   */
  async removeAlias({ owner, target }) {
    if (!owner) {
      return await this.__sendTx(
        this.getContract().methods.removeAlias(target)
      );
    }
    return await this.__sendTx(
      this.getContract().methods.removeAlias(owner, target)
    );
  }

  /**
   * @function withdrawTokens
   * @description Withdraw tokens from the contract
   * @param {Address} token
   * @param {Integer} amount
   */
  async withdrawTokens({ tokenAddress, amount }) {
    const amountDecimals = Numbers.toSmartContractDecimals(amount, 18);

    return await this.__sendTx(
      this.getContract().methods.withdrawTokens(tokenAddress, amountDecimals)
    );
  }
}

module.exports = RewardsDistributorContract;
