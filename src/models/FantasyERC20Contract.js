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
    super({ ...params, abi: fantasyerc20 });
    this.contractName = 'fantasyerc20';
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
