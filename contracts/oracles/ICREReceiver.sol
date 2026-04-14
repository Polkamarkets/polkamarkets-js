// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICREReceiver
/// @notice Minimal Chainlink CRE IReceiver interface.
///         Contracts implementing this interface can receive verified reports
///         from the Chainlink KeystoneForwarder.
interface ICREReceiver {
  /// @notice Called by the KeystoneForwarder to deliver a verified workflow report.
  /// @param metadata ABI-encoded workflow metadata (execution ID, workflow ID, name, owner).
  /// @param report ABI-encoded report payload.
  function onReport(bytes calldata metadata, bytes calldata report) external;
}
