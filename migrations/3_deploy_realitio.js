const RealityETH_ERC20_v3_0 = artifacts.require("RealityETH_ERC20_v3_0");

const {
  TOKEN
} = process.env;

module.exports = async function (deployer) {
  await deployer.deploy(RealityETH_ERC20_v3_0);
  const realitio = await RealityETH_ERC20_v3_0.deployed(RealityETH_ERC20_v3_0);
  await realitio.setToken(TOKEN);
};
