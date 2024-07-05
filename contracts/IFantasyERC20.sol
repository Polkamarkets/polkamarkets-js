// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFantasyERC20 is IERC20 {
  function mint(address account, uint256 amount) external;

  function burn(address account, uint256 amount) external;

  function claimTokens() external;

  function claimAndApproveTokens() external;

  function hasUserClaimedTokens(address user) external view returns (bool);
}
