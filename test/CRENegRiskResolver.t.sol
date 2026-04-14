// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AdminRegistry.sol";
import "../contracts/oracles/CREOracle.sol";
import "../contracts/oracles/CRENegRiskResolver.sol";
import "../contracts/Outcomes.sol";

/// @dev Mock manager for CREOracle.
contract MockCLOBManagerForResolver {
  mapping(uint256 => uint256) public closesAtMap;
  function setClosesAt(uint256 marketId, uint256 closesAt) external { closesAtMap[marketId] = closesAt; }
  function getMarketClosesAt(uint256 marketId) external view returns (uint256) { return closesAtMap[marketId]; }
}

/// @dev Mock NegRiskAdapter that tracks resolveEvent calls.
contract MockNegRiskAdapter {
  struct EventData {
    uint256 outcomeCount;
    bool resolved;
    int256 winningIndex;
  }

  mapping(bytes32 => EventData) public events;

  function createEvent(bytes32 eventId, uint256 outcomeCount) external {
    events[eventId].outcomeCount = outcomeCount;
  }

  function resolveEvent(bytes32 eventId, int256 winningIndex) external {
    EventData storage e = events[eventId];
    require(e.outcomeCount > 0, "event !exist");
    require(!e.resolved, "already resolved");
    e.resolved = true;
    e.winningIndex = winningIndex;
  }

  function getEventOutcomeCount(bytes32 eventId) external view returns (uint256) {
    return events[eventId].outcomeCount;
  }

  function isEventResolved(bytes32 eventId) external view returns (bool) {
    return events[eventId].resolved;
  }

  function getWinningIndex(bytes32 eventId) external view returns (int256) {
    return events[eventId].winningIndex;
  }
}

