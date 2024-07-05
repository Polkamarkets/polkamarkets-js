const PredictionMarketV3Querier = artifacts.require("PredictionMarketV3Querier");

const { PM3_ADDRESS } = process.env;

module.exports = async function(deployer) {
  await deployer.deploy(PredictionMarketV3Querier, PM3_ADDRESS);
}
