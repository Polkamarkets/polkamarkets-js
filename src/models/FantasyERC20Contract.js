const fantasyerc20 = require("../interfaces").fantasyerc20;
const ERC20Contract = require("./ERC20Contract");


/**
 * Fantasy ERC20 Contract Object
 * @constructor FantasyERC20Contract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class FantasyERC20Contract extends ERC20Contract {
  constructor(params) {
    super({ abi: fantasyerc20, ...params });
    this.contractName = 'fantasyerc20';
  }

  /* Get Functions */
  /**
   * @function hasUserClaimedTokens
   * @description Returns if the user has already claimed the tokens
   * @returns {Boolean} claimedTokens
   */
  async hasUserClaimedTokens({ address }) {
    return await this.params.contract
      .getContract()
      .methods
      .hasUserClaimedTokens(address)
      .call();
  }

  /* POST User Functions */

  /**
   * @function claimTokens
   * @description Claim tokens for address
   * @param {Address} address
   */
  async claimTokens({ address }) {
    return await this.__sendTx(
      this.getContract().methods.claimTokens(address)
    );
  };
}

module.exports = FantasyERC20Contract;
