// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/oracles/CryptoCREOracle.sol";
import "../contracts/oracles/ICREReceiver.sol";
import "../contracts/AdminRegistry.sol";
import "../contracts/Outcomes.sol";

/// @dev Mock manager that stores closesAt per market (mimics PredictionMarketV3ManagerCLOB).
contract MockCLOBManager {
  mapping(uint256 => uint256) public closesAtMap;

  function setClosesAt(uint256 marketId, uint256 closesAt) external {
    closesAtMap[marketId] = closesAt;
  }

  function getMarketClosesAt(uint256 marketId) external view returns (uint256) {
    return closesAtMap[marketId];
  }
}

contract CryptoCREOracleTest is Test {
  CryptoCREOracle internal oracle;
  MockCLOBManager internal mockManager;
  AdminRegistry internal registry;

  address internal admin;
  address internal marketAdmin = address(0xA2);
  address internal forwarder = address(0xF0);
  bytes32 internal workflowId = keccak256("test-workflow");
  bytes32 internal workflowName = bytes32(bytes10("testflow"));
  address internal workflowOwner = address(0xABCD);
  address internal other = address(0xBAD);

  bytes32 internal BTC_FEED = keccak256("BTCUSDT");
  bytes32 internal ETH_FEED = keccak256("ETHUSDT");

  function setUp() public {
    admin = address(this);
    registry = new AdminRegistry(admin);
    registry.grantRole(registry.MARKET_ADMIN_ROLE(), marketAdmin);

    mockManager = new MockCLOBManager();
    oracle = new CryptoCREOracle(
      registry,
      address(mockManager),
      forwarder
    );

    // Enable opt-in checks so existing tests continue to validate them
    vm.startPrank(marketAdmin);
    oracle.setExpectedAuthor(workflowOwner);
    oracle.setExpectedWorkflowName(bytes10(workflowName));
    oracle.setExpectedWorkflowId(workflowId);
    vm.stopPrank();
  }

  // ─── Helpers ─────────────────────────────────────────────────────────

  /// @dev Builds CRE metadata with the configured workflow identity.
  function _buildMetadata() internal view returns (bytes memory) {
    return _buildMetadata(workflowId, workflowName, workflowOwner);
  }

  function _buildMetadata(bytes32 wfId, bytes32 wfName, address wfOwner) internal pure returns (bytes memory) {
    // Chainlink CRE metadata layout (TIGHTLY PACKED, 64 bytes total):
    // [0:32] workflowId (bytes32)
    // [32:42] workflowName (bytes10)
    // [42:62] workflowOwner (address, 20 bytes)
    // Extra 2 bytes of padding at the end (Chainlink adds reportId to rawReport but it's before the payload, not in metadata)
    return abi.encodePacked(wfId, bytes10(wfName), wfOwner, bytes2(0x0001));
  }

  /// @dev Delivers a single price via onReport.
  function _deliverPrice(bytes32 feedId, uint256 timestamp, int256 close, int256 high, int256 low) internal {
    bytes32[] memory feedIds = new bytes32[](1);
    uint256[] memory timestamps = new uint256[](1);
    int256[] memory closes = new int256[](1);
    int256[] memory highs = new int256[](1);
    int256[] memory lows = new int256[](1);

    feedIds[0] = feedId;
    timestamps[0] = timestamp;
    closes[0] = close;
    highs[0] = high;
    lows[0] = low;

    bytes memory report = abi.encode(feedIds, timestamps, closes, highs, lows);
    vm.prank(forwarder);
    oracle.onReport(_buildMetadata(), report);
  }

  /// @dev Initializes a market on the mock manager and oracle.
  function _initMarket(
    uint256 marketId,
    bytes32 feedId,
    bytes32 feedIdB,
    uint8 rule,
    bool yesAbove,
    int256 param,
    uint256 openTimestamp,
    uint256 closesAt
  ) internal {
    _initMarketFull(marketId, feedId, feedIdB, rule, yesAbove, param, openTimestamp, closesAt, int256(0), uint256(0));
  }

  function _initMarketFull(
    uint256 marketId,
    bytes32 feedId,
    bytes32 feedIdB,
    uint8 rule,
    bool yesAbove,
    int256 param,
    uint256 openTimestamp,
    uint256 closesAt,
    int256 paramB,
    uint256 interval
  ) internal {
    mockManager.setClosesAt(marketId, closesAt);
    bytes memory data = abi.encode(feedId, feedIdB, rule, yesAbove, param, openTimestamp, paramB, interval, uint8(0), uint8(0));
    vm.prank(address(mockManager));
    oracle.initialize(marketId, data);
  }

  // =========================================================================
  // Constructor
  // =========================================================================

  function testConstructorSetsImmutables() public view {
    assertEq(oracle.manager(), address(mockManager));
    assertEq(oracle.getForwarder(), forwarder);
    assertEq(oracle.getExpectedWorkflowId(), workflowId);
    assertEq(oracle.getExpectedAuthor(), workflowOwner);
    assertEq(address(oracle.registry()), address(registry));
  }

  function testConstructorZeroManagerReverts() public {
    vm.expectRevert("manager 0");
    new CryptoCREOracle(registry, address(0), forwarder);
  }

  function testConstructorZeroForwarderReverts() public {
    vm.expectRevert("forwarder 0");
    new CryptoCREOracle(registry, address(mockManager), address(0));
  }

  // =========================================================================
  // initialize
  // =========================================================================

  function testInitializeStoresConfig() public {
    uint256 marketId = 1;
    uint256 closesAt = block.timestamp + 1 days;
    _initMarket(marketId, BTC_FEED, bytes32(0), 0, true, 100000e8, 0, closesAt);

    (
      bytes32 feedId,,
      CryptoCREOracle.RuleType rule,
      bool yesAbove,
      int256 param,
      uint256 storedClosesAt,,,,
      bool initialized,
      ,
    ) = oracle.marketConfigs(marketId);

    assertEq(feedId, BTC_FEED);
    assertEq(uint8(rule), 0); // THRESHOLD
    assertTrue(yesAbove);
    assertEq(param, 100000e8);
    assertEq(storedClosesAt, closesAt);
    assertTrue(initialized);
  }

  function testInitializeNotManagerReverts() public {
    mockManager.setClosesAt(1, block.timestamp + 1 days);
    bytes memory data = abi.encode(BTC_FEED, bytes32(0), uint8(0), true, int256(100000e8), uint256(0), int256(0), uint256(0), uint8(0), uint8(0));
    vm.prank(other);
    vm.expectRevert("!manager");
    oracle.initialize(1, data);
  }

  function testInitializeDoubleInitReverts() public {
    _initMarket(1, BTC_FEED, bytes32(0), 0, true, 100000e8, 0, block.timestamp + 1 days);
    mockManager.setClosesAt(1, block.timestamp + 1 days);
    bytes memory data = abi.encode(BTC_FEED, bytes32(0), uint8(0), true, int256(100000e8), uint256(0), int256(0), uint256(0), uint8(0), uint8(0));
    vm.prank(address(mockManager));
    vm.expectRevert("already init");
    oracle.initialize(1, data);
  }

  function testInitializeZeroFeedReverts() public {
    mockManager.setClosesAt(1, block.timestamp + 1 days);
    bytes memory data = abi.encode(bytes32(0), bytes32(0), uint8(0), true, int256(100000e8), uint256(0), int256(0), uint256(0), uint8(0), uint8(0));
    vm.prank(address(mockManager));
    vm.expectRevert("feedId 0");
    oracle.initialize(1, data);
  }

  function testInitializeRelativeRequiresFeedIdB() public {
    mockManager.setClosesAt(1, block.timestamp + 1 days);
    bytes memory data = abi.encode(BTC_FEED, bytes32(0), uint8(3), true, int256(0), uint256(100), int256(0), uint256(0), uint8(0), uint8(0));
    vm.prank(address(mockManager));
    vm.expectRevert("feedIdB required for RELATIVE");
    oracle.initialize(1, data);
  }

  function testInitializeDirectionRequiresOpenTimestamp() public {
    mockManager.setClosesAt(1, block.timestamp + 1 days);
    bytes memory data = abi.encode(BTC_FEED, bytes32(0), uint8(1), true, int256(0), uint256(0), int256(0), uint256(0), uint8(0), uint8(0));
    vm.prank(address(mockManager));
    vm.expectRevert("openTimestamp required");
    oracle.initialize(1, data);
  }

  // =========================================================================
  // onReport
  // =========================================================================

  function testOnReportStoresPrice() public {
    uint256 ts = 1714608000;
    _deliverPrice(BTC_FEED, ts, 100000e8, 101000e8, 99000e8);

    (int256 close, int256 high, int256 low, bool exists) = oracle.getVerifiedPrice(BTC_FEED, ts);
    assertTrue(exists);
    assertEq(close, 100000e8);
    assertEq(high, 101000e8);
    assertEq(low, 99000e8);
  }

  function testOnReportWriteOnce() public {
    uint256 ts = 1714608000;
    _deliverPrice(BTC_FEED, ts, 100000e8, 101000e8, 99000e8);
    // Deliver again with different values — should be ignored
    _deliverPrice(BTC_FEED, ts, 200000e8, 200000e8, 200000e8);

    (int256 close,,,) = oracle.getVerifiedPrice(BTC_FEED, ts);
    assertEq(close, 100000e8, "write-once: original price preserved");
  }

  function testOnReportNotForwarderReverts() public {
    bytes32[] memory feedIds = new bytes32[](1);
    uint256[] memory timestamps = new uint256[](1);
    int256[] memory prices = new int256[](1);
    feedIds[0] = BTC_FEED;
    timestamps[0] = 100;
    prices[0] = 100000e8;

    bytes memory report = abi.encode(feedIds, timestamps, prices, prices, prices);
    vm.prank(other);
    vm.expectRevert(
      abi.encodeWithSignature(
        "UnauthorizedSender(address,address)",
        other,
        forwarder
      )
    );
    oracle.onReport(_buildMetadata(), report);
  }

  function testOnReportWrongAuthorReverts() public {
    bytes32[] memory feedIds = new bytes32[](1);
    uint256[] memory timestamps = new uint256[](1);
    int256[] memory prices = new int256[](1);
    feedIds[0] = BTC_FEED;
    timestamps[0] = 100;
    prices[0] = 100000e8;

    bytes memory report = abi.encode(feedIds, timestamps, prices, prices, prices);
    bytes memory badMetadata = _buildMetadata(workflowId, workflowName, address(0xDEAD));
    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSignature(
        "UnauthorizedAuthor(address,address)",
        address(0xDEAD),
        workflowOwner
      )
    );
    oracle.onReport(badMetadata, report);
  }

  function testOnReportWrongWorkflowNameReverts() public {
    bytes32[] memory feedIds = new bytes32[](1);
    uint256[] memory timestamps = new uint256[](1);
    int256[] memory prices = new int256[](1);
    feedIds[0] = BTC_FEED;
    timestamps[0] = 100;
    prices[0] = 100000e8;

    bytes memory report = abi.encode(feedIds, timestamps, prices, prices, prices);
    bytes32 wrongName = bytes32(bytes10("WRONG"));
    bytes memory badMetadata = _buildMetadata(workflowId, wrongName, workflowOwner);
    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSignature(
        "UnauthorizedWorkflowName(bytes10,bytes10)",
        bytes10(wrongName),
        bytes10(workflowName)
      )
    );
    oracle.onReport(badMetadata, report);
  }

  /// @notice Workflow ID is stored for traceability but never enforced.
  function testOnReportWrongWorkflowIdDoesNotRevert() public {
    bytes32[] memory feedIds = new bytes32[](1);
    uint256[] memory timestamps = new uint256[](1);
    int256[] memory prices = new int256[](1);
    feedIds[0] = BTC_FEED;
    timestamps[0] = 100;
    prices[0] = 100000e8;

    bytes memory report = abi.encode(feedIds, timestamps, prices, prices, prices);
    bytes memory metadata = _buildMetadata(keccak256("WRONG-WF-ID"), workflowName, workflowOwner);
    vm.prank(forwarder);
    oracle.onReport(metadata, report); // should succeed
    assertTrue(oracle.priceExists(keccak256(abi.encode(BTC_FEED, uint256(100)))));
  }

  function testOnReportBatchMultiplePrices() public {
    bytes32[] memory feedIds = new bytes32[](2);
    uint256[] memory timestamps = new uint256[](2);
    int256[] memory closes = new int256[](2);
    int256[] memory highs = new int256[](2);
    int256[] memory lows = new int256[](2);

    feedIds[0] = BTC_FEED; feedIds[1] = ETH_FEED;
    timestamps[0] = 100; timestamps[1] = 100;
    closes[0] = 100000e8; closes[1] = 3500e8;
    highs[0] = 101000e8; highs[1] = 3600e8;
    lows[0] = 99000e8; lows[1] = 3400e8;

    bytes memory report = abi.encode(feedIds, timestamps, closes, highs, lows);
    vm.prank(forwarder);
    oracle.onReport(_buildMetadata(), report);

    (int256 btcClose,,,) = oracle.getVerifiedPrice(BTC_FEED, 100);
    (int256 ethClose,,,) = oracle.getVerifiedPrice(ETH_FEED, 100);
    assertEq(btcClose, 100000e8);
    assertEq(ethClose, 3500e8);
  }

  // =========================================================================
  // getResult — THRESHOLD
  // =========================================================================

  function testThresholdAboveYes() public {
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, bytes32(0), 0, true, 100000e8, 0, closesAt);
    _deliverPrice(BTC_FEED, closesAt, 105000e8, 105000e8, 95000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testThresholdAboveNo() public {
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, bytes32(0), 0, true, 100000e8, 0, closesAt);
    _deliverPrice(BTC_FEED, closesAt, 95000e8, 100000e8, 90000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testThresholdExactMatch() public {
    uint256 closesAt = 200;
    // yesAbove=true, exact match -> YES ("at or above")
    _initMarket(1, BTC_FEED, bytes32(0), 0, true, 100000e8, 0, closesAt);
    _deliverPrice(BTC_FEED, closesAt, 100000e8, 100000e8, 100000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testThresholdBelowYes() public {
    uint256 closesAt = 200;
    // yesAbove=false -> YES when close < param
    _initMarket(1, BTC_FEED, bytes32(0), 0, false, 100000e8, 0, closesAt);
    _deliverPrice(BTC_FEED, closesAt, 95000e8, 100000e8, 90000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testThresholdNotResolvedWithoutPrice() public {
    _initMarket(1, BTC_FEED, bytes32(0), 0, true, 100000e8, 0, 200);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertFalse(resolved);
    assertEq(outcome, -2);
  }

  // =========================================================================
  // getResult — DIRECTION
  // =========================================================================

  function testDirectionUpYes() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, bytes32(0), 1, true, 0, openTs, closesAt);
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 105000e8, 106000e8, 99000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testDirectionUpNo() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, bytes32(0), 1, true, 0, openTs, closesAt);
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 95000e8, 100000e8, 90000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testDirectionTieIsNo() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    // yesAbove=true (up), but flat -> NO
    _initMarket(1, BTC_FEED, bytes32(0), 1, true, 0, openTs, closesAt);
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 100000e8, 105000e8, 95000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "tie -> NO for direction up");
  }

  function testDirectionDownYes() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, bytes32(0), 1, false, 0, openTs, closesAt);
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 95000e8, 100000e8, 90000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  // =========================================================================
  // getResult — CHANGE_PCT
  // =========================================================================

  function testChangePctAboveYes() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    // param=500 bps (5%), yesAbove=true -> YES if |change| >= 5%
    _initMarket(1, BTC_FEED, bytes32(0), 2, true, 500, openTs, closesAt);
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 106000e8, 106000e8, 100000e8); // +6%

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testChangePctAboveNo() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, bytes32(0), 2, true, 500, openTs, closesAt);
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 103000e8, 103000e8, 100000e8); // +3%

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testChangePctNegativeMovement() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    // |change| uses absolute value — -7% should trigger 500 bps threshold
    _initMarket(1, BTC_FEED, bytes32(0), 2, true, 500, openTs, closesAt);
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 93000e8, 100000e8, 90000e8); // -7%

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES), "-7% move exceeds 5% threshold");
  }

  function testChangePctStayWithinYes() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    // yesAbove=false -> YES if |change| < param
    _initMarket(1, BTC_FEED, bytes32(0), 2, false, 500, openTs, closesAt);
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 102000e8, 102000e8, 100000e8); // +2%

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES), "2% < 5% -> stays within");
  }

  // =========================================================================
  // getResult — RELATIVE
  // =========================================================================

  function testRelativeAOutperformsYes() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    // BTC vs ETH, yesAbove=true -> YES if BTC outperforms
    _initMarket(1, BTC_FEED, ETH_FEED, 3, true, 0, openTs, closesAt);
    // BTC: 100K -> 110K (+10%), ETH: 3500 -> 3675 (+5%)
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 110000e8, 110000e8, 100000e8);
    _deliverPrice(ETH_FEED, openTs, 3500e8, 3500e8, 3500e8);
    _deliverPrice(ETH_FEED, closesAt, 3675e8, 3675e8, 3500e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testRelativeAOutperformsNo() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, ETH_FEED, 3, true, 0, openTs, closesAt);
    // BTC: 100K -> 103K (+3%), ETH: 3500 -> 3850 (+10%)
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 103000e8, 103000e8, 100000e8);
    _deliverPrice(ETH_FEED, openTs, 3500e8, 3500e8, 3500e8);
    _deliverPrice(ETH_FEED, closesAt, 3850e8, 3850e8, 3500e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testRelativeTieIsNo() public {
    uint256 openTs = 100;
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, ETH_FEED, 3, true, 0, openTs, closesAt);
    // Both +10%
    _deliverPrice(BTC_FEED, openTs, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, closesAt, 110000e8, 110000e8, 100000e8);
    _deliverPrice(ETH_FEED, openTs, 3500e8, 3500e8, 3500e8);
    _deliverPrice(ETH_FEED, closesAt, 3850e8, 3850e8, 3500e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "tie -> NO for relative");
  }

  // =========================================================================
  // getResult — HIT
  // =========================================================================

  function testHitAboveYes() public {
    uint256 closesAt = 200;
    // "Will BTC hit 105K?" — yesAbove=true -> YES if high >= 105K
    _initMarket(1, BTC_FEED, bytes32(0), 4, true, 105000e8, 0, closesAt);
    _deliverPrice(BTC_FEED, closesAt, 102000e8, 106000e8, 98000e8); // high=106K >= 105K

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testHitAboveNo() public {
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, bytes32(0), 4, true, 105000e8, 0, closesAt);
    _deliverPrice(BTC_FEED, closesAt, 102000e8, 104000e8, 98000e8); // high=104K < 105K

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testHitBelowYes() public {
    uint256 closesAt = 200;
    // "Will BTC dip below 95K?" — yesAbove=false -> YES if low <= 95K
    _initMarket(1, BTC_FEED, bytes32(0), 4, false, 95000e8, 0, closesAt);
    _deliverPrice(BTC_FEED, closesAt, 98000e8, 102000e8, 94000e8); // low=94K ≤ 95K

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testHitBelowNo() public {
    uint256 closesAt = 200;
    _initMarket(1, BTC_FEED, bytes32(0), 4, false, 95000e8, 0, closesAt);
    _deliverPrice(BTC_FEED, closesAt, 98000e8, 102000e8, 96000e8); // low=96K > 95K

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  // =========================================================================
  // getResult — CANDLE
  // =========================================================================

  function testCandleMoreGreenYes() public {
    // 4 candles of 100s each: openTs=100, closesAt=500, interval=100
    // Candle 1 (100->200): 100K->105K (green)
    // Candle 2 (200->300): 105K->103K (red)
    // Candle 3 (300->400): 103K->108K (green)
    // Candle 4 (400->500): 108K->110K (green)
    // Result: 3 green, 1 red -> YES (yesAbove=true means more green)
    _initMarket(1, BTC_FEED, bytes32(0), 5, true, 100, 100, 500); // rule=5=CANDLE, param=100s interval

    _deliverPrice(BTC_FEED, 100, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, 200, 105000e8, 105000e8, 100000e8);
    _deliverPrice(BTC_FEED, 300, 103000e8, 106000e8, 102000e8);
    _deliverPrice(BTC_FEED, 400, 108000e8, 108000e8, 103000e8);
    _deliverPrice(BTC_FEED, 500, 110000e8, 111000e8, 107000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES), "3 green > 1 red");
  }

  function testCandleMoreRedNo() public {
    // yesAbove=true, but more red candles -> NO
    _initMarket(1, BTC_FEED, bytes32(0), 5, true, 100, 100, 500);

    _deliverPrice(BTC_FEED, 100, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, 200, 98000e8, 100000e8, 97000e8);   // red
    _deliverPrice(BTC_FEED, 300, 96000e8, 98000e8, 95000e8);    // red
    _deliverPrice(BTC_FEED, 400, 97000e8, 97000e8, 95000e8);    // green
    _deliverPrice(BTC_FEED, 500, 94000e8, 97000e8, 93000e8);    // red

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "1 green < 3 red");
  }

  function testCandleMoreRedYesWhenFlipped() public {
    // yesAbove=false means "YES if more red candles"
    _initMarket(1, BTC_FEED, bytes32(0), 5, false, 100, 100, 500);

    _deliverPrice(BTC_FEED, 100, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, 200, 98000e8, 100000e8, 97000e8);   // red
    _deliverPrice(BTC_FEED, 300, 96000e8, 98000e8, 95000e8);    // red
    _deliverPrice(BTC_FEED, 400, 97000e8, 97000e8, 95000e8);    // green
    _deliverPrice(BTC_FEED, 500, 94000e8, 97000e8, 93000e8);    // red

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES), "yesAbove=false, 3 red > 1 green -> YES");
  }

  function testCandleTieIsNo() public {
    // 2 candles: 1 green, 1 red -> tie -> NO
    _initMarket(1, BTC_FEED, bytes32(0), 5, true, 100, 100, 300);

    _deliverPrice(BTC_FEED, 100, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, 200, 105000e8, 105000e8, 100000e8); // green
    _deliverPrice(BTC_FEED, 300, 103000e8, 106000e8, 102000e8); // red

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "1 green == 1 red -> tie -> NO");
  }

  function testCandleFlatCandlesIgnored() public {
    // 3 candles: 1 green, 1 flat, 1 red -> green=1, red=1 -> tie -> NO
    _initMarket(1, BTC_FEED, bytes32(0), 5, true, 100, 100, 400);

    _deliverPrice(BTC_FEED, 100, 100000e8, 100000e8, 100000e8);
    _deliverPrice(BTC_FEED, 200, 105000e8, 105000e8, 100000e8); // green
    _deliverPrice(BTC_FEED, 300, 105000e8, 106000e8, 104000e8); // flat (same close)
    _deliverPrice(BTC_FEED, 400, 103000e8, 105000e8, 102000e8); // red

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "1 green, 1 flat, 1 red -> tie -> NO");
  }

  function testCandleNotResolvedIfMissingPrice() public {
    _initMarket(1, BTC_FEED, bytes32(0), 5, true, 100, 100, 300);
    // Only deliver first price, missing the rest
    _deliverPrice(BTC_FEED, 100, 100000e8, 100000e8, 100000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertFalse(resolved);
    assertEq(outcome, -2);
  }

  // =========================================================================
  // getResult — FIRST_TO_HIT
  // =========================================================================

  function testFirstToHitAboveFirst() public {
    // "Will BTC hit $105K or dip to $90K first?" interval=100s, period 100-500
    // Sub-intervals: [100-200], [200-300], [300-400], [400-500]
    _initMarketFull(1, BTC_FEED, bytes32(0), 6, true, 105000e8, 100, 500, 90000e8, 100);

    // Interval 1 (100-200): high=103K, low=99K — neither hit
    _deliverPrice(BTC_FEED, 200, 101000e8, 103000e8, 99000e8);
    // Interval 2 (200-300): high=106K, low=100K — above hit! below not hit
    _deliverPrice(BTC_FEED, 300, 104000e8, 106000e8, 100000e8);
    // Don't need to deliver more — should resolve at interval 2

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES), "above ($105K) hit first");
  }

  function testFirstToHitBelowFirst() public {
    _initMarketFull(1, BTC_FEED, bytes32(0), 6, true, 105000e8, 100, 500, 90000e8, 100);

    // Interval 1 (100-200): high=102K, low=89K — below hit! above not hit
    _deliverPrice(BTC_FEED, 200, 91000e8, 102000e8, 89000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "below ($90K) hit first");
  }

  function testFirstToHitBothInSameIntervalResolvedInNext() public {
    _initMarketFull(1, BTC_FEED, bytes32(0), 6, true, 105000e8, 100, 500, 90000e8, 100);

    // Interval 1 (100-200): high=106K, low=89K — both hit! inconclusive
    _deliverPrice(BTC_FEED, 200, 95000e8, 106000e8, 89000e8);
    // Interval 2 (200-300): high=104K, low=88K — only below hit
    _deliverPrice(BTC_FEED, 300, 92000e8, 104000e8, 88000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "both hit in interval 1, below only in interval 2");
  }

  function testFirstToHitNeitherHitNotResolved() public {
    _initMarketFull(1, BTC_FEED, bytes32(0), 6, true, 105000e8, 100, 300, 90000e8, 100);

    // Interval 1 (100-200): high=103K, low=92K — neither hit
    _deliverPrice(BTC_FEED, 200, 100000e8, 103000e8, 92000e8);
    // Interval 2 (200-300): high=104K, low=91K — neither hit
    _deliverPrice(BTC_FEED, 300, 100000e8, 104000e8, 91000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertFalse(resolved);
    assertEq(outcome, -2);
  }

  function testFirstToHitMissingPriceNotResolved() public {
    _initMarketFull(1, BTC_FEED, bytes32(0), 6, true, 105000e8, 100, 300, 90000e8, 100);
    // Don't deliver any prices

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertFalse(resolved);
    assertEq(outcome, -2);
  }

  // =========================================================================
  // getResult — not initialized
  // =========================================================================

  function testGetResultNotInitializedReverts() public {
    vm.expectRevert("!init");
    oracle.getResult(999);
  }

  // =========================================================================
  // Price sharing across markets
  // =========================================================================

  function testPriceSharingAcrossMarkets() public {
    uint256 closesAt = 200;
    // Two markets with same feed+closesAt but different thresholds
    _initMarket(1, BTC_FEED, bytes32(0), 0, true, 100000e8, 0, closesAt);
    _initMarket(2, BTC_FEED, bytes32(0), 0, true, 110000e8, 0, closesAt);

    // One price delivery serves both
    _deliverPrice(BTC_FEED, closesAt, 105000e8, 105000e8, 95000e8);

    (int256 outcome1, bool resolved1) = oracle.getResult(1);
    (int256 outcome2, bool resolved2) = oracle.getResult(2);

    assertTrue(resolved1);
    assertTrue(resolved2);
    assertEq(outcome1, int256(Outcomes.YES), "105K >= 100K");
    assertEq(outcome2, int256(Outcomes.NO), "105K < 110K");
  }

  // =========================================================================
  // RANGE_BUCKET (rule 7)
  // =========================================================================

  function testRangeBucketYes() public {
    uint256 closesAt = 200;
    // bucket [100K, 110K)
    _initMarketFull(1, BTC_FEED, bytes32(0), 7, true, 100_000e8, 0, closesAt, 110_000e8, 0);
    _deliverPrice(BTC_FEED, closesAt, 105_000e8, 105_000e8, 105_000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testRangeBucketNoBelow() public {
    uint256 closesAt = 200;
    _initMarketFull(1, BTC_FEED, bytes32(0), 7, true, 100_000e8, 0, closesAt, 110_000e8, 0);
    _deliverPrice(BTC_FEED, closesAt, 99_999e8, 99_999e8, 99_999e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testRangeBucketNoAtUpperBound() public {
    uint256 closesAt = 200;
    _initMarketFull(1, BTC_FEED, bytes32(0), 7, true, 100_000e8, 0, closesAt, 110_000e8, 0);
    // Half-open: price == upperBound is NO (belongs to next bucket)
    _deliverPrice(BTC_FEED, closesAt, 110_000e8, 110_000e8, 110_000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testRangeBucketYesAtLowerBound() public {
    uint256 closesAt = 200;
    _initMarketFull(1, BTC_FEED, bytes32(0), 7, true, 100_000e8, 0, closesAt, 110_000e8, 0);
    // Half-open: price == lowerBound is YES
    _deliverPrice(BTC_FEED, closesAt, 100_000e8, 100_000e8, 100_000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testRangeBucketNotResolvedWithoutFeed() public {
    uint256 closesAt = 200;
    _initMarketFull(1, BTC_FEED, bytes32(0), 7, true, 100_000e8, 0, closesAt, 110_000e8, 0);
    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertFalse(resolved);
    assertEq(outcome, int256(-2));
  }

  function testRangeBucketRequiresUpperGreaterThanLower() public {
    mockManager.setClosesAt(1, 200);
    bytes memory data = abi.encode(BTC_FEED, bytes32(0), uint8(7), true, int256(110_000e8), uint256(0), int256(100_000e8), uint256(0), uint8(0), uint8(0));
    vm.prank(address(mockManager));
    vm.expectRevert("upperBound > lowerBound");
    oracle.initialize(1, data);
  }

  // =========================================================================
  // RANGE_BUCKET_HIGH (rule 9) — for HIT_MILESTONES outcomes
  // =========================================================================

  function testRangeBucketHighReadsHighPrice() public {
    uint256 closesAt = 200;
    // bucket [100K, 110K) on highPrice
    _initMarketFull(1, BTC_FEED, bytes32(0), 9, true, 100_000e8, 0, closesAt, 110_000e8, 0);
    // close=99K but high=105K → high is in range → YES
    _deliverPrice(BTC_FEED, closesAt, 99_000e8, 105_000e8, 90_000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testRangeBucketHighOutOfRange() public {
    uint256 closesAt = 200;
    _initMarketFull(1, BTC_FEED, bytes32(0), 9, true, 100_000e8, 0, closesAt, 110_000e8, 0);
    // high=120K — above upper → NO
    _deliverPrice(BTC_FEED, closesAt, 115_000e8, 120_000e8, 90_000e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  // =========================================================================
  // BEST_PERFORMER_OUTCOME (rule 8)
  // =========================================================================

  function _initBestPerformerMarket(
    uint256 marketId,
    bytes32 myFeedId,
    bytes32[] memory peers,
    uint256 openTimestamp,
    uint256 closesAt
  ) internal {
    mockManager.setClosesAt(marketId, closesAt);
    bytes memory data = abi.encode(myFeedId, bytes32(0), uint8(8), peers, openTimestamp, uint8(0), uint8(0));
    vm.prank(address(mockManager));
    oracle.initialize(marketId, data);
  }

  function testBestPerformerOutcomeUniqueWinner() public {
    bytes32 SOL = keccak256("SOLUSDT");
    bytes32 DOGE = keccak256("DOGEUSDT");

    uint256 openTs = 100;
    uint256 closeTs = 200;

    // Market 1 = BTC. Peers: ETH, SOL, DOGE.
    bytes32[] memory peers = new bytes32[](3);
    peers[0] = ETH_FEED;
    peers[1] = SOL;
    peers[2] = DOGE;
    _initBestPerformerMarket(1, BTC_FEED, peers, openTs, closeTs);

    // Deliver opens (all at $100 for simple math) and closes:
    //   BTC: 100 → 130 (+30%)
    //   ETH: 100 → 110 (+10%)
    //   SOL: 100 → 120 (+20%)
    //   DOGE: 100 → 105 (+5%)
    _deliverPrice(BTC_FEED, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(BTC_FEED, closeTs, 130e8, 130e8, 130e8);
    _deliverPrice(ETH_FEED, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(ETH_FEED, closeTs, 110e8, 110e8, 110e8);
    _deliverPrice(SOL, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(SOL, closeTs, 120e8, 120e8, 120e8);
    _deliverPrice(DOGE, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(DOGE, closeTs, 105e8, 105e8, 105e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES), "BTC wins uniquely");
  }

  function testBestPerformerOutcomeNotWinner() public {
    uint256 openTs = 100;
    uint256 closeTs = 200;

    // Market 2 = ETH (less performer). Peers: BTC.
    bytes32[] memory peers = new bytes32[](1);
    peers[0] = BTC_FEED;
    _initBestPerformerMarket(2, ETH_FEED, peers, openTs, closeTs);

    _deliverPrice(BTC_FEED, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(BTC_FEED, closeTs, 130e8, 130e8, 130e8);
    _deliverPrice(ETH_FEED, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(ETH_FEED, closeTs, 110e8, 110e8, 110e8);

    (int256 outcome, bool resolved) = oracle.getResult(2);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "ETH loses to BTC");
  }

  function testBestPerformerOutcomeTieAtTop() public {
    uint256 openTs = 100;
    uint256 closeTs = 200;

    bytes32[] memory peers = new bytes32[](1);
    peers[0] = ETH_FEED;
    _initBestPerformerMarket(1, BTC_FEED, peers, openTs, closeTs);

    // Identical % change → tie → BTC market resolves NO (strict comparison).
    _deliverPrice(BTC_FEED, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(BTC_FEED, closeTs, 110e8, 110e8, 110e8);
    _deliverPrice(ETH_FEED, openTs, 200e8, 200e8, 200e8);
    _deliverPrice(ETH_FEED, closeTs, 220e8, 220e8, 220e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO), "tie -> NO");
  }

  function testBestPerformerOutcomeNotReadyMissingPeerOpen() public {
    uint256 openTs = 100;
    uint256 closeTs = 200;

    bytes32[] memory peers = new bytes32[](1);
    peers[0] = ETH_FEED;
    _initBestPerformerMarket(1, BTC_FEED, peers, openTs, closeTs);

    _deliverPrice(BTC_FEED, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(BTC_FEED, closeTs, 130e8, 130e8, 130e8);
    _deliverPrice(ETH_FEED, closeTs, 110e8, 110e8, 110e8);
    // Peer's open price is missing.

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertFalse(resolved);
    assertEq(outcome, int256(-2));
  }

  function testBestPerformerOutcomeMyOpenZero() public {
    uint256 openTs = 100;
    uint256 closeTs = 200;

    bytes32[] memory peers = new bytes32[](1);
    peers[0] = ETH_FEED;
    _initBestPerformerMarket(1, BTC_FEED, peers, openTs, closeTs);

    // My open price is zero — can't compute %change → automatic NO
    _deliverPrice(BTC_FEED, openTs, 0, 0, 0);
    _deliverPrice(BTC_FEED, closeTs, 130e8, 130e8, 130e8);
    _deliverPrice(ETH_FEED, openTs, 100e8, 100e8, 100e8);
    _deliverPrice(ETH_FEED, closeTs, 110e8, 110e8, 110e8);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testBestPerformerOutcomeRejectsSelfAsPeer() public {
    bytes32[] memory peers = new bytes32[](1);
    peers[0] = BTC_FEED; // same as myFeedId
    mockManager.setClosesAt(1, 200);
    bytes memory data = abi.encode(BTC_FEED, bytes32(0), uint8(8), peers, uint256(100), uint8(0), uint8(0));
    vm.prank(address(mockManager));
    vm.expectRevert("peer = self");
    oracle.initialize(1, data);
  }

  function testBestPerformerOutcomeRejectsEmptyPeers() public {
    bytes32[] memory peers = new bytes32[](0);
    mockManager.setClosesAt(1, 200);
    bytes memory data = abi.encode(BTC_FEED, bytes32(0), uint8(8), peers, uint256(100), uint8(0), uint8(0));
    vm.prank(address(mockManager));
    vm.expectRevert("no peers");
    oracle.initialize(1, data);
  }

  function testBestPerformerOutcomePeerListGetter() public {
    bytes32[] memory peers = new bytes32[](2);
    peers[0] = ETH_FEED;
    peers[1] = keccak256("SOLUSDT");
    _initBestPerformerMarket(1, BTC_FEED, peers, 100, 200);

    bytes32[] memory got = oracle.getMarketPeerFeedIds(1);
    assertEq(got.length, 2);
    assertEq(got[0], ETH_FEED);
    assertEq(got[1], peers[1]);
  }
}
