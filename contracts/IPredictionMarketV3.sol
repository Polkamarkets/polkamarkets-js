// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./IRealityETH_ERC20.sol";
import "./IPredictionMarketV3Manager.sol";

interface IPredictionMarketV3 {
  struct CreateMarketDescription {
    uint256 value;
    uint256 closesAt;
    uint256 outcomes;
    IERC20 token;
    uint256[] distribution;
    string question;
    string image;
    address arbitrator;
    uint256 fee;
    uint256 treasuryFee;
    address treasury;
    IRealityETH_ERC20 realitio;
    uint256 realitioTimeout;
    IPredictionMarketV3Manager manager;
  }

  function createMarket(CreateMarketDescription calldata description) external returns (uint256);
  // TODO: add remaining functions
}
