// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Creates a CLOB market with an optional oracle (Realitio or CRE).
///
///         Env vars (required):
///           PRIVATE_KEY    — signer (must have MARKET_ADMIN_ROLE)
///           CLOB_MANAGER   — manager address
///           CLOB_FEE_MODULE — fee module address
///           CLOSES_AT      — unix timestamp when the market closes
///           QUESTION       — market question text
///
///         Env vars (optional):
///           IMAGE          — IPFS hash or URL (default: "")
///           ORACLE         — oracle contract address (default: address(0) = no oracle)
///           ORACLE_TYPE    — "realitio", "cre", or "none" (default: "none")
///
///         Realitio-specific env vars:
///           ARBITRATOR       — Reality.eth arbitrator address
///           REALITIO_TIMEOUT — timeout in seconds (default: 3600)
///
///         CRE-specific env vars:
///           FEED_ID          — price feed pair (e.g. "BTCUSDT")
///           FEED_ID_B        — second feed for RELATIVE rule (default: "")
///           RULE_TYPE        — 0=THRESHOLD, 1=DIRECTION, 2=CHANGE_PCT, 3=RELATIVE, 4=HIT
///           YES_ABOVE        — "true" or "false"
///           PARAM            — price (THRESHOLD/HIT) or bps (CHANGE_PCT), 0 otherwise
///           OPEN_TIMESTAMP   — start timestamp for DIRECTION/CHANGE_PCT/RELATIVE (default: 0)
contract CreateCLOBMarket is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address feeModule = vm.envAddress("CLOB_FEE_MODULE");
    uint256 closesAt = vm.envUint("CLOSES_AT");
    string memory question = vm.envString("QUESTION");
    string memory image = vm.envOr("IMAGE", string(""));

    address oracle = vm.envOr("ORACLE", address(0));
    string memory oracleType = vm.envOr("ORACLE_TYPE", string("none"));

    bytes memory oracleData;

    if (keccak256(bytes(oracleType)) == keccak256(bytes("realitio"))) {
      address arbitrator = vm.envAddress("ARBITRATOR");
      uint32 timeout = uint32(vm.envOr("REALITIO_TIMEOUT", uint256(3600)));
      oracleData = abi.encode(question, arbitrator, timeout, uint32(closesAt));
    } else if (keccak256(bytes(oracleType)) == keccak256(bytes("cre"))) {
      string memory feedIdStr = vm.envString("FEED_ID");
      string memory feedIdBStr = vm.envOr("FEED_ID_B", string(""));
      uint8 ruleType = uint8(vm.envUint("RULE_TYPE"));
      bool yesAbove = vm.envBool("YES_ABOVE");
      int256 param = vm.envOr("PARAM", int256(0));
      uint256 openTimestamp = vm.envOr("OPEN_TIMESTAMP", uint256(0));

      bytes32 feedId = keccak256(bytes(feedIdStr));
      bytes32 feedIdB = bytes(feedIdBStr).length > 0 ? keccak256(bytes(feedIdBStr)) : bytes32(0);

      oracleData = abi.encode(feedId, feedIdB, ruleType, yesAbove, param, openTimestamp);
    }

    vm.startBroadcast(privateKey);

    uint256 marketId = PredictionMarketV3ManagerCLOB(managerAddr).createMarket(
      PredictionMarketV3ManagerCLOB.CreateMarketParams({
        closesAt: closesAt,
        question: question,
        image: image,
        feeModule: feeModule,
        oracle: oracle,
        oracleData: oracleData
      })
    );

    vm.stopBroadcast();

    console.log("Market created with ID:", marketId);
    console.log("Oracle:", oracle);
    console.log("Oracle type:", oracleType);
  }
}
