const IContract = require('./IContract');

const multicall3 = require('../interfaces').multicall3;

class Multicall3Contract extends IContract {
  constructor(params) {
    super({ abi: multicall3, ...params });
    // used by bepro-api routing (contract name in /call?contract=...)
    this.contractName = 'multicall3';
  }
}

module.exports = Multicall3Contract;

