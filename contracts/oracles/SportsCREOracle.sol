// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../IMarketOracle.sol";
import "../Outcomes.sol";
import {CREReceiverBase} from "./CREReceiverBase.sol";
import {AdminRegistry} from "../AdminRegistry.sol";

interface ISportsManagerView {
  function getMarketClosesAt(uint256 marketId) external view returns (uint256);
}

/// @title SportsCREOracle
/// @notice IMarketOracle + ICREReceiver implementation for sports markets.
///         Generic result store — the CRE workflow resolves off-chain via OddsPapi
///         (inside DON consensus + TEE) and delivers the winning outcome per market.
///         The contract has no sport-specific logic: any market type (match winner,
///         totals, spread, player props, parlay, ...) is handled by the workflow.
///
///         Trust model: DON consensus over OddsPapi HTTP response + write-once storage.
///         This is "Option A" (off-chain calculation) applied to sports because the
///         data source and resolution logic are inherently off-chain.
contract SportsCREOracle is IMarketOracle, CREReceiverBase {
  // ─── Types ───────────────────────────────────────────────────────────

  struct MarketConfig {
    string externalRef;      // e.g. "oddspapi:id1100013262926181:1:2"
                             // parseable by CRE workflow
    uint256 closesAt;        // end timestamp (copied from manager)
    bool initialized;
  }

  // ─── State ───────────────────────────────────────────────────────────

  address public immutable manager;

  /// @dev Resolved outcomes keyed by keccak256(externalRef).
  ///      Shared across markets with the same externalRef (rare but possible).
  mapping(bytes32 => int256) public resolvedOutcomes;
  mapping(bytes32 => bool) public outcomeResolved;

  mapping(uint256 => MarketConfig) public marketConfigs;

  // ─── Events ──────────────────────────────────────────────────────────

  event SportsResultReported(bytes32 indexed externalRefHash, int256 outcomeId);
  event MarketConfigured(uint256 indexed marketId, string externalRef);

  // ─── Constructor ─────────────────────────────────────────────────────

  constructor(
    AdminRegistry _registry,
    address _manager,
    address _keystoneForwarder
  ) CREReceiverBase(_registry, _keystoneForwarder) {
    require(_manager != address(0), "manager 0");
    manager = _manager;
  }

  // ─── IMarketOracle: initialize ───────────────────────────────────────

  /// @notice Called by the manager during createMarket().
  /// @param data ABI-encoded (string externalRef)
  function initialize(uint256 marketId, bytes calldata data) external override {
    require(msg.sender == manager, "!manager");
    require(!marketConfigs[marketId].initialized, "already init");

    (string memory externalRef) = abi.decode(data, (string));
    require(bytes(externalRef).length > 0, "externalRef required");

    uint256 closesAt = ISportsManagerView(manager).getMarketClosesAt(marketId);

    marketConfigs[marketId] = MarketConfig({
      externalRef: externalRef,
      closesAt: closesAt,
      initialized: true
    });

    emit MarketConfigured(marketId, externalRef);
  }

  // ─── ICREReceiver: onReport ──────────────────────────────────────────

  /// @notice Receives resolved sports outcomes from the CRE workflow.
  /// @param metadata Workflow metadata (validated for workflow identity).
  /// @param report ABI-encoded (string[] externalRefs, int256[] outcomeIds).
  ///        outcomeId: 0 = YES, 1 = NO, -1 = VOIDED (fixture cancelled/postponed)
  function onReport(bytes calldata metadata, bytes calldata report) external override {
    _validate(metadata);

    (string[] memory externalRefs, int256[] memory outcomeIds) =
      abi.decode(report, (string[], int256[]));

    uint256 len = externalRefs.length;
    require(outcomeIds.length == len, "length mismatch");

    for (uint256 i = 0; i < len; i++) {
      bytes32 refHash = keccak256(bytes(externalRefs[i]));

      // Write-once: skip if already resolved
      if (!outcomeResolved[refHash]) {
        int256 outcomeId = outcomeIds[i];
        require(
          outcomeId == int256(Outcomes.YES) ||
          outcomeId == int256(Outcomes.NO) ||
          outcomeId == Outcomes.VOIDED,
          "invalid outcomeId"
        );

        resolvedOutcomes[refHash] = outcomeId;
        outcomeResolved[refHash] = true;

        emit SportsResultReported(refHash, outcomeId);
      }
    }
  }

  // ─── IMarketOracle: getResult ────────────────────────────────────────

  /// @notice Returns the resolved outcome for a market.
  /// @return outcome 0 (YES), 1 (NO), or -1 (VOIDED).
  /// @return resolved true if the CRE workflow has reported the outcome.
  function getResult(uint256 marketId) external view override returns (int256 outcome, bool resolved) {
    MarketConfig storage config = marketConfigs[marketId];
    require(config.initialized, "!init");

    bytes32 refHash = keccak256(bytes(config.externalRef));
    if (!outcomeResolved[refHash]) {
      return (-2, false);
    }

    return (resolvedOutcomes[refHash], true);
  }

  // ─── View helpers ────────────────────────────────────────────────────

  /// @notice Returns the externalRef and its hash for a market.
  function getMarketExternalRef(uint256 marketId) external view returns (string memory ref, bytes32 refHash) {
    MarketConfig storage config = marketConfigs[marketId];
    require(config.initialized, "!init");
    ref = config.externalRef;
    refHash = keccak256(bytes(config.externalRef));
  }

}
