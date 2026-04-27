// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IRealityETH_ERC20} from "../contracts/IRealityETH_ERC20.sol";
import {RealitioOracle} from "../contracts/oracles/RealitioOracle.sol";
import {CryptoCREOracle} from "../contracts/oracles/CryptoCREOracle.sol";

/// @notice Deploys oracle contracts for use with PredictionMarketV3ManagerCLOB.
///
///         Required env vars:
///           PRIVATE_KEY        — deployer private key
///           CLOB_MANAGER       — address of the deployed PredictionMarketV3ManagerCLOB
///           REALITIO_ERC20     — Reality.eth contract address
///
///         Optional CRE env vars (set to deploy CryptoCREOracle):
///           KEYSTONE_FORWARDER     — Chainlink KeystoneForwarder address
///           CRE_WORKFLOW_ID        — bytes32 workflow ID
///           CRE_WORKFLOW_NAME      — bytes32 workflow name
///           CRE_WORKFLOW_OWNER     — address of workflow owner
contract DeployOracles is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address realitioAddr = vm.envAddress("REALITIO_ERC20");

    vm.startBroadcast(privateKey);

    RealitioOracle realitioOracle = new RealitioOracle(
      IRealityETH_ERC20(realitioAddr),
      managerAddr
    );

    console.log("RealitioOracle:", address(realitioOracle));

    // Deploy CryptoCREOracle if CRE env vars are set
    address keystoneForwarder = vm.envOr("KEYSTONE_FORWARDER", address(0));
    if (keystoneForwarder != address(0)) {
      bytes32 creWorkflowId = vm.envBytes32("CRE_WORKFLOW_ID");
      bytes32 creWorkflowName = vm.envBytes32("CRE_WORKFLOW_NAME");
      address creWorkflowOwner = vm.envAddress("CRE_WORKFLOW_OWNER");

      CryptoCREOracle creOracle = new CryptoCREOracle(
        managerAddr,
        keystoneForwarder,
        creWorkflowId,
        creWorkflowName,
        creWorkflowOwner
      );

      console.log("CryptoCREOracle:", address(creOracle));
    }

    vm.stopBroadcast();
  }
}
