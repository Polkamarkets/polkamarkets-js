// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AdminRegistry} from "../contracts/AdminRegistry.sol";
import {SportsCREOracle} from "../contracts/oracles/SportsCREOracle.sol";
import {SportsCRENegRiskResolver} from "../contracts/oracles/SportsCRENegRiskResolver.sol";

/// @notice Deploys SportsCRENegRiskResolver and grants it RESOLUTION_ADMIN_ROLE.
///
///         Required env vars:
///           PRIVATE_KEY               — deployer private key (must have DEFAULT_ADMIN_ROLE)
///           ADMIN_REGISTRY            — AdminRegistry address
///           NEG_RISK_ADAPTER          — NegRiskAdapter address
///           SPORTS_ORACLE             — SportsCREOracle address
///           KEYSTONE_FORWARDER        — Chainlink KeystoneForwarder address
///
///         Workflow identity (author + name) is configured POST-deploy via
///         setExpectedAuthor / setExpectedWorkflowName from MARKET_ADMIN_ROLE.
contract DeploySportsCRENegRiskResolver is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address registryAddr = vm.envAddress("ADMIN_REGISTRY");
    address negRiskAdapterAddr = vm.envAddress("NEG_RISK_ADAPTER");
    address sportsOracleAddr = vm.envAddress("SPORTS_ORACLE");
    address keystoneForwarder = vm.envAddress("KEYSTONE_FORWARDER");

    AdminRegistry registry = AdminRegistry(registryAddr);

    vm.startBroadcast(privateKey);

    SportsCRENegRiskResolver resolver = new SportsCRENegRiskResolver(
      registry,
      negRiskAdapterAddr,
      SportsCREOracle(sportsOracleAddr),
      keystoneForwarder
    );

    // Grant RESOLUTION_ADMIN_ROLE so resolver can call NegRiskAdapter.resolveEvent()
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), address(resolver));

    vm.stopBroadcast();

    console.log("SportsCRENegRiskResolver:", address(resolver));
    console.log("RESOLUTION_ADMIN_ROLE granted");
  }
}
