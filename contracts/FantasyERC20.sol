// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./ERC20MinterPauser.sol";
import "./IPredictionMarketV3Factory.sol";

contract FantasyERC20 is ERC20MinterPauser {
  event TokensClaimed(address indexed user, uint256 amount, uint256 timestamp);

  mapping(address => bool) usersClaimed;
  address public tokenManager;
  uint256 public tokenAmountToClaim;
  address PMV3Factory;
  address PMV3Controller;

  // ------ Modifiers ------

  modifier shouldNotHaveClaimedYet() {
    require(usersClaimed[msg.sender] == false, "FantasyERC20: address already claimed the tokens");
    _;
  }

  constructor(
    string memory name,
    string memory symbol,
    uint256 _tokenAmountToClaim,
    address _tokenManager,
    address _PMV3Factory,
    address _PMV3Controller
  ) ERC20MinterPauser(name, symbol) {
    tokenAmountToClaim = _tokenAmountToClaim;
    tokenManager = _tokenManager;
    PMV3Factory = _PMV3Factory;
    PMV3Controller = _PMV3Controller;
  }

  /// @dev Validates if the transfer is from or to the tokenManager, blocking it otherwise
  function _transfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    require(
      from == tokenManager || to == tokenManager,
      "FantasyERC20: token transfer not allowed between the addresses"
    );

    super._transfer(from, to, amount);
  }

  /// @dev Allows user to claim the amount of tokens by minting them
  function claimTokens() public shouldNotHaveClaimedYet {
    _mint(msg.sender, tokenAmountToClaim);

    usersClaimed[msg.sender] = true;

    emit TokensClaimed(msg.sender, tokenAmountToClaim, block.timestamp);
  }

  /// @dev Allows user to approve and claim the amount of tokens by minting them
  function claimAndApproveTokens() external shouldNotHaveClaimedYet {
    claimTokens();
    approve(tokenManager, 2**128 - 1);
  }

  /// @dev Returns if the address has already claimed or not the tokens
  function hasUserClaimedTokens(address user) external view returns (bool) {
    return usersClaimed[user];
  }

  function paused() public view virtual override returns (bool) {
    bool pausedSuper = super.paused();

    if (PMV3Factory != address(0) && PMV3Controller != address(0)) {
      IPredictionMarketV3Factory factory = IPredictionMarketV3Factory(PMV3Factory);
      pausedSuper = pausedSuper || !factory.isPMControllerActive(PMV3Controller);
    }

    return pausedSuper;
  }
}
