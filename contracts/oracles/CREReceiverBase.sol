// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ICREReceiver} from "./ICREReceiver.sol";
import {AdminRegistry} from "../AdminRegistry.sol";

/// @title CREReceiverBase
/// @notice Abstract base for Chainlink CRE receivers. Mirrors the pattern in
///         Chainlink's `ReceiverTemplate`: settable expected values, opt-in
///         per-field validation (a check is enforced only if the expected
///         value is non-zero), and admin-gated rotation.
/// @dev    The forwarder check is always enforced once a forwarder is set.
///         Author and workflow-name checks are opt-in. Workflow id is stored
///         for traceability but never enforced (it changes on every workflow
///         recompile, so enforcing it would couple on-chain contracts to
///         off-chain code releases).
abstract contract CREReceiverBase is ICREReceiver {
  // ─── Storage ─────────────────────────────────────────────────────────

  AdminRegistry public immutable registry;

  address private s_forwarder;
  address private s_expectedAuthor;
  bytes10 private s_expectedWorkflowName;
  bytes32 private s_expectedWorkflowId; // stored for traceability, never enforced

  // ─── Events ──────────────────────────────────────────────────────────

  event ForwarderUpdated(address indexed previous, address indexed current);
  event ExpectedAuthorUpdated(address indexed previous, address indexed current);
  event ExpectedWorkflowNameUpdated(bytes10 indexed previous, bytes10 indexed current);
  event ExpectedWorkflowIdUpdated(bytes32 indexed previous, bytes32 indexed current);

  // ─── Errors ──────────────────────────────────────────────────────────

  error UnauthorizedSender(address sender, address expected);
  error UnauthorizedAuthor(address received, address expected);
  error UnauthorizedWorkflowName(bytes10 received, bytes10 expected);

  // ─── Modifier ────────────────────────────────────────────────────────

  modifier onlyAdmin() {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not admin");
    _;
  }

  // ─── Constructor ─────────────────────────────────────────────────────

  constructor(AdminRegistry _registry, address _forwarder) {
    require(address(_registry) != address(0), "registry 0");
    require(_forwarder != address(0), "forwarder 0");
    registry = _registry;
    s_forwarder = _forwarder;
    emit ForwarderUpdated(address(0), _forwarder);
  }

  // ─── Getters ─────────────────────────────────────────────────────────

  function getForwarder() external view returns (address) {
    return s_forwarder;
  }

  function getExpectedAuthor() external view returns (address) {
    return s_expectedAuthor;
  }

  function getExpectedWorkflowName() external view returns (bytes10) {
    return s_expectedWorkflowName;
  }

  function getExpectedWorkflowId() external view returns (bytes32) {
    return s_expectedWorkflowId;
  }

  // ─── Setters (admin-gated) ───────────────────────────────────────────

  function setForwarder(address forwarder) external onlyAdmin {
    require(forwarder != address(0), "forwarder 0");
    address previous = s_forwarder;
    s_forwarder = forwarder;
    emit ForwarderUpdated(previous, forwarder);
  }

  function setExpectedAuthor(address author) external onlyAdmin {
    address previous = s_expectedAuthor;
    s_expectedAuthor = author;
    emit ExpectedAuthorUpdated(previous, author);
  }

  function setExpectedWorkflowName(bytes10 name) external onlyAdmin {
    bytes10 previous = s_expectedWorkflowName;
    s_expectedWorkflowName = name;
    emit ExpectedWorkflowNameUpdated(previous, name);
  }

  function setExpectedWorkflowId(bytes32 id) external onlyAdmin {
    bytes32 previous = s_expectedWorkflowId;
    s_expectedWorkflowId = id;
    emit ExpectedWorkflowIdUpdated(previous, id);
  }

  // ─── Validation ──────────────────────────────────────────────────────

  /// @dev Subclass `onReport()` MUST call this first. Forwarder check is
  ///      always enforced; author / workflow-name checks are opt-in.
  function _validate(bytes calldata metadata) internal view {
    if (msg.sender != s_forwarder) revert UnauthorizedSender(msg.sender, s_forwarder);

    address expectedAuthor = s_expectedAuthor;
    bytes10 expectedName = s_expectedWorkflowName;

    // Skip metadata decode if no opt-in checks are enabled
    if (expectedAuthor == address(0) && expectedName == bytes10(0)) return;

    (, bytes10 name, address author) = _decodeMetadata(metadata);

    if (expectedAuthor != address(0) && author != expectedAuthor) {
      revert UnauthorizedAuthor(author, expectedAuthor);
    }
    if (expectedName != bytes10(0) && name != expectedName) {
      revert UnauthorizedWorkflowName(name, expectedName);
    }
  }

  /// @dev Chainlink CRE metadata layout (TIGHTLY PACKED, 62 bytes):
  ///        [0:32]  workflowId    (bytes32)
  ///        [32:42] workflowName  (bytes10)
  ///        [42:62] workflowOwner (address, 20 bytes)
  function _decodeMetadata(bytes calldata metadata)
    internal
    pure
    returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
  {
    require(metadata.length >= 62, "metadata too short");
    assembly {
      let base := metadata.offset
      workflowId := calldataload(base)
      workflowName := and(
        calldataload(add(base, 32)),
        0xFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000000000000000
      )
      workflowOwner := shr(96, calldataload(add(base, 42)))
    }
  }

  // ─── ERC165 ──────────────────────────────────────────────────────────

  function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
    return interfaceId == type(ICREReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
  }
}
