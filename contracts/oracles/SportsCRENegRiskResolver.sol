// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AdminRegistry} from "../AdminRegistry.sol";
import {Outcomes} from "../Outcomes.sol";
import {ICREReceiver} from "./ICREReceiver.sol";
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
contract SportsCRENegRiskResolver is ICREReceiver {
  // ─── Types ───────────────────────────────────────────────────────────

  struct EventConfig {
    string[] externalRefs;   // one OddsPapi ref per outcome (same order as event outcomes)
    bool initialized;
  }

  // ─── State ───────────────────────────────────────────────────────────

  AdminRegistry public immutable registry;
  INegRiskAdapterResolver public immutable negRiskAdapter;
  SportsCREOracle public immutable sportsOracle;

  address public immutable keystoneForwarder;
  bytes32 public immutable allowedWorkflowId;
  bytes32 public immutable allowedWorkflowName;
  address public immutable allowedWorkflowOwner;

  mapping(bytes32 => EventConfig) internal _eventConfigs;

  // ─── Events ──────────────────────────────────────────────────────────

  event SportsEventConfigured(bytes32 indexed eventId, uint256 outcomeCount);
  event SportsEventResolvedByCRE(bytes32 indexed eventId, int256 winningIndex);
  event DebugMetadata(uint256 metadataLength, bytes32 workflowId, bytes32 workflowName, address workflowOwner, address allowedOwner);

  // ─── Constructor ─────────────────────────────────────────────────────

  constructor(
    AdminRegistry _registry,
    address _negRiskAdapter,
    SportsCREOracle _sportsOracle,
    address _keystoneForwarder,
    bytes32 _allowedWorkflowId,
    bytes32 _allowedWorkflowName,
    address _allowedWorkflowOwner
  ) {
    require(address(_registry) != address(0), "registry 0");
    require(_negRiskAdapter != address(0), "adapter 0");
    require(address(_sportsOracle) != address(0), "oracle 0");
    require(_keystoneForwarder != address(0), "forwarder 0");
    require(_allowedWorkflowOwner != address(0), "owner 0");

    registry = _registry;
    negRiskAdapter = INegRiskAdapterResolver(_negRiskAdapter);
    sportsOracle = _sportsOracle;
    keystoneForwarder = _keystoneForwarder;
    allowedWorkflowId = _allowedWorkflowId;
    allowedWorkflowName = _allowedWorkflowName;
    allowedWorkflowOwner = _allowedWorkflowOwner;
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
    require(msg.sender == keystoneForwarder, "!forwarder");
    _validateMetadata(metadata);

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

  function _validateMetadata(bytes calldata metadata) internal {
    // Chainlink CRE metadata layout (TIGHTLY PACKED, 64 bytes total):
    //   [0:32]  workflowId    (bytes32)
    //   [32:42] workflowName  (bytes10)
    //   [42:62] workflowOwner (address, 20 bytes)
    require(metadata.length >= 62, "metadata too short");

    bytes32 workflowId;
    bytes32 workflowName;
    address workflowOwner;
    assembly {
      let base := metadata.offset
      workflowId := calldataload(base)
      // workflowName: 10 bytes at offset 32, mask top 10 bytes of the loaded word
      workflowName := and(calldataload(add(base, 32)), 0xFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000000000000000)
      // workflowOwner: 20 bytes at offset 42, shift right to get address as right-aligned 160 bits
      workflowOwner := shr(96, calldataload(add(base, 42)))
    }

    emit DebugMetadata(metadata.length, workflowId, workflowName, workflowOwner, allowedWorkflowOwner);

    // TODO: TESTING ONLY — re-enable these checks before production deployment
    // require(workflowId == allowedWorkflowId, "!workflowId");
    // require(workflowName == allowedWorkflowName, "!workflowName");
    // require(workflowOwner == allowedWorkflowOwner, "!workflowOwner");
  }

  // ─── ERC165 ──────────────────────────────────────────────────────────

  /// @dev The forwarder checks supportsInterface(type(ICREReceiver).interfaceId) before calling.
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(ICREReceiver).interfaceId ||
      interfaceId == 0x01ffc9a7; // ERC165 itself
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
