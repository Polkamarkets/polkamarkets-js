// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FeeModule} from "../contracts/FeeModule.sol";

/// @notice Sets fees for a CLOB market.
///
///         Env vars (required):
///           PRIVATE_KEY      — signer (must have FEE_ADMIN_ROLE)
///           CLOB_FEE_MODULE  — FeeModule address
///           MARKET_ID        — market to configure
///           MAKER_FEE_BPS    — peak maker fee in basis points
///           TAKER_FEE_BPS    — peak taker fee in basis points
///
///         Env vars (optional):
///           FEE_CURVE        — "true" for curved fees (peak at center), "false" for flat (default: false)
contract SetCLOBFees is Script {
  uint128 private constant ONE = uint128(1e18);
  uint256 private constant BUCKETS = 100;

  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address feeModuleAddr = vm.envAddress("CLOB_FEE_MODULE");
    uint256 marketId = vm.envUint("MARKET_ID");
    uint64 makerFeeBps = uint64(vm.envUint("MAKER_FEE_BPS"));
    uint64 takerFeeBps = uint64(vm.envUint("TAKER_FEE_BPS"));
    bool feeCurve = vm.envOr("FEE_CURVE", false);

    FeeModule.FeeTier[] memory tiers;

    if (feeCurve) {
      tiers = _buildCurvedTiers(makerFeeBps, takerFeeBps);
      console.log("Fee curve: peaked at center (100 tiers)");
    } else {
      tiers = new FeeModule.FeeTier[](1);
      tiers[0] = FeeModule.FeeTier({maxPrice: ONE, makerFeeBps: makerFeeBps, takerFeeBps: takerFeeBps});
      console.log("Fee curve: flat (1 tier)");
    }

    console.log("Market:", marketId);
    console.log("Maker BPS (peak):", makerFeeBps);
    console.log("Taker BPS (peak):", takerFeeBps);

    vm.startBroadcast(privateKey);
    FeeModule(feeModuleAddr).setMarketFees(marketId, tiers);
    vm.stopBroadcast();

    console.log("Fees set successfully");
  }

  /// @dev Builds 100 tiers (one per 1% price bucket). Fees scale linearly from
  ///      the extremes to a peak at the center (price = 0.50), with symmetric BPS:
  ///
  ///        feeAtBucket = peakFee * min(bucket, 100 - bucket) / 50
  ///
  ///      Examples with peakFee = 75 bps:
  ///        price 0.10 → 15 bps,  price 0.50 → 75 bps,  price 0.90 → 15 bps
  function _buildCurvedTiers(uint64 makerPeak, uint64 takerPeak) internal pure returns (FeeModule.FeeTier[] memory) {
    FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](BUCKETS);

    for (uint256 i = 1; i <= BUCKETS; i++) {
      uint256 distFromEdge = i <= 50 ? i : (BUCKETS - i);
      // Symmetric: i=20 → distFromEdge=20, i=80 → distFromEdge=20
      uint64 maker = uint64((uint256(makerPeak) * distFromEdge) / 50);
      uint64 taker = uint64((uint256(takerPeak) * distFromEdge) / 50);
      if (maker == 0 && makerPeak > 0) maker = 1;
      if (taker == 0 && takerPeak > 0) taker = 1;

      tiers[i - 1] = FeeModule.FeeTier({
        maxPrice: uint128((i * ONE) / BUCKETS),
        makerFeeBps: maker,
        takerFeeBps: taker
      });
    }

    return tiers;
  }
}
