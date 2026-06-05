// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WrappedCollateral
/// @notice ERC20 wrapper around the real collateral token (e.g. USDC).
///         Only the NegRiskAdapter can wrap or mint; anyone holding wcol
///         may unwrap it back to underlying.
contract WrappedCollateral is ERC20 {
  using SafeERC20 for IERC20;

  IERC20 public immutable underlying;
  address public immutable adapter;

  error OnlyAdapter();

  modifier onlyAdapter() {
    if (msg.sender != adapter) revert OnlyAdapter();
    _;
  }

  constructor(
    IERC20 _underlying,
    address _adapter
  ) ERC20("Wrapped Collateral", "WCOL") {
    require(address(_underlying) != address(0), "underlying 0");
    require(_adapter != address(0), "adapter 0");
    underlying = _underlying;
    adapter = _adapter;
  }

  /// @notice Match the underlying token's decimals.
  function decimals() public view override returns (uint8) {
    return IERC20Metadata(address(underlying)).decimals();
  }

  /// @notice Deposit underlying and receive an equal amount of wcol. Adapter-only.
  function wrap(uint256 amount) external onlyAdapter {
    require(amount > 0, "amount 0");
    underlying.safeTransferFrom(msg.sender, address(this), amount);
    _mint(msg.sender, amount);
  }

  /// @notice Burn wcol and receive an equal amount of underlying. Public so
  ///         holders receiving wcol from CT.redeemPosition can always exit.
  function unwrap(uint256 amount) external {
    require(amount > 0, "amount 0");
    _burn(msg.sender, amount);
    underlying.safeTransfer(msg.sender, amount);
  }

  /// @notice Adapter-only: mint wcol without underlying deposit.
  ///         Used during convertPositions to create the collateral
  ///         needed for splitting in complementary markets.
  function adapterMint(address to, uint256 amount) external onlyAdapter {
    _mint(to, amount);
  }

  /// @notice Adapter-only: burn wcol held by the adapter.
  ///         Used during resolution cleanup to destroy minted wcol
  ///         once the backing NO positions have been redeemed.
  function adapterBurn(address from, uint256 amount) external onlyAdapter {
    _burn(from, amount);
  }
}
