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


  IERC20 public token;
  Tier[] public tiers;


  /// @dev protocol is immutable and has no ownership
  constructor(IERC20 _token, uint256[] memory _minAmounts, uint256[] memory _multipliers) {
    token = _token;

    for (uint256 i=0; i < _minAmounts.length; i++){
      tiers.push(Tier(_minAmounts[i], _multipliers[i]));
    }
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

    emit ItemAction(msg.sender, LockAction.lock, itemId, amount, block.timestamp);
    emit ItemUpdated(itemId, items[itemId].totalLocked, block.timestamp);
  }

  /// @dev allows user to unlock tokens from an item
  function unlockItem(uint256 itemId, uint256 amount) external {
    uint256 amountLocked = items[itemId].userLocks[msg.sender];

    require(
      amountLocked > 0 && amountLocked >= amount,
      "no erc20 balance locked"
    );

    _unlockItem(itemId, amount);
  }

  /// @dev allows user to unlock multiple items
  function unlockMultipleItems(uint256[] calldata itemIds) external {
    for (uint256 i = 0; i < itemIds.length; i++) {
      uint256 amountLocked = items[itemIds[i]].userLocks[msg.sender];

      require(
        amountLocked > 0,
        "no erc20 balance locked"
      );

      _unlockItem(itemIds[i], amountLocked);
    }
  }

  function _unlockItem(uint256 itemId, uint256 amount) internal {
    token.transfer(msg.sender, amount);

    items[itemId].userLocks[msg.sender] = items[itemId].userLocks[msg.sender].sub(amount);
    items[itemId].totalLocked = items[itemId].totalLocked.sub(amount);

    emit ItemAction(msg.sender, LockAction.unlock, itemId, amount, block.timestamp);
    emit ItemUpdated(itemId, items[itemId].totalLocked, block.timestamp);
  }

  /// @dev Returns the total amont locked for an item
  function getItemLockedAmount(uint256 itemId) external view returns (uint256) {
    ItemLocks storage item = items[itemId];

    return item.totalLocked;
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
