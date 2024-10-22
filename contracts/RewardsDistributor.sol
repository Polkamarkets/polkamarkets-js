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

  mapping(address => mapping(IERC20 => uint256)) amountsToClaim;
  mapping(address account => uint256) private _nonces;

  // ------ Modifiers ------

  modifier mustBeAdmin() {
    require(hasRole(ADMIN_ROLE, msg.sender), "RewardsDistributor: must have admin role");
    _;
  }

  constructor() {
    _grantRole(ADMIN_ROLE, msg.sender);
    _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
  }

  function claim(address user, address receiver, uint256 amount, IERC20 token, uint256 nonce, bytes memory signature) external {
    require(amountsToClaim[user][token] >= amount, "RewardsDistributor: not enough tokens to claim");

    _useCheckedNonce(user, nonce);

    // this recreates the message that was signed on the client
    bytes32 message = (keccak256(abi.encodePacked(user, receiver, amount, token, nonce))).toEthSignedMessageHash();
    require(message.recover(signature) == user, "RewardsDistributor: invalid signature");

    token.transfer(receiver, amount);

    amountsToClaim[user][token] -= amount;

    emit TokensClaimed(user, receiver, token, amount);
  }

  function amountToClaim(address user, IERC20 token) external view returns (uint256) {
    return amountsToClaim[user][token];
  }

  /// ADMIN FUNCTIONS

  function increaseUserClaimAmount(address user, uint256 amount, IERC20 token) external mustBeAdmin  {
    amountsToClaim[user][token] += amount;

    emit UserClaimAmountIncreased(user, token, amount);
  }

  function withdrawTokens(IERC20 token, uint256 amount) external mustBeAdmin {
    token.transfer(msg.sender, amount);

    emit TokensWithdrawn(msg.sender, token, amount);
  }

  function addAdmin(address account) external mustBeAdmin {
    grantRole(ADMIN_ROLE, account);
  }

  function removeAdmin(address account) external mustBeAdmin {
    revokeRole(ADMIN_ROLE, account);
  }

  function isAdmin(address account) external view returns (bool) {
    return hasRole(ADMIN_ROLE, account);
  }
}
