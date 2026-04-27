// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AdminRegistry} from "../contracts/AdminRegistry.sol";
import {CryptoCREOracle} from "../contracts/oracles/CryptoCREOracle.sol";
import {CryptoCRENegRiskResolver} from "../contracts/oracles/CryptoCRENegRiskResolver.sol";

/// @notice Deploys CryptoCRENegRiskResolver and grants it RESOLUTION_ADMIN_ROLE.
///
///         Required env vars:
///           PRIVATE_KEY            — deployer private key (must have DEFAULT_ADMIN_ROLE)
///           ADMIN_REGISTRY         — AdminRegistry address
///           NEG_RISK_ADAPTER       — NegRiskAdapter address
///           CRE_ORACLE             — CryptoCREOracle address (for shared price storage)
///           KEYSTONE_FORWARDER     — Chainlink KeystoneForwarder address
///           CRE_WORKFLOW_ID        — bytes32 workflow ID
///           CRE_WORKFLOW_NAME      — bytes32 workflow name
///           CRE_WORKFLOW_OWNER     — address of workflow owner
contract DeployCryptoCRENegRiskResolver is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address registryAddr = vm.envAddress("ADMIN_REGISTRY");
    address negRiskAdapterAddr = vm.envAddress("NEG_RISK_ADAPTER");
    address creOracleAddr = vm.envAddress("CRE_ORACLE");
    address keystoneForwarder = vm.envAddress("KEYSTONE_FORWARDER");
    bytes32 creWorkflowId = vm.envBytes32("CRE_WORKFLOW_ID");
    bytes32 creWorkflowName = vm.envBytes32("CRE_WORKFLOW_NAME");
    address creWorkflowOwner = vm.envAddress("CRE_WORKFLOW_OWNER");

    AdminRegistry registry = AdminRegistry(registryAddr);

    vm.startBroadcast(privateKey);

    CryptoCRENegRiskResolver resolver = new CryptoCRENegRiskResolver(
      registry,
      negRiskAdapterAddr,
      CryptoCREOracle(creOracleAddr),
      keystoneForwarder,
      creWorkflowId,
      creWorkflowName,
      creWorkflowOwner
    );

    // Grant RESOLUTION_ADMIN_ROLE so the resolver can call NegRiskAdapter.resolveEvent()
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), address(resolver));

    vm.stopBroadcast();

    console.log("CryptoCRENegRiskResolver:", address(resolver));
    console.log("RESOLUTION_ADMIN_ROLE granted");
  }
}
