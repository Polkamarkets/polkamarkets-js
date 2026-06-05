// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ICREReceiver
/// @notice Chainlink CRE IReceiver interface (must extend ERC165).
///         Contracts implementing this interface can receive verified reports
///         from the Chainlink KeystoneForwarder.
/// @dev The forwarder verifies ERC165 support for type(ICREReceiver).interfaceId
///      before calling onReport. Implementers MUST return true for it.
interface ICREReceiver is IERC165 {
  /// @notice Called by the KeystoneForwarder to deliver a verified workflow report.
  /// @param metadata Packed metadata (64 bytes): workflowId(32) + workflowName(10) + workflowOwner(20).
  /// @param report ABI-encoded report payload.
  function onReport(bytes calldata metadata, bytes calldata report) external;
}
