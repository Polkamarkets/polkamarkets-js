pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;


// openzeppelin imports
import "@openzeppelin/contracts/math/SafeMath.sol";


/// @title Prediction Market Voting Contract
contract Voting {

  /// @dev protocol is immutable and has no ownership


  // still missing fields
  event MarketVotesUpdated(
  );

  event MarketVotesAction(
    address indexed user,
    VotesAction indexed action,
    uint256 indexed marketId,
  );

  enum VotesAction {
    upvoted,
    removeUpvoted
    downvoted,
    removeDownvoted,
  }

  struct MarketVotes {
    mapping(address => bool) usersUpvoted;
    mapping(address => bool) usersDownvoted;
    Votes totalVotes;
  }

  struct Votes {
    uint256 upvotes;
    uint256 downvotes;
  }

  mapping(uint256 => MarketVotes) markets;

  // Do i need to connect with the prediction market deployed? If so, for what? To validate if the market exists?
  constructor() public {}

  // Do i need to check if sender has at least 1 ERC20 token?
  function upvoteMarket(uint256 marketId) public {
    // getMarket
    // check if user has not already upvoted
    // check if user has already downvoted. If so, remove downvoted
    // add the upvote

    // emit events
  }

  function removeUpvoteMarket(uint256 marketId) external {
    // getMarket
    // check if user has upvoted market
    // remove the upvote

    // emit events
  }

  function downvoteMarket(uint256 marketId) external {
    // like upvoteMarket but for downvote
  }

  function removeDownvoteMarket(uint256 marketId) external {
    // like removeUpvoteMarket but for downvote
  }

  function getVotesMarket(uint256 marketId) public view returns (Votes) {
    // return market votes
  }

  // should get user as input or should use msg.sender?
  function hasUserUpvotedMarket(uint256 marketId) public view returns (bool) {
    // get market
    // check if user has upvoted this market
  }

  // should get user as input or should use msg.sender?
  function hasUserDownvotedMarket(uint256 marketId) public view returns (bool) {
    // get market
    // check if user has downvoted this market
  }

}
