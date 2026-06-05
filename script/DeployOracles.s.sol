// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IRealityETH_ERC20} from "../contracts/IRealityETH_ERC20.sol";
import {RealitioOracle} from "../contracts/oracles/RealitioOracle.sol";

/// @notice Deploys the RealitioOracle for use with PredictionMarketV3ManagerCLOB.
///
///         Required env vars:
///           PRIVATE_KEY        — deployer private key
///           CLOB_MANAGER       — address of the deployed PredictionMarketV3ManagerCLOB
///           REALITIO_ERC20     — Reality.eth contract address
contract DeployOracles is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address managerAddr = vm.envAddress("CLOB_MANAGER");
    address realitioAddr = vm.envAddress("REALITIO_ERC20");

    vm.startBroadcast(privateKey);

    RealitioOracle realitioOracle = new RealitioOracle(
      IRealityETH_ERC20(realitioAddr),
      managerAddr
    );

    vm.stopBroadcast();

    console.log("RealitioOracle:", address(realitioOracle));
  }
}
