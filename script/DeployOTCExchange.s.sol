// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OTCExchange} from "../contracts/OTCExchange.sol";
import {OTCQuerier} from "../contracts/OTCQuerier.sol";
import {AdminRegistry} from "../contracts/AdminRegistry.sol";

/**
 * @title DeployOTCExchange
 * @notice Deploys OTCExchange (and its read-only OTCQuerier lens) to BNB Chain.
 *         All initial config is wired through the constructor, so the deployer
 *         needs no roles: governance lives in the shared AdminRegistry from day
 *         one (DEFAULT_ADMIN_ROLE = allow-lists / min order / pause,
 *         FEE_ADMIN_ROLE = fee rate / recipient / withdrawals), and admin
 *         hand-off is the registry's two-step proposeAdmin/acceptAdmin.
 *
 * Required env vars:
 *   PRIVATE_KEY        deployer key (holds no roles on the deployed contract)
 *   ADMIN_REGISTRY     shared AdminRegistry address (same instance as the CLOB stack)
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
 *   MIN_ORDER_AMOUNT   minimum order.tokenAmount (defaults to 0 = no minimum)
 *
 * Example:
 *   forge script script/DeployOTCExchange.s.sol:DeployOTCExchange \
 *     --rpc-url $BSC_RPC --broadcast --verify
 */
contract DeployOTCExchange is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address registry = vm.envAddress("ADMIN_REGISTRY");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envUint("FEE_BPS");
        address conditionalToken = vm.envAddress("CONDITIONAL_TOKEN");
        address marketManager = vm.envAddress("MARKET_MANAGER");
        address collateral = vm.envAddress("COLLATERAL");
        uint256 minOrderAmount = vm.envOr("MIN_ORDER_AMOUNT", uint256(0));

        vm.startBroadcast(pk);

        // UUPS: deploy the implementation, then an ERC-1967 proxy that runs
        // initialize() in its constructor. All interaction goes through the proxy.
        OTCExchange impl = new OTCExchange();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                OTCExchange.initialize,
                (
                    AdminRegistry(registry),
                    feeRecipient,
                    feeBps,
                    conditionalToken,
                    marketManager,
                    collateral,
                    minOrderAmount
                )
            )
        );
        OTCExchange otc = OTCExchange(address(proxy));

        // Read-only lens for order discovery (no roles, no funds). Points at the proxy.
        OTCQuerier querier = new OTCQuerier(otc);

        vm.stopBroadcast();

        console2.log("OTCExchange proxy deployed at:", address(otc));
        console2.log("OTCExchange implementation at:", address(impl));
        console2.log("OTCQuerier deployed at:", address(querier));
        console2.log("AdminRegistry:", registry);
        console2.log("Fee recipient:", feeRecipient);
        console2.log("Fee bps:", feeBps);
        console2.log("Min order amount:", minOrderAmount);
    }
}
