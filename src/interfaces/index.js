let index = {
  achievements: require("../../build/contracts/Achievements.json"),
  arbitration: require("../../build/contracts/RealitioForeignArbitrationProxyWithAppeals.json"),
  arbitrationProxy: require("../../build/contracts/RealitioHomeArbitrationProxy.json"),
  fantasyerc20: require("../../build/contracts/FantasyERC20.json"),
  ierc20: require("../../build/contracts/ERC20PresetMinterPauser.json"),
  prediction: require("../../build/contracts/PredictionMarket.json"),
  predictionV2: require("../../build/contracts/PredictionMarketV2.json"),
  predictionV3: require("../../build/contracts/PredictionMarketV3.json"),
  predictionV3Manager: require("../../build/contracts/PredictionMarketV3Manager.json"),
  predictionV3Controller: require("../../build/contracts/PredictionMarketV3Controller.json"),
  predictionMarketV3Factory: require("../../build/contracts/PredictionMarketV3Factory.json"),
  predictionV3Querier: require("../../build/contracts/PredictionMarketV3Querier.json"),
  ppmm: require("../../build/contracts/PPMMarket.json"),
  realitio: require("../../build/contracts/RealitioERC20.json"),
  voting: require("../../build/contracts/Voting.json"),
  weth: require("../../build/contracts/WETH9.json"),
};

module.exports = index;
