// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {CREReceiverBase} from "../contracts/oracles/CREReceiverBase.sol";
import {ICREReceiver} from "../contracts/oracles/ICREReceiver.sol";
import {AdminRegistry} from "../contracts/AdminRegistry.sol";

/// @dev Concrete subclass for testing the abstract base directly. Captures
///      `report` bytes so we can assert that `_validate` ran before the body.
contract MockReceiver is CREReceiverBase {
  bytes public lastReport;

  constructor(AdminRegistry _registry, address _forwarder)
    CREReceiverBase(_registry, _forwarder) {}

  function onReport(bytes calldata metadata, bytes calldata report) external override {
    _validate(metadata);
    lastReport = report;
  }
}

contract CREReceiverBaseTest is Test {
  AdminRegistry internal registry;
  MockReceiver internal receiver;

  address internal admin;
  address internal marketAdmin = address(0xA2);
  address internal forwarder = address(0xF0);
  address internal other = address(0xBAD);

  bytes32 internal workflowId = keccak256("workflow-id");
  bytes10 internal workflowName = bytes10("flowname");
  address internal workflowOwner = address(0xABCD);

  function setUp() public {
    admin = address(this);
    registry = new AdminRegistry(admin);
    registry.grantRole(registry.MARKET_ADMIN_ROLE(), marketAdmin);

    receiver = new MockReceiver(registry, forwarder);
  }

  function _buildMetadata(bytes32 wfId, bytes10 wfName, address wfOwner)
    internal pure returns (bytes memory)
  {
    return abi.encodePacked(wfId, wfName, wfOwner, bytes2(0x0001));
  }

  function _buildMetadata() internal view returns (bytes memory) {
    return _buildMetadata(workflowId, workflowName, workflowOwner);
  }

  // ─── Constructor ─────────────────────────────────────────────────────

  function testConstructorStoresForwarder() public view {
    assertEq(receiver.getForwarder(), forwarder);
    assertEq(address(receiver.registry()), address(registry));
  }

  function testConstructorRevertsZeroRegistry() public {
    vm.expectRevert("registry 0");
    new MockReceiver(AdminRegistry(address(0)), forwarder);
  }

  function testConstructorRevertsZeroForwarder() public {
    vm.expectRevert("forwarder 0");
    new MockReceiver(registry, address(0));
  }

  function testConstructorEmitsForwarderUpdated() public {
    vm.expectEmit(true, true, false, false);
    emit CREReceiverBase.ForwarderUpdated(address(0), forwarder);
    new MockReceiver(registry, forwarder);
  }

  // ─── Default state: all expected values zero, only forwarder check active ────

  function testDefaultStateNoOptIn() public {
    assertEq(receiver.getExpectedAuthor(), address(0));
    assertEq(receiver.getExpectedWorkflowName(), bytes10(0));
    assertEq(receiver.getExpectedWorkflowId(), bytes32(0));
  }

  function testForwarderCheckAlwaysActive() public {
    bytes memory report = "test-report";
    vm.prank(other);
    vm.expectRevert(
      abi.encodeWithSignature("UnauthorizedSender(address,address)", other, forwarder)
    );
    receiver.onReport(_buildMetadata(), report);
  }

  function testForwarderAcceptedWhenNoOptInChecks() public {
    bytes memory report = "test-report";
    // Default state: author and name are zero, so only forwarder check runs.
    vm.prank(forwarder);
    receiver.onReport(_buildMetadata(), report);
    assertEq(receiver.lastReport(), report);
  }

  // ─── Setters ─────────────────────────────────────────────────────────

  function testSetForwarder() public {
    address newForwarder = address(0xF1);
    vm.prank(marketAdmin);
    vm.expectEmit(true, true, false, false);
    emit CREReceiverBase.ForwarderUpdated(forwarder, newForwarder);
    receiver.setForwarder(newForwarder);
    assertEq(receiver.getForwarder(), newForwarder);
  }

  function testSetForwarderZeroReverts() public {
    vm.prank(marketAdmin);
    vm.expectRevert("forwarder 0");
    receiver.setForwarder(address(0));
  }

  function testSetForwarderNotAdminReverts() public {
    vm.prank(other);
    vm.expectRevert("not admin");
    receiver.setForwarder(address(0xF1));
  }

  function testSetExpectedAuthor() public {
    vm.prank(marketAdmin);
    vm.expectEmit(true, true, false, false);
    emit CREReceiverBase.ExpectedAuthorUpdated(address(0), workflowOwner);
    receiver.setExpectedAuthor(workflowOwner);
    assertEq(receiver.getExpectedAuthor(), workflowOwner);
  }

  function testSetExpectedAuthorNotAdminReverts() public {
    vm.prank(other);
    vm.expectRevert("not admin");
    receiver.setExpectedAuthor(workflowOwner);
  }

  function testSetExpectedWorkflowName() public {
    vm.prank(marketAdmin);
    receiver.setExpectedWorkflowName(workflowName);
    assertEq(receiver.getExpectedWorkflowName(), workflowName);
  }

  function testSetExpectedWorkflowId() public {
    vm.prank(marketAdmin);
    receiver.setExpectedWorkflowId(workflowId);
    assertEq(receiver.getExpectedWorkflowId(), workflowId);
  }

  // ─── Opt-in author check ─────────────────────────────────────────────

  function testAuthorCheckPassesWhenAuthorMatches() public {
    vm.prank(marketAdmin);
    receiver.setExpectedAuthor(workflowOwner);

    vm.prank(forwarder);
    receiver.onReport(_buildMetadata(), "ok");
    assertEq(receiver.lastReport(), "ok");
  }

  function testAuthorCheckFailsWhenAuthorMismatch() public {
    vm.prank(marketAdmin);
    receiver.setExpectedAuthor(workflowOwner);

    bytes memory bad = _buildMetadata(workflowId, workflowName, address(0xDEAD));
    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSignature(
        "UnauthorizedAuthor(address,address)", address(0xDEAD), workflowOwner
      )
    );
    receiver.onReport(bad, "x");
  }

  // ─── Opt-in workflow-name check ─────────────────────────────────────

  function testNameCheckPassesWhenNameMatches() public {
    vm.startPrank(marketAdmin);
    receiver.setExpectedWorkflowName(workflowName);
    vm.stopPrank();

    vm.prank(forwarder);
    receiver.onReport(_buildMetadata(), "ok");
    assertEq(receiver.lastReport(), "ok");
  }

  function testNameCheckFailsWhenNameMismatch() public {
    vm.startPrank(marketAdmin);
    receiver.setExpectedWorkflowName(workflowName);
    vm.stopPrank();

    bytes10 wrongName = bytes10("WRONG");
    bytes memory bad = _buildMetadata(workflowId, wrongName, workflowOwner);
    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSignature(
        "UnauthorizedWorkflowName(bytes10,bytes10)", wrongName, workflowName
      )
    );
    receiver.onReport(bad, "x");
  }

  // ─── Workflow ID is NEVER enforced ───────────────────────────────────

  function testWorkflowIdNeverEnforced() public {
    // Even when expectedWorkflowId is set to a specific value, mismatch must NOT revert.
    vm.startPrank(marketAdmin);
    receiver.setExpectedWorkflowId(workflowId);
    vm.stopPrank();

    bytes memory wrongIdMeta = _buildMetadata(keccak256("WRONG-ID"), workflowName, workflowOwner);
    vm.prank(forwarder);
    receiver.onReport(wrongIdMeta, "ok"); // should succeed
    assertEq(receiver.lastReport(), "ok");
  }

  // ─── Forwarder rotation ──────────────────────────────────────────────

  function testForwarderRotation() public {
    address newForwarder = address(0xF1);
    vm.prank(marketAdmin);
    receiver.setForwarder(newForwarder);

    // Old forwarder no longer accepted
    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSignature("UnauthorizedSender(address,address)", forwarder, newForwarder)
    );
    receiver.onReport(_buildMetadata(), "x");

    // New forwarder accepted
    vm.prank(newForwarder);
    receiver.onReport(_buildMetadata(), "ok");
    assertEq(receiver.lastReport(), "ok");
  }

  // ─── Metadata length validation ──────────────────────────────────────

  function testShortMetadataReverts() public {
    // Enable a check so the decoder runs
    vm.prank(marketAdmin);
    receiver.setExpectedAuthor(workflowOwner);

    bytes memory shortMeta = abi.encodePacked(workflowId); // only 32 bytes, need 62+
    vm.prank(forwarder);
    vm.expectRevert("metadata too short");
    receiver.onReport(shortMeta, "x");
  }

  // ─── ERC165 ──────────────────────────────────────────────────────────

  function testSupportsInterface() public view {
    assertTrue(receiver.supportsInterface(type(ICREReceiver).interfaceId));
    assertTrue(receiver.supportsInterface(0x01ffc9a7)); // ERC165 itself
    assertFalse(receiver.supportsInterface(0xdeadbeef));
  }
}
