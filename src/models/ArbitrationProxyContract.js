const arbitrationProxy = require("../interfaces").arbitrationProxy;
const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');

/**
 * ArbitrationProxy Contract Object
 * @constructor ArbitrationProxyContract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class ArbitrationProxyContract extends IContract {
  constructor(params) {
    super({ abi: arbitrationProxy, ...params });
    this.contractName = 'arbitrationProxy';
  }

  async getArbitrationRequestsRejected({ questionId }) {
    const allEvents = await this.getEvents('RequestRejected');
    const questionEvents = allEvents.filter(event => event.returnValues._questionID === questionId);

    return questionEvents.map(event => ({
      questionId: event.returnValues._questionID,
      requester: event.returnValues._requester,
      maxPrevious: Numbers.fromDecimalsNumber(event.returnValues._maxPrevious, 18),
      reason: event.returnValues._reason
    }));
  }
}

module.exports = ArbitrationProxyContract;
