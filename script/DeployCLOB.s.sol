// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {AdminRegistry} from "../contracts/AdminRegistry.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";
import {ConditionalTokens} from "../contracts/ConditionalTokens.sol";
import {MyriadCTFExchange} from "../contracts/MyriadCTFExchange.sol";
import {FeeModule} from "../contracts/FeeModule.sol";
import {IMyriadMarketManager} from "../contracts/IMyriadMarketManager.sol";
import {IRealityETH_ERC20} from "../contracts/IRealityETH_ERC20.sol";
import {RealityETH_ERC20_v3_0} from "@reality.eth/contracts/development/contracts/RealityETH_ERC20-3.0.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployCLOB is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(privateKey);

    address admin = vm.envOr("ADMIN", deployer);
    address collateral = vm.envAddress("COLLATERAL");
    address realitio = vm.envOr("REALITIO_ERC20", address(0));
    address adminRegistryAddr = vm.envOr("ADMIN_REGISTRY", address(0));
    address treasury = vm.envOr("TREASURY", admin);
    address distributor = vm.envOr("DISTRIBUTOR", admin);
    address network = vm.envOr("NETWORK", admin);
    address operator = vm.envOr("OPERATOR", admin);

    bool deployRegistry = adminRegistryAddr == address(0);
    bool deployRealitio = realitio == address(0);

    // Count every transaction before the Exchange deployment to predict its CREATE address.
    //   Base (always): Manager + ConditionalTokens + FeeModule = 3 txns before Exchange
    //   +1 if deploying AdminRegistry
    //   +2 if deploying RealityETH (deployment tx + setToken tx)
    uint256 nonce = vm.getNonce(deployer);
    uint256 exchangeOffset = 3;
    if (deployRegistry) exchangeOffset += 1;
    if (deployRealitio) exchangeOffset += 2;
    address predictedExchange = vm.computeCreateAddress(deployer, nonce + exchangeOffset);

    vm.startBroadcast(privateKey);

    if (deployRegistry) {
      adminRegistryAddr = address(new AdminRegistry(admin));
    }

    AdminRegistry registry = AdminRegistry(adminRegistryAddr);

    if (realitio == address(0)) {
      RealityETH_ERC20_v3_0 realitioInstance = new RealityETH_ERC20_v3_0();
      realitio = address(realitioInstance);
      IRealityETH_ERC20(realitio).setToken(collateral);
    }

    PredictionMarketV3ManagerCLOB manager = new PredictionMarketV3ManagerCLOB(
      registry,
      IRealityETH_ERC20(realitio),
      IERC20(collateral)
    );
    ConditionalTokens conditionalTokens = new ConditionalTokens(registry, IMyriadMarketManager(address(manager)));
    FeeModule feeModule = new FeeModule(registry, MyriadCTFExchange(predictedExchange));
    MyriadCTFExchange exchange = new MyriadCTFExchange(IMyriadMarketManager(address(manager)), conditionalTokens, address(feeModule));

    conditionalTokens.setExchange(address(exchange));

    registry.grantRole(registry.MARKET_ADMIN_ROLE(), admin);
    registry.grantRole(registry.FEE_ADMIN_ROLE(), admin);
    registry.grantRole(registry.OPERATOR_ROLE(), operator);
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), admin);

    feeModule.setFeeRecipients(treasury, distributor, network);
    feeModule.setFeeSplit(5000, 3000, 2000);

    vm.stopBroadcast();

    console.log("AdminRegistry:", adminRegistryAddr);
    console.log("Manager:", address(manager));
    console.log("ConditionalTokens:", address(conditionalTokens));
    console.log("FeeModule:", address(feeModule));
    console.log("Exchange:", address(exchange));
  }
}
