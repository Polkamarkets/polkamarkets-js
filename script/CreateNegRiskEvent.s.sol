// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {NegRiskAdapter} from "../contracts/NegRiskAdapter.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Creates a neg-risk event with all named outcomes via the NegRiskAdapter.
///         Each constituent market carries per-market oracle config encoded in
///         `oracleData` so it resolves independently — see `EVENT_RULE_TYPE` modes.
///
///         Common env vars (required):
///           PRIVATE_KEY          — signer (must have MARKET_ADMIN_ROLE)
///           NEG_RISK_ADAPTER     — NegRiskAdapter address
///           CLOB_FEE_MODULE      — FeeModule address (used per-market)
///           CLOSES_AT            — unix timestamp when all outcome markets close
///           OUTCOMES             — comma-separated outcome names (e.g. "Trump,Harris,Biden")
///           QUESTION             — parent event question
///
///         Common env vars (optional):
///           IMAGE                — IPFS hash or URL (default: "")
///           ORACLE               — oracle contract address (default: address(0))
///           EVENT_RULE_TYPE      — 0=NONE (uniform empty oracleData),
///                                  1=RANGE       (CryptoCREOracle, RANGE_BUCKET on close),
///                                  2=HIT_MILESTONES (CryptoCREOracle, RANGE_BUCKET_HIGH on high),
///                                  3=BEST_PERFORMER (CryptoCREOracle, BEST_PERFORMER_OUTCOME)
///                                  default: 0
///
///         RANGE / HIT_MILESTONES env vars:
///           FEED_ID              — feed pair name (e.g. "BTCUSDT")
///           BOUNDARIES           — N-1 sorted ascending int256 boundaries
///                                  (8-decimal fixed point), comma-separated
///                                  Defines N buckets:
///                                    bucket 0 : [int256.min, b0)
///                                    bucket i : [b_{i-1}, b_i)   (1 <= i <= N-2)
///                                    bucket N-1: [b_{N-2}, int256.max)
///
///         BEST_PERFORMER env vars:
///           FEED_IDS             — comma-separated feed pair names, one per outcome
///                                  (e.g. "BTCUSDT,ETHUSDT,SOLUSDT,DOGEUSDT")
///           OPEN_TIMESTAMP       — unix timestamp at which open prices are sampled
contract CreateNegRiskEvent is Script {
  // CryptoCREOracle.RuleType values (kept here as constants to avoid the
  // dependency on the oracle's own enum for callers that compile alone)
  uint8 internal constant RULE_HIT = 4;
  uint8 internal constant RULE_RANGE_BUCKET = 7;
  uint8 internal constant RULE_BEST_PERFORMER_OUTCOME = 8;
  uint8 internal constant RULE_RANGE_BUCKET_HIGH = 9;

  // EVENT_RULE_TYPE values
  uint8 internal constant EVENT_NONE = 0;
  uint8 internal constant EVENT_RANGE = 1;
  uint8 internal constant EVENT_HIT_MILESTONES = 2;
  uint8 internal constant EVENT_BEST_PERFORMER = 3;

  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address adapterAddr = vm.envAddress("NEG_RISK_ADAPTER");
    address feeModule = vm.envAddress("CLOB_FEE_MODULE");
    uint256 closesAt = vm.envUint("CLOSES_AT");
    string memory outcomesRaw = vm.envString("OUTCOMES");
    string memory eventQuestion = vm.envString("QUESTION");
    string memory image = vm.envOr("IMAGE", string(""));
    address oracle = vm.envOr("ORACLE", address(0));
    uint8 eventRuleType = uint8(vm.envOr("EVENT_RULE_TYPE", uint256(EVENT_NONE)));

    string[] memory outcomes = _split(outcomesRaw, ",");
    require(outcomes.length >= 2, "need >= 2 outcomes");

    bytes[] memory perMarketOracleData = _buildOracleData(eventRuleType, outcomes.length);

    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](outcomes.length);
    for (uint256 i = 0; i < outcomes.length; i++) {
      params[i] = PredictionMarketV3ManagerCLOB.CreateMarketParams({
        closesAt: closesAt,
        question: outcomes[i],
        image: image,
        feeModule: feeModule,
        oracle: oracle,
        oracleData: perMarketOracleData[i]
      });
    }

    vm.startBroadcast(privateKey);
    bytes32 eventId = NegRiskAdapter(adapterAddr).createEvent(eventQuestion, params);
    vm.stopBroadcast();

    console.log("Event created:");
    console.logBytes32(eventId);
    console.log("Outcomes:", outcomes.length);
    console.log("Event rule type:", eventRuleType);
    for (uint256 i = 0; i < outcomes.length; i++) {
      console.log("  Outcome", i, ":", outcomes[i]);
    }
  }

  function _buildOracleData(uint8 eventRuleType, uint256 n)
    internal
    view
    returns (bytes[] memory data)
  {
    data = new bytes[](n);

    if (eventRuleType == EVENT_NONE) {
      for (uint256 i = 0; i < n; i++) data[i] = "";
      return data;
    }

    if (eventRuleType == EVENT_RANGE || eventRuleType == EVENT_HIT_MILESTONES) {
      string memory feedIdRaw = vm.envString("FEED_ID");
      bytes32 feedId = keccak256(bytes(feedIdRaw));

      string memory boundariesRaw = vm.envString("BOUNDARIES");
      string[] memory boundaryStrs = _split(boundariesRaw, ",");
      require(boundaryStrs.length == n - 1, "BOUNDARIES count must equal outcomes-1");

      int256[] memory boundaries = new int256[](n - 1);
      for (uint256 i = 0; i < n - 1; i++) {
        boundaries[i] = vm.parseInt(boundaryStrs[i]);
        if (i > 0) {
          require(boundaries[i] > boundaries[i - 1], "boundaries not ascending");
        }
      }

      uint8 rule = eventRuleType == EVENT_RANGE ? RULE_RANGE_BUCKET : RULE_RANGE_BUCKET_HIGH;

      for (uint256 i = 0; i < n; i++) {
        int256 lower = i == 0 ? type(int256).min : boundaries[i - 1];
        int256 upper = i == n - 1 ? type(int256).max : boundaries[i];
        data[i] = abi.encode(
          feedId,         // feedId
          bytes32(0),     // feedIdB
          rule,           // ruleRaw
          true,           // yesAbove (unused by RANGE_BUCKET*; harmless)
          lower,          // param = lowerBound
          uint256(0),     // openTimestamp (unused for RANGE_BUCKET*)
          upper,          // paramB = upperBound
          uint256(0),     // interval (unused)
          uint8(0),       // dataSourceRaw (AUTO)
          uint8(0)        // binanceIntervalRaw (1m)
        );
      }
      return data;
    }

    if (eventRuleType == EVENT_BEST_PERFORMER) {
      string memory feedIdsRaw = vm.envString("FEED_IDS");
      uint256 openTimestamp = vm.envUint("OPEN_TIMESTAMP");
      require(openTimestamp > 0, "OPEN_TIMESTAMP required");

      string[] memory feedNames = _split(feedIdsRaw, ",");
      require(feedNames.length == n, "FEED_IDS count must equal outcomes");

      bytes32[] memory feedIds = new bytes32[](n);
      for (uint256 i = 0; i < n; i++) feedIds[i] = keccak256(bytes(feedNames[i]));

      for (uint256 i = 0; i < n; i++) {
        bytes32[] memory peers = new bytes32[](n - 1);
        uint256 p;
        for (uint256 j = 0; j < n; j++) {
          if (j == i) continue;
          peers[p++] = feedIds[j];
        }
        data[i] = abi.encode(
          feedIds[i],            // myFeedId
          bytes32(0),            // unused
          RULE_BEST_PERFORMER_OUTCOME,
          peers,
          openTimestamp,
          uint8(0),              // dataSourceRaw (AUTO)
          uint8(0)               // binanceIntervalRaw (1m)
        );
      }
      return data;
    }

    revert("unknown EVENT_RULE_TYPE");
  }

  /// @dev Simple comma splitter. Allocates worst-case array and fills.
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
