pragma solidity ^0.8.18;
pragma experimental ABIEncoderV2;

// openzeppelin imports
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Upvoting / Downvoting Contract
contract Reward {
  using SafeMath for uint256;

  event ItemUpdated(uint256 indexed itemId, uint256 lockAmount, uint256 timestamp);

  event ItemAction(address indexed user, LockAction indexed action, uint256 indexed itemId, uint256 lockAmount, uint256 timestamp);

  enum LockAction {
    lock,
    unlock
  }

  struct Tiers {
    uint256 minAmount;
    uint256 multiplier;
  }

  struct ItemLocks {
    mapping(address => uint256) usersLocked;
    uint256 totalLocked;
  }

  mapping(uint256 => ItemLocks) items;

  struct UserLocks {
    mapping(uint256 => uint256) amountLocked;
    uint256 totalLocked;
  }

  mapping(address => UserLocks) users;

  IERC20 public token;
  Tiers[] public tiers;


  /// @dev protocol is immutable and has no ownership
  constructor(IERC20 _token, Tiers[] _tiers) {
    token = _token;
    tiers = _tiers;
  }

  /// lock tokens in the contract
  /// transfer?
  /// save total amount locked for each market
  /// save info of address/market id/amount locked
  /// emit event
  /// @dev allows user to lock an item
  function lockItem(uint256 itemId, uint256 amount) external {
    // TODO - implement
  }

  // unlock goes the other way around
  /// @dev allows user to unlock an item
  function unlockItem(uint256 itemId) external {
    // TODO - implement
  }

/// @dev allows user to unlock multiple items
  function unlockMultipleItems(uint256[] itemIds) external {
    // TODO - implement
  }

  /// @dev Returns the total amont locked for an item
  function getItemLockedAmount(uint256 itemId) external view returns (uint256) {
    ItemLocks storage item = items[itemId];

    return ItemLocks.totalLocked;
  }

  /// @dev Returns the amount the user has locked for an item
  function amountUserLockedItem(address user, uint256 itemId) external view returns (uint256) {
    ItemLocks storage item = items[itemId];

    return (item.usersLocked[user]);
  }
}
