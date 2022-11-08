pragma solidity ^0.6.0;

import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";

contract FantasyERC20 is ERC20PresetMinterPauser {

  event TokensClaimed(
    address indexed user,
    uint256 amount,
    uint256 timestamp
  );

  mapping(address => bool) usersClaimed;
  address public tokenManager;
  uint256 public tokenAmountToClaim;

  constructor(
    string memory name,
    string memory symbol,
    uint256 _tokenAmountToClaim,
    address _tokenManager
    ) public ERC20PresetMinterPauser(name, symbol) {
      tokenAmountToClaim = _tokenAmountToClaim;
      tokenManager = _tokenManager;
    }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    super._beforeTokenTransfer(from, to, amount);

    require(from == tokenManager || to == tokenManager, "FantasyERC20: token transfer not allowed between the addresses");
  }

  function claimTokens(address user) external {
    require(usersClaimed[user] == false, "FantasyERC20: address already claimed the tokens");

    mint(user, tokenAmountToClaim);

    usersClaimed[user] = true;

    emit TokensClaimed(user, tokenAmountToClaim, now);
  }
}
