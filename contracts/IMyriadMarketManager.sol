// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMyriadMarketManager {
  enum MarketState {
    open,
    closed,
    resolved
  }

  function getMarketCollateral(uint256 marketId) external view returns (IERC20);

  function getMarketOutcome(uint256 marketId) external view returns (int256);

  function getMarketState(uint256 marketId) external view returns (MarketState);

  function isMarketPaused(uint256 marketId) external view returns (bool);

  function getMarketExecutionMode(uint256 marketId) external view returns (uint8);
}
