// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AdminRegistry.sol";
import "./IMyriadMarketManager.sol";

/// @title ConditionalTokens
/// @notice ERC1155 outcome positions for YES/NO markets.
contract ConditionalTokens is ERC1155, ReentrancyGuard {
  using SafeERC20 for IERC20;

  AdminRegistry public immutable registry;
  IMyriadMarketManager public immutable manager;

  address public exchange;

  constructor(AdminRegistry _registry, IMyriadMarketManager _manager) ERC1155("") {
    registry = _registry;
    manager = _manager;
  }

  modifier onlyExchange() {
    require(msg.sender == exchange, "only exchange");
    _;
  }

  function setExchange(address newExchange) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    exchange = newExchange;
  }

  function splitPosition(uint256 marketId, uint256 amount) external nonReentrant {
    require(amount > 0, "amount 0");
    require(manager.getMarketState(marketId) != IMyriadMarketManager.MarketState.resolved, "resolved");

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransferFrom(msg.sender, address(this), amount);

    _mint(msg.sender, getTokenId(marketId, 0), amount, "");
    _mint(msg.sender, getTokenId(marketId, 1), amount, "");
  }

  function mergePositions(uint256 marketId, uint256 amount) external nonReentrant {
    require(amount > 0, "amount 0");

    _burn(msg.sender, getTokenId(marketId, 0), amount);
    _burn(msg.sender, getTokenId(marketId, 1), amount);

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(msg.sender, amount);
  }

  function redeemPositions(uint256 marketId) external nonReentrant {
    int256 outcome = manager.getMarketOutcome(marketId);
    require(outcome == 0 || outcome == 1, "not resolved");

    uint256 tokenId = getTokenId(marketId, uint256(outcome));
    uint256 amount = balanceOf(msg.sender, tokenId);
    require(amount > 0, "no balance");

    _burn(msg.sender, tokenId, amount);

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(msg.sender, amount);
  }

  /// @notice Exchange-only mint for mint-matched buys.
  function mintPositionsTo(
    address yesRecipient,
    address noRecipient,
    uint256 marketId,
    uint256 amount
  ) external onlyExchange {
    require(amount > 0, "amount 0");
    _mint(yesRecipient, getTokenId(marketId, 0), amount, "");
    _mint(noRecipient, getTokenId(marketId, 1), amount, "");
  }

  /// @notice Exchange-only merge that burns positions held by the exchange.
  function mergePositionsTo(address recipient, uint256 marketId, uint256 amount) external onlyExchange {
    require(amount > 0, "amount 0");

    _burn(msg.sender, getTokenId(marketId, 0), amount);
    _burn(msg.sender, getTokenId(marketId, 1), amount);

    IERC20 collateral = manager.getMarketCollateral(marketId);
    collateral.safeTransfer(recipient, amount);
  }

  function getTokenId(uint256 marketId, uint256 outcome) public pure returns (uint256) {
    return (marketId << 1) | outcome;
  }
}
