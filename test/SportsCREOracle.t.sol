// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/oracles/SportsCREOracle.sol";
import "../contracts/oracles/ICREReceiver.sol";
import "../contracts/AdminRegistry.sol";
import "../contracts/Outcomes.sol";

/// @dev Mock manager that stores closesAt per market.
contract MockSportsManager {
  mapping(uint256 => uint256) public closesAtMap;

  function setClosesAt(uint256 marketId, uint256 closesAt) external {
    closesAtMap[marketId] = closesAt;
  }

  function getMarketClosesAt(uint256 marketId) external view returns (uint256) {
    return closesAtMap[marketId];
  }
}

contract SportsCREOracleTest is Test {
  SportsCREOracle internal oracle;
  MockSportsManager internal mockManager;
  AdminRegistry internal registry;

  address internal admin;
  address internal marketAdmin = address(0xA2);
  address internal forwarder = address(0xF0);
  bytes32 internal workflowId = keccak256("sports-workflow");
  bytes32 internal workflowName = bytes32(bytes10("sportsflow"));
  address internal workflowOwner = address(0xABCD);
  address internal other = address(0xBAD);

  // Ref v2 (ENG-3264): apisports:{sport}.{fixtureId}:{1x2|ml}:{home|away|draw}.
  // The contract never parses the ref; these only need to be unique strings.
  string internal REF_NBA = "apisports:basketball.519594:ml:away";
  string internal REF_NFL = "apisports:americanfootball.21620:ml:home";
  // Longest realistic ref v2: the longest sport name, a 10-digit fixture id, "draw".
  string internal REF_LONGEST = "apisports:americanfootball.4294967295:1x2:draw";
  string internal REF_LEGACY = "oddspapi:id1100013262926181:1:2";

  function setUp() public {
    admin = address(this);
    registry = new AdminRegistry(admin);
    registry.grantRole(registry.MARKET_ADMIN_ROLE(), marketAdmin);

    mockManager = new MockSportsManager();
    oracle = new SportsCREOracle(
      registry,
      address(mockManager),
      forwarder
    );

    // Enable opt-in checks
    vm.startPrank(marketAdmin);
    oracle.setExpectedAuthor(workflowOwner);
    oracle.setExpectedWorkflowName(bytes10(workflowName));
    oracle.setExpectedWorkflowId(workflowId);
    vm.stopPrank();
  }

  // ─── Helpers ─────────────────────────────────────────────────────────

  function _buildMetadata() internal view returns (bytes memory) {
    return _buildMetadata(workflowId, workflowName, workflowOwner);
  }

  function _buildMetadata(bytes32 wfId, bytes32 wfName, address wfOwner) internal pure returns (bytes memory) {
    // Chainlink CRE metadata layout (TIGHTLY PACKED, 64 bytes total):
    // [0:32] workflowId, [32:42] workflowName (10 bytes), [42:62] workflowOwner (20 bytes)
    return abi.encodePacked(wfId, bytes10(wfName), wfOwner, bytes2(0x0001));
  }

  function _deliverResult(string memory externalRef, int256 outcomeId) internal {
    string[] memory refs = new string[](1);
    int256[] memory outcomes = new int256[](1);
    refs[0] = externalRef;
    outcomes[0] = outcomeId;
    bytes memory report = abi.encode(refs, outcomes);
    vm.prank(forwarder);
    oracle.onReport(_buildMetadata(), report);
  }

  function _initMarket(uint256 marketId, string memory externalRef, uint256 closesAt) internal {
    mockManager.setClosesAt(marketId, closesAt);
    bytes memory data = abi.encode(externalRef);
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
    new SportsCREOracle(registry, address(0), forwarder);
  }

  function testConstructorZeroForwarderReverts() public {
    vm.expectRevert("forwarder 0");
    new SportsCREOracle(registry, address(mockManager), address(0));
  }

  // =========================================================================
  // initialize
  // =========================================================================

  function testInitializeStoresConfig() public {
    uint256 marketId = 1;
    uint256 closesAt = block.timestamp + 1 days;
    _initMarket(marketId, REF_NBA, closesAt);

    (string memory ref, bytes32 refHash) = oracle.getMarketExternalRef(marketId);
    assertEq(ref, REF_NBA);
    assertEq(refHash, keccak256(bytes(REF_NBA)));
  }

  function testInitializeNotManagerReverts() public {
    mockManager.setClosesAt(1, block.timestamp + 1 days);
    bytes memory data = abi.encode(REF_NBA);
    vm.prank(other);
    vm.expectRevert("!manager");
    oracle.initialize(1, data);
  }

  function testInitializeDoubleInitReverts() public {
    _initMarket(1, REF_NBA, block.timestamp + 1 days);
    bytes memory data = abi.encode(REF_NBA);
    vm.prank(address(mockManager));
    vm.expectRevert("already init");
    oracle.initialize(1, data);
  }

  function testInitializeEmptyRefReverts() public {
    mockManager.setClosesAt(1, block.timestamp + 1 days);
    bytes memory data = abi.encode("");
    vm.prank(address(mockManager));
    vm.expectRevert("externalRef required");
    oracle.initialize(1, data);
  }

  // =========================================================================
  // onReport
  // =========================================================================

  function testOnReportStoresOutcome() public {
    _deliverResult(REF_NBA, int256(Outcomes.YES));

    bytes32 refHash = keccak256(bytes(REF_NBA));
    assertTrue(oracle.outcomeResolved(refHash));
    assertEq(oracle.resolvedOutcomes(refHash), int256(Outcomes.YES));
  }

  function testOnReportWriteOnce() public {
    _deliverResult(REF_NBA, int256(Outcomes.YES));
    // Attempt to overwrite with NO
    _deliverResult(REF_NBA, int256(Outcomes.NO));

    bytes32 refHash = keccak256(bytes(REF_NBA));
    assertEq(oracle.resolvedOutcomes(refHash), int256(Outcomes.YES), "write-once: original preserved");
  }

  function testOnReportNotForwarderReverts() public {
    string[] memory refs = new string[](1);
    int256[] memory outcomes = new int256[](1);
    refs[0] = REF_NBA;
    outcomes[0] = int256(Outcomes.YES);
    bytes memory report = abi.encode(refs, outcomes);

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
    string[] memory refs = new string[](1);
    int256[] memory outcomes = new int256[](1);
    refs[0] = REF_NBA;
    outcomes[0] = int256(Outcomes.YES);
    bytes memory report = abi.encode(refs, outcomes);

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

  /// @notice Workflow ID is stored for traceability but never enforced.
  function testOnReportWrongWorkflowIdDoesNotRevert() public {
    string[] memory refs = new string[](1);
    int256[] memory outcomes = new int256[](1);
    refs[0] = REF_NBA;
    outcomes[0] = int256(Outcomes.YES);
    bytes memory report = abi.encode(refs, outcomes);

    bytes memory metadata = _buildMetadata(keccak256("WRONG-WF-ID"), workflowName, workflowOwner);
    vm.prank(forwarder);
    oracle.onReport(metadata, report); // should succeed
    assertTrue(oracle.outcomeResolved(keccak256(bytes(REF_NBA))));
  }

  function testOnReportInvalidOutcomeReverts() public {
    string[] memory refs = new string[](1);
    int256[] memory outcomes = new int256[](1);
    refs[0] = REF_NBA;
    outcomes[0] = 999; // not YES/NO/VOIDED
    bytes memory report = abi.encode(refs, outcomes);

    vm.prank(forwarder);
    vm.expectRevert("invalid outcomeId");
    oracle.onReport(_buildMetadata(), report);
  }

  function testOnReportBatchMultiple() public {
    string[] memory refs = new string[](2);
    int256[] memory outcomes = new int256[](2);
    refs[0] = REF_NBA; refs[1] = REF_NFL;
    outcomes[0] = int256(Outcomes.YES); outcomes[1] = int256(Outcomes.NO);
    bytes memory report = abi.encode(refs, outcomes);

    vm.prank(forwarder);
    oracle.onReport(_buildMetadata(), report);

    assertEq(oracle.resolvedOutcomes(keccak256(bytes(REF_NBA))), int256(Outcomes.YES));
    assertEq(oracle.resolvedOutcomes(keccak256(bytes(REF_NFL))), int256(Outcomes.NO));
  }

  function testOnReportVoidedOutcome() public {
    _deliverResult(REF_NBA, Outcomes.VOIDED);
    bytes32 refHash = keccak256(bytes(REF_NBA));
    assertEq(oracle.resolvedOutcomes(refHash), Outcomes.VOIDED);
  }

  // =========================================================================
  // getResult
  // =========================================================================

  function testGetResultNotInitializedReverts() public {
    vm.expectRevert("!init");
    oracle.getResult(999);
  }

  function testGetResultBeforeReport() public {
    _initMarket(1, REF_NBA, block.timestamp + 1 days);
    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertEq(outcome, -2);
    assertFalse(resolved);
  }

  function testGetResultYes() public {
    _initMarket(1, REF_NBA, block.timestamp + 1 days);
    _deliverResult(REF_NBA, int256(Outcomes.YES));

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  function testGetResultNo() public {
    _initMarket(1, REF_NBA, block.timestamp + 1 days);
    _deliverResult(REF_NBA, int256(Outcomes.NO));

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }

  function testGetResultVoided() public {
    _initMarket(1, REF_NBA, block.timestamp + 1 days);
    _deliverResult(REF_NBA, Outcomes.VOIDED);

    (int256 outcome, bool resolved) = oracle.getResult(1);
    assertTrue(resolved);
    assertEq(outcome, Outcomes.VOIDED);
  }

  // =========================================================================
  // Shared externalRef across markets
  // =========================================================================

  function testSharedRefResolvesBothMarkets() public {
    // Two markets with the same externalRef (rare but possible)
    _initMarket(1, REF_NBA, block.timestamp + 1 days);
    _initMarket(2, REF_NBA, block.timestamp + 2 days);

    // One delivery resolves both
    _deliverResult(REF_NBA, int256(Outcomes.YES));

    (int256 outcome1, bool resolved1) = oracle.getResult(1);
    (int256 outcome2, bool resolved2) = oracle.getResult(2);

    assertTrue(resolved1);
    assertTrue(resolved2);
    assertEq(outcome1, int256(Outcomes.YES));
    assertEq(outcome2, int256(Outcomes.YES));
  }

  // =========================================================================
  // ERC165
  // =========================================================================

  function testSupportsICREReceiverInterface() public view {
    assertTrue(oracle.supportsInterface(type(ICREReceiver).interfaceId));
  }

  function testSupportsERC165() public view {
    assertTrue(oracle.supportsInterface(0x01ffc9a7));
  }

  function testDoesNotSupportRandomInterface() public view {
    assertFalse(oracle.supportsInterface(0x12345678));
  }

  // =========================================================================
  // Ref v2 (ENG-3271): the ref is opaque to the contract, so the switch from
  // oddspapi: to apisports: refs is data-only. These lock the format in.
  // =========================================================================

  function testRefV2LongestInitializesAndResolves() public {
    assertEq(bytes(REF_LONGEST).length, 46);
    _initMarket(7, REF_LONGEST, block.timestamp + 1 days);

    (string memory ref, bytes32 refHash) = oracle.getMarketExternalRef(7);
    assertEq(ref, REF_LONGEST);
    assertEq(refHash, keccak256(bytes(REF_LONGEST)));

    _deliverResult(REF_LONGEST, int256(Outcomes.YES));
    (int256 outcome, bool resolved) = oracle.getResult(7);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.YES));
  }

  /// A 3-way event (soccer 1x2, or NFL after a tie) is three markets with three
  /// refs on one fixture: the draw ref resolves YES, both team refs NO.
  function testRefV2ThreeWayEventResolvesEachSideIndependently() public {
    string memory home = "apisports:americanfootball.21620:ml:home";
    string memory draw = "apisports:americanfootball.21620:ml:draw";
    string memory away = "apisports:americanfootball.21620:ml:away";
    _initMarket(10, home, block.timestamp + 1 days);
    _initMarket(11, draw, block.timestamp + 1 days);
    _initMarket(12, away, block.timestamp + 1 days);

    string[] memory refs = new string[](3);
    int256[] memory outcomes = new int256[](3);
    refs[0] = home; outcomes[0] = int256(Outcomes.NO);
    refs[1] = draw; outcomes[1] = int256(Outcomes.YES);
    refs[2] = away; outcomes[2] = int256(Outcomes.NO);
    vm.prank(forwarder);
    oracle.onReport(_buildMetadata(), abi.encode(refs, outcomes));

    (int256 o10,) = oracle.getResult(10);
    (int256 o11,) = oracle.getResult(11);
    (int256 o12,) = oracle.getResult(12);
    assertEq(o10, int256(Outcomes.NO));
    assertEq(o11, int256(Outcomes.YES));
    assertEq(o12, int256(Outcomes.NO));
  }

  /// Sides of one fixture hash differently, so a report for one side never
  /// touches another (the write-once store is per ref, not per fixture).
  function testRefV2SidesOfOneFixtureAreDistinct() public {
    string memory home = "apisports:football.1549529:1x2:home";
    string memory draw = "apisports:football.1549529:1x2:draw";
    assertTrue(keccak256(bytes(home)) != keccak256(bytes(draw)));
    _initMarket(20, home, block.timestamp + 1 days);
    _initMarket(21, draw, block.timestamp + 1 days);
    _deliverResult(home, int256(Outcomes.YES));
    (, bool drawResolved) = oracle.getResult(21);
    assertFalse(drawResolved);
  }

  /// Legacy OddsPapi refs still initialize (the contract is ref-agnostic); the
  /// CRE workflow is what refuses to resolve them.
  function testLegacyRefStillInitializes() public {
    _initMarket(30, REF_LEGACY, block.timestamp + 1 days);
    (, bool resolved) = oracle.getResult(30);
    assertFalse(resolved);
  }

  /// onReport has no timing guard: a result can land before the market closes.
  /// Acceptable for end-of-game markets (kickoff = close); documented in
  /// scripts/CRE_RUNBOOK.md.
  function testOnReportAcceptedBeforeClose() public {
    _initMarket(40, REF_NBA, block.timestamp + 30 days);
    _deliverResult(REF_NBA, int256(Outcomes.NO));
    (int256 outcome, bool resolved) = oracle.getResult(40);
    assertTrue(resolved);
    assertEq(outcome, int256(Outcomes.NO));
  }
}
