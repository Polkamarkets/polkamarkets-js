// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AdminRegistry} from "../AdminRegistry.sol";
import {ICREReceiver} from "./ICREReceiver.sol";
import {CREOracle} from "./CREOracle.sol";

/// @title INegRiskAdapterResolver
/// @notice Minimal interface for the NegRiskAdapter functions needed by the resolver.
interface INegRiskAdapterResolver {
  function resolveEvent(bytes32 eventId, int256 winningIndex) external;
  function getEventOutcomeCount(bytes32 eventId) external view returns (uint256);
  function isEventResolved(bytes32 eventId) external view returns (bool);
}

/// @title CRENegRiskResolver
/// @notice Receives CRE trigger reports and resolves neg-risk events using verified
///         price data stored in CREOracle. Holds RESOLUTION_ADMIN_ROLE to call
///         NegRiskAdapter.resolveEvent().
///
///         Supports 3 event rule types:
///           RANGE          — bucket close price into ranges
///           BEST_PERFORMER — highest % change across N tokens wins
///           HIT_MILESTONES — highest milestone the high price reached wins
contract CRENegRiskResolver is ICREReceiver {
  // ─── Types ───────────────────────────────────────────────────────────

  enum EventRuleType {
    RANGE,            // 0
    BEST_PERFORMER,   // 1
    HIT_MILESTONES,   // 2
    FIRST_TO_HIT      // 3 — "Which boundary is hit first?" CRE determines winner off-chain.
  }

  struct EventConfig {
    EventRuleType ruleType;
    bytes32[] feedIds;       // RANGE/HIT_MILESTONES: 1 feed; BEST_PERFORMER/FIRST_TO_HIT: N feeds
    uint256 openTimestamp;   // BEST_PERFORMER needs this; 0 for RANGE/HIT_MILESTONES
    uint256 closesAt;
    int256[] boundaries;     // RANGE/HIT_MILESTONES: sorted ascending; FIRST_TO_HIT: one per outcome
    bool[] hitDirections;    // FIRST_TO_HIT only: true = hit above, false = hit below; empty otherwise
    bool initialized;
  }

  // ─── State ───────────────────────────────────────────────────────────

  AdminRegistry public immutable registry;
  INegRiskAdapterResolver public immutable negRiskAdapter;
  CREOracle public immutable creOracle;

  address public immutable keystoneForwarder;
  bytes32 public immutable allowedWorkflowId;
  bytes32 public immutable allowedWorkflowName;
  address public immutable allowedWorkflowOwner;

  mapping(bytes32 => EventConfig) internal _eventConfigs;

  // ─── Events ──────────────────────────────────────────────────────────

  event EventConfigured(bytes32 indexed eventId, EventRuleType ruleType, uint256 feedCount, uint256 boundaryCount);
  event EventResolvedByCRE(bytes32 indexed eventId, int256 winningIndex, EventRuleType ruleType);

  // ─── Constructor ─────────────────────────────────────────────────────

  constructor(
    AdminRegistry _registry,
    address _negRiskAdapter,
    CREOracle _creOracle,
    address _keystoneForwarder,
    bytes32 _allowedWorkflowId,
    bytes32 _allowedWorkflowName,
    address _allowedWorkflowOwner
  ) {
    require(address(_registry) != address(0), "registry 0");
    require(_negRiskAdapter != address(0), "adapter 0");
    require(address(_creOracle) != address(0), "oracle 0");
    require(_keystoneForwarder != address(0), "forwarder 0");
    require(_allowedWorkflowOwner != address(0), "owner 0");

    registry = _registry;
    negRiskAdapter = INegRiskAdapterResolver(_negRiskAdapter);
    creOracle = _creOracle;
    keystoneForwarder = _keystoneForwarder;
    allowedWorkflowId = _allowedWorkflowId;
    allowedWorkflowName = _allowedWorkflowName;
    allowedWorkflowOwner = _allowedWorkflowOwner;
  }

  // ─── Configuration ───────────────────────────────────────────────────

  /// @notice Configure a neg-risk event for CRE-based resolution.
  /// @param eventId The NegRiskAdapter event identifier.
  /// @param ruleType The event resolution rule.
  /// @param feedIds Feed IDs (1 for RANGE/HIT_MILESTONES, N for BEST_PERFORMER).
  /// @param openTimestamp Start timestamp (required for BEST_PERFORMER).
  /// @param closesAt End timestamp.
  /// @param boundaries Sorted ascending price boundaries (for RANGE/HIT_MILESTONES).
  function configureEvent(
    bytes32 eventId,
    EventRuleType ruleType,
    bytes32[] calldata feedIds,
    uint256 openTimestamp,
    uint256 closesAt,
    int256[] calldata boundaries
  ) external {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not market admin");
    require(!_eventConfigs[eventId].initialized, "already configured");

    uint256 outcomeCount = negRiskAdapter.getEventOutcomeCount(eventId);
    require(outcomeCount > 0, "event !exist");

    if (ruleType == EventRuleType.RANGE) {
      require(feedIds.length == 1, "RANGE: 1 feed");
      require(boundaries.length == outcomeCount - 1, "RANGE: boundary count");
      _requireAscending(boundaries);
    } else if (ruleType == EventRuleType.BEST_PERFORMER) {
      require(feedIds.length == outcomeCount, "BEST_PERFORMER: feed per outcome");
      require(boundaries.length == 0, "BEST_PERFORMER: no boundaries");
      require(openTimestamp > 0, "BEST_PERFORMER: openTimestamp");
    } else if (ruleType == EventRuleType.HIT_MILESTONES) {
      require(feedIds.length == 1, "HIT_MILESTONES: 1 feed");
      require(boundaries.length == outcomeCount - 1, "HIT_MILESTONES: boundary count");
      _requireAscending(boundaries);
    } else if (ruleType == EventRuleType.FIRST_TO_HIT) {
      revert("use configureFirstToHitEvent");
    }

    require(closesAt > 0, "closesAt 0");

    bool[] memory emptyDirs = new bool[](0);
    _eventConfigs[eventId] = EventConfig({
      ruleType: ruleType,
      feedIds: feedIds,
      openTimestamp: openTimestamp,
      closesAt: closesAt,
      boundaries: boundaries,
      hitDirections: emptyDirs,
      initialized: true
    });

    emit EventConfigured(eventId, ruleType, feedIds.length, boundaries.length);
  }

  /// @notice Configure a FIRST_TO_HIT event. Each outcome has a feed, threshold, and direction.
  ///         "Will BTC hit $100K or $50K first?" → 2 outcomes, boundaries=[100Ke8, 50Ke8], directions=[true, false]
  function configureFirstToHitEvent(
    bytes32 eventId,
    bytes32[] calldata feedIds,
    uint256 closesAt,
    int256[] calldata thresholds,
    bool[] calldata directions
  ) external {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not market admin");
    require(!_eventConfigs[eventId].initialized, "already configured");

    uint256 outcomeCount = negRiskAdapter.getEventOutcomeCount(eventId);
    require(outcomeCount > 0, "event !exist");
    require(feedIds.length == outcomeCount, "FIRST_TO_HIT: feed per outcome");
    require(thresholds.length == outcomeCount, "FIRST_TO_HIT: threshold per outcome");
    require(directions.length == outcomeCount, "FIRST_TO_HIT: direction per outcome");
    require(closesAt > 0, "closesAt 0");

    _eventConfigs[eventId] = EventConfig({
      ruleType: EventRuleType.FIRST_TO_HIT,
      feedIds: feedIds,
      openTimestamp: 0,
      closesAt: closesAt,
      boundaries: thresholds,
      hitDirections: directions,
      initialized: true
    });

    emit EventConfigured(eventId, EventRuleType.FIRST_TO_HIT, feedIds.length, thresholds.length);
  }

  // ─── ICREReceiver: onReport ──────────────────────────────────────────

  /// @notice Receives a CRE report triggering event resolution.
  ///         For RANGE/BEST_PERFORMER/HIT_MILESTONES: prices must already be in CREOracle.
  ///         For FIRST_TO_HIT: CRE provides the winning index directly.
  /// @param metadata Workflow metadata.
  /// @param report ABI-encoded (bytes32[] eventIds, int256[] winningIndices).
  ///        winningIndices[i] is used only for FIRST_TO_HIT events; ignored otherwise (pass 0).
  function onReport(bytes calldata metadata, bytes calldata report) external override {
    require(msg.sender == keystoneForwarder, "!forwarder");
    _validateMetadata(metadata);

    (bytes32[] memory eventIds, int256[] memory winningIndices) = abi.decode(report, (bytes32[], int256[]));
    require(eventIds.length == winningIndices.length, "length mismatch");

    for (uint256 i = 0; i < eventIds.length; i++) {
      _resolveEvent(eventIds[i], winningIndices[i]);
    }
  }

  // ─── Resolution logic ────────────────────────────────────────────────

  function _resolveEvent(bytes32 eventId, int256 reportedWinner) internal {
    EventConfig storage config = _eventConfigs[eventId];
    require(config.initialized, "event not configured");
    require(!negRiskAdapter.isEventResolved(eventId), "already resolved");

    int256 winningIndex;

    if (config.ruleType == EventRuleType.RANGE) {
      winningIndex = _resolveRange(config);
    } else if (config.ruleType == EventRuleType.BEST_PERFORMER) {
      winningIndex = _resolveBestPerformer(config);
    } else if (config.ruleType == EventRuleType.HIT_MILESTONES) {
      winningIndex = _resolveHitMilestones(config);
    } else if (config.ruleType == EventRuleType.FIRST_TO_HIT) {
      winningIndex = _resolveFirstToHit(config, reportedWinner);
    }

    negRiskAdapter.resolveEvent(eventId, winningIndex);
    emit EventResolvedByCRE(eventId, winningIndex, config.ruleType);
  }

  function _resolveRange(EventConfig storage config) internal view returns (int256) {
    (int256 closePrice,,, bool exists) = creOracle.getVerifiedPrice(config.feedIds[0], config.closesAt);
    require(exists, "price not available");

    // Range 0: price < boundaries[0]
    // Range i: boundaries[i-1] <= price < boundaries[i]
    // Range N-1: price >= boundaries[N-2]
    for (uint256 i = 0; i < config.boundaries.length; i++) {
      if (closePrice < config.boundaries[i]) {
        return int256(i);
      }
    }
    return int256(config.boundaries.length); // last range
  }

  function _resolveBestPerformer(EventConfig storage config) internal view returns (int256) {
    uint256 n = config.feedIds.length;
    int256 bestIndex = -1; // -1 = "Other wins" (tie or error)
    int256 bestChange = type(int256).min;
    bool hasTie = false;

    for (uint256 i = 0; i < n; i++) {
      (int256 openPrice,,, bool okOpen) = creOracle.getVerifiedPrice(config.feedIds[i], config.openTimestamp);
      require(okOpen, "open price not available");
      (int256 closePrice,,, bool okClose) = creOracle.getVerifiedPrice(config.feedIds[i], config.closesAt);
      require(okClose, "close price not available");

      if (openPrice == 0) continue; // skip tokens with zero open price

      // % change = (close - open) * 10000 / open (in bps, preserving sign)
      int256 change = ((closePrice - openPrice) * 10000) / openPrice;

      if (change > bestChange) {
        bestChange = change;
        bestIndex = int256(i);
        hasTie = false;
      } else if (change == bestChange) {
        hasTie = true;
      }
    }

    // Tie → "Other wins" (all markets resolve NO)
    if (hasTie) return int256(-1);

    return bestIndex;
  }

  function _resolveHitMilestones(EventConfig storage config) internal view returns (int256) {
    (, int256 highPrice,, bool exists) = creOracle.getVerifiedPrice(config.feedIds[0], config.closesAt);
    require(exists, "price not available");

    // Find the highest milestone reached by highPrice.
    // Outcome 0 = didn't reach boundaries[0]
    // Outcome i = reached boundaries[i-1] but not boundaries[i]
    // Outcome N-1 = reached boundaries[N-2] (highest milestone)
    //
    // We iterate from the top to find the highest milestone reached.
    int256 winningIndex = 0; // default: below first boundary

    for (uint256 i = config.boundaries.length; i > 0; i--) {
      if (highPrice >= config.boundaries[i - 1]) {
        winningIndex = int256(i);
        break;
      }
    }

    return winningIndex;
  }

  /// @dev FIRST_TO_HIT: CRE determines the winner off-chain by scanning candles chronologically.
  ///      The contract performs a sanity check: the reported winner's threshold must actually
  ///      have been crossed (verified via highPrice/lowPrice in the shared price store).
  ///      If CRE reports -1 (neither hit), that's accepted at deadline (voided via "Other").
  function _resolveFirstToHit(EventConfig storage config, int256 reportedWinner) internal view returns (int256) {
    uint256 n = config.boundaries.length;
    require(reportedWinner >= -1 && reportedWinner < int256(n), "invalid winner");

    if (reportedWinner == -1) {
      // "Neither hit" — only valid at or after deadline
      return int256(-1);
    }

    // Sanity check: verify the reported winner's threshold was actually crossed
    uint256 idx = uint256(reportedWinner);
    (, int256 highPrice, int256 lowPrice, bool exists) = creOracle.getVerifiedPrice(config.feedIds[idx], config.closesAt);
    require(exists, "price not available");

    if (config.hitDirections[idx]) {
      // Hit above: highPrice must have reached threshold
      require(highPrice >= config.boundaries[idx], "threshold not reached");
    } else {
      // Hit below: lowPrice must have dropped to threshold
      require(lowPrice <= config.boundaries[idx], "threshold not reached");
    }

    return reportedWinner;
  }

  // ─── Internal helpers ────────────────────────────────────────────────

  function _validateMetadata(bytes calldata metadata) internal view {
    require(metadata.length >= 128, "metadata too short");

    bytes32 workflowId;
    bytes32 workflowName;
    address workflowOwner;
    assembly {
      let base := metadata.offset
      workflowId := calldataload(add(base, 32))
      workflowName := calldataload(add(base, 64))
      workflowOwner := shr(96, calldataload(add(base, 96)))
    }

    require(workflowId == allowedWorkflowId, "!workflowId");
    require(workflowName == allowedWorkflowName, "!workflowName");
    require(workflowOwner == allowedWorkflowOwner, "!workflowOwner");
  }

  function _requireAscending(int256[] calldata values) internal pure {
    for (uint256 i = 1; i < values.length; i++) {
      require(values[i] > values[i - 1], "boundaries not ascending");
    }
  }

  // ─── View functions ──────────────────────────────────────────────────

  function getEventConfig(bytes32 eventId)
    external
    view
    returns (
      EventRuleType ruleType,
      bytes32[] memory feedIds,
      uint256 openTimestamp,
      uint256 closesAt,
      int256[] memory boundaries,
      bool[] memory hitDirections,
      bool initialized
    )
  {
    EventConfig storage config = _eventConfigs[eventId];
    return (config.ruleType, config.feedIds, config.openTimestamp, config.closesAt, config.boundaries, config.hitDirections, config.initialized);
  }
}
