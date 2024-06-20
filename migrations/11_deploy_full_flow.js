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
  LAND_TOKEN
} = process.env;

module.exports = async function(deployer) {

  let ERC20;
  // Comment block if you want to use an existing token
  await deployer.deploy(ERC20PresetMinterPauser, "PM3 Token", "PM3TOKEN");
  ERC20 = await ERC20PresetMinterPauser.deployed();
  await ERC20.mint(ERC20_USER, '1000000000000000000000');
  TOKEN = ERC20.address;

  ERC20 = await ERC20PresetMinterPauser.at(TOKEN);

  // Comment block if you want to use existing realitio
  await deployer.deploy(RealityETH_ERC20_v3_0);
  const realitio = await RealityETH_ERC20_v3_0.deployed(RealityETH_ERC20_v3_0);
  await realitio.setToken(TOKEN);
  REALITIO_ADDRESS = realitio.address;

  let PM3;
  // Comment block if you want to use existing PM3
  await deployer.deploy(
    PredictionMarketV3,
    WETH, // weth
  );
  PM3 = await PredictionMarketV3.deployed(PredictionMarketV3);
  PM3_ADDRESS = PM3.address;

  PM3 = await PredictionMarketV3.at(PM3_ADDRESS);

  let PM3Manager;
  // Comment block if you want to use existing PM3Manager
  await deployer.deploy(
    PredictionMarketV3Manager,
    PM3_ADDRESS,
    TOKEN,
    LOCK_AMOUNT,
    REALITIO_ADDRESS
  );
  PM3Manager = await PredictionMarketV3Manager.deployed(PredictionMarketV3Manager);
  PM3_MANAGER_ADDRESS = PM3Manager.address;

  PM3Manager = await PredictionMarketV3Manager.at(PM3_MANAGER_ADDRESS);

  // Comment block if approve was already performed
  await ERC20.approve(PM3_MANAGER_ADDRESS, '1000000000000000000000');

  let LandERC20;
  // Comment block if you want to use a land already created
  await PM3Manager.createLand(
    'PM3 Land Token',
    'LAND',
    '1000000000000000000',
    TOKEN
  )
  LAND_TOKEN = await PM3Manager.landTokens(0);

  LandERC20 = await FantasyERC20.at(LAND_TOKEN);

  // Comment block if approve was already performed
  await LandERC20.approve(PM3_ADDRESS, '1000000000000000000000');

  // Comment block if market was already created
  const land = await PM3Manager.lands(LAND_TOKEN);
  const landRealitio = land.realitio;
  await PM3.mintAndCreateMarket(
    {
      value: '1000000000000000000',
      closesAt: 1735689600,
      outcomes: 2,
      token: LAND_TOKEN,
      distribution: [50000000,50000000],
      question: 'Will this market be created?;This is a test market.␟"Yes","No"␟Test;Testing;https://google.pt/␟',
      image: "",
      arbitrator: '0x000000000000000000000000000000000000dead',
      fee: 0,
      treasuryFee: 0,
      treasury: '0x000000000000000000000000000000000000dead',
      realitio: landRealitio,
      realitioTimeout: 300,
      manager: PM3_MANAGER_ADDRESS,
    }
  )
}
