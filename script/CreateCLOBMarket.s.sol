// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";

contract CreateCLOBMarket is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address feeModule = vm.envAddress("CLOB_FEE_MODULE");
    address arbitrator = vm.envAddress("ARBITRATOR");
    uint256 closesAt = vm.envUint("CLOSES_AT");
    string memory question = vm.envString("QUESTION");
    string memory image = vm.envOr("IMAGE", string(""));

    vm.startBroadcast(privateKey);

    PredictionMarketV3ManagerCLOB(managerAddr).createMarket(
      PredictionMarketV3ManagerCLOB.CreateMarketParams({
        closesAt: closesAt,
        question: question,
        image: image,
        arbitrator: arbitrator,
        realitioTimeout: 3600,
        executionMode: PredictionMarketV3ManagerCLOB.ExecutionMode.CLOB,
        feeModule: feeModule
      })
    );

    vm.stopBroadcast();
  }
}
