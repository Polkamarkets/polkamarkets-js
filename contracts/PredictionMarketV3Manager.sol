// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./RealityETH_ERC20_Factory.sol";
import "./LandFactory.sol";

// openzeppelin ownable contract import
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PredictionMarketV3Manager is LandFactory {
  // inherited variables from LandFactory
  // address public immutable PMV3
  // IERC20 public immutable token
  // uint256 public lockAmount
  // RealityETH_ERC20_Factory public immutable realitioFactory;
  // mapping(address => Land) public lands;
  // address[] public landTokens;
  // uint256 public landTokensLength;

  constructor(
    address _PMV3,
    IERC20 _token,
    uint256 _lockAmount,
    address _realitioLibraryAddress
  ) {
    PMV3 = _PMV3;
    token = _token;
    lockAmount = _lockAmount;
    realitioFactory = new RealityETH_ERC20_Factory(_realitioLibraryAddress);
  }

  // lockAmount is the amount of tokens that the user needs to lock to create a land
  // by locking the amount the factory will create an erc20 token and store it in the contract
  // the user will be the admin of the land
  function createLand(
    string memory name,
    string memory symbol,
    uint256 tokenAmountToClaim,
    IERC20 tokenToAnswer
  ) external override nonReentrant returns (IERC20) {
    return _createLand(name, symbol, tokenAmountToClaim, tokenToAnswer, address(0), address(0));
  }
}
