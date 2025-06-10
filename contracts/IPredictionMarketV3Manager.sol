// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPredictionMarketV3Manager {
  function isAllowedToCreateMarket(IERC20 token, address user) external view returns (bool);

  function isAllowedToResolveMarket(IERC20 token, address user) external view returns (bool);

  function isAllowedToEditMarket(IERC20 token, address user) external view returns (bool);

  function isIERC20TokenSocial(IERC20 token) external view returns (bool);
}
