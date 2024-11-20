
const simpleAccount = require("../interfaces").simpleAccount;

/**
 * Simple Acount Contract Object
 * @constructor Simple Acount
 * @param {Web3} web3
 * @param {Address} token
 */

class SimpleAccountContract extends IContract {
  constructor(params) {
    super({ abi: simpleAccount, ...params });
    this.contractName = 'simpleAccount';
  }

  /* Get Functions */
  /**
   * @function getOwner
   * @description Returns the owner of the contract
   * @returns {Address} owner
   */
  async getOwner() {
    return await this.params.contract
      .getContract()
      .methods
      .owner()
      .call();
  }
}

module.exports = SimpleAccountContract;
