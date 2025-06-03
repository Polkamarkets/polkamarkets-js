// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPredictionMarketV3 {
  struct Fees {
    uint256 fee; // fee % taken from every transaction
    uint256 treasuryFee; // fee % taken from every transaction to a treasury address
    uint256 distributorFee; // fee % taken from every transaction to a distributor address
  }

  struct CreateMarketDescription {
    uint256 value;
    uint256 closesAt;
    uint256 outcomes;
    address token;
    uint256[] distribution;
    string question;
    string image;
    address arbitrator;
    Fees buyFees;
    Fees sellFees;
    address treasury;
    address distributor;
    address realitio;
    uint256 realitioTimeout;
    address manager;
  }

  event MarketActionTx(
    address indexed user,
    uint8 indexed action,
    uint256 indexed marketId,
    uint256 outcomeId,
    uint256 shares,
    uint256 value,
    uint256 timestamp
  );
  event MarketCreated(
    address indexed user,
    uint256 indexed marketId,
    uint256 outcomes,
    string question,
    string image,
    address token
  );
  event MarketLiquidity(uint256 indexed marketId, uint256 value, uint256 price, uint256 timestamp);
  event MarketOutcomePrice(uint256 indexed marketId, uint256 indexed outcomeId, uint256 value, uint256 timestamp);
  event MarketOutcomeShares(uint256 indexed marketId, uint256 timestamp, uint256[] outcomeShares, uint256 liquidity);
  event MarketResolved(
    address indexed user,
    uint256 indexed marketId,
    uint256 outcomeId,
    uint256 timestamp,
    bool admin
  );

  function MAX_FEE() external view returns (uint256);

  function MAX_OUTCOMES() external view returns (uint256);

  function MAX_UINT_256() external view returns (uint256);

  function ONE() external view returns (uint256);

  function WETH() external view returns (address);

  function marketIndex() external view returns (uint256);

  function createMarket(CreateMarketDescription memory desc) external returns (uint256);

  function createMarketWithETH(CreateMarketDescription memory desc) external payable returns (uint256);

  function mintAndCreateMarket(CreateMarketDescription memory desc) external returns (uint256);

  function calcBuyAmount(
    uint256 amount,
    uint256 marketId,
    uint256 outcomeId
  ) external view returns (uint256);

  function calcSellAmount(
    uint256 amount,
    uint256 marketId,
    uint256 outcomeId
  ) external view returns (uint256 outcomeTokenSellAmount);

  function buy(
    uint256 marketId,
    uint256 outcomeId,
    uint256 minOutcomeSharesToBuy,
    uint256 value
  ) external;

  function buyWithETH(
    uint256 marketId,
    uint256 outcomeId,
    uint256 minOutcomeSharesToBuy
  ) external payable;

  function sell(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value,
    uint256 maxOutcomeSharesToSell
  ) external;

  function sellToETH(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value,
    uint256 maxOutcomeSharesToSell
  ) external;

  function addLiquidity(uint256 marketId, uint256 value) external;

  function addLiquidityWithETH(uint256 marketId) external payable;

  function removeLiquidity(uint256 marketId, uint256 shares) external;

  function removeLiquidityToETH(uint256 marketId, uint256 shares) external;

  function resolveMarketOutcome(uint256 marketId) external returns (uint256);

  function adminResolveMarketOutcome(uint256 marketId, uint256 outcomeId) external returns (uint256);

  function claimWinnings(uint256 marketId) external;

  function claimWinningsToETH(uint256 marketId) external;

  function claimVoidedOutcomeShares(uint256 marketId, uint256 outcomeId) external;

  function claimVoidedOutcomeSharesToETH(uint256 marketId, uint256 outcomeId) external;

  function claimLiquidity(uint256 marketId) external;

  function claimLiquidityToETH(uint256 marketId) external;

  function claimFees(uint256 marketId) external;

  function claimFeesToETH(uint256 marketId) external;

  function getUserMarketShares(uint256 marketId, address user) external view returns (uint256, uint256[] memory);

  function getUserClaimStatus(uint256 marketId, address user)
    external
    view
    returns (
      bool,
      bool,
      bool,
      bool,
      uint256
    );

  function getUserLiquidityPoolShare(uint256 marketId, address user) external view returns (uint256);

  function getUserClaimableFees(uint256 marketId, address user) external view returns (uint256);

  function getMarkets() external view returns (uint256[] memory);

  function getMarketData(uint256 marketId)
    external
    view
    returns (
      uint8,
      uint256,
      uint256,
      uint256,
      uint256,
      int256
    );

  function getMarketAltData(uint256 marketId)
    external
    view
    returns (
      uint256,
      bytes32,
      uint256,
      address,
      uint256,
      address,
      address,
      uint256,
      address
    );

  function getMarketQuestion(uint256 marketId) external view returns (bytes32);

  function getMarketPrices(uint256 marketId) external view returns (uint256, uint256[] memory);

  function getMarketShares(uint256 marketId) external view returns (uint256, uint256[] memory);

  function getMarketLiquidityPrice(uint256 marketId) external view returns (uint256);

  function getMarketResolvedOutcome(uint256 marketId) external view returns (int256);

  function isMarketVoided(uint256 marketId) external view returns (bool);

  function getMarketFee(uint256 marketId) external view returns (uint256);

  function getMarketOutcomeIds(uint256 marketId) external view returns (uint256[] memory);

  function getMarketOutcomePrice(uint256 marketId, uint256 outcomeId) external view returns (uint256);

  function getMarketOutcomeData(uint256 marketId, uint256 outcomeId)
    external
    view
    returns (
      uint256,
      uint256,
      uint256
    );
}
