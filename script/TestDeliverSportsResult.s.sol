// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SportsCREOracle} from "../contracts/oracles/SportsCREOracle.sol";

/// @notice Delivers a test sports result to SportsCREOracle, simulating what the
///         CRE workflow does. Your deployer wallet must be the KeystoneForwarder.
///
///         Required env vars:
///           PRIVATE_KEY       — deployer private key (must match KeystoneForwarder)
///           SPORTS_ORACLE     — SportsCREOracle address
///           EXTERNAL_REFS     — comma-separated externalRefs
///                               (e.g. "oddspapi:id1100013262926181:1:2,oddspapi:id999:4:10")
///           OUTCOME_IDS       — comma-separated outcomes (0=YES, 1=NO, -1=VOIDED)
contract TestDeliverSportsResult is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address oracleAddr = vm.envAddress("SPORTS_ORACLE");

    SportsCREOracle oracle = SportsCREOracle(oracleAddr);

    // Build metadata matching the oracle's expected workflow identity
    bytes32 execId = keccak256("test-exec");
    bytes32 workflowId = oracle.allowedWorkflowId();
    bytes32 workflowName = oracle.allowedWorkflowName();
    address workflowOwner = oracle.allowedWorkflowOwner();
    bytes memory metadata = abi.encode(execId, workflowId, workflowName, bytes32(bytes20(workflowOwner)));

    string[] memory refs = _split(vm.envString("EXTERNAL_REFS"), ",");
    string[] memory outcomeStrs = _split(vm.envString("OUTCOME_IDS"), ",");
    require(refs.length == outcomeStrs.length, "length mismatch");

    int256[] memory outcomes = new int256[](refs.length);
    for (uint256 i = 0; i < refs.length; i++) {
      outcomes[i] = vm.parseInt(outcomeStrs[i]);
    }

    bytes memory report = abi.encode(refs, outcomes);

    console.log("Delivering sports results:", refs.length);
    console.log("SportsCREOracle:", oracleAddr);
    for (uint256 i = 0; i < refs.length; i++) {
      console.log("  Ref:", refs[i]);
      console.log("  Outcome:", uint256(outcomes[i]));
    }

    vm.startBroadcast(privateKey);
    oracle.onReport(metadata, report);
    vm.stopBroadcast();

    console.log("Results delivered!");
  }

  function _split(string memory str, string memory delimiter) internal pure returns (string[] memory) {
    bytes memory strBytes = bytes(str);
    bytes1 delim = bytes(delimiter)[0];

    uint256 count = 1;
    for (uint256 i = 0; i < strBytes.length; i++) {
      if (strBytes[i] == delim) count++;
    }

    string[] memory parts = new string[](count);
    uint256 partIdx;
    uint256 start;

    for (uint256 i = 0; i <= strBytes.length; i++) {
      if (i == strBytes.length || strBytes[i] == delim) {
        uint256 len = i - start;
        bytes memory part = new bytes(len);
        for (uint256 j = 0; j < len; j++) {
          part[j] = strBytes[start + j];
        }
        parts[partIdx] = string(part);
        partIdx++;
        start = i + 1;
      }
    }

    return parts;
  }
}
