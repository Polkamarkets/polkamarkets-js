// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {NegRiskAdapter} from "../contracts/NegRiskAdapter.sol";

/// @notice Admin override for event resolution. Caller supplies `winningIndex`.
///         Already-resolved constituent markets are skipped, but their existing
///         outcome must agree with the supplied index — otherwise reverts.
///
///         Env vars:
///           PRIVATE_KEY          — signer (must have RESOLUTION_ADMIN_ROLE)
///           NEG_RISK_ADAPTER     — NegRiskAdapter address
///           EVENT_ID             — bytes32 hex event identifier
///           WINNING_INDEX        — int: -1 = "Other" wins (all NO), 0..N-1 = named outcome wins
///           REDEEM               — "true" to also call redeemNOPositions (default: true)
contract AdminResolveNegRiskEvent is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address adapterAddr = vm.envAddress("NEG_RISK_ADAPTER");
    bytes32 eventId = vm.envBytes32("EVENT_ID");
    int256 winningIndex = vm.envInt("WINNING_INDEX");
    bool redeem = vm.envOr("REDEEM", true);

    vm.startBroadcast(privateKey);

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
