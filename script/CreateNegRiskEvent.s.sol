// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {NegRiskAdapter} from "../contracts/NegRiskAdapter.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Creates a neg-risk event with all named outcomes via the NegRiskAdapter.
///
///         Signing: use an encrypted keystore account, never a plaintext key —
///           cast wallet import <name> --interactive   # one-time
///           forge script ... --account <name> --sender <addr>
///         The signer must have MARKET_ADMIN_ROLE.
///
///         Env vars (required):
///           NEG_RISK_ADAPTER     — NegRiskAdapter address
///           CLOB_FEE_MODULE      — FeeModule address (used per-market)
///           CLOSES_AT            — unix timestamp when all outcome markets close
///           OUTCOMES             — comma-separated outcome names (e.g. "Trump,Harris,Biden")
///           QUESTION             — parent event question
///
///         Env vars (optional):
///           IMAGE                — IPFS hash or URL (default: "")
///           ORACLE               — oracle contract address (default: address(0))
contract CreateNegRiskEvent is Script {
  function run() external {
    address adapterAddr = vm.envAddress("NEG_RISK_ADAPTER");
    address feeModule = vm.envAddress("CLOB_FEE_MODULE");
    uint256 closesAt = vm.envUint("CLOSES_AT");
    string memory outcomesRaw = vm.envString("OUTCOMES");
    string memory eventQuestion = vm.envString("QUESTION");
    string memory image = vm.envOr("IMAGE", string(""));
    address oracle = vm.envOr("ORACLE", address(0));

    string[] memory outcomes = _split(outcomesRaw, ",");
    require(outcomes.length >= 2, "need >= 2 outcomes");

    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](outcomes.length);
    for (uint256 i = 0; i < outcomes.length; i++) {
      params[i] = PredictionMarketV3ManagerCLOB.CreateMarketParams({
        closesAt: closesAt,
        question: outcomes[i],
        image: image,
        feeModule: feeModule,
        oracle: oracle,
        oracleData: ""
      });
    }

    // Signer comes from the --account keystore; no private key in env.
    vm.startBroadcast();
    bytes32 eventId = NegRiskAdapter(adapterAddr).createEvent(eventQuestion, params);
    vm.stopBroadcast();

    console.log("Event created:");
    console.logBytes32(eventId);
    console.log("Outcomes:", outcomes.length);
    for (uint256 i = 0; i < outcomes.length; i++) {
      console.log("  Outcome", i, ":", outcomes[i]);
    }
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
