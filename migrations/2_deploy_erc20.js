const PredictionMarket = artifacts.require("PredictionMarket");
const ERC20PresetMinterPauser = artifacts.require("ERC20PresetMinterPauser");
const ERC20_USER = process.env.ERC20_USER;

module.exports = async function(deployer, network, accounts) {
  // NOTE: USE THIS ONLY FOR DEV PURPOSES!!
  await deployer.deploy(ERC20PresetMinterPauser, "Test Token", "TEST");
  const token = await ERC20PresetMinterPauser.deployed();
  await token.mint(ERC20_USER, '100000000000000000000000000');
}
