const PredictionMarketV3Factory = artifacts.require("PredictionMarketV3Factory");

const { TOKEN, PM3_ADDRESS, REALITIO_ADDRESS } = process.env;

module.exports = async function(deployer) {
  await deployer.deploy(
    PredictionMarketV3Factory,
    TOKEN,
    '1000000000000000000',
    PM3_ADDRESS,
    REALITIO_ADDRESS,
    { gas: 10000000 }
  );
}