contract CRENegRiskResolverTest is Test {
  CRENegRiskResolver internal resolver;
  CREOracle internal creOracle;
  MockCLOBManagerForResolver internal mockManager;
  MockNegRiskAdapter internal mockAdapter;
  AdminRegistry internal registry;

  address internal admin;
  address internal marketAdmin;
  address internal forwarder = address(0xF0);
  bytes32 internal workflowId = keccak256("test-workflow");
  bytes32 internal workflowName = bytes32(bytes10("testflow"));
  address internal workflowOwner = address(0xABCD);
  address internal other = address(0xBAD);

  bytes32 internal BTC_FEED = keccak256("BTCUSDT");
  bytes32 internal ETH_FEED = keccak256("ETHUSDT");
  bytes32 internal SOL_FEED = keccak256("SOLUSDT");
  bytes32 internal DOGE_FEED = keccak256("DOGEUSDT");

  function setUp() public {
    admin = address(this);
    marketAdmin = address(0xAD);

    registry = new AdminRegistry(admin);
    registry.grantRole(registry.MARKET_ADMIN_ROLE(), marketAdmin);
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), address(0)); // placeholder

    mockManager = new MockCLOBManagerForResolver();
    mockAdapter = new MockNegRiskAdapter();

    creOracle = new CREOracle(
      address(mockManager),
      forwarder,
      workflowId,
      workflowName,
      workflowOwner
    );

    resolver = new CRENegRiskResolver(
      registry,
      address(mockAdapter),
      creOracle,
      forwarder,
      workflowId,
      workflowName,
      workflowOwner
    );

    // Grant RESOLUTION_ADMIN_ROLE to resolver so it can call resolveEvent on the real adapter
    // (mock doesn't check roles, but we set it for correctness)
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), address(resolver));
  }

  // ─── Helpers ─────────────────────────────────────────────────────────

  function _buildMetadata() internal view returns (bytes memory) {
    bytes32 executionId = keccak256("exec-1");
    return abi.encode(executionId, workflowId, workflowName, bytes32(bytes20(workflowOwner)));
  }

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
    creOracle.onReport(_buildMetadata(), report);
  }

  function _triggerResolve(bytes32 eventId) internal {
    _triggerResolveWith(eventId, int256(0));
  }

  function _triggerResolveWith(bytes32 eventId, int256 winningIndex) internal {
    bytes32[] memory eventIds = new bytes32[](1);
    int256[] memory winningIndices = new int256[](1);
    eventIds[0] = eventId;
    winningIndices[0] = winningIndex;
    bytes memory report = abi.encode(eventIds, winningIndices);
    vm.prank(forwarder);
    resolver.onReport(_buildMetadata(), report);
  }

  // =========================================================================
  // Constructor
  // =========================================================================

  function testConstructorSetsImmutables() public view {
    assertEq(address(resolver.registry()), address(registry));
    assertEq(address(resolver.creOracle()), address(creOracle));
    assertEq(resolver.keystoneForwarder(), forwarder);
  }

  function testConstructorZeroRegistryReverts() public {
    vm.expectRevert("registry 0");
    new CRENegRiskResolver(
      AdminRegistry(address(0)), address(mockAdapter), creOracle,
      forwarder, workflowId, workflowName, workflowOwner
    );
  }

  // =========================================================================
  // configureEvent
  // =========================================================================

  function testConfigureRangeEvent() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 4); // 4 outcomes = 3 boundaries

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 90000e8;
    boundaries[1] = 95000e8;
    boundaries[2] = 100000e8;

    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(
      eventId,
      CRENegRiskResolver.EventRuleType.RANGE,
      feedIds, 0, 200, boundaries
    );

    (CRENegRiskResolver.EventRuleType ruleType,,,,,,bool initialized) = resolver.getEventConfig(eventId);
    assertEq(uint8(ruleType), 0); // RANGE
    assertTrue(initialized);
  }

  function testConfigureNotMarketAdminReverts() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(other);
    vm.expectRevert("not market admin");
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);
  }

  function testConfigureDoubleConfigReverts() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 90000e8;
    boundaries[1] = 95000e8;
    boundaries[2] = 100000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);

    vm.prank(marketAdmin);
    vm.expectRevert("already configured");
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);
  }

  function testConfigureBoundariesNotAscendingReverts() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 100000e8;
    boundaries[1] = 95000e8; // not ascending
    boundaries[2] = 90000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    vm.expectRevert("boundaries not ascending");
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);
  }

  function testConfigureBestPerformerRequiresFeedPerOutcome() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](0);
    bytes32[] memory feedIds = new bytes32[](2); // should be 4
    feedIds[0] = BTC_FEED;
    feedIds[1] = ETH_FEED;

    vm.prank(marketAdmin);
    vm.expectRevert("BEST_PERFORMER: feed per outcome");
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.BEST_PERFORMER, feedIds, 100, 200, boundaries);
  }

  // =========================================================================
  // RANGE resolution
  // =========================================================================

  function testRangeResolvesLowestBucket() public {
    bytes32 eventId = keccak256("range-low");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 90000e8;
    boundaries[1] = 95000e8;
    boundaries[2] = 100000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);

    // Close at 85K -> bucket 0 (< 90K)
    _deliverPrice(BTC_FEED, 200, 85000e8, 90000e8, 80000e8);
    _triggerResolve(eventId);

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 0);
  }

  function testRangeResolvesMiddleBucket() public {
    bytes32 eventId = keccak256("range-mid");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 90000e8;
    boundaries[1] = 95000e8;
    boundaries[2] = 100000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);

    // Close at 97K -> bucket 2 (95K <= 97K < 100K)
    _deliverPrice(BTC_FEED, 200, 97000e8, 100000e8, 95000e8);
    _triggerResolve(eventId);

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 2);
  }

  function testRangeResolvesHighestBucket() public {
    bytes32 eventId = keccak256("range-high");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 90000e8;
    boundaries[1] = 95000e8;
    boundaries[2] = 100000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);

    // Close at 105K -> bucket 3 (>= 100K)
    _deliverPrice(BTC_FEED, 200, 105000e8, 110000e8, 100000e8);
    _triggerResolve(eventId);

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 3);
  }

  function testRangeOnBoundaryGoesToHigherBucket() public {
    bytes32 eventId = keccak256("range-boundary");
    mockAdapter.createEvent(eventId, 3);

    int256[] memory boundaries = new int256[](2);
    boundaries[0] = 90000e8;
    boundaries[1] = 100000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);

    // Close exactly at boundary 90K -> bucket 1 (90K <= 90K < 100K)
    _deliverPrice(BTC_FEED, 200, 90000e8, 95000e8, 85000e8);
    _triggerResolve(eventId);

    assertEq(mockAdapter.getWinningIndex(eventId), 1, "exactly on boundary -> higher bucket");
  }

  // =========================================================================
  // BEST_PERFORMER resolution
  // =========================================================================

  function testBestPerformerResolvesCorrectWinner() public {
    bytes32 eventId = keccak256("best-perf");
    mockAdapter.createEvent(eventId, 4);

    bytes32[] memory feedIds = new bytes32[](4);
    feedIds[0] = BTC_FEED; feedIds[1] = ETH_FEED; feedIds[2] = SOL_FEED; feedIds[3] = DOGE_FEED;
    int256[] memory boundaries = new int256[](0);

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.BEST_PERFORMER, feedIds, 100, 200, boundaries);

    // Open prices
    _deliverPrice(BTC_FEED, 100, 100000e8, 100000e8, 100000e8);
    _deliverPrice(ETH_FEED, 100, 3500e8, 3500e8, 3500e8);
    _deliverPrice(SOL_FEED, 100, 150e8, 150e8, 150e8);
    _deliverPrice(DOGE_FEED, 100, 1000000000, 1000000000, 1000000000); // 10e8

    // Close prices: SOL +20%, BTC +5%, ETH +10%, DOGE +15%
    _deliverPrice(BTC_FEED, 200, 105000e8, 106000e8, 99000e8);       // +5%
    _deliverPrice(ETH_FEED, 200, 3850e8, 3900e8, 3400e8);            // +10%
    _deliverPrice(SOL_FEED, 200, 180e8, 185e8, 145e8);               // +20% winner
    _deliverPrice(DOGE_FEED, 200, 1150000000, 1200000000, 900000000); // 11.5e8 = +15%

    _triggerResolve(eventId);

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 2, "SOL (index 2) had best performance");
  }

  function testBestPerformerTieResolvesToOther() public {
    bytes32 eventId = keccak256("best-tie");
    mockAdapter.createEvent(eventId, 2);

    bytes32[] memory feedIds = new bytes32[](2);
    feedIds[0] = BTC_FEED; feedIds[1] = ETH_FEED;
    int256[] memory boundaries = new int256[](0);

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.BEST_PERFORMER, feedIds, 100, 200, boundaries);

    // Both +10%
    _deliverPrice(BTC_FEED, 100, 100000e8, 100000e8, 100000e8);
    _deliverPrice(ETH_FEED, 100, 3500e8, 3500e8, 3500e8);
    _deliverPrice(BTC_FEED, 200, 110000e8, 110000e8, 100000e8);
    _deliverPrice(ETH_FEED, 200, 3850e8, 3850e8, 3500e8);

    _triggerResolve(eventId);

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), -1, "tie -> Other wins");
  }

  // =========================================================================
  // HIT_MILESTONES resolution
  // =========================================================================

  function testHitMilestonesHighestReached() public {
    bytes32 eventId = keccak256("hit-mile");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 95000e8;
    boundaries[1] = 100000e8;
    boundaries[2] = 105000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.HIT_MILESTONES, feedIds, 0, 200, boundaries);

    // High was 102K -> reached 100K but not 105K -> outcome 2
    _deliverPrice(BTC_FEED, 200, 99000e8, 102000e8, 93000e8);
    _triggerResolve(eventId);

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 2, "reached 100K milestone (index 2)");
  }

  function testHitMilestonesNoneReached() public {
    bytes32 eventId = keccak256("hit-none");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 95000e8;
    boundaries[1] = 100000e8;
    boundaries[2] = 105000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.HIT_MILESTONES, feedIds, 0, 200, boundaries);

    // High was 93K -> didn't reach any milestone -> outcome 0
    _deliverPrice(BTC_FEED, 200, 90000e8, 93000e8, 88000e8);
    _triggerResolve(eventId);

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 0, "no milestone reached -> outcome 0");
  }

  function testHitMilestonesAllReached() public {
    bytes32 eventId = keccak256("hit-all");
    mockAdapter.createEvent(eventId, 4);

    int256[] memory boundaries = new int256[](3);
    boundaries[0] = 95000e8;
    boundaries[1] = 100000e8;
    boundaries[2] = 105000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.HIT_MILESTONES, feedIds, 0, 200, boundaries);

    // High was 110K -> reached all milestones -> outcome 3 (last)
    _deliverPrice(BTC_FEED, 200, 108000e8, 110000e8, 94000e8);
    _triggerResolve(eventId);

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 3, "all milestones reached -> last outcome");
  }

  // =========================================================================
  // CRE validation in onReport
  // =========================================================================

  function testOnReportNotForwarderReverts() public {
    bytes32[] memory eventIds = new bytes32[](1);
    int256[] memory winners = new int256[](1);
    eventIds[0] = keccak256("x");
    bytes memory report = abi.encode(eventIds, winners);

    vm.prank(other);
    vm.expectRevert("!forwarder");
    resolver.onReport(_buildMetadata(), report);
  }

  function testOnReportWrongWorkflowReverts() public {
    bytes32[] memory eventIds = new bytes32[](1);
    int256[] memory winners = new int256[](1);
    eventIds[0] = keccak256("x");
    bytes memory report = abi.encode(eventIds, winners);

    bytes32 execId = keccak256("exec-1");
    bytes memory badMeta = abi.encode(execId, keccak256("wrong"), workflowName, bytes32(bytes20(workflowOwner)));

    vm.prank(forwarder);
    vm.expectRevert("!workflowId");
    resolver.onReport(badMeta, report);
  }

  // =========================================================================
  // Already resolved
  // =========================================================================

  function testAlreadyResolvedReverts() public {
    bytes32 eventId = keccak256("already-done");
    mockAdapter.createEvent(eventId, 3);

    int256[] memory boundaries = new int256[](2);
    boundaries[0] = 90000e8;
    boundaries[1] = 100000e8;
    bytes32[] memory feedIds = new bytes32[](1);
    feedIds[0] = BTC_FEED;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, CRENegRiskResolver.EventRuleType.RANGE, feedIds, 0, 200, boundaries);

    _deliverPrice(BTC_FEED, 200, 95000e8, 100000e8, 90000e8);
    _triggerResolve(eventId);

    // Try again
    vm.expectRevert("already resolved");
    _triggerResolve(eventId);
  }

  // =========================================================================
  // FIRST_TO_HIT resolution
  // =========================================================================

  function testFirstToHitResolvesWinner() public {
    // "Will BTC hit $100K or dip below $80K first?"
    bytes32 eventId = keccak256("first-hit");
    mockAdapter.createEvent(eventId, 2);

    bytes32[] memory feedIds = new bytes32[](2);
    feedIds[0] = BTC_FEED; feedIds[1] = BTC_FEED;
    int256[] memory thresholds = new int256[](2);
    thresholds[0] = 100000e8; // hit above 100K
    thresholds[1] = 80000e8;  // hit below 80K
    bool[] memory directions = new bool[](2);
    directions[0] = true;  // above
    directions[1] = false; // below

    vm.prank(marketAdmin);
    resolver.configureFirstToHitEvent(eventId, feedIds, 200, thresholds, directions);

    // CRE determined outcome 0 won (BTC hit 100K first)
    // Deliver price data showing high reached 102K
    _deliverPrice(BTC_FEED, 200, 99000e8, 102000e8, 85000e8);

    // CRE reports winner = 0
    _triggerResolveWith(eventId, int256(0));

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 0, "BTC hit 100K first");
  }

  function testFirstToHitRejectsIfThresholdNotReached() public {
    bytes32 eventId = keccak256("first-hit-reject");
    mockAdapter.createEvent(eventId, 2);

    bytes32[] memory feedIds = new bytes32[](2);
    feedIds[0] = BTC_FEED; feedIds[1] = BTC_FEED;
    int256[] memory thresholds = new int256[](2);
    thresholds[0] = 100000e8;
    thresholds[1] = 80000e8;
    bool[] memory directions = new bool[](2);
    directions[0] = true;
    directions[1] = false;

    vm.prank(marketAdmin);
    resolver.configureFirstToHitEvent(eventId, feedIds, 200, thresholds, directions);

    // High was only 98K - didn't actually reach 100K threshold
    _deliverPrice(BTC_FEED, 200, 95000e8, 98000e8, 85000e8);

    // CRE falsely reports winner = 0 -> should revert
    vm.expectRevert("threshold not reached");
    _triggerResolveWith(eventId, int256(0));
  }

  function testFirstToHitNeitherHit() public {
    bytes32 eventId = keccak256("first-hit-neither");
    mockAdapter.createEvent(eventId, 2);

    bytes32[] memory feedIds = new bytes32[](2);
    feedIds[0] = BTC_FEED; feedIds[1] = BTC_FEED;
    int256[] memory thresholds = new int256[](2);
    thresholds[0] = 100000e8;
    thresholds[1] = 80000e8;
    bool[] memory directions = new bool[](2);
    directions[0] = true;
    directions[1] = false;

    vm.prank(marketAdmin);
    resolver.configureFirstToHitEvent(eventId, feedIds, 200, thresholds, directions);

    _deliverPrice(BTC_FEED, 200, 90000e8, 95000e8, 85000e8);

    // CRE reports -1 (neither hit by deadline)
    _triggerResolveWith(eventId, int256(-1));

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), -1, "neither hit -> Other wins");
  }

  // =========================================================================
  // Not configured
  // =========================================================================

  function testUnconfiguredEventReverts() public {
    bytes32 eventId = keccak256("not-configured");

    vm.expectRevert("event not configured");
    _triggerResolve(eventId);
  }
}
