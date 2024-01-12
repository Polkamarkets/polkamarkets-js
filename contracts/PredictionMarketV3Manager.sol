// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "./FantasyERC20.sol";
import "./RealityETH_ERC20_Factory.sol";
import "./IPredictionMarketV3.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PredictionMarketV3Manager is Ownable, ReentrancyGuard {
  IPredictionMarketV3 public immutable PMV3; // PredictionMarketV3 contract
  IERC20 public immutable token; // PredictionMarketV3 contract
  uint256 public lockAmount; // amount necessary to lock to create a land
  RealityETH_ERC20_Factory public immutable realitioFactory;

  event LandCreated(address indexed user, address indexed token, address indexed tokenToAnswer, uint256 amountLocked);

  event LandDisabled(address indexed user, address indexed token, uint256 amountUnlocked);

  event LandEnabled(address indexed user, address indexed token, uint256 amountLocked);

  event LandOffsetUnlocked(address indexed user, address indexed token, uint256 amountUnlocked);

  event LandAdminAdded(address indexed user, address indexed token, address indexed admin);

  event LandAdminRemoved(address indexed user, address indexed token, address indexed admin);

  struct Land {
    FantasyERC20 token;
    bool active;
    mapping(address => bool) admins;
    uint256 lockAmount;
    address lockUser;
    IRealityETH_IERC20 realitio;
  }

  mapping(address => Land) public lands;
  address[] public landTokens;

  constructor(
    IPredictionMarketV3 _PMV3,
    IERC20 _token,
    uint256 _lockAmount,
    address _realitioLibraryAddress
  ) {
    PMV3 = _PMV3;
    token = _token;
    lockAmount = _lockAmount;
    realitioFactory = new RealityETH_ERC20_Factory(_realitioLibraryAddress);
  }

  function updateLockAmount(uint256 newLockAmount) external onlyOwner {
    require(newLockAmount > 0, "Lock amount must be greater than 0");
    require(newLockAmount != lockAmount, "Lock amount is the same");

    lockAmount = newLockAmount;
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
    require(token.balanceOf(msg.sender) >= lockAmount, "Not enough tokens to lock");

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
    land.lockAmount = lockAmount;
    land.lockUser = msg.sender;
    landTokens.push(address(landToken));

    IERC20 realitioToken = address(tokenToAnswer) == address(0) ? landToken : tokenToAnswer;

    // creating the realityETH_ERC20 contract
    if (realitioFactory.deployments(address(realitioToken)) == address(0)) {
      realitioFactory.createInstance(address(realitioToken));
    }
    land.realitio = IRealityETH_IERC20(realitioFactory.deployments(address(realitioToken)));

    // transfer the lockAmount to the contract
    token.transferFrom(msg.sender, address(this), lockAmount);

    emit LandCreated(msg.sender, address(landToken), address(tokenToAnswer), lockAmount);

    return landToken;
  }

  function disableLand(IERC20 landToken) external returns (uint256) {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land is not active");
    require(land.admins[msg.sender], "Not admin of the land");

    uint256 amountToUnlock = land.lockAmount;

    token.transfer(land.lockUser, amountToUnlock);

    // disable the land
    land.active = false;
    land.lockAmount = 0;
    land.lockUser = address(0);

    // pausing token
    FantasyERC20(address(landToken)).pause();

    emit LandDisabled(msg.sender, address(landToken), amountToUnlock);

    return amountToUnlock;
  }

  function enableLand(IERC20 landToken) external returns (uint256) {
    Land storage land = lands[address(landToken)];

    require(!land.active, "Land is already active");
    require(land.admins[msg.sender], "Not admin of the land");

    uint256 amountToLock = lockAmount > land.lockAmount ? lockAmount - land.lockAmount : 0;

    // transfer the lockAmount to the contract
    token.transferFrom(msg.sender, address(this), amountToLock);

    // enable the land
    land.active = true;
    land.lockAmount = land.lockAmount + amountToLock;
    land.lockUser = msg.sender;

    // unpausing token
    FantasyERC20(address(landToken)).unpause();

    emit LandEnabled(msg.sender, address(landToken), amountToLock);

    return amountToLock;
  }

  function unlockOffsetFromLand(IERC20 landToken) external returns (uint256) {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(land.admins[msg.sender], "Not admin of the land");

    uint256 amountToUnlock = land.lockAmount > lockAmount ? land.lockAmount - lockAmount : 0;

    if (amountToUnlock > 0) {
      token.transfer(msg.sender, amountToUnlock);
      land.lockAmount = land.lockAmount - amountToUnlock;
    }

    emit LandOffsetUnlocked(msg.sender, address(landToken), amountToUnlock);

    return amountToUnlock;
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
    // call from the mintAndCreateMarket function
    if (user == address(this)) return true;

    Land storage land = lands[address(marketToken)];

    return land.active && land.admins[user];
  }

  function isIERC20TokenSocial(IERC20 marketToken) external view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active;
  }

  function isAllowedToResolveMarket(IERC20 marketToken, address user) external view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active && land.admins[user];
  }
}
