const arbitration = require("../interfaces").arbitration;
const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');

const ERC20Contract = require('./ERC20Contract');

/**
 * RealitioERC20 Contract Object
 * @constructor RealitioERC20Contract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class ArbitrationContract extends IContract {
  constructor(params) {
    super({ abi: arbitration, ...params });
    this.contractName = 'arbitration';
  }

  /**
   * @function getTokenDecimals
   * @description Get Token Decimals
   * @return {Integer} decimals
   */
  async getTokenDecimals() {
    try {
      const contractAddress = await this.params.contract.getContract().methods.token().call();
      const erc20Contract = new ERC20Contract({ ...this.params, contractAddress });

      return await erc20Contract.getDecimalsAsync();
    } catch (err) {
      // defaulting to 18 decimals
      return 18;
    }
  }

  /**
   * @function getDisputeFee
   * @description get cost of applying for arbitration
   * @param {bytes32} questionId
   * @return {Integer} decimals
   */
  async getDisputeFee({ questionId }) {
    const fee = await this.params.contract.getContract().methods.getDisputeFee(questionId).call();

    return Numbers.fromDecimalsNumber(fee, 18);
  }

  /**
   * @function requestArbitration
   * @description apply for arbitration
   * @param {bytes32} questionId
   * @param {Integer} maxPrevious
   */
  async requestArbitration({ questionId, bond }) {
    const fee = await this.params.contract.getContract().methods.getDisputeFee(questionId).call();
    const maxPrevious = Numbers.toSmartContractDecimals(bond, 18);

    return await this.__sendTx(
      this.getContract().methods.requestArbitration(questionId, maxPrevious),
      false,
      fee
    );
  }
}

module.exports = ArbitrationContract;
