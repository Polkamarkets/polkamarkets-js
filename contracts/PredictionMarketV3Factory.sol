// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import "./FantasyERC20.sol";
// import "./RealityETH_ERC20_Factory.sol";
import "./PredictionMarketV3.sol";
import "./PredictionMarketV3Controller.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PredictionMarketV3Factory is Ownable, ReentrancyGuard {
  IERC20 public immutable token; // Governance IERC20
  uint256 public lockAmount; // amount necessary to lock to create a land

  event ControllerCreated(address indexed user, address indexed controller, uint256 amountLocked);

  event ControllerDisabled(address indexed user, address indexed controller, uint256 amountUnlocked);

  event ControllerEnabled(address indexed user, address indexed controller, uint256 amountUnlocked);

  event ControllerOffsetUnlocked(address indexed user, address indexed controller, uint256 amountUnlocked);

  event ControllerAdminAdded(address indexed user, address indexed controller, address indexed admin);

  event ControllerAdminRemoved(address indexed user, address indexed controller, address indexed admin);

  struct Controller {
    bool active;
    mapping(address => bool) admins;
    uint256 lockAmount;
    address lockUser;
  }

  mapping(address => Controller) public controllers;
  address[] public controllersAddresses;
  uint256 public controllersLength;

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
  // by locking the amount the factory will create a PredicitonMarketController contract and store it in the contract
  // the user will be the admin of the PredicitonMarketController contract
  function createPMController(
    address PMV3,
    IWETH _WETH,
    address _realitioLibraryAddress
  ) external returns (PredictionMarketV3Controller) {
    require(token.balanceOf(msg.sender) >= lockAmount, "Not enough tokens to lock");

    if (PMV3 == address(0)) {
      // deploy new PredictionMarketV3 contract
      // PMV3 = address(new PredictionMarketV3(_WETH));
    }

    // deploy prediction market controller contract
    PredictionMarketV3Controller PMV3Controller = new PredictionMarketV3Controller(
      PMV3,
      _realitioLibraryAddress,
      address(this)
    );

    // store the new controller in the contract
    Controller storage controller = controllers[address(PMV3Controller)];
    controller.active = true;
    controller.admins[msg.sender] = true;
    controller.lockAmount = lockAmount;
    controller.lockUser = msg.sender;
    controllersAddresses.push(address(PMV3Controller));
    controllersLength++;

    // transfer the lockAmount to the contract
    token.transferFrom(msg.sender, address(this), lockAmount);

    // ControllerCreated event
    emit ControllerCreated(msg.sender, address(PMV3Controller), lockAmount);

    return PMV3Controller;
  }

  function disablePMController(PredictionMarketV3Controller controllerAddress) external returns (uint256) {
    Controller storage controller = controllers[address(controllerAddress)];

    require(controller.active, "Controller is not active");
    require(controller.admins[msg.sender], "Not admin of the controller");

    uint256 amountToUnlock = controller.lockAmount;

    token.transfer(controller.lockUser, amountToUnlock);

    // disable the land
    controller.active = false;
    controller.lockAmount = 0;
    controller.lockUser = address(0);

    // ControllerDisabled event
    emit ControllerDisabled(msg.sender, address(controllerAddress), amountToUnlock);

    return amountToUnlock;
  }

  function enablePMController(PredictionMarketV3Controller controllerAddress) external returns (uint256) {
    Controller storage controller = controllers[address(controllerAddress)];

    require(!controller.active, "Controller is already active");
    require(controller.admins[msg.sender], "Not admin of the controller");

    uint256 amountToLock = lockAmount > controller.lockAmount ? lockAmount - controller.lockAmount : 0;

    // transfer the lockAmount to the contract
    token.transferFrom(msg.sender, address(this), amountToLock);

    // enable the land
    controller.active = true;
    controller.lockAmount = controller.lockAmount + amountToLock;
    controller.lockUser = msg.sender;

    // ControllerEnabled event
    emit ControllerEnabled(msg.sender, address(controllerAddress), amountToLock);

    return amountToLock;
  }

  function unlockOffsetFromPMController(PredictionMarketV3Controller controllerAddress) external returns (uint256) {
    Controller storage controller = controllers[address(controllerAddress)];

    require(controller.active, "controller does not exist");
    require(controller.admins[msg.sender], "Not admin of the controller");

    uint256 amountToUnlock = controller.lockAmount > lockAmount ? controller.lockAmount - lockAmount : 0;

    if (amountToUnlock > 0) {
      token.transfer(msg.sender, amountToUnlock);
      controller.lockAmount = controller.lockAmount - amountToUnlock;
    }

    // ControllerOffsetUnlocked event
    emit ControllerOffsetUnlocked(msg.sender, address(controllerAddress), amountToUnlock);

    return amountToUnlock;
  }

  function addAdminToPMController(PredictionMarketV3Controller controllerAddress, address admin) external {
    Controller storage controller = controllers[address(controllerAddress)];

    require(controller.active, "Controller does not exist");
    require(controller.admins[msg.sender], "Not admin of the controller");

    controller.admins[admin] = true;

    // ControllerAdminAdded event
    emit ControllerAdminAdded(msg.sender, address(controllerAddress), admin);
  }

  function removeAdminFromPMController(PredictionMarketV3Controller controllerAddress, address admin) external {
    Controller storage controller = controllers[address(controllerAddress)];

    require(controller.active, "Controller does not exist");
    require(controller.admins[msg.sender], "Not admin of the controller");
    require(controller.lockUser != admin, "Can not remove from admin the lockUser");

    controller.admins[admin] = false;

    // ControllerAdminRemoved event
    emit ControllerAdminRemoved(msg.sender, address(controllerAddress), admin);
  }

  function isPMControllerActive(PredictionMarketV3Controller controllerAddress) external view returns (bool) {
    Controller storage controller = controllers[address(controllerAddress)];

    return controller.active;
  }

  function isPMControllerAdmin(PredictionMarketV3Controller controllerAddress, address user) external view returns (bool) {
    Controller storage controller = controllers[address(controllerAddress)];

    return controller.admins[user];
  }
}
