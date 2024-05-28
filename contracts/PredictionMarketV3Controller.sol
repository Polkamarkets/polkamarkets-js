// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "./FantasyERC20.sol";
import "./RealityETH_ERC20_Factory.sol";
import "./PredictionMarketV3Factory.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PredictionMarketV3Controller is Ownable, ReentrancyGuard {
  address public immutable PMV3; // PredictionMarketV3 contract
  address public immutable PMV3Factory; // PredictionMarketFactory contract

  RealityETH_ERC20_Factory public immutable realitioFactory;

  event LandCreated(address indexed user, address indexed token, address indexed tokenToAnswer);

  event LandDisabled(address indexed user, address indexed token);

  event LandEnabled(address indexed user, address indexed token);

  event LandOffsetUnlocked(address indexed user, address indexed token);

  event LandAdminAdded(address indexed user, address indexed token, address indexed admin);

  event LandAdminRemoved(address indexed user, address indexed token, address indexed admin);

  struct Land {
    FantasyERC20 token;
    bool active;
    mapping(address => bool) admins;
    IRealityETH_IERC20 realitio;
  }

  mapping(address => Land) public lands;
  address[] public landTokens;
  uint256 public landTokensLength;

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

  // lockAmount is the amount of tokens that the user needs to lock to create a land
  // by locking the amount the factory will create a fantasyERC20 token and store it in the contract
  // the user will be the admin of the land
  function createLand(
    string memory name,
    string memory symbol,
    uint256 tokenAmountToClaim,
    IERC20 tokenToAnswer
  ) external returns (FantasyERC20) {

    require(address(tokenToAnswer) != address(0), "Token to answer cannot be 0 address");

    PredictionMarketV3Factory predictionMarketFactory = PredictionMarketV3Factory(PMV3Factory); // FIXME change to interface
    require(predictionMarketFactory.isPMControllerAdmin(this, msg.sender));

    // create a new fantasyERC20 token
    FantasyERC20 landToken = new FantasyERC20(name, symbol, tokenAmountToClaim, address(PMV3));

    // adding minting privileges to the PMV3 contract
    landToken.grantRole(keccak256("MINTER_ROLE"), address(PMV3));
    // adding minting privileges to the msg.sender
    landToken.grantRole(keccak256("MINTER_ROLE"), msg.sender);

    // store the new token in the contract
    Land storage land = lands[address(landToken)];
    land.token = landToken;
    land.active = true;
    land.admins[msg.sender] = true;
    landTokens.push(address(landToken));
    landTokensLength++;

    // creating the realityETH_ERC20 contract
    if (realitioFactory.deployments(address(tokenToAnswer)) == address(0)) {
      realitioFactory.createInstance(address(tokenToAnswer));
    }
    land.realitio = IRealityETH_IERC20(realitioFactory.deployments(address(tokenToAnswer)));

    emit LandCreated(msg.sender, address(landToken), address(tokenToAnswer));

    return landToken;
  }

  function disableLand(IERC20 landToken) external {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land is not active");
    require(land.admins[msg.sender], "Not admin of the land");

    // disable the land
    land.active = false;

    // pausing token
    FantasyERC20(address(landToken)).pause();

    emit LandDisabled(msg.sender, address(landToken));
  }

  function enableLand(IERC20 landToken) external {
    Land storage land = lands[address(landToken)];

    require(!land.active, "Land is already active");
    require(land.admins[msg.sender], "Not admin of the land");

    // enable the land
    land.active = true;

    // unpausing token
    FantasyERC20(address(landToken)).unpause();

    emit LandEnabled(msg.sender, address(landToken));
  }

  function addAdminToLand(IERC20 landToken, address admin) external {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(land.admins[msg.sender], "Not admin of the land");

    // adding minting privileges to the admin
    land.token.grantRole(keccak256("MINTER_ROLE"), admin);

    land.admins[admin] = true;

    emit LandAdminAdded(msg.sender, address(landToken), admin);
  }

  function removeAdminFromLand(IERC20 landToken, address admin) external {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(land.admins[msg.sender], "Not admin of the land");

    // removing minting privileges from the admin
    land.token.revokeRole(keccak256("MINTER_ROLE"), admin);

    land.admins[admin] = false;

    emit LandAdminRemoved(msg.sender, address(landToken), admin);
  }

  function isAllowedToCreateMarket(IERC20 marketToken, address user) public view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active && land.admins[user];
  }

  function isAllowedToResolveMarket(IERC20 marketToken, address user) external view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active && land.admins[user];
  }

  function isIERC20TokenSocial(IERC20 marketToken) external view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active;
  }

  function isLandAdmin(IERC20 marketToken, address user) external view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.admins[user];
  }
}
