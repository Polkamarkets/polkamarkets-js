const PolkamarketsSocialLoginBiconomy = require("../models/PolkamarketsSocialLoginBiconomy");
const PolkamarketsSocialLogin = require("../models/PolkamarketsSocialLogin");

class AccountAbstraction {

  static getSocialLoginClass(type) {
    switch (type) {
      case 'biconomy':
        return PolkamarketsSocialLoginBiconomy;
      default:
        return PolkamarketsSocialLogin;
    }
  }
}

module.exports = AccountAbstraction;
