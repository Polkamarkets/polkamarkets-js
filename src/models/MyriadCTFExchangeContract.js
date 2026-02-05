const IContract = require("./IContract");

const myriadCTFExchange = require("../interfaces").myriadCTFExchange;

class MyriadCTFExchangeContract extends IContract {
  constructor(params) {
    super({ abi: myriadCTFExchange, ...params });
    this.contractName = "MyriadCTFExchange";
  }

  async cancelOrders({ orders }) {
    return await this.__sendTx(this.getContract().methods.cancelOrders(orders));
  }

  async hashOrder({ order }) {
    return await this.getContract().methods.hashOrder(order).call();
  }
}

module.exports = MyriadCTFExchangeContract;
