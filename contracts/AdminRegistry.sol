// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AdminRegistry
/// @notice Centralized role registry for protocol governance and operations.
contract AdminRegistry is AccessControl {
  bytes32 public constant MARKET_ADMIN_ROLE = keccak256("MARKET_ADMIN_ROLE");
  bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
  bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
  bytes32 public constant RESOLUTION_ADMIN_ROLE = keccak256("RESOLUTION_ADMIN_ROLE");

  constructor(address admin) {
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }
}
