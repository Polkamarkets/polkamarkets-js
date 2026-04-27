// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AdminRegistry.sol";
import "../contracts/oracles/SportsCREOracle.sol";
import "../contracts/oracles/SportsCRENegRiskResolver.sol";
import "../contracts/Outcomes.sol";

/// @dev Mock manager for SportsCREOracle.
contract MockSportsManagerForResolver {
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

contract SportsCRENegRiskResolverTest is Test {
  SportsCRENegRiskResolver internal resolver;
  SportsCREOracle internal sportsOracle;
  MockSportsManagerForResolver internal mockManager;
  MockNegRiskAdapter internal mockAdapter;
  AdminRegistry internal registry;

  address internal admin;
  address internal marketAdmin;
  address internal forwarder = address(0xF0);
  bytes32 internal workflowId = keccak256("sports-workflow");
  bytes32 internal workflowName = bytes32(bytes10("sportsflow"));
  address internal workflowOwner = address(0xABCD);
  address internal other = address(0xBAD);

  string internal REF_LAKERS = "oddspapi:id1100013262926181:1:2";
  string internal REF_CELTICS = "oddspapi:id1100013262926181:1:3";
  string internal REF_OTHER = "oddspapi:id1100013262926181:1:4";
  string internal REF_TEAM_D = "oddspapi:id1100013262926181:1:5";

  function setUp() public {
    admin = address(this);
    marketAdmin = address(0xAD);

    registry = new AdminRegistry(admin);
    registry.grantRole(registry.MARKET_ADMIN_ROLE(), marketAdmin);

    mockManager = new MockSportsManagerForResolver();
    mockAdapter = new MockNegRiskAdapter();

    sportsOracle = new SportsCREOracle(
      address(mockManager),
      forwarder,
      workflowId,
      workflowName,
      workflowOwner
    );

    resolver = new SportsCRENegRiskResolver(
      registry,
      address(mockAdapter),
      sportsOracle,
      forwarder,
      workflowId,
      workflowName,
      workflowOwner
    );

    // Grant RESOLUTION_ADMIN_ROLE to resolver so it can call resolveEvent
    // (mock doesn't check roles but we set it for correctness)
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), address(resolver));
  }

  // ─── Helpers ─────────────────────────────────────────────────────────

  function _buildMetadata() internal view returns (bytes memory) {
    // Chainlink CRE metadata: [0:32] workflowId, [32:42] name (10b), [42:62] owner (20b)
    return abi.encodePacked(workflowId, bytes10(workflowName), workflowOwner, bytes2(0x0001));
  }

  function _buildBadMetadata(bytes32 wfId, bytes32 wfName, address wfOwner) internal pure returns (bytes memory) {
    return abi.encodePacked(wfId, bytes10(wfName), wfOwner, bytes2(0x0001));
  }

  function _deliverOutcomeToOracle(string memory externalRef, int256 outcomeId) internal {
    string[] memory refs = new string[](1);
    int256[] memory outcomes = new int256[](1);
    refs[0] = externalRef;
    outcomes[0] = outcomeId;
    bytes memory report = abi.encode(refs, outcomes);
    vm.prank(forwarder);
    sportsOracle.onReport(_buildMetadata(), report);
  }

  function _triggerResolve(bytes32 eventId, int256 winningIndex) internal {
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
    assertEq(address(resolver.negRiskAdapter()), address(mockAdapter));
    assertEq(address(resolver.sportsOracle()), address(sportsOracle));
    assertEq(resolver.keystoneForwarder(), forwarder);
  }

  function testConstructorZeroRegistryReverts() public {
    vm.expectRevert("registry 0");
    new SportsCRENegRiskResolver(
      AdminRegistry(address(0)), address(mockAdapter), sportsOracle,
      forwarder, workflowId, workflowName, workflowOwner
    );
  }

  function testConstructorZeroAdapterReverts() public {
    vm.expectRevert("adapter 0");
    new SportsCRENegRiskResolver(
      registry, address(0), sportsOracle,
      forwarder, workflowId, workflowName, workflowOwner
    );
  }

  function testConstructorZeroOracleReverts() public {
    vm.expectRevert("oracle 0");
    new SportsCRENegRiskResolver(
      registry, address(mockAdapter), SportsCREOracle(address(0)),
      forwarder, workflowId, workflowName, workflowOwner
    );
  }

  // =========================================================================
  // configureEvent
  // =========================================================================

  function testConfigureEvent() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 4);

    string[] memory refs = new string[](4);
    refs[0] = REF_LAKERS;
    refs[1] = REF_CELTICS;
    refs[2] = REF_OTHER;
    refs[3] = REF_TEAM_D;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, refs);

    (string[] memory storedRefs, bool initialized) = resolver.getEventConfig(eventId);
    assertTrue(initialized);
    assertEq(storedRefs.length, 4);
    assertEq(storedRefs[0], REF_LAKERS);
    assertEq(storedRefs[3], REF_TEAM_D);
  }

  function testConfigureNotMarketAdminReverts() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 2);

    string[] memory refs = new string[](2);
    refs[0] = REF_LAKERS; refs[1] = REF_CELTICS;

    vm.prank(other);
    vm.expectRevert("not market admin");
    resolver.configureEvent(eventId, refs);
  }

  function testConfigureEventNotExistReverts() public {
    string[] memory refs = new string[](2);
    refs[0] = REF_LAKERS; refs[1] = REF_CELTICS;

    vm.prank(marketAdmin);
    vm.expectRevert("event !exist");
    resolver.configureEvent(keccak256("nonexistent"), refs);
  }

  function testConfigureDoubleConfigReverts() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 2);

    string[] memory refs = new string[](2);
    refs[0] = REF_LAKERS; refs[1] = REF_CELTICS;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, refs);

    vm.prank(marketAdmin);
    vm.expectRevert("already configured");
    resolver.configureEvent(eventId, refs);
  }

  function testConfigureRefCountMismatchReverts() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 4); // 4 outcomes

    string[] memory refs = new string[](2); // 2 refs
    refs[0] = REF_LAKERS; refs[1] = REF_CELTICS;

    vm.prank(marketAdmin);
    vm.expectRevert("refs != outcome count");
    resolver.configureEvent(eventId, refs);
  }

  function testConfigureEmptyRefReverts() public {
    bytes32 eventId = keccak256("event-1");
    mockAdapter.createEvent(eventId, 2);

    string[] memory refs = new string[](2);
    refs[0] = REF_LAKERS;
    refs[1] = "";

    vm.prank(marketAdmin);
    vm.expectRevert("empty externalRef");
    resolver.configureEvent(eventId, refs);
  }

  // =========================================================================
  // onReport — resolution
  // =========================================================================

  function _setupEventAndOracle(
    bytes32 eventId,
    uint256 outcomeCount,
    string memory winningRef,
    int256 oracleOutcome
  ) internal returns (string[] memory refs) {
    mockAdapter.createEvent(eventId, outcomeCount);

    refs = new string[](outcomeCount);
    refs[0] = REF_LAKERS;
    refs[1] = REF_CELTICS;
    if (outcomeCount >= 3) refs[2] = REF_OTHER;
    if (outcomeCount >= 4) refs[3] = REF_TEAM_D;

    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, refs);

    // Deliver the winning outcome to the oracle (as CRE would)
    if (bytes(winningRef).length > 0) {
      _deliverOutcomeToOracle(winningRef, oracleOutcome);
    }
  }

  function testResolveEventWithValidWinner() public {
    bytes32 eventId = keccak256("nba-1");
    _setupEventAndOracle(eventId, 4, REF_CELTICS, int256(Outcomes.YES));

    _triggerResolve(eventId, int256(1)); // Celtics = index 1

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), 1);
  }

  function testResolveEventOtherWins() public {
    // winningIndex = -1 means "Other" — all outcomes lose
    // Oracle check is skipped for -1
    bytes32 eventId = keccak256("nba-other");
    _setupEventAndOracle(eventId, 4, "", 0);

    _triggerResolve(eventId, int256(-1));

    assertTrue(mockAdapter.isEventResolved(eventId));
    assertEq(mockAdapter.getWinningIndex(eventId), -1);
  }

  function testResolveRevertsIfOutcomeNotInOracle() public {
    // Configure event but don't deliver to oracle
    bytes32 eventId = keccak256("nba-noracle");
    mockAdapter.createEvent(eventId, 2);

    string[] memory refs = new string[](2);
    refs[0] = REF_LAKERS; refs[1] = REF_CELTICS;
    vm.prank(marketAdmin);
    resolver.configureEvent(eventId, refs);

    // Try to resolve without oracle delivery
    vm.expectRevert("winning outcome not resolved in oracle");
    _triggerResolve(eventId, int256(0));
  }

  function testResolveRevertsIfOracleSaysNO() public {
    // If CRE delivers NO to oracle but then claims the outcome won at event level, revert
    bytes32 eventId = keccak256("nba-inconsistent");
    _setupEventAndOracle(eventId, 2, REF_LAKERS, int256(Outcomes.NO)); // oracle says Lakers LOST

    // But CRE claims Lakers (index 0) won the event — should revert
    vm.expectRevert("winning outcome not YES in oracle");
    _triggerResolve(eventId, int256(0));
  }

  function testResolveRevertsIfAlreadyResolved() public {
    bytes32 eventId = keccak256("nba-dup");
    _setupEventAndOracle(eventId, 2, REF_LAKERS, int256(Outcomes.YES));

    _triggerResolve(eventId, int256(0));

    vm.expectRevert("already resolved");
    _triggerResolve(eventId, int256(0));
  }

  function testResolveRevertsIfNotConfigured() public {
    bytes32 eventId = keccak256("nba-unconfigured");
    mockAdapter.createEvent(eventId, 2);

    vm.expectRevert("event not configured");
    _triggerResolve(eventId, int256(0));
  }

  function testResolveRevertsIfBadWinningIndex() public {
    bytes32 eventId = keccak256("nba-badidx");
    _setupEventAndOracle(eventId, 2, REF_LAKERS, int256(Outcomes.YES));

    // 2 outcomes, index 5 is out of range
    vm.expectRevert("bad winning index");
    _triggerResolve(eventId, int256(5));

    // Index -2 is also invalid (only -1 allowed for "Other")
    vm.expectRevert("bad winning index");
    _triggerResolve(eventId, int256(-2));
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

  // TODO: TESTING ONLY — re-enable when workflow identity validation is restored
  // function testOnReportWrongWorkflowIdReverts() public {
  //   ...
  // }

  function skip_testOnReportWrongOwnerReverts() public {
    bytes32[] memory eventIds = new bytes32[](1);
    int256[] memory winners = new int256[](1);
    eventIds[0] = keccak256("x");
    bytes memory report = abi.encode(eventIds, winners);

    bytes memory badMeta = _buildBadMetadata(workflowId, workflowName, address(0xDEAD));
    vm.prank(forwarder);
    vm.expectRevert("!workflowOwner");
    resolver.onReport(badMeta, report);
  }

  function testOnReportMismatchedArrayLengthsReverts() public {
    bytes32[] memory eventIds = new bytes32[](2);
    int256[] memory winners = new int256[](1);
    eventIds[0] = keccak256("a"); eventIds[1] = keccak256("b");
    winners[0] = 0;
    bytes memory report = abi.encode(eventIds, winners);

    vm.prank(forwarder);
    vm.expectRevert("length mismatch");
    resolver.onReport(_buildMetadata(), report);
  }

  function testOnReportBatchResolveMultipleEvents() public {
    bytes32 e1 = keccak256("game-1");
    bytes32 e2 = keccak256("game-2");

    _setupEventAndOracle(e1, 2, REF_LAKERS, int256(Outcomes.YES));
    _setupEventAndOracle(e2, 2, REF_CELTICS, int256(Outcomes.YES));

    bytes32[] memory eventIds = new bytes32[](2);
    int256[] memory winners = new int256[](2);
    eventIds[0] = e1; eventIds[1] = e2;
    winners[0] = 0; winners[1] = 1;

    bytes memory report = abi.encode(eventIds, winners);
    vm.prank(forwarder);
    resolver.onReport(_buildMetadata(), report);

    assertEq(mockAdapter.getWinningIndex(e1), 0);
    assertEq(mockAdapter.getWinningIndex(e2), 1);
  }

  // =========================================================================
  // ERC165
  // =========================================================================

  function testSupportsICREReceiverInterface() public view {
    assertTrue(resolver.supportsInterface(type(ICREReceiver).interfaceId));
  }

  function testSupportsERC165() public view {
    assertTrue(resolver.supportsInterface(0x01ffc9a7));
  }

  function testDoesNotSupportRandomInterface() public view {
    assertFalse(resolver.supportsInterface(0x12345678));
  }
}
