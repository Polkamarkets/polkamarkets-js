// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {NegRiskAdapter} from "../contracts/NegRiskAdapter.sol";

/// @notice Permissionless event resolution. Reads `winningIndex` from the
///         constituent markets — every market must already be resolved
///         (per-market via `manager.resolveMarket(id)`) before this call.
///
///         Signing: use an encrypted keystore account, never a plaintext key —
///           cast wallet import <name> --interactive   # one-time
///           forge script ... --account <name> --sender <addr>
///         No role required for resolveEvent itself.
///
///         Env vars:
///           NEG_RISK_ADAPTER     — NegRiskAdapter address
///           EVENT_ID             — bytes32 hex event identifier
///           REDEEM               — "true" to also call redeemNOPositions (default: false)
///                                  (redeemNOPositions still requires DEFAULT_ADMIN_ROLE)
contract ResolveNegRiskEvent is Script {
  function run() external {
    address adapterAddr = vm.envAddress("NEG_RISK_ADAPTER");
    bytes32 eventId = vm.envBytes32("EVENT_ID");
    bool redeem = vm.envOr("REDEEM", false);

    // Signer comes from the --account keystore; no private key in env.
    vm.startBroadcast();

    NegRiskAdapter adapter = NegRiskAdapter(adapterAddr);
    adapter.resolveEvent(eventId);

    (, , int256 winningIndex, , ) = adapter.getEvent(eventId);
    console.log("Event resolved:");
    console.logBytes32(eventId);
    if (winningIndex == -1) {
      console.log("Winning index: -1 (Other wins - all markets resolved NO)");
    } else {
      console.log("Winning index:", uint256(winningIndex));
    }

    if (redeem) {
      adapter.redeemNOPositions(eventId);
      console.log("NO positions redeemed");
    }

    vm.stopBroadcast();
  }
}
