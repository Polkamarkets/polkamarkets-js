// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdminRegistry} from "../contracts/AdminRegistry.sol";
import {PredictionMarketV3ManagerCLOB} from "../contracts/PredictionMarketV3ManagerCLOB.sol";
import {ConditionalTokens} from "../contracts/ConditionalTokens.sol";
import {MyriadCTFExchange} from "../contracts/MyriadCTFExchange.sol";
import {FeeModule} from "../contracts/FeeModule.sol";
import {IMyriadMarketManager} from "../contracts/IMyriadMarketManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys the core CLOB stack via UUPS proxies.
///         Manager, FeeModule, and Exchange are deployed behind ERC1967 proxies.
///         ConditionalTokens is deployed directly (holds user funds, no proxy).
///
///         When ADMIN differs from the deployer, the deployer is used as the
///         initial registry admin so it can perform all setup (setExchange,
///         grantRole). After setup it calls proposeAdmin(ADMIN); the ADMIN
///         wallet must then call acceptAdmin() to complete the transfer, which
///         atomically revokes every role from the deployer.
///
///         Env vars:
///           PRIVATE_KEY      — deployer private key
///           COLLATERAL       — ERC20 collateral token address
///           ADMIN            — admin address (default: deployer)
///           ADMIN_REGISTRY   — existing AdminRegistry (default: deploy new one)
///           OPERATOR         — operator address (default: admin)
///           TREASURY         — fee treasury address (default: admin)
contract DeployCLOB is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(privateKey);

    address admin = vm.envOr("ADMIN", deployer);
    address collateral = vm.envAddress("COLLATERAL");
    address adminRegistryAddr = vm.envOr("ADMIN_REGISTRY", address(0));
    address operator = vm.envOr("OPERATOR", admin);
    address treasuryAddr = vm.envOr("TREASURY", admin);

    bool deployRegistry = adminRegistryAddr == address(0);
    bool transferAdmin = admin != deployer;

    vm.startBroadcast(privateKey);

    // Always deploy registry with deployer as initial admin so we can
    // call setExchange / grantRole. Admin is transferred at the end.
    if (deployRegistry) {
      adminRegistryAddr = address(new AdminRegistry(deployer));
    }

    AdminRegistry registry = AdminRegistry(adminRegistryAddr);

    // Deploy Manager (UUPS proxy)
    PredictionMarketV3ManagerCLOB managerImpl = new PredictionMarketV3ManagerCLOB();
    ERC1967Proxy managerProxy = new ERC1967Proxy(
      address(managerImpl),
      abi.encodeCall(PredictionMarketV3ManagerCLOB.initialize, (registry, IERC20(collateral)))
    );
    PredictionMarketV3ManagerCLOB manager = PredictionMarketV3ManagerCLOB(address(managerProxy));

    // Deploy ConditionalTokens (no proxy — holds user funds)
    ConditionalTokens conditionalTokens = new ConditionalTokens(registry, IMyriadMarketManager(address(manager)));

    // Deploy FeeModule (UUPS proxy)
    FeeModule feeModuleImpl = new FeeModule();
    ERC1967Proxy feeModuleProxy = new ERC1967Proxy(
      address(feeModuleImpl),
      abi.encodeCall(FeeModule.initialize, (registry, treasuryAddr))
    );
    FeeModule feeModuleContract = FeeModule(address(feeModuleProxy));

    // Deploy Exchange (UUPS proxy)
    MyriadCTFExchange exchangeImpl = new MyriadCTFExchange();
    ERC1967Proxy exchangeProxy = new ERC1967Proxy(
      address(exchangeImpl),
      abi.encodeCall(MyriadCTFExchange.initialize, (
        IMyriadMarketManager(address(manager)),
        conditionalTokens,
        address(feeModuleContract),
        registry
      ))
    );
    MyriadCTFExchange exchange = MyriadCTFExchange(address(exchangeProxy));

    feeModuleContract.setExchange(address(exchange));

    registry.grantRole(registry.MARKET_ADMIN_ROLE(), admin);
    registry.grantRole(registry.FEE_ADMIN_ROLE(), admin);
    registry.grantRole(registry.OPERATOR_ROLE(), operator);
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), admin);

    // Transfer DEFAULT_ADMIN_ROLE to the intended admin via two-step handoff.
    // The admin wallet must call registry.acceptAdmin() to complete the transfer,
    // which atomically revokes all roles from the deployer.
    if (transferAdmin) {
      registry.proposeAdmin(admin);
      console.log("");
      console.log("!! Admin transfer initiated. The ADMIN wallet must call");
      console.log("!! AdminRegistry.acceptAdmin() to complete the handoff.");
      console.log("!! Until then, the deployer retains DEFAULT_ADMIN_ROLE.");
    }

    vm.stopBroadcast();

    console.log("AdminRegistry:", adminRegistryAddr);
    console.log("Manager:", address(manager));
    console.log("Manager impl:", address(managerImpl));
    console.log("ConditionalTokens:", address(conditionalTokens));
    console.log("FeeModule:", address(feeModuleContract));
    console.log("FeeModule impl:", address(feeModuleImpl));
    console.log("Exchange:", address(exchange));
    console.log("Exchange impl:", address(exchangeImpl));
  }
}
