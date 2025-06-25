// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "./Nonces.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract RewardsDistributor is Nonces, AccessControl {
  using ECDSA for bytes32;

  bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

  event TokensClaimed(address indexed user, address indexed receiver, IERC20 indexed token, uint256 amount);
  event UserClaimAmountSet(address indexed user, IERC20 indexed token, uint256 amount);
  event UserClaimAmountIncreased(address indexed user, IERC20 indexed token, uint256 amount);
  event TokensWithdrawn(address indexed account, IERC20 indexed token, uint256 amount);
  event AliasAdded(address indexed owner, address indexed target, address indexed addedBy);
  event AliasRemoved(address indexed owner, address indexed target, address indexed removedBy);

  mapping(address => mapping(IERC20 => uint256)) private _amountsToClaim;
  mapping(address => mapping(IERC20 => uint256)) private _amountsClaimed;
  mapping(address account => uint256) private _nonces;
  mapping(address => mapping(address => bool)) private aliases;

  // ------ Modifiers ------

  modifier onlyAdmin() {
    require(hasRole(ADMIN_ROLE, msg.sender), "RewardsDistributor: must have admin role");
    _;
  }

  constructor() {
    _grantRole(ADMIN_ROLE, msg.sender);
    _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
  }

  function claim(address user, address receiver, uint256 amount, IERC20 token) external {
    require(msg.sender == user || aliases[user][msg.sender], "RewardsDistributor: invalid user");

    _claim(user, receiver, amount, token);
  }

  function claim(address user, address receiver, uint256 amount, IERC20 token, uint256 nonce, bytes memory signature) external {
    _useCheckedNonce(user, nonce);

    // this recreates the message that was signed on the client
    bytes32 message = (keccak256(abi.encodePacked(user, receiver, amount, token, nonce))).toEthSignedMessageHash();
    address signer = message.recover(signature);
    require(signer == user || aliases[user][signer], "RewardsDistributor: invalid signature");

    _claim(user, receiver, amount, token);
  }

  function _claim(address user, address receiver, uint256 amount, IERC20 token) private {
    // checking the contract has enough balance to transfer
    require(token.balanceOf(address(this)) >= amount, "RewardsDistributor: not enough balance to transfer");
    require(amountToClaim(user, token) >= amount, "RewardsDistributor: not enough tokens to claim");

    token.transfer(receiver, amount);

    // _amountsToClaim[user][token] -= amount;
    _amountsClaimed[user][token] += amount;

    emit TokensClaimed(user, receiver, token, amount);
  }

  function amountToClaim(address user, IERC20 token) public view returns (uint256) {
    return _amountsToClaim[user][token] - _amountsClaimed[user][token];
  }

  function claimAmounts(address user, IERC20 token) external view returns (uint256, uint256) {
    return (_amountsClaimed[user][token], _amountsToClaim[user][token]);
  }

  function claimsAmounts(address[] calldata users, IERC20 token) external view returns (uint256[] memory, uint256[] memory) {
    uint256[] memory claimed = new uint256[](users.length);
    uint256[] memory toClaim = new uint256[](users.length);

    for (uint256 i = 0; i < users.length; i++) {
      claimed[i] = _amountsClaimed[users[i]][token];
      toClaim[i] = _amountsToClaim[users[i]][token];
    }

    return (claimed, toClaim);
  }

  /// ADMIN FUNCTIONS

  function increaseUserClaimAmount(address user, uint256 amount, IERC20 token) external onlyAdmin  {
    _amountsToClaim[user][token] += amount;

    emit UserClaimAmountIncreased(user, token, amount);
  }

  function increaseUsersClaimAmounts(address[] calldata users, uint256[] calldata amounts, IERC20 token) external onlyAdmin {
    require(users.length == amounts.length, "RewardsDistributor: arrays length mismatch");

    for (uint256 i = 0; i < users.length; i++) {
      _amountsToClaim[users[i]][token] += amounts[i];
      emit UserClaimAmountIncreased(users[i], token, amounts[i]);
    }
  }

  function setUserClaimAmount(address user, uint256 amount, IERC20 token) external onlyAdmin {
    _amountsToClaim[user][token] = amount;

    emit UserClaimAmountSet(user, token, amount);
  }

  function setUsersClaimAmounts(address[] calldata users, uint256[] calldata amounts, IERC20 token) external onlyAdmin {
    require(users.length == amounts.length, "RewardsDistributor: arrays length mismatch");

    for (uint256 i = 0; i < users.length; i++) {
      _amountsToClaim[users[i]][token] = amounts[i];
      emit UserClaimAmountSet(users[i], token, amounts[i]);
    }
  }

  function withdrawTokens(IERC20 token, uint256 amount) external onlyAdmin {
    token.transfer(msg.sender, amount);

    emit TokensWithdrawn(msg.sender, token, amount);
  }

  function addAdmin(address account) external onlyAdmin {
    grantRole(ADMIN_ROLE, account);
  }

  function removeAdmin(address account) external onlyAdmin {
    revokeRole(ADMIN_ROLE, account);
  }

  function addAlias(address target) external {
    aliases[msg.sender][target] = true;

    emit AliasAdded(msg.sender, target, msg.sender);
  }

  function removeAlias(address target) external {
    aliases[msg.sender][target] = false;

    emit AliasRemoved(msg.sender, target, msg.sender);
  }

  function addAlias(address owner, address target) external onlyAdmin {
    aliases[owner][target] = true;

    emit AliasAdded(owner, target, msg.sender);
  }

  function removeAlias(address owner, address target) external onlyAdmin {
    aliases[owner][target] = false;

    emit AliasRemoved(owner, target, msg.sender);
  }

  function isAdmin(address account) external view returns (bool) {
    return hasRole(ADMIN_ROLE, account);
  }

  function isAlias(address owner, address target) external view returns (bool) {
    return aliases[owner][target];
  }
}
