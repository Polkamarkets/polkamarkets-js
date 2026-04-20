// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../IMarketOracle.sol";
import "../Outcomes.sol";
import "./ICREReceiver.sol";

interface ICREOracleManagerView {
  function getMarketClosesAt(uint256 marketId) external view returns (uint256);
}

/// @title CREOracle
/// @notice IMarketOracle + ICREReceiver implementation for deterministic crypto markets.
///         Receives verified price data from a Chainlink CRE workflow via onReport(),
///         stores it immutably, and computes binary market outcomes on-chain via getResult().
///
///         Supports 6 rule types with a yesAbove flag (12 market directions):
///           THRESHOLD  — close vs fixed price
///           DIRECTION  — close vs open (same feed)
///           CHANGE_PCT — |% change| vs bps threshold (volatility)
///           RELATIVE   — feed A's % change vs feed B's % change
///           HIT        — did high/low reach a target at any point
///           CANDLE     — more green or red candles in a period
contract CREOracle is IMarketOracle, ICREReceiver {
  // ─── Types ───────────────────────────────────────────────────────────

  enum RuleType {
    THRESHOLD,      // 0
    DIRECTION,      // 1
    CHANGE_PCT,     // 2
    RELATIVE,       // 3
    HIT,            // 4
    CANDLE,         // 5 — param = candle interval in seconds
    FIRST_TO_HIT    // 6 — param = above threshold, paramB = below threshold, interval = sub-interval
  }

  struct MarketConfig {
    bytes32 feedId;          // primary feed, e.g. keccak256("BTCUSDT")
    bytes32 feedIdB;         // second feed for RELATIVE; 0x0 otherwise
    RuleType rule;
    bool yesAbove;           // flips direction — YES when condition met "above"
    int256 param;            // price (THRESHOLD/HIT) or bps (CHANGE_PCT); 0 for DIRECTION/RELATIVE
    uint256 closesAt;        // end timestamp (copied from manager)
    uint256 openTimestamp;   // start timestamp; 0 for THRESHOLD
    int256 paramB;           // FIRST_TO_HIT: below threshold; 0 otherwise
    uint256 interval;        // FIRST_TO_HIT: sub-interval in seconds; 0 otherwise
    bool initialized;
  }

  struct PriceData {
    int256 closePrice;       // price at this exact timestamp
    int256 highPrice;        // highest price during the period ending at this timestamp
    int256 lowPrice;         // lowest price during the period ending at this timestamp
  }

  // ─── State ───────────────────────────────────────────────────────────

  address public immutable manager;
  address public immutable keystoneForwarder;
  bytes32 public immutable allowedWorkflowId;
  bytes32 public immutable allowedWorkflowName;
  address public immutable allowedWorkflowOwner;

  /// @dev Verified prices keyed by keccak256(abi.encode(feedId, timestamp)).
  mapping(bytes32 => PriceData) public verifiedPrices;
  mapping(bytes32 => bool) public priceExists;

  mapping(uint256 => MarketConfig) public marketConfigs;

  // ─── Events ──────────────────────────────────────────────────────────

  event PriceVerified(bytes32 indexed feedId, uint256 indexed timestamp, int256 closePrice, int256 highPrice, int256 lowPrice);
  event MarketConfigured(uint256 indexed marketId, bytes32 feedId, RuleType rule, bool yesAbove, int256 param);
  event DebugMetadata(uint256 metadataLength, bytes32 workflowId, bytes32 workflowName, address workflowOwner, address allowedOwner);

  // ─── Constructor ─────────────────────────────────────────────────────

  constructor(
    address _manager,
    address _keystoneForwarder,
    bytes32 _allowedWorkflowId,
    bytes32 _allowedWorkflowName,
    address _allowedWorkflowOwner
  ) {
    require(_manager != address(0), "manager 0");
    require(_keystoneForwarder != address(0), "forwarder 0");
    require(_allowedWorkflowOwner != address(0), "owner 0");

    manager = _manager;
    keystoneForwarder = _keystoneForwarder;
    allowedWorkflowId = _allowedWorkflowId;
    allowedWorkflowName = _allowedWorkflowName;
    allowedWorkflowOwner = _allowedWorkflowOwner;
  }

  // ─── ERC165 (required by KeystoneForwarder) ──────────────────────────

  /// @dev The forwarder checks supportsInterface(type(ICREReceiver).interfaceId) before calling.
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(ICREReceiver).interfaceId ||
      interfaceId == 0x01ffc9a7; // ERC165 itself
  }

  // ─── IMarketOracle: initialize ───────────────────────────────────────

  /// @notice Called by the manager during createMarket().
  /// @param data ABI-encoded (bytes32 feedId, bytes32 feedIdB, uint8 rule, bool yesAbove, int256 param, uint256 openTimestamp, int256 paramB, uint256 interval)
  function initialize(uint256 marketId, bytes calldata data) external override {
    require(msg.sender == manager, "!manager");
    require(!marketConfigs[marketId].initialized, "already init");

    (
      bytes32 feedId,
      bytes32 feedIdB,
      uint8 ruleRaw,
      bool yesAbove,
      int256 param,
      uint256 openTimestamp,
      int256 paramB,
      uint256 interval
    ) = abi.decode(data, (bytes32, bytes32, uint8, bool, int256, uint256, int256, uint256));

    require(feedId != bytes32(0), "feedId 0");
    require(ruleRaw <= uint8(type(RuleType).max), "invalid rule");

    RuleType rule = RuleType(ruleRaw);

    // Validate rule-specific constraints
    if (rule == RuleType.RELATIVE) {
      require(feedIdB != bytes32(0), "feedIdB required for RELATIVE");
    }
    if (rule == RuleType.DIRECTION || rule == RuleType.CHANGE_PCT || rule == RuleType.RELATIVE || rule == RuleType.CANDLE || rule == RuleType.FIRST_TO_HIT) {
      require(openTimestamp > 0, "openTimestamp required");
    }
    if (rule == RuleType.THRESHOLD || rule == RuleType.HIT) {
      require(param != 0, "param required");
    }
    if (rule == RuleType.CANDLE) {
      require(param > 0, "candle interval required");
    }
    if (rule == RuleType.FIRST_TO_HIT) {
      require(param != 0, "above threshold required");
      require(paramB != 0, "below threshold required");
      require(interval > 0, "interval required");
    }

    uint256 closesAt = ICREOracleManagerView(manager).getMarketClosesAt(marketId);

    marketConfigs[marketId] = MarketConfig({
      feedId: feedId,
      feedIdB: feedIdB,
      rule: rule,
      yesAbove: yesAbove,
      param: param,
      closesAt: closesAt,
      openTimestamp: openTimestamp,
      paramB: paramB,
      interval: interval,
      initialized: true
    });

    emit MarketConfigured(marketId, feedId, rule, yesAbove, param);
  }

  // ─── ICREReceiver: onReport ──────────────────────────────────────────

  /// @notice Receives verified price data from the Chainlink CRE workflow.
  /// @param metadata Workflow metadata (contains workflow ID, name, owner).
  /// @param report ABI-encoded (bytes32[] feedIds, uint256[] timestamps, int256[] closePrices, int256[] highPrices, int256[] lowPrices).
  function onReport(bytes calldata metadata, bytes calldata report) external override {
    require(msg.sender == keystoneForwarder, "!forwarder");

    // Chainlink CRE metadata layout (TIGHTLY PACKED, 64 bytes total):
    // [0:32]  workflowId    (bytes32)
    // [32:42] workflowName  (bytes10)
    // [42:62] workflowOwner (address, 20 bytes)
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

    // Decode report
    (
      bytes32[] memory feedIds,
      uint256[] memory timestamps,
      int256[] memory closePrices,
      int256[] memory highPrices,
      int256[] memory lowPrices
    ) = abi.decode(report, (bytes32[], uint256[], int256[], int256[], int256[]));

    uint256 len = feedIds.length;
    require(
      timestamps.length == len && closePrices.length == len && highPrices.length == len && lowPrices.length == len,
      "length mismatch"
    );

    for (uint256 i = 0; i < len; i++) {
      bytes32 priceKey = keccak256(abi.encode(feedIds[i], timestamps[i]));

      // Write-once: skip if already stored
      if (!priceExists[priceKey]) {
        verifiedPrices[priceKey] = PriceData({
          closePrice: closePrices[i],
          highPrice: highPrices[i],
          lowPrice: lowPrices[i]
        });
        priceExists[priceKey] = true;

        emit PriceVerified(feedIds[i], timestamps[i], closePrices[i], highPrices[i], lowPrices[i]);
      }
    }
  }

  // ─── IMarketOracle: getResult ────────────────────────────────────────

  /// @notice Computes the binary outcome for a market from stored verified prices.
  /// @return outcome 0 (YES), 1 (NO), or -1 (VOIDED).
  /// @return resolved true if all required prices are available and outcome is computed.
  function getResult(uint256 marketId) external view override returns (int256 outcome, bool resolved) {
    MarketConfig storage config = marketConfigs[marketId];
    require(config.initialized, "!init");

    if (config.rule == RuleType.THRESHOLD) {
      return _resolveThreshold(config);
    } else if (config.rule == RuleType.DIRECTION) {
      return _resolveDirection(config);
    } else if (config.rule == RuleType.CHANGE_PCT) {
      return _resolveChangePct(config);
    } else if (config.rule == RuleType.RELATIVE) {
      return _resolveRelative(config);
    } else if (config.rule == RuleType.HIT) {
      return _resolveHit(config);
    } else if (config.rule == RuleType.CANDLE) {
      return _resolveCandle(config);
    } else if (config.rule == RuleType.FIRST_TO_HIT) {
      return _resolveFirstToHit(config);
    }

    return (Outcomes.VOIDED, true);
  }

  // ─── Internal resolution logic ───────────────────────────────────────

  function _resolveThreshold(MarketConfig storage config) internal view returns (int256, bool) {
    (int256 closePrice, bool ok) = _getClosePrice(config.feedId, config.closesAt);
    if (!ok) return (-2, false);

    bool condition = closePrice >= config.param;
    return _outcomeFromCondition(condition, config.yesAbove);
  }

  function _resolveDirection(MarketConfig storage config) internal view returns (int256, bool) {
    (int256 openPrice, bool okOpen) = _getClosePrice(config.feedId, config.openTimestamp);
    if (!okOpen) return (-2, false);

    (int256 closePrice, bool okClose) = _getClosePrice(config.feedId, config.closesAt);
    if (!okClose) return (-2, false);

    // Tie → NO regardless of yesAbove
    if (closePrice == openPrice) return (int256(Outcomes.NO), true);

    bool condition = closePrice > openPrice;
    return _outcomeFromCondition(condition, config.yesAbove);
  }

  function _resolveChangePct(MarketConfig storage config) internal view returns (int256, bool) {
    (int256 openPrice, bool okOpen) = _getClosePrice(config.feedId, config.openTimestamp);
    if (!okOpen) return (-2, false);

    (int256 closePrice, bool okClose) = _getClosePrice(config.feedId, config.closesAt);
    if (!okClose) return (-2, false);

    // Avoid division by zero
    if (openPrice == 0) return (Outcomes.VOIDED, true);

    // Calculate |% change| in bps: |close - open| * 10000 / |open|
    int256 diff = closePrice - openPrice;
    if (diff < 0) diff = -diff;
    int256 absOpen = openPrice < 0 ? -openPrice : openPrice;
    int256 changeBps = (diff * 10000) / absOpen;

    bool condition = changeBps >= config.param;
    return _outcomeFromCondition(condition, config.yesAbove);
  }

  function _resolveRelative(MarketConfig storage config) internal view returns (int256, bool) {
    // Feed A: primary
    (int256 openA, bool okOpenA) = _getClosePrice(config.feedId, config.openTimestamp);
    if (!okOpenA) return (-2, false);
    (int256 closeA, bool okCloseA) = _getClosePrice(config.feedId, config.closesAt);
    if (!okCloseA) return (-2, false);

    // Feed B: secondary
    (int256 openB, bool okOpenB) = _getClosePrice(config.feedIdB, config.openTimestamp);
    if (!okOpenB) return (-2, false);
    (int256 closeB, bool okCloseB) = _getClosePrice(config.feedIdB, config.closesAt);
    if (!okCloseB) return (-2, false);

    if (openA == 0 || openB == 0) return (Outcomes.VOIDED, true);

    // Compare % changes using cross-multiplication to avoid precision loss:
    // changeA% > changeB%  ⟺  (closeA - openA) / openA > (closeB - openB) / openB
    // ⟺  (closeA - openA) * openB > (closeB - openB) * openA  (when openA, openB > 0)
    // For negative prices (shouldn't happen but be safe), we use the sign-aware form.
    int256 lhs = (closeA - openA) * openB;
    int256 rhs = (closeB - openB) * openA;

    // Tie → NO
    if (lhs == rhs) return (int256(Outcomes.NO), true);

    bool condition = lhs > rhs;
    return _outcomeFromCondition(condition, config.yesAbove);
  }

  function _resolveHit(MarketConfig storage config) internal view returns (int256, bool) {
    bytes32 priceKey = keccak256(abi.encode(config.feedId, config.closesAt));
    if (!priceExists[priceKey]) return (-2, false);

    PriceData storage pd = verifiedPrices[priceKey];

    bool condition;
    if (config.yesAbove) {
      // "Will price hit X?" — did the high reach param?
      condition = pd.highPrice >= config.param;
    } else {
      // "Will price dip below X?" — did the low drop to param?
      condition = pd.lowPrice <= config.param;
    }

    return _outcomeFromCondition(condition, true); // condition already accounts for yesAbove
  }

  function _resolveCandle(MarketConfig storage config) internal view returns (int256, bool) {
    uint256 interval = uint256(config.param);
    uint256 start = config.openTimestamp;
    uint256 end = config.closesAt;

    uint256 greenCount = 0;
    uint256 redCount = 0;

    for (uint256 t = start; t + interval <= end; t += interval) {
      (int256 candleOpen, bool okOpen) = _getClosePrice(config.feedId, t);
      if (!okOpen) return (-2, false);
      (int256 candleClose, bool okClose) = _getClosePrice(config.feedId, t + interval);
      if (!okClose) return (-2, false);

      if (candleClose > candleOpen) {
        greenCount++;
      } else if (candleClose < candleOpen) {
        redCount++;
      }
      // flat candle (close == open) counts as neither
    }

    // Tie (green == red) → NO
    if (greenCount == redCount) return (int256(Outcomes.NO), true);

    bool condition = greenCount > redCount;
    return _outcomeFromCondition(condition, config.yesAbove);
  }

  function _resolveFirstToHit(MarketConfig storage config) internal view returns (int256, bool) {
    uint256 start = config.openTimestamp;
    uint256 end = config.closesAt;
    uint256 step = config.interval;

    for (uint256 t = start; t + step <= end; t += step) {
      bytes32 priceKey = keccak256(abi.encode(config.feedId, t + step));
      if (!priceExists[priceKey]) return (-2, false);

      PriceData storage pd = verifiedPrices[priceKey];
      bool aboveHit = pd.highPrice >= config.param;
      bool belowHit = pd.lowPrice <= config.paramB;

      if (aboveHit && !belowHit) {
        // Above threshold hit first in this interval
        return _outcomeFromCondition(true, config.yesAbove);
      }
      if (belowHit && !aboveHit) {
        // Below threshold hit first in this interval
        return _outcomeFromCondition(false, config.yesAbove);
      }
      // Both hit in same interval → inconclusive, check next (finer) interval
      // Neither hit → continue
    }

    // Exhausted all intervals with no clear winner → not resolved
    return (-2, false);
  }

  // ─── Helpers ─────────────────────────────────────────────────────────

  function _getClosePrice(bytes32 feedId, uint256 timestamp) internal view returns (int256, bool) {
    bytes32 priceKey = keccak256(abi.encode(feedId, timestamp));
    if (!priceExists[priceKey]) return (0, false);
    return (verifiedPrices[priceKey].closePrice, true);
  }

  /// @dev Maps a boolean condition to YES/NO based on yesAbove.
  function _outcomeFromCondition(bool condition, bool yesAbove) internal pure returns (int256, bool) {
    if (condition == yesAbove) {
      return (int256(Outcomes.YES), true);
    } else {
      return (int256(Outcomes.NO), true);
    }
  }

  // ─── View helpers (for CRENegRiskResolver) ───────────────────────────

  /// @notice Returns verified price data for a (feedId, timestamp) pair.
  function getVerifiedPrice(bytes32 feedId, uint256 timestamp)
    external
    view
    returns (int256 closePrice, int256 highPrice, int256 lowPrice, bool exists)
  {
    bytes32 priceKey = keccak256(abi.encode(feedId, timestamp));
    if (!priceExists[priceKey]) return (0, 0, 0, false);
    PriceData storage pd = verifiedPrices[priceKey];
    return (pd.closePrice, pd.highPrice, pd.lowPrice, true);
  }
}
