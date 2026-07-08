// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OTCExchange} from "../contracts/OTCExchange.sol";
import {OTCQuerier} from "../contracts/OTCQuerier.sol";

/**
 * @title DeployOTCExchange
 * @notice Deploys OTCExchange (and its read-only OTCQuerier lens) to BNB Chain and
 *         wires the initial config in one broadcast. The deployer is the temporary
 *         admin so it can run the config calls; if FINAL_ADMIN differs from the
 *         deployer, roles are handed over and the deployer renounces its own roles
 *         at the end.
 *
 * Required env vars:
 *   PRIVATE_KEY        deployer key (the deployer becomes the temporary admin)
 *   FEE_RECIPIENT      address that receives withdrawn fees
 *   FEE_BPS            initial fee in basis points (e.g. 100 = 1%, 0 = no fee)
 *   CONDITIONAL_TOKEN  Myriad conditional-token (ERC-1155) address
 *                      e.g. 0x6413734f92248D4B29ae35883290BD93212654Dc
 *   MARKET_MANAGER     Myriad market manager address (resolution source, CLOB);
 *                      must equal CONDITIONAL_TOKEN.manager() — asserted on-chain
 *   COLLATERAL         collateral token allowed as payment (more can be added
 *                      later via setCollateralAllowed)
 *
 * Optional env vars:
 *   FINAL_ADMIN        multisig/owner to hold roles after setup (defaults to deployer)
 *
 * Example:
 *   forge script script/DeployOTCExchange.s.sol:DeployOTCExchange \
 *     --rpc-url $BSC_RPC --broadcast --verify
 */
contract DeployOTCExchange is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envUint("FEE_BPS");
        address conditionalToken = vm.envAddress("CONDITIONAL_TOKEN");
        address marketManager = vm.envAddress("MARKET_MANAGER");
        address collateral = vm.envAddress("COLLATERAL");
        address finalAdmin = vm.envOr("FINAL_ADMIN", deployer);

        vm.startBroadcast(pk);

        // Deploy with the deployer as initial admin so the config calls below pass.
        OTCExchange otc = new OTCExchange(deployer, feeRecipient, feeBps);

        otc.allowConditionalToken(conditionalToken, marketManager);
        otc.setCollateralAllowed(collateral, true);

        // Read-only lens for order discovery (no roles, no funds).
        OTCQuerier querier = new OTCQuerier(otc);

        // Hand over control if a separate admin was specified.
        if (finalAdmin != deployer) {
            otc.grantRole(otc.DEFAULT_ADMIN_ROLE(), finalAdmin);
            otc.grantRole(otc.ADMIN_ROLE(), finalAdmin);
            otc.renounceRole(otc.ADMIN_ROLE(), deployer);
            otc.renounceRole(otc.DEFAULT_ADMIN_ROLE(), deployer);
        }

        vm.stopBroadcast();

        console2.log("OTCExchange deployed at:", address(otc));
        console2.log("OTCQuerier deployed at:", address(querier));
        console2.log("Admin:", finalAdmin);
        console2.log("Fee recipient:", feeRecipient);
        console2.log("Fee bps:", feeBps);
    }
}
