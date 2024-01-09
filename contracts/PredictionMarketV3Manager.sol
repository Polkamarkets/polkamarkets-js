// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "./FantasyERC20.sol";
import "./RealityETH_ERC20_Factory.sol";
import "./IPredictionMarketV3.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";

contract PredictionMarketV3Manager is Ownable {
  IPredictionMarketV3 public immutable PMV3; // PredictionMarketV3 contract
  IERC20 public immutable token; // PredictionMarketV3 contract
  uint256 public lockAmount; // amount necessary to lock to create a land
  RealityETH_ERC20_Factory public immutable realitioFactory;

  struct Land {
    IERC20 token;
    bool active;
    mapping(address => bool) admins;
    uint256 amountLocked;
    IRealityETH_IERC20 realitio;
  }

  mapping(address => Land) public lands;

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
  ) external {
    require(token.balanceOf(msg.sender) >= lockAmount, "Not enough tokens to lock");

    // create a new fantasyERC20 token
    FantasyERC20 landToken = new FantasyERC20(name, symbol, tokenAmountToClaim, address(PMV3));

    // store the new token in the contract
    Land storage land = lands[address(landToken)];
    land.token = landToken;
    land.active = true;
    land.admins[msg.sender] = true;
    land.amountLocked = lockAmount;

    IERC20 realitioToken = address(tokenToAnswer) == address(0) ? landToken : tokenToAnswer;

    // creating the realityETH_ERC20 contract
    if (realitioFactory.deployments(address(realitioToken)) == address(0)) {
      realitioFactory.createInstance(address(realitioToken));
    }
    land.realitio = IRealityETH_IERC20(realitioFactory.deployments(address(realitioToken)));

    // transfer the lockAmount to the contract
    token.transferFrom(msg.sender, address(this), lockAmount);
  }

  function disableLand(IERC20 landToken) external {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land is not active");
    require(land.admins[msg.sender], "Not admin of the land");

    uint256 amountToUnlock = land.amountLocked;

    token.transfer(msg.sender, amountToUnlock);

    // disable the land
    land.active = false;
    land.amountLocked = 0;
  }

  function enableLand(IERC20 landToken) external {
    Land storage land = lands[address(landToken)];

    require(!land.active, "Land is already active");
    require(land.admins[msg.sender], "Not admin of the land");

    uint256 amountToLock = lockAmount > land.amountLocked ? lockAmount - land.amountLocked : 0;

    // transfer the lockAmount to the contract
    token.transferFrom(msg.sender, address(this), amountToLock);

    // enable the land
    land.active = true;
    land.amountLocked = land.amountLocked + amountToLock;
  }

  function unlockOffsetFromLand(IERC20 landToken) external returns (uint256) {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(land.admins[msg.sender], "Not admin of the land");

    uint256 amountToUnlock = land.amountLocked > lockAmount ? land.amountLocked - lockAmount : 0;

    if (amountToUnlock > 0) {
      token.transfer(msg.sender, amountToUnlock);
      land.amountLocked = land.amountLocked - amountToUnlock;
    }

    return amountToUnlock;
  }

  function addAdminToLand(IERC20 landToken, address admin) external {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(land.admins[msg.sender], "Not admin of the land");

    land.admins[admin] = true;
  }

  function removeAdminFromLand(IERC20 landToken, address admin) external {
    Land storage land = lands[address(landToken)];

    require(land.active, "Land does not exist");
    require(land.admins[msg.sender], "Not admin of the land");

    land.admins[admin] = false;
  }

  function isAllowedToCreateMarket(IERC20 marketToken) external view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active && land.admins[msg.sender];
  }

  function isIERC20TokenSocial(IERC20 marketToken) external view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active;
  }

  function isAllowedToResolveMarket(IERC20 marketToken, address user) external view returns (bool) {
    Land storage land = lands[address(marketToken)];

    return land.active && land.admins[user];
  }

  function mintAndCreateMarket(IPredictionMarketV3.CreateMarketDescription calldata description, uint256 amount)
    external
  {
    Land storage land = lands[address(description.token)];

    require(land.active, "Land is not active");
    require(land.admins[msg.sender], "Not admin of the land");

    // mint the amount of tokens to the user
    FantasyERC20(address(description.token)).mint(msg.sender, amount);

    // create the market
    PMV3.createMarket(description);
  }
}
