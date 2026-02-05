const IContract = require("./IContract");

const adminRegistry = require("../interfaces").adminRegistry;

class AdminRegistryContract extends IContract {
  constructor(params) {
    super({ abi: adminRegistry, ...params });
    this.contractName = "AdminRegistry";
  }

  async grantRole({ role, account }) {
    return await this.__sendTx(this.getContract().methods.grantRole(role, account));
  }

  async revokeRole({ role, account }) {
    return await this.__sendTx(this.getContract().methods.revokeRole(role, account));
  }

  async hasRole({ role, account }) {
    return await this.getContract().methods.hasRole(role, account).call();
  }

  async getRoleAdmin({ role }) {
    return await this.getContract().methods.getRoleAdmin(role).call();
  }
}

module.exports = AdminRegistryContract;
