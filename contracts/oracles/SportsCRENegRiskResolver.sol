// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AdminRegistry} from "../AdminRegistry.sol";
import {Outcomes} from "../Outcomes.sol";
import {CREReceiverBase} from "./CREReceiverBase.sol";
import {SportsCREOracle} from "./SportsCREOracle.sol";

/// @title INegRiskAdapterResolver
/// @notice Minimal interface for the NegRiskAdapter functions needed by the resolver.
interface INegRiskAdapterResolver {
  function resolveEvent(bytes32 eventId, int256 winningIndex) external;
  function getEventOutcomeCount(bytes32 eventId) external view returns (uint256);
  function isEventResolved(bytes32 eventId) external view returns (bool);
}

/// @title SportsCRENegRiskResolver
/// @notice Receives CRE reports with pre-computed winning indices and resolves
///         sports neg-risk events by calling NegRiskAdapter.resolveEvent().
///         Holds RESOLUTION_ADMIN_ROLE.
///
///         Unlike CryptoCRENegRiskResolver (which computes the winner from prices),
///         this resolver trusts the CRE workflow's determination because sports
///         outcomes are categorical and inherently off-chain.
///
///         Defensive check: if a SportsCREOracle is provided, the contract
///         verifies the winning outcome's externalRef has been resolved to YES
///         in the oracle. This cross-checks that the workflow's per-outcome
///         delivery to SportsCREOracle agrees with its event-level winning index.
contract SportsCRENegRiskResolver is CREReceiverBase {
  // ─── Types ───────────────────────────────────────────────────────────

  struct EventConfig {
    string[] externalRefs;   // one OddsPapi ref per outcome (same order as event outcomes)
    bool initialized;
  }

  // ─── State ───────────────────────────────────────────────────────────

  INegRiskAdapterResolver public immutable negRiskAdapter;
  SportsCREOracle public immutable sportsOracle;

  mapping(bytes32 => EventConfig) internal _eventConfigs;

  // ─── Events ──────────────────────────────────────────────────────────

  event SportsEventConfigured(bytes32 indexed eventId, uint256 outcomeCount);
  event SportsEventResolvedByCRE(bytes32 indexed eventId, int256 winningIndex);

  // ─── Constructor ─────────────────────────────────────────────────────

  constructor(
    AdminRegistry _registry,
    address _negRiskAdapter,
    SportsCREOracle _sportsOracle,
    address _keystoneForwarder
  ) CREReceiverBase(_registry, _keystoneForwarder) {
    require(_negRiskAdapter != address(0), "adapter 0");
    require(address(_sportsOracle) != address(0), "oracle 0");

    negRiskAdapter = INegRiskAdapterResolver(_negRiskAdapter);
    sportsOracle = _sportsOracle;
  }

  // ─── Configuration ───────────────────────────────────────────────────

  /// @notice Configure a sports neg-risk event with one externalRef per outcome.
  ///         externalRefs[i] is the OddsPapi reference for outcome i
  ///         (e.g. for event "Who wins the World Series?", index 0 = Team A's ref,
  ///          index 1 = Team B's ref, etc.)
  function configureEvent(
    bytes32 eventId,
    string[] calldata externalRefs
  ) external {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not market admin");
    require(!_eventConfigs[eventId].initialized, "already configured");

    uint256 outcomeCount = negRiskAdapter.getEventOutcomeCount(eventId);
    require(outcomeCount > 0, "event !exist");
    require(externalRefs.length == outcomeCount, "refs != outcome count");

    for (uint256 i = 0; i < externalRefs.length; i++) {
      require(bytes(externalRefs[i]).length > 0, "empty externalRef");
    }

    _eventConfigs[eventId] = EventConfig({
      externalRefs: externalRefs,
      initialized: true
    });

    emit SportsEventConfigured(eventId, outcomeCount);
  }

  // ─── ICREReceiver: onReport ──────────────────────────────────────────

  /// @notice Receives CRE reports delivering the winning outcome index per event.
  ///         CRE workflow computes the winner off-chain (from OddsPapi settlements
  ///         across all outcomes in the event) and delivers it here.
  /// @param metadata Workflow metadata (forwarder + workflow identity validation).
  /// @param report ABI-encoded (bytes32[] eventIds, int256[] winningIndices).
  ///        winningIndex >= 0: that outcome won
  ///        winningIndex == -1: "Other" (all markets resolve NO — e.g. fixture cancelled)
  function onReport(bytes calldata metadata, bytes calldata report) external override {
    _validate(metadata);

    (bytes32[] memory eventIds, int256[] memory winningIndices) =
      abi.decode(report, (bytes32[], int256[]));

    uint256 len = eventIds.length;
    require(winningIndices.length == len, "length mismatch");

    for (uint256 i = 0; i < len; i++) {
      _resolveEvent(eventIds[i], winningIndices[i]);
    }
  }

  // ─── Internal ────────────────────────────────────────────────────────

  function _resolveEvent(bytes32 eventId, int256 winningIndex) internal {
    EventConfig storage config = _eventConfigs[eventId];
    require(config.initialized, "event not configured");
    require(!negRiskAdapter.isEventResolved(eventId), "already resolved");

    uint256 n = config.externalRefs.length;
    require(winningIndex >= -1 && winningIndex < int256(n), "bad winning index");

    // Defensive check: if winningIndex >= 0, the winning outcome's externalRef
    // should be resolved to YES in SportsCREOracle. This cross-checks that the
    // workflow's per-outcome delivery agrees with its event-level determination.
    if (winningIndex >= 0) {
      string memory winningRef = config.externalRefs[uint256(winningIndex)];
      bytes32 refHash = keccak256(bytes(winningRef));
      require(sportsOracle.outcomeResolved(refHash), "winning outcome not resolved in oracle");
      int256 oracleOutcome = sportsOracle.resolvedOutcomes(refHash);
      require(oracleOutcome == int256(Outcomes.YES), "winning outcome not YES in oracle");
    }

    negRiskAdapter.resolveEvent(eventId, winningIndex);
    emit SportsEventResolvedByCRE(eventId, winningIndex);
  }

  // ─── View functions ──────────────────────────────────────────────────

  function getEventConfig(bytes32 eventId)
    external
    view
    returns (string[] memory externalRefs, bool initialized)
  {
    EventConfig storage config = _eventConfigs[eventId];
    return (config.externalRefs, config.initialized);
  }
}
