const IContract = require('./IContract');

const predictionV3Manager = require("../interfaces").predictionV3Manager;

const Numbers = require('../utils/Numbers');

class PredictionMarketV3ManagerContract extends IContract {
  constructor(params) {
    super({ abi: predictionV3Manager, ...params });
    this.contractName = 'PredictionMarketV3Manager';
  }

  async getLandById({ id }) {
    const token = await this.getContract().methods.landTokens(id).call();

    return await this.getLandByAddress({ token });
  }

  async getLandByAddress({ token }) {
    const res = await this.getContract().methods.lands(token).call();

    return {
      token: res.token,
      active: res.active,
      lockAmount: Numbers.fromDecimalsNumber(res.lockAmount, 18),
      lockUser: res.lockUser,
      realitio: res.realitio,
    }
  }

  async getLandTokensLength() {
    const index = await this.getContract().methods.landTokensLength().call();

    return parseInt(index);
  }

  async isAllowedToCreateMarket({ token, user }) {
    return await this.params.contract.getContract().methods.isAllowedToCreateMarket(token, user).call();
  }

  async isAllowedToResolveMarket({ token, user }) {
    return await this.params.contract.getContract().methods.isAllowedToResolveMarket(token, user).call();
  }

  async isAllowedToEditMarket({ token, user }) {
    return await this.params.contract.getContract().methods.isAllowedToEditMarket(token, user).call();
  }

  async isIERC20TokenSocial({ token }) {
    return await this.params.contract.getContract().methods.isIERC20TokenSocial(token, user).call();
  }

  async isLandAdmin({ token, user }) {
    return await this.params.contract.getContract().methods.isLandAdmin(token, user).call();
  }

  async lockAmount() {
    const amount = await this.params.contract.getContract().methods.lockAmount().call();
    // TODO: fetch ERC20 decimals
    return Numbers.fromDecimalsNumber(amount, 18);
  }

  async lockToken() {
    return await this.params.contract.getContract().methods.token().call();
  }

  async updateLockAmount({ amount }) {
    return await this.__sendTx(
      this.getContract().methods.updateLockAmount(Numbers.toSmartContractDecimals(amount, 18))
    );
  }

  async createLand({ name, symbol, tokenAmountToClaim, tokenToAnswer }) {
    return await this.__sendTx(
      this.getContract().methods.createLand(
        name,
        symbol,
        Numbers.toSmartContractDecimals(tokenAmountToClaim, 18),
        tokenToAnswer
      )
    );
  };

  async disableLand({ token }) {
    return await this.__sendTx(
      this.getContract().methods.disableLand(token)
    );
  }

  async enableLand({ token }) {
    return await this.__sendTx(
      this.getContract().methods.enableLand(token)
    );
  }

  async unlockOffsetFromLand({ token }) {
    return await this.__sendTx(
      this.getContract().methods.unlockOffsetFromLand(token)
    );
  }

  async addAdminToLand({ token, user }) {
    return await this.__sendTx(
      this.getContract().methods.addAdminToLand(token, user)
    );
  }

  async removeAdminFromLand({ token, user }) {
    return await this.__sendTx(
      this.getContract().methods.removeAdminFromLand(token, user)
    );
  }
}

module.exports = PredictionMarketV3ManagerContract;
