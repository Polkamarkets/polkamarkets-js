// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "./PredictionMarketV3Controller.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

contract PredictionMarketV3Factory is Ownable, ReentrancyGuard {
  IERC20 public immutable token; // Governance IERC20
  uint256 public lockAmount; // amount necessary to lock to create a land
  address public PMV3LibraryAddress; // PredictionMarketV3 library address
  address public realitioLibraryAddress; // PredictionMarketV3 contract

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
    uint256 _lockAmount,
    address _PMV3LibraryAddress,
    address _realitioLibraryAddress
  ) {
    token = _token;
    lockAmount = _lockAmount;
    PMV3LibraryAddress = _PMV3LibraryAddress;
    realitioLibraryAddress = _realitioLibraryAddress;
  }

  function updateLockAmount(uint256 newLockAmount) external onlyOwner {
    require(newLockAmount != lockAmount, "Lock amount is the same");

    lockAmount = newLockAmount;
  }

  function updatePMV3LibraryAddress(address _PMV3LibraryAddress) external onlyOwner {
    require(_PMV3LibraryAddress != address(0), "PMV3LibraryAddress address cannot be 0 address");

    PMV3LibraryAddress = _PMV3LibraryAddress;
  }

  function updateRealitioLibraryAddress(address _realitioLibraryAddress) external onlyOwner {
    require(_realitioLibraryAddress != address(0), "RealitioLibraryAddress address cannot be 0 address");

    realitioLibraryAddress = _realitioLibraryAddress;
  }

  // lockAmount is the amount of tokens that the user needs to lock to create a land
  // by locking the amount the factory will create a PredictionMarketController contract and store it in the contract
  // the user will be the admin of the PredictionMarketController contract
  function createPMController(address _PMV3) external returns (PredictionMarketV3Controller) {
    require(token.balanceOf(msg.sender) >= lockAmount, "Not enough tokens to lock");

    // a PMV3 address can be provided, if not, the factory will deploy a new one
    if (_PMV3 == address(0)) {
      // deploy new PredictionMarketV3 contract
      _PMV3 = Clones.clone(PMV3LibraryAddress);
    }

    // deploy prediction market controller contract
    PredictionMarketV3Controller PMV3Controller = new PredictionMarketV3Controller(
      _PMV3,
      realitioLibraryAddress,
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

  function disablePMController(address controllerAddress) external returns (uint256) {
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

  function enablePMController(address controllerAddress) external returns (uint256) {
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

  function unlockOffsetFromPMController(address controllerAddress) external returns (uint256) {
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

  function addAdminToPMController(address controllerAddress, address admin) external {
    Controller storage controller = controllers[address(controllerAddress)];

    require(controller.active, "Controller does not exist");
    require(controller.admins[msg.sender], "Not admin of the controller");

    controller.admins[admin] = true;

    // ControllerAdminAdded event
    emit ControllerAdminAdded(msg.sender, address(controllerAddress), admin);
  }

  function removeAdminFromPMController(address controllerAddress, address admin) external {
    Controller storage controller = controllers[address(controllerAddress)];

    require(controller.active, "Controller does not exist");
    require(controller.admins[msg.sender], "Not admin of the controller");
    require(controller.lockUser != admin, "Can not remove from admin the lockUser");

    controller.admins[admin] = false;

    // ControllerAdminRemoved event
    emit ControllerAdminRemoved(msg.sender, address(controllerAddress), admin);
  }

  function isPMControllerActive(address controllerAddress) external view returns (bool) {
    Controller storage controller = controllers[address(controllerAddress)];

    return controller.active;
  }

  function isPMControllerAdmin(address controllerAddress, address user) external view returns (bool) {
    Controller storage controller = controllers[address(controllerAddress)];

    return controller.admins[user];
  }
}
