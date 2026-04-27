// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {NegRiskAdapter} from "../contracts/NegRiskAdapter.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Creates a neg-risk event with one SportsCREOracle-backed market per outcome.
///         Each per-outcome market is initialized with its OddsPapi externalRef.
///
///         Env vars (required):
///           PRIVATE_KEY          — signer (must have MARKET_ADMIN_ROLE)
///           NEG_RISK_ADAPTER     — NegRiskAdapter address
///           CLOB_FEE_MODULE      — FeeModule address (used per-market)
///           SPORTS_ORACLE        — SportsCREOracle address
///           CLOSES_AT            — unix timestamp when all outcome markets close
///           OUTCOMES             — comma-separated outcome names
///           EXTERNAL_REFS        — comma-separated OddsPapi refs (one per outcome,
///                                  same order as OUTCOMES)
///           QUESTION             — parent event question
///
///         Env vars (optional):
///           IMAGE                — IPFS hash or URL (default: "")
contract CreateSportsNegRiskEvent is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address adapterAddr = vm.envAddress("NEG_RISK_ADAPTER");
    address feeModule = vm.envAddress("CLOB_FEE_MODULE");
    address oracle = vm.envAddress("SPORTS_ORACLE");
    uint256 closesAt = vm.envUint("CLOSES_AT");
    string memory outcomesRaw = vm.envString("OUTCOMES");
    string memory refsRaw = vm.envString("EXTERNAL_REFS");
    string memory eventQuestion = vm.envString("QUESTION");
    string memory image = vm.envOr("IMAGE", string(""));

    string[] memory outcomes = _split(outcomesRaw, ",");
    string[] memory refs = _split(refsRaw, ",");
    require(outcomes.length >= 2, "need >= 2 outcomes");
    require(outcomes.length == refs.length, "outcomes != refs count");

    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](outcomes.length);

    for (uint256 i = 0; i < outcomes.length; i++) {
      params[i] = PredictionMarketV3ManagerCLOB.CreateMarketParams({
        closesAt: closesAt,
        question: outcomes[i],
        image: image,
        feeModule: feeModule,
        oracle: oracle,
        oracleData: abi.encode(refs[i])
      });
    }

    vm.startBroadcast(privateKey);
    bytes32 eventId = NegRiskAdapter(adapterAddr).createEvent(eventQuestion, params);
    vm.stopBroadcast();

    console.log("Sports neg-risk event created:");
    console.logBytes32(eventId);
    console.log("Outcomes:", outcomes.length);
    for (uint256 i = 0; i < outcomes.length; i++) {
      console.log("  ", outcomes[i], "->", refs[i]);
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
