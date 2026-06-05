// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AdminRegistry} from "../contracts/AdminRegistry.sol";
import {SportsCREOracle} from "../contracts/oracles/SportsCREOracle.sol";

/// @notice Standalone SportsCREOracle deployment.
///
///         Required env vars:
///           PRIVATE_KEY            — deployer private key
///           ADMIN_REGISTRY         — AdminRegistry address
///           CLOB_MANAGER           — PredictionMarketV3ManagerCLOB address
///           KEYSTONE_FORWARDER     — Chainlink KeystoneForwarder address
///
///         Workflow identity (author + name) is configured POST-deploy via
///         setExpectedAuthor / setExpectedWorkflowName from MARKET_ADMIN_ROLE.
contract DeploySportsCREOracle is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address registry = vm.envAddress("ADMIN_REGISTRY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address keystoneForwarder = vm.envAddress("KEYSTONE_FORWARDER");

    vm.startBroadcast(privateKey);

    SportsCREOracle sportsOracle = new SportsCREOracle(
      AdminRegistry(registry),
      managerAddr,
      keystoneForwarder
    );

    vm.stopBroadcast();

    console.log("SportsCREOracle:", address(sportsOracle));
  }
}
