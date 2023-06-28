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

  struct Tier {
    uint256 minAmount;
    uint256 multiplier;
  }

  struct ItemLocks {
    mapping(address => uint256) userLocks;
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
  constructor(IERC20 _token, Tier[] _tiers) {
    token = _token;
    tiers = _tiers;
  }

  /// @dev allows user to lock tokens in an item
  function lockItem(uint256 itemId, uint256 amount) external {
    require(
      amount > 0 && token.balanceOf(msg.sender) >= amount,
      "not enough erc20 balance held"
    );


    token.transferFrom(msg.sender, address(this), amount);

    items[itemId].userLocks[msg.sender] = items[itemId].userLocks[msg.sender].add(amount);
    items[itemId].totalLocked = items[itemId].totalLocked.add(amount);

    users[msg.sender].amountLocked[itemId] = users[msg.sender].amountLocked[itemId].add(amount);
    users[msg.sender].totalLocked = users[msg.sender].totalLocked.add(amount);

    emit ItemAction(msg.sender, LockAction.lock, itemId, amount, block.timestamp);
    emit ItemUpdated(itemId, items[itemId].totalLocked, block.timestamp);
  }

  /// @dev allows user to unlock tokens from an item
  function unlockItem(uint256 itemId) external {
    uint256 storage amountLocked = items[itemId].userLocks[msg.sender];

    require(
      amountLocked > 0,
      "no erc20 balance locked"
    );

    _unlockItem(itemId, amountLocked);
  }

  /// @dev allows user to unlock multiple items
  function unlockMultipleItems(uint256[] itemIds) external {
    for (uint256 i = 0; i < itemIds.length; i++) {
      uint256 storage amountLocked = items[itemIds[i]].userLocks[msg.sender];

      require(
        amountLocked > 0,
        "no erc20 balance locked"
      );

      _unlockItem(itemIds[i], amountLocked);
    }
  }

  function _unlockItem(uint256 itemId, uint256 amount) internal {
    token.transferFrom(address(this), msg.sender, amount);

    items[itemId].userLocks[msg.sender] = items[itemId].userLocks[msg.sender].sub(amount);
    items[itemId].totalLocked = items[itemId].totalLocked.sub(amount);

    users[msg.sender].amountLocked[itemId] = users[msg.sender].amountLocked[itemId].sub(amount);
    users[msg.sender].totalLocked = users[msg.sender].totalLocked.sub(amount);

    emit ItemAction(msg.sender, LockAction.unlock, itemId, amount, block.timestamp);
    emit ItemUpdated(itemId, items[itemId].totalLocked, block.timestamp);
  }

  /// @dev Returns the total amount locked by a user
  function getUserLockedAmount(address user) external view returns (uint256) {
    return users[user].totalLocked;
  }

  /// @dev Returns the total amont locked for an item
  function getItemLockedAmount(uint256 itemId) external view returns (uint256) {
    ItemLocks storage item = items[itemId];

    return ItemLocks.totalLocked;
  }

  /// @dev Returns the amount the user has locked for an item
  function amountUserLockedItem(address user, uint256 itemId) external view returns (uint256) {
    ItemLocks storage item = items[itemId];

    return item.userLocks[user];
  }

  /// @dev Returns the ERC20 token address
  function getTokenAddress() external view returns (address) {
    return address(token);
  }
}
