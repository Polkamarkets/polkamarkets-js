// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {AdminRegistry} from "../contracts/AdminRegistry.sol";
import {FeeModule} from "../contracts/FeeModule.sol";

/// @title SetupCLOBOperator
/// @notice Grants OPERATOR_ROLE to the matcher wallet and FEE_ADMIN_ROLE to the admin.
///         Idempotent — safe to re-run if already configured.
///
///         Env vars:
///           PRIVATE_KEY      — caller private key (must hold DEFAULT_ADMIN_ROLE)
///           CLOB_FEE_MODULE  — FeeModule proxy address
///           OPERATOR         — operator address to receive OPERATOR_ROLE
///           ADMIN            — admin address to receive FEE_ADMIN_ROLE (default: caller)
contract SetupCLOBOperator is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address caller = vm.addr(privateKey);

    address feeModuleAddr = vm.envAddress("CLOB_FEE_MODULE");
    address operatorAddr = vm.envAddress("OPERATOR");
    address admin = vm.envOr("ADMIN", caller);

    FeeModule feeModule = FeeModule(feeModuleAddr);
    AdminRegistry registry = feeModule.registry();

    // ── Diagnostics (read-only) ──────────────────────────────────────
    console.log("=== CLOB Operator Setup ===");
    console.log("FeeModule:", feeModuleAddr);
    console.log("AdminRegistry:", address(registry));
    console.log("Caller:", caller);
    console.log("Admin:", admin);
    console.log("Operator:", operatorAddr);

    bytes32 defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();
    bytes32 operatorRole = registry.OPERATOR_ROLE();
    bytes32 feeAdminRole = registry.FEE_ADMIN_ROLE();

    bool callerIsAdmin = registry.hasRole(defaultAdminRole, caller);
    bool operatorHasRole = registry.hasRole(operatorRole, operatorAddr);
    bool adminIsFeeAdmin = registry.hasRole(feeAdminRole, admin);

    console.log("");
    console.log("--- Current State ---");
    console.log("Caller has DEFAULT_ADMIN_ROLE:", callerIsAdmin);
    console.log("Operator has OPERATOR_ROLE:", operatorHasRole);
    console.log("Admin has FEE_ADMIN_ROLE:", adminIsFeeAdmin);

    require(callerIsAdmin, "Caller does not have DEFAULT_ADMIN_ROLE - cannot grant roles");

    // ── Broadcast transactions ───────────────────────────────────────
    vm.startBroadcast(privateKey);

    if (!operatorHasRole) {
      console.log("");
      console.log("[tx] Granting OPERATOR_ROLE to", operatorAddr);
      registry.grantRole(operatorRole, operatorAddr);
    } else {
      console.log("");
      console.log("[skip] OPERATOR_ROLE already granted to", operatorAddr);
    }

    if (!adminIsFeeAdmin) {
      console.log("[tx] Granting FEE_ADMIN_ROLE to", admin);
      registry.grantRole(feeAdminRole, admin);
    } else {
      console.log("[skip] FEE_ADMIN_ROLE already granted to", admin);
    }

    vm.stopBroadcast();

    console.log("");
    console.log("=== Setup complete ===");
  }
}
