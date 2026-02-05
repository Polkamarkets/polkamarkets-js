// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AdminRegistry.sol";
import "./IRealityETH_ERC20.sol";
import "./IMyriadMarketManager.sol";

/// @title PredictionMarketV3ManagerCLOB
/// @notice Market lifecycle registry for AMM and CLOB markets without Lands.
contract PredictionMarketV3ManagerCLOB is ReentrancyGuard, IMyriadMarketManager {
  using SafeERC20 for IERC20;

  enum ExecutionMode {
    AMM,
    CLOB
  }

  struct Market {
    uint256 id;
    IERC20 collateral;
    uint256 closesAt;
    uint8 outcomes;
    string question;
    string image;
    address arbitrator;
    uint32 realitioTimeout;
    MarketState state;
    bytes32 questionId;
    int256 resolvedOutcome;
    bool paused;
    ExecutionMode executionMode;
    uint256 yesTokenId;
    uint256 noTokenId;
    address feeModule;
    address creator;
  }

  struct CreateMarketParams {
    uint256 closesAt;
    string question;
    string image;
    address arbitrator;
    uint32 realitioTimeout;
    ExecutionMode executionMode;
    address feeModule;
  }

  uint256 public constant MINIMUM_REALITIO_TIMEOUT = 3600;

  AdminRegistry public immutable registry;
  IRealityETH_ERC20 public immutable realitio;
  IERC20 public immutable collateralToken;

  uint256 public marketIndex;
  mapping(uint256 => Market) public markets;

  event MarketCreated(
    address indexed user,
    uint256 indexed marketId,
    string question,
    string image,
    address collateral,
    ExecutionMode executionMode
  );
  event MarketResolved(address indexed user, uint256 indexed marketId, int256 outcomeId, uint256 timestamp);
  event MarketPaused(address indexed user, uint256 indexed marketId, bool paused, uint256 timestamp);

  constructor(AdminRegistry _registry, IRealityETH_ERC20 _realitio, IERC20 _collateralToken) {
    registry = _registry;
    realitio = _realitio;
    collateralToken = _collateralToken;
  }

  function createMarket(CreateMarketParams calldata params) external nonReentrant returns (uint256 marketId) {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not market admin");
    require(params.closesAt > block.timestamp, "close in past");
    require(params.arbitrator != address(0), "arbitrator 0");
    require(params.realitioTimeout >= MINIMUM_REALITIO_TIMEOUT, "timeout < 1h");

    marketId = marketIndex;
    marketIndex += 1;

    Market storage market = markets[marketId];
    market.id = marketId;
    market.collateral = collateralToken;
    market.closesAt = params.closesAt;
    market.outcomes = 2;
    market.question = params.question;
    market.image = params.image;
    market.arbitrator = params.arbitrator;
    market.realitioTimeout = params.realitioTimeout;
    market.state = MarketState.open;
    market.resolvedOutcome = -3;
    market.executionMode = params.executionMode;
    market.yesTokenId = _getTokenId(marketId, 0);
    market.noTokenId = _getTokenId(marketId, 1);
    market.feeModule = params.feeModule;
    market.creator = msg.sender;

    market.questionId = realitio.askQuestionERC20(
      2,
      params.question,
      params.arbitrator,
      params.realitioTimeout,
      uint32(params.closesAt),
      0,
      0
    );

    emit MarketCreated(msg.sender, marketId, params.question, params.image, address(collateralToken), params.executionMode);
  }

  function resolveMarket(uint256 marketId) external nonReentrant returns (int256 outcomeId) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");
    require(getMarketState(marketId) == MarketState.closed, "!closed");
    require(market.state != MarketState.resolved, "resolved");

    outcomeId = int256(uint256(realitio.resultFor(market.questionId)));
    market.resolvedOutcome = outcomeId;
    market.state = MarketState.resolved;

    emit MarketResolved(msg.sender, marketId, outcomeId, block.timestamp);
  }

  function adminResolveMarket(uint256 marketId, int256 outcomeId) external nonReentrant returns (int256) {
    require(registry.hasRole(registry.RESOLUTION_ADMIN_ROLE(), msg.sender), "not resolution admin");

    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");
    require(market.state != MarketState.resolved, "resolved");

    market.resolvedOutcome = outcomeId;
    market.state = MarketState.resolved;

    emit MarketResolved(msg.sender, marketId, outcomeId, block.timestamp);

    return outcomeId;
  }

  function pauseMarket(uint256 marketId, bool paused) external nonReentrant {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not market admin");

    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");
    market.paused = paused;

    emit MarketPaused(msg.sender, marketId, paused, block.timestamp);
  }

  function getMarket(uint256 marketId)
    external
    view
    returns (
      MarketState state,
      ExecutionMode executionMode,
      IERC20 collateral,
      uint256 closesAt,
      uint256 yesTokenId,
      uint256 noTokenId,
      address feeModule,
      bool paused
    )
  {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return (
      getMarketState(marketId),
      market.executionMode,
      market.collateral,
      market.closesAt,
      market.yesTokenId,
      market.noTokenId,
      market.feeModule,
      market.paused
    );
  }

  function getOutcomeTokenIds(uint256 marketId) external view returns (uint256 yesTokenId, uint256 noTokenId) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return (market.yesTokenId, market.noTokenId);
  }

  function getMarketCollateral(uint256 marketId) external view override returns (IERC20) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return market.collateral;
  }

  function getMarketOutcome(uint256 marketId) external view override returns (int256) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    if (market.state != MarketState.resolved) {
      return -3;
    }

    return market.resolvedOutcome;
  }

  function getMarketState(uint256 marketId) public view override returns (MarketState) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    if (market.state == MarketState.open && block.timestamp >= market.closesAt) {
      return MarketState.closed;
    }

    return market.state;
  }

  function isMarketPaused(uint256 marketId) external view override returns (bool) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return market.paused;
  }

  function getMarketExecutionMode(uint256 marketId) external view override returns (uint8) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return uint8(market.executionMode);
  }

  function _getTokenId(uint256 marketId, uint256 outcome) internal pure returns (uint256) {
    return (marketId << 1) | outcome;
  }
}
