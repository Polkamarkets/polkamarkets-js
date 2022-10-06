pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;


// openzeppelin imports
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


/// @title Upvoting / Downvoting Contract
contract Voting {
  using SafeMath for uint256;
  /// @dev protocol is immutable and has no ownership

  event ItemVotesUpdated(
    uint256 indexed itemId,
    uint256 upvotes,
    uint256 downvotes,
    uint256 timestamp
  );

  event ItemVotesAction(
    address indexed user,
    VotesAction indexed action,
    uint256 indexed itemId,
    uint256 timestamp
  );

  enum VotesAction {
    upvoted,
    removeUpvoted,
    downvoted,
    removeDownvoted
  }

  struct ItemVotes {
    mapping(address => bool) usersUpvoted;
    mapping(address => bool) usersDownvoted;
    uint256 upvotes;
    uint256 downvotes;
  }

  mapping(uint256 => ItemVotes) items;

  IERC20 public token;
  uint256 public requiredBalance; // required balance for voting

  modifier mustHoldRequiredBalance() {
    require(token.balanceOf(msg.sender) >= requiredBalance, "msg.sender must hold minimum erc20 balance");
    _;
  }

  constructor(
    IERC20 _token,
    uint256 _requiredBalance
  ) public {
    token = _token;
    requiredBalance = _requiredBalance;
  }

  function upvoteItem(uint256 itemId) mustHoldRequiredBalance external {
    voteItem(itemId, VotesAction.upvoted);
  }

  function downvoteItem(uint256 itemId) mustHoldRequiredBalance external {
    voteItem(itemId, VotesAction.downvoted);
  }

  function voteItem(uint256 itemId, VotesAction action) private {
    require(action == VotesAction.upvoted || action == VotesAction.downvoted, "Function parameter has to be upvoted or downvoted");

    ItemVotes storage item = items[itemId];

    mapping(address => bool) storage listToAddVote = action == VotesAction.upvoted ? item.usersUpvoted : item.usersDownvoted;
    mapping(address => bool) storage listToRemoveVote = action == VotesAction.upvoted ? item.usersDownvoted : item.usersUpvoted;

    // check if user has not already voted on the selected direction
    bool hasUserVotedSelectedDirection = listToAddVote[msg.sender];

    require(hasUserVotedSelectedDirection == false, "User has already a vote on this item");

    // check if user has already downvoted
    bool hasUserVotedOtherDirection = listToRemoveVote[msg.sender];

    // remove from total downvoted if needed
    if (hasUserVotedOtherDirection) {
      action == VotesAction.upvoted ? item.downvotes.sub(1) : item.upvotes.sub(1);
    }

    // add the vote
    action == VotesAction.upvoted ? item.upvotes.add(1) : item.downvotes.add(1);
    listToAddVote[msg.sender] = true;
    listToRemoveVote[msg.sender] = false;

    // emit events
    emit ItemVotesAction(msg.sender, action, itemId, now);

    emit ItemVotesUpdated(itemId, item.upvotes, item.downvotes, now);

  }

  function removeUpvoteItem(uint256 itemId) mustHoldRequiredBalance external {
    removeVoteItem(itemId, VotesAction.removeUpvoted);
  }

  function removeDownvoteItem(uint256 itemId) mustHoldRequiredBalance external {
    removeVoteItem(itemId, VotesAction.removeDownvoted);
  }

  function removeVoteItem(uint256 itemId, VotesAction action) private {
    require(action == VotesAction.removeUpvoted || action == VotesAction.removeDownvoted, "Function parameter has to be removeUpvoted or removeDownvoted");

    // get item votes
    ItemVotes storage item = items[itemId];

    mapping(address => bool) storage listToRemoveVote = action == VotesAction.removeUpvoted ? item.usersUpvoted : item.usersDownvoted;

    // check if user has voted item
    bool hasUserVoted = listToRemoveVote[msg.sender];

    require(hasUserVoted == true, "User doesn't have a vote on this item");

    // remove the vote
    action == VotesAction.removeUpvoted ? item.upvotes.sub(1) : item.downvotes.sub(1);
    listToRemoveVote[msg.sender] = false;

    // emit events
    emit ItemVotesAction(msg.sender, action, itemId, now);

    emit ItemVotesUpdated(itemId, item.upvotes, item.downvotes, now);
  }

  function getItemVotes(uint256 itemId) external view returns (uint256, uint256) {
    ItemVotes storage item = items[itemId];

    return (item.upvotes, item.downvotes);
  }

  function hasUserVotedItem(address user, uint256 itemId) external view returns (bool, bool) {
    ItemVotes storage item = items[itemId];

    return (item.usersUpvoted[user], item.usersDownvoted[user]);
  }

}
