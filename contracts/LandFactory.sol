// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./FantasyERC20.sol";
import "./RealityETH_ERC20_Factory.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

abstract contract LandFactory is Ownable, ReentrancyGuard {
  struct Land {
    FantasyERC20 token;
    bool active;
    mapping(address => bool) admins;
    uint256 lockAmount;
    address lockUser;
    IRealityETH_IERC20 realitio;
  }

  address public PMV3; // PredictionMarketV3 contract
  IERC20 public token; // Governance IERC20
  uint256 public lockAmount; // amount necessary to lock to create a land
  RealityETH_ERC20_Factory public realitioFactory;

  mapping(address => Land) public lands;
  address[] public landTokens;
  uint256 public landTokensLength;
  mapping(address => bool) public fantasyTokens;

  event LandCreated(address indexed user, address indexed token, address indexed tokenToAnswer, uint256 amountLocked);

  event LandDisabled(address indexed user, address indexed token, uint256 amountUnlocked);

  event LandEnabled(address indexed user, address indexed token, uint256 amountLocked);

  event LandOffsetUnlocked(address indexed user, address indexed token, uint256 amountUnlocked);

  event LandAdminAdded(address indexed user, address indexed token, address indexed admin);

  event LandAdminRemoved(address indexed user, address indexed token, address indexed admin);

  // lockAmount is the amount of tokens that the user needs to lock to create a land
  // by locking the amount the factory will create a fantasyERC20 token and store it in the contract
  // the user will be the admin of the land
  function createLand(
    string memory name,
    string memory symbol,
    uint256 tokenAmountToClaim,
    IERC20 tokenToAnswer
  ) external virtual returns (FantasyERC20) {
    return _createLand(name, symbol, tokenAmountToClaim, tokenToAnswer, address(0), address(0));
  }

  function createLand(FantasyERC20 landToken, IERC20 tokenToAnswer) external virtual returns (FantasyERC20) {
    return _createLand(landToken, tokenToAnswer);
  }

  function _createLand(
    string memory name,
    string memory symbol,
    uint256 tokenAmountToClaim,
    IERC20 tokenToAnswer,
    address PMV3Factory,
    address PMV3Controller
  ) internal returns (FantasyERC20) {
    // create a new fantasyERC20 token
    FantasyERC20 landToken = new FantasyERC20(
      name,
      symbol,
      tokenAmountToClaim,
      address(PMV3),
      PMV3Factory,
      PMV3Controller
    );

    // adding minting privileges to the PMV3 contract
    landToken.grantRole(keccak256("MINTER_ROLE"), address(PMV3));
    // adding minting privileges to the msg.sender
    landToken.grantRole(keccak256("MINTER_ROLE"), msg.sender);

    fantasyTokens[address(landToken)] = true;

    return _createLand(landToken, tokenToAnswer);
  }

  function _createLand(FantasyERC20 landToken, IERC20 tokenToAnswer) internal returns (FantasyERC20) {
    // checking if land with same token was already created
    require(!lands[address(landToken)].active, "Land already exists");

    if (lockAmount > 0) {
      // transfer the lockAmount to the contract
      require(token.balanceOf(msg.sender) >= lockAmount, "Not enough tokens to lock");
      token.transferFrom(msg.sender, address(this), lockAmount);
    }
    require(address(tokenToAnswer) != address(0), "Token to answer cannot be 0 address");

    // store the new token in the contract
    Land storage land = lands[address(landToken)];
    land.token = landToken;
    land.active = true;
    land.admins[msg.sender] = true;
    land.lockAmount = lockAmount;
    land.lockUser = msg.sender;
    landTokens.push(address(landToken));
    landTokensLength++;

    // creating the realityETH_ERC20 contract
    if (realitioFactory.deployments(address(tokenToAnswer)) == address(0)) {
      realitioFactory.createInstance(address(tokenToAnswer));
    }
    land.realitio = IRealityETH_IERC20(realitioFactory.deployments(address(tokenToAnswer)));

    emit LandCreated(msg.sender, address(landToken), address(tokenToAnswer), lockAmount);

    return landToken;
  }

  function disableLand(IERC20 landToken) external virtual {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land is not active");
    require(isLandAdmin(landToken, msg.sender), "Not admin of the land");

    uint256 amountToUnlock = land.lockAmount;

    if (amountToUnlock > 0) {
      token.transfer(land.lockUser, amountToUnlock);
    }

    // disable the land
    land.active = false;
    land.lockAmount = 0;
    land.lockUser = address(0);

    if (fantasyTokens[address(landToken)]) {
      // pausing token
      land.token.pause();
    }

    emit LandDisabled(msg.sender, address(landToken), amountToUnlock);
  }

  function enableLand(IERC20 landToken) external virtual {
    Land storage land = lands[address(landToken)];

    require(!land.active, "Land is already active");
    require(isLandAdmin(landToken, msg.sender), "Not admin of the land");

    uint256 amountToLock = lockAmount > land.lockAmount ? lockAmount - land.lockAmount : 0;

    // transfer the lockAmount to the contract
    if (amountToLock > 0) {
      token.transferFrom(msg.sender, address(this), amountToLock);
    }

    // enable the land
    land.active = true;
    land.lockAmount = land.lockAmount + amountToLock;
    land.lockUser = msg.sender;

    if (fantasyTokens[address(landToken)]) {
      // unpausing token
      land.token.unpause();
    }

    emit LandEnabled(msg.sender, address(landToken), amountToLock);
  }

  function unlockOffsetFromLand(IERC20 landToken) external virtual {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land is not active");
    require(isLandAdmin(landToken, msg.sender), "Not admin of the land");

    uint256 amountToUnlock = land.lockAmount > lockAmount ? land.lockAmount - lockAmount : 0;

    if (amountToUnlock > 0) {
      token.transfer(msg.sender, amountToUnlock);
      land.lockAmount = land.lockAmount - amountToUnlock;
    }

    emit LandOffsetUnlocked(msg.sender, address(landToken), amountToUnlock);
  }

  function updateLockAmount(uint256 newLockAmount) external onlyOwner {
    require(newLockAmount > 0, "Lock amount must be greater than 0");
    require(newLockAmount != lockAmount, "Lock amount is the same");

    lockAmount = newLockAmount;
  }

  function addAdminToLand(IERC20 landToken, address admin) external virtual {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(isLandAdmin(landToken, msg.sender), "Not admin of the land");

    // adding minting privileges to the admin
    if (fantasyTokens[address(landToken)]) {
      land.token.grantRole(keccak256("MINTER_ROLE"), admin);
    }

    land.admins[admin] = true;

    emit LandAdminAdded(msg.sender, address(landToken), admin);
  }

  function removeAdminFromLand(IERC20 landToken, address admin) external virtual {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(isLandAdmin(landToken, msg.sender), "Not admin of the land");

    // removing minting privileges from the admin
    if (fantasyTokens[address(landToken)]) {
      land.token.revokeRole(keccak256("MINTER_ROLE"), admin);
    }

    land.admins[admin] = false;

    emit LandAdminRemoved(msg.sender, address(landToken), admin);
  }

  function isAllowedToCreateMarket(IERC20 marketToken, address user) public view virtual returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active && land.admins[user];
  }

  function isAllowedToEditMarket(IERC20 marketToken, address user) external view virtual returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active && land.admins[user];
  }

  function isIERC20TokenSocial(IERC20 marketToken) external view virtual returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active;
  }

  function isLandAdmin(IERC20 marketToken, address user) public view virtual returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.admins[user];
  }

  function getERC20RealitioAddress(IERC20 marketToken) external view virtual returns (address) {
    Land storage land = lands[address(marketToken)];

    require(land.active, "Land does not exist");

    return address(land.realitio);
  }
}
