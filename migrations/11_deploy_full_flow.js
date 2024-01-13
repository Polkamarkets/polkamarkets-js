const PredictionMarketV3 = artifacts.require("PredictionMarketV3");
const PredictionMarketV3Manager = artifacts.require("PredictionMarketV3Manager");
const ERC20PresetMinterPauser = artifacts.require("ERC20PresetMinterPauser");
const RealityETH_ERC20_v3_0 = artifacts.require("RealityETH_ERC20_v3_0");
const FantasyERC20 = artifacts.require("FantasyERC20");

let {
  TOKEN,
  REALITIO_ADDRESS,
  LOCK_AMOUNT,
  WETH,
  PM3_ADDRESS,
  ERC20_USER,
  PM3_MANAGER_ADDRESS,
} = process.env;

module.exports = async function(deployer) {
  await deployer.deploy(ERC20PresetMinterPauser, "PM3 Test", "PM3TEST");
  let ERC20 = await ERC20PresetMinterPauser.deployed();
  TOKEN = ERC20.address;
  await ERC20.mint(ERC20_USER, '1000000000000000000000');

  await deployer.deploy(RealityETH_ERC20_v3_0);
  const realitio = await RealityETH_ERC20_v3_0.deployed(RealityETH_ERC20_v3_0);
  await realitio.setToken(TOKEN);
  REALITIO_ADDRESS = realitio.address;

  await deployer.deploy(
    PredictionMarketV3,
    WETH, // weth
  );

  const PM3 = await PredictionMarketV3.deployed(PredictionMarketV3);
  PM3_ADDRESS = PM3.address;

  await deployer.deploy(
    PredictionMarketV3Manager,
    PM3_ADDRESS,
    TOKEN,
    LOCK_AMOUNT,
    REALITIO_ADDRESS
  );

  const PM3Manager = await PredictionMarketV3Manager.deployed(PredictionMarketV3Manager);
  // const ERC20 = await ERC20PresetMinterPauser.at(TOKEN);
  await ERC20.approve(PredictionMarketV3Manager.address, '1000000000000000000000');

  await PM3Manager.createLand(
    'Test Land',
    'LAND',
    '1000000000000000000',
    '0x0000000000000000000000000000000000000000'
  )
  const landToken = await PM3Manager.landTokens(0);
  const LAND_ERC20 = await FantasyERC20.at(landToken);
  await LAND_ERC20.approve(PredictionMarketV3.address, '1000000000000000000000');

  await PM3.mintAndCreateMarket(
    {
      value: '1000000000000000000',
      closesAt: 1735689600,
      outcomes: 2,
      token: landToken,
      distribution: [50000000,50000000],
      question: 'Will this market be created?;This is a test market.␟"Yes","No"␟Test;Testing;https://google.pt/␟',
      image: "",
      arbitrator: '0x000000000000000000000000000000000000dead',
      fee: 0,
      treasuryFee: 0,
      treasury: '0x000000000000000000000000000000000000dead',
      realitio: REALITIO_ADDRESS,
      realitioTimeout: 300,
      manager: PM3Manager.address,
    }
  )
}
