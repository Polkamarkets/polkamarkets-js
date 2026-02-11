// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./AdminRegistry.sol";
import "./MyriadCTFExchange.sol";

/// @title FeeModule
/// @notice Computes maker/taker fees and routes settlement through the exchange.
contract FeeModule {
  uint256 private constant BPS = 10000;

  struct MarketFee {
    uint16 makerFeeBps;
    uint16 takerFeeBps;
  }

  struct FeeSplit {
    uint16 treasuryBps;
    uint16 distributorBps;
    uint16 networkBps;
  }

  AdminRegistry public immutable registry;
  MyriadCTFExchange public immutable exchange;

  mapping(uint256 => MarketFee) public marketFees;

  address public treasury;
  address public distributor;
  address public network;
  FeeSplit public feeSplit;

  event MarketFeesUpdated(uint256 indexed marketId, uint16 makerFeeBps, uint16 takerFeeBps);
  event FeeRecipientsUpdated(address treasury, address distributor, address network);
  event FeeSplitUpdated(uint16 treasuryBps, uint16 distributorBps, uint16 networkBps);

  constructor(AdminRegistry _registry, MyriadCTFExchange _exchange) {
    registry = _registry;
    exchange = _exchange;
  }

  function setMarketFees(uint256 marketId, uint16 makerFeeBps, uint16 takerFeeBps) external {
    require(registry.hasRole(registry.FEE_ADMIN_ROLE(), msg.sender), "not fee admin");
    require(makerFeeBps <= BPS && takerFeeBps <= BPS, "fee too high");

    marketFees[marketId] = MarketFee({makerFeeBps: makerFeeBps, takerFeeBps: takerFeeBps});
    emit MarketFeesUpdated(marketId, makerFeeBps, takerFeeBps);
  }

  function setFeeRecipients(address _treasury, address _distributor, address _network) external {
    require(registry.hasRole(registry.FEE_ADMIN_ROLE(), msg.sender), "not fee admin");
    require(_treasury != address(0) && _distributor != address(0) && _network != address(0), "recipient 0");

    treasury = _treasury;
    distributor = _distributor;
    network = _network;
    emit FeeRecipientsUpdated(_treasury, _distributor, _network);
  }

  function setFeeSplit(uint16 treasuryBps, uint16 distributorBps, uint16 networkBps) external {
    require(registry.hasRole(registry.FEE_ADMIN_ROLE(), msg.sender), "not fee admin");
    require(uint256(treasuryBps) + uint256(distributorBps) + uint256(networkBps) == BPS, "bad split");

    feeSplit = FeeSplit({
      treasuryBps: treasuryBps,
      distributorBps: distributorBps,
      networkBps: networkBps
    });

    emit FeeSplitUpdated(treasuryBps, distributorBps, networkBps);
  }

  function matchOrdersWithFees(
    MyriadCTFExchange.Order calldata maker,
    bytes calldata makerSig,
    MyriadCTFExchange.Order calldata taker,
    bytes calldata takerSig,
    uint256 fillAmount
  ) external {
    require(registry.hasRole(registry.OPERATOR_ROLE(), msg.sender), "not operator");
    require(maker.marketId == taker.marketId, "market mismatch");

    MarketFee memory fees = marketFees[maker.marketId];

    MyriadCTFExchange.FeeConfig memory feeConfig = MyriadCTFExchange.FeeConfig({
      makerFeeBps: fees.makerFeeBps,
      takerFeeBps: fees.takerFeeBps,
      treasuryBps: feeSplit.treasuryBps,
      distributorBps: feeSplit.distributorBps,
      networkBps: feeSplit.networkBps
    });

    MyriadCTFExchange.FeeRecipients memory recipients = MyriadCTFExchange.FeeRecipients({
      treasury: treasury,
      distributor: distributor,
      network: network
    });

    exchange.matchOrders(maker, makerSig, taker, takerSig, fillAmount, feeConfig, recipients);
  }
}
