// SPDX-License-Identifier: GPL-3.0-only
// Based on https://github.com/RealityETH/reality-eth-monorepo/blob/main/packages/contracts/development/contracts/RealityETH_ERC20_Factory.sol

pragma solidity ^0.8.18;

// local imports
import "./IRealityETH_ERC20.sol";
import "./Proxy.sol";

// definining interface this way instead of IERC20 to avoid conflicts
interface IRealityETH_IERC20 {
  function decimals() external view returns (uint8);
  function symbol() external view returns (string memory);
}

contract RealityETH_ERC20_Factory {

  address public libraryAddress;
  mapping(address => address) public deployments;

  event RealityETH_ERC20_deployed (address reality_eth, address token, uint8 decimals, string token_ticker);

  constructor(address _libraryAddress) {
    libraryAddress = _libraryAddress;
  }

  /// @notice Returns the address of a proxy based on the specified address
  /// @dev based on https://github.com/optionality/clone-factory
  function _deployProxy(address _target) internal returns (address clone) {
    return address(new Proxy(_target));
  }

  function createInstance(address _token) external {
    require(deployments[_token] == address(0), "There should only be one deployment per version per token");
    uint8 decimals = IRealityETH_IERC20(_token).decimals();
    string memory ticker = IRealityETH_IERC20(_token).symbol();
    address clone = _deployProxy(libraryAddress);
    IRealityETH_ERC20(clone).setToken(_token);
    IRealityETH_ERC20(clone).createTemplate('{"title": "%s", "type": "bool", "category": "%s", "lang": "%s"}');
    IRealityETH_ERC20(clone).createTemplate('{"title": "%s", "type": "uint", "decimals": 18, "category": "%s", "lang": "%s"}');
    IRealityETH_ERC20(clone).createTemplate('{"title": "%s", "type": "single-select", "outcomes": [%s], "category": "%s", "lang": "%s"}');
    IRealityETH_ERC20(clone).createTemplate('{"title": "%s", "type": "multiple-select", "outcomes": [%s], "category": "%s", "lang": "%s"}');
    IRealityETH_ERC20(clone).createTemplate('{"title": "%s", "type": "datetime", "category": "%s", "lang": "%s"}');
    deployments[_token] = clone;
    emit RealityETH_ERC20_deployed(clone, _token, decimals, ticker);
  }
}
