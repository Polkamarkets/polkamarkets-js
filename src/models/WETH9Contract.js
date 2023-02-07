const weth = require("../interfaces").weth;
const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');

class WETH9Contract extends IContract {
  constructor(params) {
    super({ abi: weth, ...params });
    this.contractName = 'weth';
  }

  getDecimals() {
    return 18;
  }

  async totalSupply() {
    return Numbers.fromDecimals(await this.getContract().methods.totalSupply().call(), this.getDecimals());
  }

  async balanceOf({ address }) {
    return Numbers.fromDecimalsNumber(await this.getContract().methods.balanceOf(address).call(), this.getDecimals());
  }

  async isApproved({ address, amount, spenderAddress }) {
    try {
      let approvedAmount = Numbers.fromDecimals(
        await this.getContract().methods.allowance(address, spenderAddress).call(),
        this.getDecimals()
      );
      return (approvedAmount >= amount);
    } catch (err) {
      throw err;
    }
  }

  async approve({ address, amount, callback }) {
    try {
      let amountWithDecimals = Numbers.toSmartContractDecimals(
        amount,
        this.getDecimals()
      );
      let res = await this.__sendTx(
        this.getContract()
          .methods.approve(address, amountWithDecimals),
        null,
        null,
        callback
      );
      return res;
    } catch (err) {
      throw err;
    }
  }

  async deposit({ amount, callback }) {
    try {
      let amountWithDecimals = Numbers.toSmartContractDecimals(
        amount,
        this.getDecimals()
      );
      let res = await this.__sendTx(
        this.getContract().methods.deposit(),
        false,
        amountWithDecimals,
        callback
      );
      return res;
    } catch (err) {
      throw err;
    }
  }

  async withdraw({ amount, callback }) {
    try {
      let amountWithDecimals = Numbers.toSmartContractDecimals(
        amount,
        this.getDecimals()
      );
      let res = await this.__sendTx(
        this.getContract()
          .methods.withdraw(amountWithDecimals),
        null,
        null,
        callback
      );
      return res;
    } catch (err) {
      throw err;
    }
  }
}

module.exports = WETH9Contract;
