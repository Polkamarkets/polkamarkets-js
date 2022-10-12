const PredictionMarket = artifacts.require("PredictionMarket");
const ERC20PresetMinterPauser = artifacts.require("ERC20PresetMinterPauser");
const USER = process.env.USER;

module.exports = async function(deployer, network, accounts) {
  // NOTE: USE THIS ONLY FOR DEV PURPOSES!!
  await deployer.deploy(ERC20PresetMinterPauser, "Polkamarkets", "POLK");
  const token = await ERC20PresetMinterPauser.deployed();
  await token.mint(USER, '100000000000000000000000000');
}
