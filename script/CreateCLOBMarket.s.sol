// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Creates a CLOB market with an optional Realitio oracle.
///
///         Signing: use an encrypted keystore account, never a plaintext key —
///           cast wallet import <name> --interactive   # one-time
///           forge script ... --account <name> --sender <addr>
///         The signer must have MARKET_ADMIN_ROLE.
///
///         Env vars (required):
///           CLOB_MANAGER   — manager address
///           CLOB_FEE_MODULE — fee module address
///           CLOSES_AT      — unix timestamp when the market closes
///           QUESTION       — market question text
///
///         Env vars (optional):
///           IMAGE          — IPFS hash or URL (default: "")
///           ORACLE         — oracle contract address (default: address(0) = no oracle)
///           ORACLE_TYPE    — "realitio" or "none" (default: "none")
///
///         Realitio-specific env vars:
///           ARBITRATOR       — Reality.eth arbitrator address
///           REALITIO_TIMEOUT — timeout in seconds (default: 3600)
contract CreateCLOBMarket is Script {
  function run() external {
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
    }

    // Signer comes from the --account keystore; no private key in env.
    vm.startBroadcast();

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
