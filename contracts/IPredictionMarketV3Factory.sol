// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPredictionMarketV3Factory {
  function isPMControllerAdmin(address controllerAddress, address user) external view returns (bool);

  function isPMControllerActive(address controllerAddress) external view returns (bool);
}
