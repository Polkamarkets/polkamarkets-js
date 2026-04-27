// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SportsCREOracle} from "../contracts/oracles/SportsCREOracle.sol";

/// @notice Standalone SportsCREOracle deployment.
///
///         Required env vars:
///           PRIVATE_KEY            — deployer private key
///           CLOB_MANAGER           — PredictionMarketV3ManagerCLOB address
///           KEYSTONE_FORWARDER     — Chainlink KeystoneForwarder address
///           CRE_SPORTS_WORKFLOW_ID        — bytes32 workflow ID
///           CRE_SPORTS_WORKFLOW_NAME      — bytes32 workflow name (bytes10 padded)
///           CRE_SPORTS_WORKFLOW_OWNER     — address of workflow owner
contract DeploySportsCREOracle is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address keystoneForwarder = vm.envAddress("KEYSTONE_FORWARDER");
    bytes32 workflowId = vm.envBytes32("CRE_SPORTS_WORKFLOW_ID");
    bytes32 workflowName = vm.envBytes32("CRE_SPORTS_WORKFLOW_NAME");
    address workflowOwner = vm.envAddress("CRE_SPORTS_WORKFLOW_OWNER");

    vm.startBroadcast(privateKey);

    SportsCREOracle sportsOracle = new SportsCREOracle(
      managerAddr,
      keystoneForwarder,
      workflowId,
      workflowName,
      workflowOwner
    );

    vm.stopBroadcast();

    console.log("SportsCREOracle:", address(sportsOracle));
  }
}
