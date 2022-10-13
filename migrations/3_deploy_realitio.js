const RealitioERC20 = artifacts.require("RealitioERC20");

const {
  TOKEN
} = process.env;

module.exports = async function (deployer) {
  await deployer.deploy(RealitioERC20);
  const realitio = await RealitioERC20.deployed(RealitioERC20);
  await realitio.setToken(TOKEN);
};
