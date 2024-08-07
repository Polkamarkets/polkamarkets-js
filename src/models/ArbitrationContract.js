const arbitration = require("../interfaces").arbitration;
const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');

/**
 * Arbitration Contract Object
 * @constructor ArbitrationContract
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
   * @function getDisputeFee
   * @description get cost of applying for arbitration
   * @param {bytes32} questionId
   * @return {Integer} decimals
   */
  async getDisputeFee({ questionId }) {
    const fee = await this.params.contract.getContract().methods.getDisputeFee(questionId).call();

    return Numbers.fromDecimalsNumber(fee, 18);
  }

  async getArbitrationDisputeId({ questionId }) {
    const allEvents = await this.getEvents('ArbitrationCreated');
    const questionEvents = allEvents.filter(event => event.returnValues._questionID === questionId);

    if (questionEvents.length === 0) return null;

    return Number(questionEvents[0].returnValues._disputeID);
  }

  async getArbitrationRequests({ questionId }) {
    const allEvents = await this.getEvents('ArbitrationRequested');
    const questionEvents = allEvents.filter(event => event.returnValues._questionID === questionId);

    return questionEvents.map(event => ({
      questionId: event.returnValues._questionID,
      requester: event.returnValues._requester,
      maxPrevious: Numbers.fromDecimalsNumber(event.returnValues._maxPrevious, 18)
    }));
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
