// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {FeeModule} from "../contracts/FeeModule.sol";

/// @notice Sets maker/taker fees for a CLOB market.
contract SetCLOBFees is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address feeModule = vm.envAddress("CLOB_FEE_MODULE");
    uint256 marketId = vm.envUint("MARKET_ID");
    uint16 makerFeeBps = uint16(vm.envUint("MAKER_FEE_BPS"));
    uint16 takerFeeBps = uint16(vm.envUint("TAKER_FEE_BPS"));

    vm.startBroadcast(privateKey);
    FeeModule(feeModule).setMarketFees(marketId, makerFeeBps, takerFeeBps);
    vm.stopBroadcast();
  }
}
