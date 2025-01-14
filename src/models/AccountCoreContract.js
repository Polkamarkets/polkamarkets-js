
const accountCore = require("../interfaces").accountCore;

const IContract = require('./IContract');

/**
 * Acount Core Contract Object
 * @constructor Acount COre
 * @param {Web3} web3
 * @param {Address} token
 */

class AccountCoreContract extends IContract {
  constructor(params) {
    super({ abi: accountCore, ...params });
    this.contractName = 'accountCore';
  }

  /* Get Functions */
  /**
   * @function getAllAdmins
   * @description Returns the address of all admins
   * @returns {Address[]} admins
   */
  async getAllAdmins() {
    return await this.params.contract
      .getContract()
      .methods
      .getAllAdmins()
      .call();
  }
}

module.exports = AccountCoreContract;
