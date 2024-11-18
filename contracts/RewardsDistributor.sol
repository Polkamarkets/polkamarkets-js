// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "./Nonces.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract RewardsDistributor is Nonces, AccessControl {
  using ECDSA for bytes32;

  bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

  event TokensClaimed(address indexed user, address indexed receiver, IERC20 indexed token, uint256 amount);
  event UserClaimAmountIncreased(address indexed user, IERC20 indexed token, uint256 amount);
  event TokensWithdrawn(address indexed account, IERC20 indexed token, uint256 amount);

  mapping(address => mapping(IERC20 => uint256)) private _amountsToClaim;
  mapping(address => mapping(IERC20 => uint256)) private _amountsClaimed;
  mapping(address account => uint256) private _nonces;

  // ------ Modifiers ------

  modifier onlyAdmin() {
    require(hasRole(ADMIN_ROLE, msg.sender), "RewardsDistributor: must have admin role");
    _;
  }

  constructor() {
    _grantRole(ADMIN_ROLE, msg.sender);
    _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
  }

  function claim(address user, address receiver, uint256 amount, IERC20 token, uint256 nonce, bytes memory signature) external {
    require(amountToClaim(user, token) >= amount, "RewardsDistributor: not enough tokens to claim");

    _useCheckedNonce(user, nonce);

    // this recreates the message that was signed on the client
    bytes32 message = (keccak256(abi.encodePacked(user, receiver, amount, token, nonce))).toEthSignedMessageHash();
    require(message.recover(signature) == user, "RewardsDistributor: invalid signature");

    // checking the contract has enough balance to transfer
    require(token.balanceOf(address(this)) >= amount, "RewardsDistributor: not enough balance to transfer");

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

  /// ADMIN FUNCTIONS

  function increaseUserClaimAmount(address user, uint256 amount, IERC20 token) external onlyAdmin  {
    _amountsToClaim[user][token] += amount;

    emit UserClaimAmountIncreased(user, token, amount);
  }

  function increaseUsersClaimAmounts(address[] calldata users, uint256[] calldata amounts, IERC20 token) external onlyAdmin {
    require(users.length == amounts.length, "RewardsDistributor: arrays length mismatch");

    for (uint256 i = 0; i < users.length; i++) {
      _amountsToClaim[users[i]][token] += amounts[i];
    }
  }

  function setUserClaimAmount(address user, uint256 amount, IERC20 token) external onlyAdmin {
    _amountsToClaim[user][token] = amount;
  }

  function setUsersClaimAmounts(address[] calldata users, uint256[] calldata amounts, IERC20 token) external onlyAdmin {
    require(users.length == amounts.length, "RewardsDistributor: arrays length mismatch");

    for (uint256 i = 0; i < users.length; i++) {
      _amountsToClaim[users[i]][token] = amounts[i];
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

  function isAdmin(address account) external view returns (bool) {
    return hasRole(ADMIN_ROLE, account);
  }
}
