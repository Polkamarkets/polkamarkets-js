// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SportsCRENegRiskResolver} from "../contracts/oracles/SportsCRENegRiskResolver.sol";

/// @notice Configures a sports neg-risk event with one externalRef per outcome.
///
///         Required env vars:
///           PRIVATE_KEY                  — signer (must have MARKET_ADMIN_ROLE)
///           SPORTS_NEG_RISK_RESOLVER     — SportsCRENegRiskResolver address
///           EVENT_ID                     — bytes32 event identifier
///           EXTERNAL_REFS                — comma-separated list of OddsPapi refs
///                                          (one per outcome, in the same order)
///
///         Example EXTERNAL_REFS:
///           "oddspapi:id123:1:2,oddspapi:id123:1:3,oddspapi:id123:1:4,oddspapi:id123:1:5"
contract ConfigureSportsEvent is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address resolverAddr = vm.envAddress("SPORTS_NEG_RISK_RESOLVER");
    bytes32 eventId = vm.envBytes32("EVENT_ID");
    string memory raw = vm.envString("EXTERNAL_REFS");

    string[] memory refs = _split(raw, ",");
    require(refs.length > 0, "no refs provided");

    SportsCRENegRiskResolver resolver = SportsCRENegRiskResolver(resolverAddr);

    vm.startBroadcast(privateKey);
    resolver.configureEvent(eventId, refs);
    vm.stopBroadcast();

    console.log("Sports event configured:");
    console.logBytes32(eventId);
    console.log("Outcomes:", refs.length);
    for (uint256 i = 0; i < refs.length; i++) {
      console.log("  Outcome", i, ":", refs[i]);
    }
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
