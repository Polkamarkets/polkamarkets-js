// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {NegRiskAdapter} from "../contracts/NegRiskAdapter.sol";

/// @notice Admin override for event resolution. Caller supplies `winningIndex`.
///         Already-resolved constituent markets are skipped, but their existing
///         outcome must agree with the supplied index — otherwise reverts.
///
///         Signing: use an encrypted keystore account, never a plaintext key —
///           cast wallet import <name> --interactive   # one-time
///           forge script ... --account <name> --sender <addr>
///         The signer must have RESOLUTION_ADMIN_ROLE.
///
///         Env vars:
///           NEG_RISK_ADAPTER     — NegRiskAdapter address
///           EVENT_ID             — bytes32 hex event identifier
///           WINNING_INDEX        — int: -1 = "Other" wins (all NO), 0..N-1 = named outcome wins
///           REDEEM               — "true" to also call redeemNOPositions (default: true)
contract AdminResolveNegRiskEvent is Script {
  function run() external {
    address adapterAddr = vm.envAddress("NEG_RISK_ADAPTER");
    bytes32 eventId = vm.envBytes32("EVENT_ID");
    int256 winningIndex = vm.envInt("WINNING_INDEX");
    bool redeem = vm.envOr("REDEEM", true);

    // Signer comes from the --account keystore; no private key in env.
    vm.startBroadcast();

    NegRiskAdapter adapter = NegRiskAdapter(adapterAddr);
    adapter.adminResolveEvent(eventId, winningIndex);

    console.log("Event resolved (admin):");
    console.logBytes32(eventId);
    if (winningIndex == -1) {
      console.log("Winning index: -1 (Other wins - all markets resolve NO)");
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
