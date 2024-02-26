const PolkamarketsSocialLoginPnPBiconomy = require("../models/PolkamarketsSocialLoginPnPBiconomy");
const PolkamarketsSocialLoginPnPParticle = require("../models/PolkamarketsSocialLoginPnPParticle");
const PolkamarketsSocialLogin = require("../models/PolkamarketsSocialLogin");

class AccountAbstraction {

  static getSocialLoginClass(type) {
    switch (type) {
      case 'PnPBiconomy':
        return PolkamarketsSocialLoginPnPBiconomy;
      case 'PnPParticle':
        return PolkamarketsSocialLoginPnPParticle;
      default:
        return PolkamarketsSocialLogin;
    }
  }
}

module.exports = AccountAbstraction;
