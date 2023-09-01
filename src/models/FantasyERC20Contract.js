const fantasyerc20 = require("../interfaces").fantasyerc20;
const ERC20Contract = require("./ERC20Contract");

const Numbers = require("../utils/Numbers");

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
    this.contractName = 'erc20';
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

  /**
   * @function tokenAmountToClaim
   * @description Returns the amount of tokens to claim
   * @returns {Integer} tokenAmountToClaim
   *
   */
  async tokenAmountToClaim() {
    const tokenAmountToClaim = Numbers.fromDecimalsNumber(
      await this.params.contract
        .getContract()
        .methods
        .tokenAmountToClaim()
        .call(),
      this.getDecimals()
    );

    return tokenAmountToClaim;
  }

  /* POST User Functions */

  /**
   * @function claimTokens
   * @description Claim tokens for sender
   */
  async claimTokens() {
    return await this.__sendTx(
      this.getContract().methods.claimTokens()
    );
  };

  /**
   * @function claimAndApproveTokens
   * @description Claim and approve tokens for sender
   */
  async claimAndApproveTokens() {
    return await this.__sendTx(
      this.getContract().methods.claimAndApproveTokens()
    );
  };

  /**
   * @function resetBalance
   * @description Reset user's balance to tokenAmountToClaim
   */
  async resetBalance() {
    const address = await this.getMyAccount();
    if (!address) return false;

    const tokenAmountToClaim = await this.tokenAmountToClaim();
    const balance = await this.getTokenAmount(address);

    const amountToBurn = balance - tokenAmountToClaim > 0 ? balance - tokenAmountToClaim : 0;

    return await this.burn({ amount: amountToBurn });
  };
}

module.exports = FantasyERC20Contract;
