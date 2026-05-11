// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../IMarketOracle.sol";
import "../Outcomes.sol";
import {CREReceiverBase} from "./CREReceiverBase.sol";
import {AdminRegistry} from "../AdminRegistry.sol";

interface ICREOracleManagerView {
  function getMarketClosesAt(uint256 marketId) external view returns (uint256);
}

/// @title CryptoCREOracle
/// @notice IMarketOracle + ICREReceiver implementation for deterministic crypto markets.
///         Receives verified price data from a Chainlink CRE workflow via onReport(),
///         stores it immutably, and computes binary market outcomes on-chain via getResult().
///
///         Supports 9 rule types with a yesAbove flag:
///           THRESHOLD              — close vs fixed price
///           DIRECTION              — close vs open (same feed)
///           CHANGE_PCT             — |% change| vs bps threshold (volatility)
///           RELATIVE               — feed A's % change vs feed B's % change
///           HIT                    — did high/low reach a target at any point
///           CANDLE                 — more green or red candles in a period
///           FIRST_TO_HIT           — high vs low threshold race within a window
///           RANGE_BUCKET           — close in [lowerBound, upperBound) — for neg-risk RANGE
///           BEST_PERFORMER_OUTCOME — myFeed strictly beats peers' % change — for neg-risk BEST_PERFORMER
contract CryptoCREOracle is IMarketOracle, CREReceiverBase {
  // ─── Types ───────────────────────────────────────────────────────────

  enum RuleType {
    THRESHOLD,              // 0
    DIRECTION,              // 1
    CHANGE_PCT,             // 2
    RELATIVE,               // 3
    HIT,                    // 4
    CANDLE,                 // 5 — param = candle interval in seconds
    FIRST_TO_HIT,           // 6 — param = above threshold, paramB = below threshold, interval = sub-interval
    RANGE_BUCKET,           // 7 — param = lowerBound, paramB = upperBound (half-open: [lower, upper)) on closePrice
    BEST_PERFORMER_OUTCOME, // 8 — feedId = mine; peers stored separately; openTimestamp + closesAt define the period
    RANGE_BUCKET_HIGH       // 9 — same as RANGE_BUCKET but on highPrice (for "highest milestone reached" outcomes)
  }

  /// @dev Per-market hint to the off-chain CRE workflow telling it which price
  ///      source to query. The contract itself doesn't read prices from any
  ///      source — it only stores prices the workflow delivered. This field
  ///      makes the routing choice part of the on-chain market config so an
  ///      off-chain admin can't silently flip it post-creation.
  enum DataSource {
    AUTO,             // 0 — workflow decides (Chainlink Feeds for non-OHLC where configured, Binance otherwise)
    CHAINLINK_FEEDS,  // 1 — force Chainlink Data Feeds (on-chain Aggregator)
    CHAINLINK_STREAMS,// 2 — force Chainlink Data Streams (off-chain HTTPS)
    BINANCE           // 3 — force Binance klines REST API
  }

  /// @dev Per-market candle width for Binance kline reads. Only meaningful when
  ///      the workflow's resolved data source is BINANCE; ignored otherwise.
  ///      Mirrors the full set Binance's `/api/v3/klines` endpoint accepts
  ///      (excluding `1s` which has limited endpoint coverage).
  ///      Order is ascending by duration; values must not be reordered without
  ///      a coordinated migration of any markets already initialized.
  enum BinanceInterval {
    ONE_MIN,      // 0  → "1m"
    THREE_MIN,    // 1  → "3m"
    FIVE_MIN,     // 2  → "5m"
    FIFTEEN_MIN,  // 3  → "15m"
    THIRTY_MIN,   // 4  → "30m"
    ONE_HOUR,     // 5  → "1h"
    TWO_HOUR,     // 6  → "2h"
    FOUR_HOUR,    // 7  → "4h"
    SIX_HOUR,     // 8  → "6h"
    EIGHT_HOUR,   // 9  → "8h"
    TWELVE_HOUR,  // 10 → "12h"
    ONE_DAY,      // 11 → "1d"
    THREE_DAY,    // 12 → "3d"
    ONE_WEEK,     // 13 → "1w"
    ONE_MONTH     // 14 → "1M"
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
    DataSource dataSource;          // workflow routing hint
    BinanceInterval binanceInterval; // candle width when source resolves to BINANCE
  }

  struct PriceData {
    int256 closePrice;       // price at this exact timestamp
    int256 highPrice;        // highest price during the period ending at this timestamp
    int256 lowPrice;         // lowest price during the period ending at this timestamp
  }

  // ─── State ───────────────────────────────────────────────────────────

  address public immutable manager;

  /// @dev Verified prices keyed by keccak256(abi.encode(feedId, timestamp)).
  mapping(bytes32 => PriceData) public verifiedPrices;
  mapping(bytes32 => bool) public priceExists;

  mapping(uint256 => MarketConfig) public marketConfigs;

  /// @dev BEST_PERFORMER_OUTCOME: per-market list of competing feed IDs.
  ///      Each constituent in a neg-risk event stores everyone else's feed
  ///      so it can compare its own % change against theirs.
  mapping(uint256 => bytes32[]) internal marketPeerFeedIds;

  // ─── Events ──────────────────────────────────────────────────────────

  event PriceVerified(bytes32 indexed feedId, uint256 indexed timestamp, int256 closePrice, int256 highPrice, int256 lowPrice);
  event MarketConfigured(uint256 indexed marketId, bytes32 feedId, RuleType rule, bool yesAbove, int256 param);

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
  ///
  /// @param data Two encodings are accepted, distinguished by the third field
  ///   (rule). Both formats start with `(bytes32 feedId, bytes32 feedIdB, uint8 rule)`
  ///   so we peek at those three slots first.
  ///
  ///   Standard rules (rule ∈ 0..7, 9):
  ///     abi.encode(bytes32 feedId, bytes32 feedIdB, uint8 rule, bool yesAbove,
  ///                int256 param, uint256 openTimestamp, int256 paramB, uint256 interval,
  ///                uint8 dataSource, uint8 binanceInterval)
  ///
  ///   BEST_PERFORMER_OUTCOME (rule == 8):
  ///     abi.encode(bytes32 myFeedId, bytes32 unused, uint8 rule,
  ///                bytes32[] peerFeedIds, uint256 openTimestamp,
  ///                uint8 dataSource, uint8 binanceInterval)
  function initialize(uint256 marketId, bytes calldata data) external override {
    require(msg.sender == manager, "!manager");
    require(!marketConfigs[marketId].initialized, "already init");

    (bytes32 feedId, , uint8 ruleRaw) = abi.decode(data[:96], (bytes32, bytes32, uint8));
    require(feedId != bytes32(0), "feedId 0");
    require(ruleRaw <= uint8(type(RuleType).max), "invalid rule");
    RuleType rule = RuleType(ruleRaw);

    if (rule == RuleType.BEST_PERFORMER_OUTCOME) {
      _initBestPerformerOutcome(marketId, data);
    } else {
      _initStandard(marketId, data);
    }
  }

  function _initStandard(uint256 marketId, bytes calldata data) internal {
    (
      bytes32 feedId,
      bytes32 feedIdB,
      uint8 ruleRaw,
      bool yesAbove,
      int256 param,
      uint256 openTimestamp,
      int256 paramB,
      uint256 interval,
      uint8 dataSourceRaw,
      uint8 binanceIntervalRaw
    ) = abi.decode(data, (bytes32, bytes32, uint8, bool, int256, uint256, int256, uint256, uint8, uint8));

    RuleType rule = RuleType(ruleRaw);
    require(dataSourceRaw <= uint8(type(DataSource).max), "invalid dataSource");
    require(binanceIntervalRaw <= uint8(type(BinanceInterval).max), "invalid binanceInterval");
    DataSource dataSource = DataSource(dataSourceRaw);

    // OHLC-only rules can't be served by either Chainlink path.
    if (rule == RuleType.HIT || rule == RuleType.CANDLE || rule == RuleType.FIRST_TO_HIT || rule == RuleType.RANGE_BUCKET_HIGH) {
      require(
        dataSource == DataSource.AUTO || dataSource == DataSource.BINANCE,
        "OHLC rule needs binance/auto"
      );
    }

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
    if (rule == RuleType.RANGE_BUCKET || rule == RuleType.RANGE_BUCKET_HIGH) {
      require(paramB > param, "upperBound > lowerBound");
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
      initialized: true,
      dataSource: dataSource,
      binanceInterval: BinanceInterval(binanceIntervalRaw)
    });

    emit MarketConfigured(marketId, feedId, rule, yesAbove, param);
  }

  function _initBestPerformerOutcome(uint256 marketId, bytes calldata data) internal {
    (
      bytes32 myFeedId,
      ,
      uint8 ruleRaw,
      bytes32[] memory peerFeedIds,
      uint256 openTimestamp,
      uint8 dataSourceRaw,
      uint8 binanceIntervalRaw
    ) = abi.decode(data, (bytes32, bytes32, uint8, bytes32[], uint256, uint8, uint8));

    require(peerFeedIds.length > 0, "no peers");
    require(openTimestamp > 0, "openTimestamp required");
    require(dataSourceRaw <= uint8(type(DataSource).max), "invalid dataSource");
    require(binanceIntervalRaw <= uint8(type(BinanceInterval).max), "invalid binanceInterval");
    for (uint256 i = 0; i < peerFeedIds.length; i++) {
      require(peerFeedIds[i] != bytes32(0), "peer feedId 0");
      require(peerFeedIds[i] != myFeedId, "peer = self");
    }

    uint256 closesAt = ICREOracleManagerView(manager).getMarketClosesAt(marketId);

    marketConfigs[marketId] = MarketConfig({
      feedId: myFeedId,
      feedIdB: bytes32(0),
      rule: RuleType(ruleRaw),
      yesAbove: true,
      param: 0,
      closesAt: closesAt,
      openTimestamp: openTimestamp,
      paramB: 0,
      interval: 0,
      initialized: true,
      dataSource: DataSource(dataSourceRaw),
      binanceInterval: BinanceInterval(binanceIntervalRaw)
    });

    bytes32[] storage peers = marketPeerFeedIds[marketId];
    for (uint256 i = 0; i < peerFeedIds.length; i++) {
      peers.push(peerFeedIds[i]);
    }

    emit MarketConfigured(marketId, myFeedId, RuleType(ruleRaw), true, 0);
  }

  // ─── ICREReceiver: onReport ──────────────────────────────────────────

  /// @notice Receives verified price data from the Chainlink CRE workflow.
  /// @param metadata Workflow metadata (contains workflow ID, name, owner).
  /// @param report ABI-encoded (bytes32[] feedIds, uint256[] timestamps, int256[] closePrices, int256[] highPrices, int256[] lowPrices).
  function onReport(bytes calldata metadata, bytes calldata report) external override {
    _validate(metadata);

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
    } else if (config.rule == RuleType.RANGE_BUCKET) {
      return _resolveRangeBucket(config, false);
    } else if (config.rule == RuleType.BEST_PERFORMER_OUTCOME) {
      return _resolveBestPerformerOutcome(config, marketId);
    } else if (config.rule == RuleType.RANGE_BUCKET_HIGH) {
      return _resolveRangeBucket(config, true);
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

  function _resolveRangeBucket(MarketConfig storage config, bool useHigh) internal view returns (int256, bool) {
    bytes32 priceKey = keccak256(abi.encode(config.feedId, config.closesAt));
    if (!priceExists[priceKey]) return (-2, false);

    PriceData storage pd = verifiedPrices[priceKey];
    int256 price = useHigh ? pd.highPrice : pd.closePrice;

    bool inRange = price >= config.param && price < config.paramB;
    return inRange ? (int256(Outcomes.YES), true) : (int256(Outcomes.NO), true);
  }

  function _resolveBestPerformerOutcome(MarketConfig storage config, uint256 marketId)
    internal
    view
    returns (int256, bool)
  {
    (int256 myOpen, bool okMyOpen) = _getClosePrice(config.feedId, config.openTimestamp);
    if (!okMyOpen) return (-2, false);
    (int256 myClose, bool okMyClose) = _getClosePrice(config.feedId, config.closesAt);
    if (!okMyClose) return (-2, false);

    // If my open is 0 we can't compute a meaningful % change → can't win.
    if (myOpen == 0) return (int256(Outcomes.NO), true);

    int256 myAbsOpen = myOpen < 0 ? -myOpen : myOpen;
    int256 myChange = ((myClose - myOpen) * 10000) / myAbsOpen;

    bytes32[] storage peers = marketPeerFeedIds[marketId];
    uint256 n = peers.length;
    for (uint256 i = 0; i < n; i++) {
      (int256 peerOpen, bool okPeerOpen) = _getClosePrice(peers[i], config.openTimestamp);
      if (!okPeerOpen) return (-2, false);
      (int256 peerClose, bool okPeerClose) = _getClosePrice(peers[i], config.closesAt);
      if (!okPeerClose) return (-2, false);

      // Skip peers with a zero open price — they have no comparable %change.
      if (peerOpen == 0) continue;

      int256 peerAbsOpen = peerOpen < 0 ? -peerOpen : peerOpen;
      int256 peerChange = ((peerClose - peerOpen) * 10000) / peerAbsOpen;

      // Strictly greater than every peer to win. Tie at top → NO.
      if (peerChange >= myChange) return (int256(Outcomes.NO), true);
    }

    return (int256(Outcomes.YES), true);
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

  // ─── View helpers ────────────────────────────────────────────────────

  /// @notice Returns the peer feed IDs configured for a BEST_PERFORMER_OUTCOME market.
  function getMarketPeerFeedIds(uint256 marketId) external view returns (bytes32[] memory) {
    return marketPeerFeedIds[marketId];
  }

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
