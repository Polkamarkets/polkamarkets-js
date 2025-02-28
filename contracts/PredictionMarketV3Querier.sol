// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// openzeppelin imports
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// local imports
import "./IPredictionMarketV3.sol";

/// @title Market Contract Factory
contract PredictionMarketV3Querier {
  IPredictionMarketV3 public immutable PredictionMarketV3;

  struct UserMarketData {
    uint256 liquidityShares;
    uint256[] outcomeShares;
    bool winningsToClaim;
    bool winningsClaimed;
    bool liquidityToClaim;
    bool liquidityClaimed;
    bool voidedSharesToClaim;
  }

  struct MarketPrices {
    uint256 liquidityPrice;
    uint256[] outcomePrices;
  }

  /// @dev protocol is immutable and has no ownership
  constructor(IPredictionMarketV3 _PredictionMarketV3) {
    PredictionMarketV3 = _PredictionMarketV3;
  }

  function getUserMarketData(uint256 marketId, address user) public view returns (UserMarketData memory) {
    bool isMarketVoided = PredictionMarketV3.isMarketVoided(marketId);
    bool voidedSharesToClaim = false;

    (uint256 liquidityShares, uint256[] memory outcomeShares) = PredictionMarketV3.getUserMarketShares(marketId, user);
    (bool winningsToClaim, bool winningsClaimed, bool liquidityToClaim, bool liquidityClaimed, ) = PredictionMarketV3
      .getUserClaimStatus(marketId, user);

    if (isMarketVoided) {
      for (uint256 i = 0; i < outcomeShares.length; i++) {
        if (outcomeShares[i] > 0) {
          voidedSharesToClaim = true;
          break;
        }
      }
    }

    return
      UserMarketData({
        liquidityShares: liquidityShares,
        outcomeShares: outcomeShares,
        winningsToClaim: winningsToClaim,
        winningsClaimed: winningsClaimed,
        liquidityToClaim: liquidityToClaim,
        liquidityClaimed: liquidityClaimed,
        voidedSharesToClaim: voidedSharesToClaim
      });
  }

  function getMarketPrices(uint256 marketId) public view returns (MarketPrices memory) {
    (uint256 liquidityPrice, uint256[] memory outcomePrices) = PredictionMarketV3.getMarketPrices(marketId);

    return MarketPrices({liquidityPrice: liquidityPrice, outcomePrices: outcomePrices});
  }

  function getMarketERC20Decimals(uint256 marketId) public view returns (uint8) {
    (, , , address token, , , , , ) = PredictionMarketV3.getMarketAltData(marketId);

    return IERC20Metadata(token).decimals();
  }

  function getUserMarketsData(uint256[] calldata marketIds, address user)
    external
    view
    returns (UserMarketData[] memory)
  {
    UserMarketData[] memory userMarketsData = new UserMarketData[](marketIds.length);

    for (uint256 i = 0; i < marketIds.length; i++) {
      userMarketsData[i] = getUserMarketData(marketIds[i], user);
    }

    return userMarketsData;
  }

  function getUserAllMarketsData(address user) external view returns (UserMarketData[] memory) {
    uint256[] memory marketIds = PredictionMarketV3.getMarkets();
    UserMarketData[] memory userMarketsData = new UserMarketData[](marketIds.length);

    for (uint256 i = 0; i < marketIds.length; i++) {
      userMarketsData[i] = getUserMarketData(marketIds[i], user);
    }

    return userMarketsData;
  }

  function getMarketsPrices(uint256[] calldata marketIds) external view returns (MarketPrices[] memory) {
    MarketPrices[] memory marketPrices = new MarketPrices[](marketIds.length);

    for (uint256 i = 0; i < marketIds.length; i++) {
      marketPrices[i] = getMarketPrices(marketIds[i]);
    }

    return marketPrices;
  }

  function getMarketsERC20Decimals(uint256[] calldata marketIds) external view returns (uint8[] memory) {
    uint8[] memory decimals = new uint8[](marketIds.length);

    for (uint256 i = 0; i < marketIds.length; i++) {
      decimals[i] = getMarketERC20Decimals(marketIds[i]);
    }

    return decimals;
  }
}
