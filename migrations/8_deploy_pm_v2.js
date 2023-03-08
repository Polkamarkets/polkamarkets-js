const PredictionMarketV2 = artifacts.require("PredictionMarketV2");
const {
  TOKEN,
  REQUIRED_BALANCE,
  REALITIO_ADDRESS,
  REALITIO_TIMEOUT,
  WETH,
} = process.env;


module.exports = async function(deployer) {
  await deployer.deploy(
    PredictionMarketV2,
    TOKEN, // token
    REQUIRED_BALANCE, // requiredBalance
    REALITIO_ADDRESS, // realitioAddress
    REALITIO_TIMEOUT, // realitioTimeout,
    WETH, // weth
  );
};
