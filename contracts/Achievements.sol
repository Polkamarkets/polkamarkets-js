pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import "./PredictionMarketV2.sol";

// openzeppelin imports
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/// @title Prediction Market Achievements Contract
contract Achievements is ERC721 {
  using Counters for Counters.Counter;
  Counters.Counter private _tokenIds;

  /// @dev protocol is immutable and has no ownership
  PredictionMarketV2 public predictionMarket;

  event LogNewAchievement(uint256 indexed achievementId, address indexed user, string content);

  // Buy: Claim through market[x].outcome[y].shares.holders[msg.sender] > 0
  // AddLiquidity: Claim through market[x].liquidityShares[msg.sender] > 0
  // CreateMarket: RealitioERC20 question arbitrator == msg.sender
  // ClaimWinnings: Claim through market[x].outcome[y].shares.holders[msg.sender] > 0 && y == market.resolution.outcomeId
  enum Action {
    Buy,
    AddLiquidity,
    ClaimWinnings,
    CreateMarket
  }

  struct Achievement {
    Action action;
    uint256 occurrences;
    mapping(address => bool) claims;
  }

  uint256 public achievementIndex = 0;
  mapping(uint256 => Achievement) public achievements;
  mapping(uint256 => uint256) public tokens; // tokenId => achievementId

  // Base URI
  string private _baseURIExtended;

  constructor(string memory token, string memory ticker) ERC721(token, ticker) {}

  function setContracts(PredictionMarketV2 _predictionMarket) public {
    require(address(predictionMarket) == address(0), "predictionMarket can only be initialized once");
    require(address(_predictionMarket) != address(0), "_predictionMarket address is 0");
    predictionMarket = _predictionMarket;
  }

  function _baseURI() internal view virtual override returns (string memory) {
    return _baseURIExtended;
  }

  function setBaseURI(string memory baseURI_) external {
    require(bytes(_baseURI()).length == 0, "baseURI can only be initialized once");
    _baseURIExtended = baseURI_;
  }

  function createAchievement(
    Action action,
    uint256 occurrences,
    string memory content
  ) public returns (uint256) {
    require(occurrences > 0, "occurrences has to be greater than 0");
    uint256 achievementId = achievementIndex;
    Achievement storage achievement = achievements[achievementId];

    achievement.action = action;
    achievement.occurrences = occurrences;
    emit LogNewAchievement(achievementId, msg.sender, content);
    achievementIndex = achievementId + 1;
    return achievementId;
  }

  function hasUserClaimedAchievement(address user, uint256 achievementId) public view returns (bool) {
    Achievement storage achievement = achievements[achievementId];

    return achievement.claims[user];
  }

  function hasUserPlacedPrediction(address user, uint256 marketId) public view returns (bool) {
    uint256[] memory outcomeShares;
    (, outcomeShares) = predictionMarket.getUserMarketShares(marketId, user);

    bool hasPlacedPrediction;

    for (uint256 i = 0; i < outcomeShares.length; i++) {
      if (outcomeShares[i] > 0) {
        hasPlacedPrediction = true;
        break;
      }
    }

    require(hasPlacedPrediction == true, "user does not hold outcome shares");

    return true;
  }

  function hasUserAddedLiquidity(address user, uint256 marketId) public view returns (bool) {
    uint256 liquidityShares;
    (liquidityShares, ) = predictionMarket.getUserMarketShares(marketId, user);

    require(liquidityShares > 0, "user does not hold liquidity shares");

    return true;
  }

  function hasUserClaimedWinnings(address user, uint256 marketId) public view returns (bool) {
    uint256[] memory outcomeShares;
    (, outcomeShares) = predictionMarket.getUserMarketShares(marketId, user);
    int256 resolvedOutcomeId = predictionMarket.getMarketResolvedOutcome(marketId);

    require(resolvedOutcomeId >= 0, "market is still not resolved");
    require(outcomeShares[uint256(resolvedOutcomeId)] > 0, "user does not hold winning outcome shares");

    return true;
  }

  function hasUserCreatedMarket(address _user, uint256 _marketId) public pure returns (bool) {
    // TODO
    return false;
  }

  function claimAchievement(uint256 achievementId, uint256[] memory marketIds) public returns (uint256) {
    Achievement storage achievement = achievements[achievementId];

    require(achievement.claims[msg.sender] == false, "Achievement already claimed");
    require(marketIds.length == achievement.occurrences, "Markets count and occurrences don't match");

    for (uint256 i = 0; i < marketIds.length; i++) {
      uint256 marketId = marketIds[i];

      if (achievement.action == Action.Buy) {
        hasUserPlacedPrediction(msg.sender, marketId);
      } else if (achievement.action == Action.AddLiquidity) {
        hasUserAddedLiquidity(msg.sender, marketId);
      } else if (achievement.action == Action.ClaimWinnings) {
        hasUserClaimedWinnings(msg.sender, marketId);
      } else if (achievement.action == Action.CreateMarket) {
        hasUserCreatedMarket(msg.sender, marketId);
      } else {
        revert("Invalid achievement action");
      }
    }

    mintAchievement(msg.sender, achievementId);
  }

  function mintAchievement(address user, uint256 achievementId) private returns (uint256) {
    _tokenIds.increment();

    uint256 tokenId = _tokenIds.current();
    _mint(user, tokenId);
    tokens[tokenId] = achievementId;

    Achievement storage achievement = achievements[achievementId];
    achievement.claims[user] = true;

    return tokenId;
  }

  function tokenIndex() public view returns (uint256) {
    return _tokenIds.current();
  }
}
