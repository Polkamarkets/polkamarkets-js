// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CREOracle} from "../contracts/oracles/CREOracle.sol";

/// @notice Standalone CREOracle deployment.
///
///         Required env vars:
///           PRIVATE_KEY            — deployer private key
///           CLOB_MANAGER           — PredictionMarketV3ManagerCLOB address
///           KEYSTONE_FORWARDER     — Chainlink KeystoneForwarder address
///           CRE_WORKFLOW_ID        — bytes32 workflow ID
///           CRE_WORKFLOW_NAME      — bytes32 workflow name (bytes10 padded)
///           CRE_WORKFLOW_OWNER     — address of workflow owner
contract DeployCREOracle is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address keystoneForwarder = vm.envAddress("KEYSTONE_FORWARDER");
    bytes32 creWorkflowId = vm.envBytes32("CRE_WORKFLOW_ID");
    bytes32 creWorkflowName = vm.envBytes32("CRE_WORKFLOW_NAME");
    address creWorkflowOwner = vm.envAddress("CRE_WORKFLOW_OWNER");

    vm.startBroadcast(privateKey);

    CREOracle creOracle = new CREOracle(
      managerAddr,
      keystoneForwarder,
      creWorkflowId,
      creWorkflowName,
      creWorkflowOwner
    );

    vm.stopBroadcast();

    console.log("CREOracle:", address(creOracle));
  }
}
