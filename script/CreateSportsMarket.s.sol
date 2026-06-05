// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

/// @notice Creates a CLOB market backed by the SportsCREOracle.
///
///         Required env vars:
///           PRIVATE_KEY         — signer (must have MARKET_ADMIN_ROLE)
///           CLOB_MANAGER        — manager address
///           CLOB_FEE_MODULE     — fee module address
///           SPORTS_ORACLE       — SportsCREOracle address
///           CLOSES_AT           — unix timestamp when the market closes
///           QUESTION            — market question text
///           EXTERNAL_REF        — OddsPapi reference, e.g. "oddspapi:id1100013262926181:1:2"
///
///         Optional:
///           IMAGE               — IPFS hash or URL (default: "")
contract CreateSportsMarket is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address feeModule = vm.envAddress("CLOB_FEE_MODULE");
    address oracle = vm.envAddress("SPORTS_ORACLE");
    uint256 closesAt = vm.envUint("CLOSES_AT");
    string memory question = vm.envString("QUESTION");
    string memory externalRef = vm.envString("EXTERNAL_REF");
    string memory image = vm.envOr("IMAGE", string(""));

    bytes memory oracleData = abi.encode(externalRef);

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

    console.log("Sports market created with ID:", marketId);
    console.log("ExternalRef:", externalRef);
  }
}
