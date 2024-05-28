// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import "./FantasyERC20.sol";
// import "./RealityETH_ERC20_Factory.sol";
import "./PredictionMarketV3.sol";
import "./PredictionMarketV3Manager.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PredictionMarketFactory is Ownable, ReentrancyGuard {
  IERC20 public immutable token; // Governance IERC20
  uint256 public lockAmount; // amount necessary to lock to create a land

  event ManagerCreated(address indexed user, address indexed manager, address indexed token, uint256 amountLocked);

  event ManagerDisabled(address indexed user, address indexed manager, uint256 amountUnlocked);

  event ManagerEnabled(address indexed user, address indexed manager, uint256 amountUnlocked);

  event ManagerOffsetUnlocked(address indexed user, address indexed token, uint256 amountUnlocked);

  event ManagerAdminAdded(address indexed user, address indexed token, address indexed admin);

  event ManagerAdminRemoved(address indexed user, address indexed token, address indexed admin);

  struct Manager {
    IERC20 token;
    bool active;
    mapping(address => bool) admins;
    uint256 lockAmount;
    address lockUser;
  }

  mapping(address => Manager) public managers;
  address[] public managersAddresses;
  uint256 public managersLength;

  constructor(
    IERC20 _token,
    uint256 _lockAmount
  ) {
    token = _token;
    lockAmount = _lockAmount;
  }

  function updateLockAmount(uint256 newLockAmount) external onlyOwner {
    require(newLockAmount > 0, "Lock amount must be greater than 0");
    require(newLockAmount != lockAmount, "Lock amount is the same");

    lockAmount = newLockAmount;
  }

  // lockAmount is the amount of tokens that the user needs to lock to create a land
  // by locking the amount the factory will create a PredicitonMarketManager contract and store it in the contract
  // the user will be the admin of the PredicitonMarketManager contract
  function createPMManager(
    uint256 lockAmountLand,
    uint256 lockAmountIsland,
    address PMV3,
    IWETH _WETH,
    address _realitioLibraryAddress,
    IERC20 lockableToken
  ) external returns (PredictionMarketV3Manager) {
    require(token.balanceOf(msg.sender) >= lockAmount, "Not enough tokens to lock");

    if (PMV3 == address(0)) {
      // deploy new PredictionMarket contract
      // PMV3 = address(new PredictionMarketManager(_WETH));
    }

    // deploy prediction market manager contract
    PredictionMarketV3Manager PMV3Manager = new PredictionMarketV3Manager(
      PMV3,
      lockableToken,
      lockAmountLand,
      lockAmountIsland,
      _realitioLibraryAddress,
      address(this)
    );

    // store the new token in the contract
    Manager storage manager = managers[address(PMV3Manager)];
    manager.token = lockableToken;
    manager.active = true;
    manager.admins[msg.sender] = true;
    manager.lockAmount = lockAmount;
    manager.lockUser = msg.sender;
    managersAddresses.push(address(PMV3Manager));
    managersLength++;

    // transfer the lockAmount to the contract
    token.transferFrom(msg.sender, address(this), lockAmount);

    // ManagerCreated event
    emit ManagerCreated(msg.sender, address(PMV3Manager), address(lockableToken), lockAmount);

    return PMV3Manager;
  }

  function disablePMManager(PredictionMarketV3Manager managerAddress) external returns (uint256) {
    Manager storage manager = managers[address(managerAddress)];

    require(manager.active, "Manager is not active");
    require(manager.admins[msg.sender], "Not admin of the manager");

    uint256 amountToUnlock = manager.lockAmount;

    token.transfer(manager.lockUser, amountToUnlock);

    // disable the land
    manager.active = false;
    manager.lockAmount = 0;
    manager.lockUser = address(0);

    // ManagerDisabled event
    emit ManagerDisabled(msg.sender, address(managerAddress), amountToUnlock);

    return amountToUnlock;
  }

  function enablePMManager(PredictionMarketV3Manager managerAddress) external returns (uint256) {
    Manager storage manager = managers[address(managerAddress)];

    require(!manager.active, "Manager is already active");
    require(manager.admins[msg.sender], "Not admin of the manager");

    uint256 amountToLock = lockAmount > manager.lockAmount ? lockAmount - manager.lockAmount : 0;

    // transfer the lockAmount to the contract
    token.transferFrom(msg.sender, address(this), amountToLock);

    // enable the land
    manager.active = true;
    manager.lockAmount = manager.lockAmount + amountToLock;
    manager.lockUser = msg.sender;

    // TODO ManagerEnabled event
    emit ManagerEnabled(msg.sender, address(managerAddress), amountToLock);

    return amountToLock;
  }

  function unlockOffsetFromPMManager(PredictionMarketV3Manager managerAddress) external returns (uint256) {
    Manager storage manager = managers[address(managerAddress)];

    require(manager.active, "Manager does not exist");
    require(manager.admins[msg.sender], "Not admin of the manager");

    uint256 amountToUnlock = manager.lockAmount > lockAmount ? manager.lockAmount - lockAmount : 0;

    if (amountToUnlock > 0) {
      token.transfer(msg.sender, amountToUnlock);
      manager.lockAmount = manager.lockAmount - amountToUnlock;
    }

    // ManagerOffsetUnlocked event
    emit ManagerOffsetUnlocked(msg.sender, address(managerAddress), amountToUnlock);

    return amountToUnlock;
  }

  function addAdminToPMManager(PredictionMarketV3Manager managerAddress, address admin) external {
    Manager storage manager = managers[address(managerAddress)];

    require(manager.active, "Manager does not exist");
    require(manager.admins[msg.sender], "Not admin of the manager");

    manager.admins[admin] = true;

    // TODO ManagerAdminAdded event
    emit ManagerAdminAdded(msg.sender, address(managerAddress), admin);
  }

  function removeAdminFromPMManager(PredictionMarketV3Manager managerAddress, address admin) external {
    Manager storage manager = managers[address(managerAddress)];

    require(manager.active, "Manager does not exist");
    require(manager.admins[msg.sender], "Not admin of the manager");
    require(manager.lockUser != admin, "Can not remove from admin the lockUser");

    manager.admins[admin] = false;

    // TODO ManagerAdminRemoved event
    emit ManagerAdminRemoved(msg.sender, address(managerAddress), admin);
  }

  function isPMManagerActive(PredictionMarketV3Manager managerAddress) external view returns (bool) {
    Manager storage manager = managers[address(managerAddress)];

    return manager.active;
  }

  function isPMManagerAdmin(PredictionMarketV3Manager managerAddress, address user) external view returns (bool) {
    Manager storage manager = managers[address(managerAddress)];

    return manager.admins[user];
  }
}
