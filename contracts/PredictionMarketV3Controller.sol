// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "./FantasyERC20.sol";
import "./RealityETH_ERC20_Factory.sol";
import "./IPredictionMarketV3Factory.sol";
import "./LandFactory.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PredictionMarketV3Controller is LandFactory {
  address public immutable PMV3Factory; // PredictionMarketFactory contract
  mapping(address => LandPermissions) public landPermissions;

  // inherited variables from LandFactory
  // address public immutable PMV3
  // IERC20 public immutable token
  // uint256 public lockAmount
  // RealityETH_ERC20_Factory public immutable realitioFactory;
  // mapping(address => Land) public lands;
  // address[] public landTokens;
  // uint256 public landTokensLength;

  struct LandPermissions {
    bool openMarketCreation;
    bool openAdminManagement;
  }

  constructor(
    address _PMV3,
    address _realitioLibraryAddress,
    address _PMV3Factory
  ) {
    require(_PMV3Factory != address(0), "PMV3Factory address cannot be 0 address");

    PMV3 = _PMV3;
    realitioFactory = new RealityETH_ERC20_Factory(_realitioLibraryAddress);
    PMV3Factory = _PMV3Factory;
  }

  function createLand(
    string memory name,
    string memory symbol,
    uint256 tokenAmountToClaim,
    IERC20 tokenToAnswer
  ) external override returns (FantasyERC20) {
    require(
      IPredictionMarketV3Factory(PMV3Factory).isPMControllerAdmin(address(this), msg.sender),
      "Not allowed to create land"
    );

    // create a new fantasyERC20 token
    return _createLand(name, symbol, tokenAmountToClaim, tokenToAnswer, PMV3Factory, address(this));
  }

  function setLandEveryoneCanCreateMarkets(IERC20 landToken, bool canCreate) external {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(land.admins[msg.sender], "Not admin of the land");

    landPermissions[address(landToken)].openMarketCreation = canCreate;
  }

  function isAllowedToCreateMarket(IERC20 marketToken, address user) public view override returns (bool) {
    return
      lands[address(marketToken)].active &&
      (lands[address(marketToken)].admins[user] ||
        landPermissions[address(lands[address(marketToken)].token)].openMarketCreation ||
        IPredictionMarketV3Factory(PMV3Factory).isPMControllerAdmin(address(this), user));
  }

  function isAllowedToResolveMarket(IERC20 marketToken, address user) public view override returns (bool) {
    return
      lands[address(marketToken)].active &&
      (lands[address(marketToken)].admins[user] ||
        IPredictionMarketV3Factory(PMV3Factory).isPMControllerAdmin(address(this), user));
  }

  function isLandAdmin(IERC20 landToken, address user) public view override returns (bool) {
    return
      lands[address(landToken)].admins[user] ||
      IPredictionMarketV3Factory(PMV3Factory).isPMControllerAdmin(address(this), user);
  }
}
