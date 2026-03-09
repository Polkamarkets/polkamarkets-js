// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AdminRegistry.sol";
import "./IMarketOracle.sol";
import "./IMyriadMarketManager.sol";

/// @title PredictionMarketV3ManagerCLOB
/// @notice Market lifecycle registry for CLOB markets.
///         Resolution is delegated to pluggable oracle contracts that implement IMarketOracle.
contract PredictionMarketV3ManagerCLOB is Initializable, ReentrancyGuardUpgradeable, UUPSUpgradeable, IMyriadMarketManager {
  using SafeERC20 for IERC20;

  struct Market {
    uint256 id;
    IERC20 collateral;
    uint256 closesAt;
    uint8 outcomes;
    string question;
    string image;
    MarketState state;
    int256 resolvedOutcome;
    bool paused;
    uint256 outcome0TokenId;
    uint256 outcome1TokenId;
    address feeModule;
    address creator;
    address oracle;
    bytes32 eventId;   // 0x0 for standalone markets
    bool negRisk;      // true for neg risk event markets
  }

  struct CreateMarketParams {
    uint256 closesAt;
    string question;
    string image;
    address feeModule;
    address oracle;
    bytes oracleData;
  }

  uint256 private constant ONE = 1e18;

  AdminRegistry public registry;
  IERC20 public collateralToken;

  uint256 public marketIndex;
  mapping(uint256 => Market) public markets;
  mapping(uint256 => uint256[2]) public voidedPayouts; // [outcome0Payout, outcome1Payout] in 1e18

  /// @notice The NegRiskAdapter address, allowed to create neg risk markets.
  address public negRiskAdapter;

  event MarketCreated(
    address indexed user,
    uint256 indexed marketId,
    string question,
    string image,
    address collateral
  );
  event MarketResolved(address indexed user, uint256 indexed marketId, int256 outcomeId, uint256 timestamp);
  event MarketPaused(address indexed user, uint256 indexed marketId, bool paused, uint256 timestamp);
  event MarketOracleUpdated(uint256 indexed marketId, address oldOracle, address newOracle);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(AdminRegistry _registry, IERC20 _collateralToken) public initializer {
    require(address(_registry) != address(0), "registry 0");
    require(address(_collateralToken) != address(0), "collateral 0");

    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    registry = _registry;
    collateralToken = _collateralToken;
    marketIndex = 1;
  }

  function _authorizeUpgrade(address) internal view override {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
  }

  function setNegRiskAdapter(address _adapter) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    negRiskAdapter = _adapter;
  }

  function createMarket(CreateMarketParams calldata params) external nonReentrant returns (uint256 marketId) {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not market admin");
    require(params.closesAt > block.timestamp, "close in past");
    require(marketIndex < type(uint128).max, "market id overflow");

    marketId = marketIndex;
    marketIndex += 1;

    Market storage market = markets[marketId];
    market.id = marketId;
    market.collateral = collateralToken;
    market.closesAt = params.closesAt;
    market.outcomes = 2;
    market.question = params.question;
    market.image = params.image;
    market.state = MarketState.open;
    market.resolvedOutcome = -3;
    market.outcome0TokenId = _getTokenId(marketId, 0);
    market.outcome1TokenId = _getTokenId(marketId, 1);
    market.feeModule = params.feeModule;
    market.creator = msg.sender;
    market.oracle = params.oracle;

    if (params.oracle != address(0) && params.oracleData.length > 0) {
      IMarketOracle(params.oracle).initialize(marketId, params.oracleData);
    }

    emit MarketCreated(msg.sender, marketId, params.question, params.image, address(collateralToken));
  }

  /// @notice Create a neg risk binary market with a custom collateral (wcol).
  ///         Only callable by the registered NegRiskAdapter.
  function createNegRiskMarket(
    CreateMarketParams calldata params,
    IERC20 collateralOverride,
    bytes32 eventId
  ) external nonReentrant returns (uint256 marketId) {
    require(msg.sender == negRiskAdapter, "not adapter");
    require(params.closesAt > block.timestamp, "close in past");
    require(marketIndex < type(uint128).max, "market id overflow");

    marketId = marketIndex;
    marketIndex += 1;

    Market storage market = markets[marketId];
    market.id = marketId;
    market.collateral = collateralOverride;
    market.closesAt = params.closesAt;
    market.outcomes = 2;
    market.question = params.question;
    market.image = params.image;
    market.state = MarketState.open;
    market.resolvedOutcome = -3;
    market.outcome0TokenId = _getTokenId(marketId, 0);
    market.outcome1TokenId = _getTokenId(marketId, 1);
    market.feeModule = params.feeModule;
    market.creator = msg.sender;
    market.oracle = params.oracle;
    market.eventId = eventId;
    market.negRisk = true;

    if (params.oracle != address(0) && params.oracleData.length > 0) {
      IMarketOracle(params.oracle).initialize(marketId, params.oracleData);
    }

    emit MarketCreated(msg.sender, marketId, params.question, params.image, address(collateralOverride));
  }

  /// @notice Permissionless resolution via the market's oracle.
  function resolveMarket(uint256 marketId) external nonReentrant returns (int256 outcomeId) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");
    require(!market.negRisk, "use resolveEvent for neg risk");
    require(getMarketState(marketId) == MarketState.closed, "!closed");
    require(market.state != MarketState.resolved, "resolved");
    require(market.oracle != address(0), "no oracle");

    (int256 outcome, bool resolved) = IMarketOracle(market.oracle).getResult(marketId);
    require(resolved, "oracle: not resolved");
    require(outcome == 0 || outcome == 1 || outcome == -1, "invalid outcome");

    market.resolvedOutcome = outcome;
    market.state = MarketState.resolved;

    emit MarketResolved(msg.sender, marketId, outcome, block.timestamp);
    return outcome;
  }

  function adminResolveMarket(uint256 marketId, int256 outcomeId) external nonReentrant returns (int256) {
    require(registry.hasRole(registry.RESOLUTION_ADMIN_ROLE(), msg.sender), "not resolution admin");
    require(outcomeId == 0 || outcomeId == 1, "invalid outcome");

    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");
    require(market.state != MarketState.resolved, "resolved");
    require(!market.negRisk || msg.sender == negRiskAdapter, "use resolveEvent");
    require(
      block.timestamp >= market.closesAt || registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender),
      "market not closed"
    );

    market.resolvedOutcome = outcomeId;
    market.state = MarketState.resolved;

    emit MarketResolved(msg.sender, marketId, outcomeId, block.timestamp);

    return outcomeId;
  }

  /// @notice Void a market with custom payout ratios for each outcome token.
  /// @param outcome0Payout Collateral returned per outcome 0 token (1e18 = 100%).
  /// @param outcome1Payout Collateral returned per outcome 1 token (1e18 = 100%).
  /// @dev outcome0Payout + outcome1Payout MUST equal 1e18 (100%).
  function adminVoidMarket(
    uint256 marketId,
    uint256 outcome0Payout,
    uint256 outcome1Payout
  ) external nonReentrant returns (int256) {
    require(registry.hasRole(registry.RESOLUTION_ADMIN_ROLE(), msg.sender), "not resolution admin");
    require(outcome0Payout + outcome1Payout == ONE, "payouts must sum to 1e18");

    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");
    require(market.state != MarketState.resolved, "resolved");
    require(!market.negRisk, "use resolveEvent for neg risk");

    market.resolvedOutcome = -1;
    market.state = MarketState.resolved;
    voidedPayouts[marketId] = [outcome0Payout, outcome1Payout];

    emit MarketResolved(msg.sender, marketId, -1, block.timestamp);

    return -1;
  }

  /// @notice Update the oracle address for a market.
  function updateMarketOracle(
    uint256 marketId,
    address newOracle,
    bytes calldata oracleData
  ) external nonReentrant {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not market admin");

    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");
    require(market.state != MarketState.resolved, "resolved");

    address oldOracle = market.oracle;
    market.oracle = newOracle;

    if (newOracle != address(0) && oracleData.length > 0) {
      IMarketOracle(newOracle).initialize(marketId, oracleData);
    }

    emit MarketOracleUpdated(marketId, oldOracle, newOracle);
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
      IERC20 collateral,
      uint256 closesAt,
      uint256 outcome0TokenId,
      uint256 outcome1TokenId,
      address feeModule,
      bool paused
    )
  {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return (
      getMarketState(marketId),
      market.collateral,
      market.closesAt,
      market.outcome0TokenId,
      market.outcome1TokenId,
      market.feeModule,
      market.paused
    );
  }

  function getOutcomeTokenIds(uint256 marketId) external view returns (uint256 outcome0TokenId, uint256 outcome1TokenId) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return (market.outcome0TokenId, market.outcome1TokenId);
  }

  function getMarketOracle(uint256 marketId) external view returns (address) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return market.oracle;
  }

  function getMarketCollateral(uint256 marketId) external view override returns (IERC20) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");

    return market.collateral;
  }

  function getMarketResolvedOutcome(uint256 marketId) external view override returns (int256) {
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

  function getVoidedPayouts(uint256 marketId) external view override returns (uint256 outcome0Payout, uint256 outcome1Payout) {
    Market storage market = markets[marketId];
    require(market.id == marketId, "!m");
    require(market.resolvedOutcome == -1, "not voided");

    outcome0Payout = voidedPayouts[marketId][0];
    outcome1Payout = voidedPayouts[marketId][1];
  }

  function isNegRisk(uint256 marketId) external view returns (bool) {
    require(markets[marketId].id == marketId, "!m");
    return markets[marketId].negRisk;
  }

  function getEventId(uint256 marketId) external view returns (bytes32) {
    require(markets[marketId].id == marketId, "!m");
    return markets[marketId].eventId;
  }

  /// @notice Returns the total number of markets created (next id to be assigned).
  function marketCount() external view returns (uint256) {
    return marketIndex;
  }

  function _getTokenId(uint256 marketId, uint256 outcome) internal pure returns (uint256) {
    return (marketId << 1) | outcome;
  }
}
