const ierc20 = require("../interfaces").ierc20;
const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');

class ERC20Contract extends IContract {
  constructor(params, abi) {
    super({...params, abi: params.abi || ierc20});
    this.contractName = 'erc20';
  }

  async __assert() {
    await super.__assert();
    this.params.decimals = await this.getDecimalsAsync();
  }

  async transferTokenAmount({ toAddress, tokenAmount }) {
    let amountWithDecimals = Numbers.toSmartContractDecimals(
      tokenAmount,
      this.getDecimals()
    );
    return await this.__sendTx(
      this.getContract()
        .methods.transfer(toAddress, amountWithDecimals)
    );
  }

  async getTokenAmount(address) {
    return Numbers.fromDecimals(
      await this.getContract().methods.balanceOf(address).call(),
      this.getDecimals()
    );
  }

  async totalSupply() {
    return Numbers.fromDecimals(await this.getContract().methods.totalSupply().call(), this.getDecimals());
  }

  getABI() {
    return this.params.contract;
  }

  getDecimals() {
    return this.params.decimals;
  }

  async getDecimalsAsync() {
    return await this.getContract().methods.decimals().call();
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

  async name() {
    return await this.getContract().methods.name().call();
  }

  async symbol() {
    return await this.getContract().methods.symbol().call();
  }

  async getTokenInfo() {
    return {
      name: await this.name(),
      address: this.getAddress(),
      ticker: await this.symbol(),
      decimals: await this.getDecimalsAsync(),
    };
  }
}

module.exports = ERC20Contract;
