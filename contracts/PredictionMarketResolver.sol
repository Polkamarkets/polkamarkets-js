pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "./FantasyERC20.sol";
import "./PredictionMarketV2.sol";

// openzeppelin imports
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PredictionMarketResolver is Ownable {
  using SafeMath for uint256;

  event MarketResolved(
    address indexed user,
    uint256 indexed marketId,
    uint256 outcomeId,
    uint256 timestamp
  );

  event MarketClaimed(
    address indexed user,
    uint256 indexed marketId,
    uint256 outcomeId,
    uint256 shares,
    uint256 timestamp
  );

  struct MarketResolution {
    bool resolved;
    uint256 outcomeId;
  }

  mapping(uint256 => mapping(address => bool)) public claims;
  mapping(uint256 => MarketResolution) markets;
  FantasyERC20 public token;
  PredictionMarketV2 public predictionMarket;

  // ------ Modifiers ------

  modifier marketIsResolved(uint256 marketId) {
    require(markets[marketId].resolved, "Market is not resolved");
    _;
  }

  // ------ Modifiers End ------

  // ------ Admin ------

  function setToken(FantasyERC20 _token) external onlyOwner {
    token = _token;
  }

  function setPredictionMarket(PredictionMarketV2 _predictionMarket)
    external
    onlyOwner
  {
    predictionMarket = _predictionMarket;
  }

  function resolveMarket(uint256 marketId, uint256 outcomeId) external onlyOwner {
    markets[marketId] = MarketResolution(true, outcomeId);
    emit MarketResolved(msg.sender, marketId, outcomeId, block.timestamp);
  }

  // ------ Admin End ------

  function getMarketResolution(uint256 marketId)
    external
    view
    returns (MarketResolution memory)
  {
    return markets[marketId];
  }

  function hasUserClaimedMarket(uint256 marketId, address user)
    external
    view
    returns (bool)
  {
    return claims[marketId][user];
  }

  function getUserMarketShares(uint256 marketId, address user)
    public
    view
    returns (uint256[] memory)
  {
    uint[] memory shares;

    // fetching user shares from predictionMarket
    (, shares) = predictionMarket.getUserMarketShares(marketId, user);

    return shares;
  }

  function claim(uint256 marketId, address user) marketIsResolved(marketId) public {
    require(!claims[marketId][user], "Already claimed");

    uint256 outcomeId = markets[marketId].outcomeId;
    uint[] memory shares;

    // fetching user shares from predictionMarket
    (, shares) = predictionMarket.getUserMarketShares(marketId, user);

    // calculating user winnings
    require(shares[outcomeId] > 0, "User has no winning shares");

    claims[marketId][user] = true;
    // minting tokens for user
    token.mint(user, shares[outcomeId]);

    emit MarketClaimed(user, marketId, outcomeId, shares[outcomeId], block.timestamp);
  }

  function claimMultiple(uint256 marketId, address[] calldata users) external {
    for (uint256 i = 0; i < users.length; i++) {
      claim(marketId, users[i]);
    }
  }
}
