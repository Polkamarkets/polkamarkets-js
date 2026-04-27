// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CryptoCRENegRiskResolver} from "../contracts/oracles/CryptoCRENegRiskResolver.sol";

/// @notice Configures a neg-risk event for CRE-based resolution.
///
///         Required env vars:
///           PRIVATE_KEY              — signer (must have MARKET_ADMIN_ROLE)
///           CRE_NEG_RISK_RESOLVER    — CryptoCRENegRiskResolver address
///           EVENT_ID                 — bytes32 event identifier
///           EVENT_RULE_TYPE          — 0=RANGE, 1=BEST_PERFORMER, 2=HIT_MILESTONES
///           CLOSES_AT                — uint256 close timestamp
///
///         RANGE / HIT_MILESTONES env vars:
///           FEED_ID                  — price feed pair (e.g. "BTCUSDT")
///           BOUNDARIES               — comma-separated int256 values (e.g. "9000000000000,9500000000000,10000000000000")
///
///         BEST_PERFORMER env vars:
///           FEED_IDS                 — comma-separated feed pairs (e.g. "BTCUSDT,ETHUSDT,SOLUSDT")
///           OPEN_TIMESTAMP           — uint256 start timestamp
contract ConfigureCREEvent is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address resolverAddr = vm.envAddress("CRE_NEG_RISK_RESOLVER");
    bytes32 eventId = vm.envBytes32("EVENT_ID");
    uint8 ruleTypeRaw = uint8(vm.envUint("EVENT_RULE_TYPE"));
    uint256 closesAt = vm.envUint("CLOSES_AT");

    CryptoCRENegRiskResolver.EventRuleType ruleType = CryptoCRENegRiskResolver.EventRuleType(ruleTypeRaw);
    CryptoCRENegRiskResolver resolver = CryptoCRENegRiskResolver(resolverAddr);

    bytes32[] memory feedIds;
    int256[] memory boundaries;
    uint256 openTimestamp = 0;

    if (ruleType == CryptoCRENegRiskResolver.EventRuleType.RANGE || ruleType == CryptoCRENegRiskResolver.EventRuleType.HIT_MILESTONES) {
      string memory feedIdStr = vm.envString("FEED_ID");
      feedIds = new bytes32[](1);
      feedIds[0] = keccak256(bytes(feedIdStr));

      string memory boundariesRaw = vm.envString("BOUNDARIES");
      string[] memory parts = _split(boundariesRaw, ",");
      boundaries = new int256[](parts.length);
      for (uint256 i = 0; i < parts.length; i++) {
        boundaries[i] = vm.parseInt(parts[i]);
      }
    } else if (ruleType == CryptoCRENegRiskResolver.EventRuleType.BEST_PERFORMER) {
      string memory feedIdsRaw = vm.envString("FEED_IDS");
      string[] memory feedParts = _split(feedIdsRaw, ",");
      feedIds = new bytes32[](feedParts.length);
      for (uint256 i = 0; i < feedParts.length; i++) {
        feedIds[i] = keccak256(bytes(feedParts[i]));
      }
      openTimestamp = vm.envUint("OPEN_TIMESTAMP");
      boundaries = new int256[](0);
    }

    vm.startBroadcast(privateKey);

    resolver.configureEvent(eventId, ruleType, feedIds, openTimestamp, closesAt, boundaries);

    vm.stopBroadcast();

    console.log("Event configured:");
    console.logBytes32(eventId);
    console.log("Rule type:", ruleTypeRaw);
    console.log("Feeds:", feedIds.length);
    console.log("Boundaries:", boundaries.length);
  }

  function _split(string memory str, string memory delimiter) internal pure returns (string[] memory) {
    bytes memory strBytes = bytes(str);
    bytes memory delimBytes = bytes(delimiter);
    require(delimBytes.length == 1, "single-char delimiter only");
    bytes1 delim = delimBytes[0];

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
