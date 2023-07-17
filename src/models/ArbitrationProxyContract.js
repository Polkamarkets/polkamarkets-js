const arbitrationProxy = require("../interfaces").arbitrationProxy;
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
}

module.exports = ArbitrationProxyContract;
