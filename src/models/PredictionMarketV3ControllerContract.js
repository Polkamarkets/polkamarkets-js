const IContract = require('./IContract');

const predictionV3Controller = require("../interfaces").predictionV3Controller;

const Numbers = require('../utils/Numbers');

class PredictionMarketV3ControllerContract extends IContract {
  constructor(params) {
    super({ abi: predictionV3Controller, ...params });
    this.contractName = 'PredictionMarketV3Controller';
  }

  async getLandById({ id }) {
    const token = await this.getContract().methods.landTokens(id).call();

    return await this.getLandByAddress({ token });
  }

  async getLandByAddress({ token }) {
    const res = await this.getContract().methods.lands(token).call();
    const landPermissions = await this.getContract().methods.landPermissions(token).call();

    return {
      token: res.token,
      active: res.active,
      realitio: res.realitio,
      everyoneCanCreateMarkets: landPermissions.openMarketCreation
    }
  }

  async getLandTokensLength() {
    const index = await this.getContract().methods.landTokensLength().call();

    return parseInt(index);
  }

  async isAllowedToCreateMarket({ token, user }) {
    return await this.params.contract.getContract().methods.isAllowedToCreateMarket(token, user).call();
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

  async createLand({ name, symbol, tokenAmountToClaim, tokenToAnswer, everyoneCanCreateMarkets }) {
    const transaction = await this.__sendTx(
      this.getContract().methods.createLand(
        name,
        symbol,
        Numbers.toSmartContractDecimals(tokenAmountToClaim, 18),
        tokenToAnswer
      )
    );

    const token = transaction.events.LandCreated[0].returnValues.token;

    // fetching land on index
    const land = await this.getLandByAddress({ token });

    if (everyoneCanCreateMarkets) {
      await this.__sendTx(
        this.getContract().methods.setLandEveryoneCanCreateMarkets(land.token, everyoneCanCreateMarkets)
      );
    }

    return land;
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

module.exports = PredictionMarketV3ControllerContract;
