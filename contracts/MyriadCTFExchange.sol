// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import "./ConditionalTokens.sol";
import "./IMyriadMarketManager.sol";

/// @title MyriadCTFExchange
/// @notice On-chain settlement engine for matched signed orders.
contract MyriadCTFExchange is ReentrancyGuard, ERC1155Holder, EIP712 {
  using SafeERC20 for IERC20;

  enum Side {
    Buy,
    Sell
  }

  struct Order {
    address trader;
    uint256 marketId;
    uint8 outcome; // 0 = YES, 1 = NO
    Side side;
    uint256 amount; // shares
    uint256 price; // collateral per share, 1e18 precision
    uint256 nonce;
    uint256 expiration;
  }

  struct FeeConfig {
    uint256 makerFeeBps;
    uint256 takerFeeBps;
    uint256 treasuryBps;
    uint256 distributorBps;
    uint256 networkBps;
  }

  struct FeeRecipients {
    address treasury;
    address distributor;
    address network;
  }

  bytes32 private constant ORDER_TYPEHASH =
    keccak256(
      "Order(address trader,uint256 marketId,uint8 outcome,uint8 side,uint256 amount,uint256 price,uint256 nonce,uint256 expiration)"
    );
  uint256 private constant ONE = 1e18;
  uint256 private constant BPS = 10000;

  IMyriadMarketManager public immutable manager;
  ConditionalTokens public immutable conditionalTokens;
  address public immutable feeModule;

  mapping(bytes32 => bool) public orderInvalidated;

  event OrderCancelled(bytes32 indexed orderHash, address indexed trader);
  event OrdersMatched(bytes32 indexed makerHash, bytes32 indexed takerHash, uint256 marketId);

  modifier onlyFeeModule() {
    require(msg.sender == feeModule, "only fee module");
    _;
  }

  constructor(
    IMyriadMarketManager _manager,
    ConditionalTokens _conditionalTokens,
    address _feeModule
  ) EIP712("MyriadCTFExchange", "1") {
    manager = _manager;
    conditionalTokens = _conditionalTokens;
    feeModule = _feeModule;
  }

  function cancelOrders(Order[] calldata orders) external {
    for (uint256 i = 0; i < orders.length; i++) {
      Order calldata order = orders[i];
      require(order.trader == msg.sender, "not trader");
      bytes32 orderHash = hashOrder(order);
      orderInvalidated[orderHash] = true;
      emit OrderCancelled(orderHash, msg.sender);
    }
  }

  function matchOrders(
    Order calldata maker,
    bytes calldata makerSig,
    Order calldata taker,
    bytes calldata takerSig,
    FeeConfig calldata feeConfig,
    FeeRecipients calldata recipients
  ) external onlyFeeModule nonReentrant {
    _validateFeeConfig(feeConfig);
    _validateOrder(maker, makerSig);
    _validateOrder(taker, takerSig);

    require(maker.marketId == taker.marketId, "market mismatch");
    require(maker.amount == taker.amount, "amount mismatch");
    require(maker.outcome < 2 && taker.outcome < 2, "bad outcome");
    require(maker.price > 0 && taker.price > 0, "bad price");
    require(maker.price <= ONE && taker.price <= ONE, "price > 1");

    _invalidateOrder(maker);
    _invalidateOrder(taker);

    if (maker.side != taker.side) {
      _settleDirectMatch(maker, taker, feeConfig, recipients);
    } else if (maker.side == Side.Buy) {
      _settleMintMatch(maker, taker, feeConfig, recipients);
    } else {
      _settleMergeMatch(maker, taker, feeConfig, recipients);
    }

    emit OrdersMatched(hashOrder(maker), hashOrder(taker), maker.marketId);
  }

  function hashOrder(Order calldata order) public view returns (bytes32) {
    return
      _hashTypedDataV4(
        keccak256(
          abi.encode(
            ORDER_TYPEHASH,
            order.trader,
            order.marketId,
            order.outcome,
            order.side,
            order.amount,
            order.price,
            order.nonce,
            order.expiration
          )
        )
      );
  }

  function _validateOrder(Order calldata order, bytes calldata signature) internal view {
    require(order.trader != address(0), "trader 0");
    require(order.amount > 0, "amount 0");
    require(order.expiration == 0 || order.expiration >= block.timestamp, "expired");

    bytes32 orderHash = hashOrder(order);
    require(!orderInvalidated[orderHash], "invalidated");

    address signer = ECDSA.recover(orderHash, signature);
    require(signer == order.trader, "bad sig");
  }

  function _invalidateOrder(Order calldata order) internal {
    bytes32 orderHash = hashOrder(order);
    orderInvalidated[orderHash] = true;
  }

  function _validateFeeConfig(FeeConfig calldata feeConfig) internal pure {
    require(feeConfig.makerFeeBps <= BPS, "maker fee");
    require(feeConfig.takerFeeBps <= BPS, "taker fee");
    require(feeConfig.treasuryBps + feeConfig.distributorBps + feeConfig.networkBps == BPS, "split");
  }

  function _settleDirectMatch(
    Order calldata maker,
    Order calldata taker,
    FeeConfig calldata feeConfig,
    FeeRecipients calldata recipients
  ) internal {
    require(maker.outcome == taker.outcome, "outcome mismatch");

    if (maker.side == Side.Buy) {
      require(taker.side == Side.Sell, "side mismatch");
      require(maker.price >= taker.price, "price mismatch");
    } else {
      require(taker.side == Side.Buy, "side mismatch");
      require(maker.price <= taker.price, "price mismatch");
    }

    _requireMarketOpen(maker.marketId);

    uint256 executionPrice = maker.price;
    uint256 notional = (maker.amount * executionPrice) / ONE;

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);
    uint256 makerRebate = (notional * feeConfig.makerFeeBps) / BPS;
    uint256 takerFee = (notional * feeConfig.takerFeeBps) / BPS;

    (uint256 treasuryFee, uint256 distributorFee, uint256 networkFee) = _splitFees(takerFee, feeConfig);

    address buyer = maker.side == Side.Buy ? maker.trader : taker.trader;
    address seller = maker.side == Side.Sell ? maker.trader : taker.trader;
    address takerTrader = taker.trader;
    address makerTrader = maker.trader;

    // Buyer pays into exchange, exchange distributes.
    uint256 buyerPayment = notional;
    if (takerTrader == buyer) {
      buyerPayment = notional + makerRebate + takerFee;
    }
    collateral.safeTransferFrom(buyer, address(this), buyerPayment);

    // Transfer outcome shares from seller to buyer.
    conditionalTokens.safeTransferFrom(
      seller,
      buyer,
      conditionalTokens.getTokenId(maker.marketId, maker.outcome),
      maker.amount,
      ""
    );

    // Pay seller.
    uint256 sellerProceeds = notional;
    if (takerTrader == seller) {
      require(notional >= makerRebate + takerFee, "fees exceed proceeds");
      sellerProceeds = notional - makerRebate - takerFee;
    }
    collateral.safeTransfer(seller, sellerProceeds);

    // Pay maker rebate and fees.
    if (makerRebate > 0) {
      collateral.safeTransfer(makerTrader, makerRebate);
    }
    _distributeFees(collateral, recipients, treasuryFee, distributorFee, networkFee);
  }

  function _settleMintMatch(
    Order calldata maker,
    Order calldata taker,
    FeeConfig calldata feeConfig,
    FeeRecipients calldata recipients
  ) internal {
    require(maker.side == Side.Buy && taker.side == Side.Buy, "side mismatch");
    require(maker.outcome != taker.outcome, "same outcome");
    _requireMarketOpen(maker.marketId);

    (Order calldata yesOrder, Order calldata noOrder) = maker.outcome == 0 ? (maker, taker) : (taker, maker);
    require(yesOrder.price + noOrder.price == ONE, "price sum");

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);

    uint256 yesNotional = (yesOrder.amount * yesOrder.price) / ONE;
    uint256 noNotional = (noOrder.amount * noOrder.price) / ONE;

    collateral.safeTransferFrom(yesOrder.trader, address(conditionalTokens), yesNotional);
    collateral.safeTransferFrom(noOrder.trader, address(conditionalTokens), noNotional);

    conditionalTokens.mintPositionsTo(yesOrder.trader, noOrder.trader, maker.marketId, maker.amount);

    _applyTakerFees(maker, taker, feeConfig, recipients, collateral);
  }

  function _settleMergeMatch(
    Order calldata maker,
    Order calldata taker,
    FeeConfig calldata feeConfig,
    FeeRecipients calldata recipients
  ) internal {
    require(maker.side == Side.Sell && taker.side == Side.Sell, "side mismatch");
    require(maker.outcome != taker.outcome, "same outcome");
    _requireMarketOpen(maker.marketId);

    (Order calldata yesOrder, Order calldata noOrder) = maker.outcome == 0 ? (maker, taker) : (taker, maker);
    require(yesOrder.price + noOrder.price == ONE, "price sum");

    uint256 yesTokenId = conditionalTokens.getTokenId(maker.marketId, 0);
    uint256 noTokenId = conditionalTokens.getTokenId(maker.marketId, 1);

    conditionalTokens.safeTransferFrom(yesOrder.trader, address(this), yesTokenId, maker.amount, "");
    conditionalTokens.safeTransferFrom(noOrder.trader, address(this), noTokenId, maker.amount, "");

    conditionalTokens.mergePositionsTo(address(this), maker.marketId, maker.amount);

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);

    uint256 yesNotional = (yesOrder.amount * yesOrder.price) / ONE;
    uint256 noNotional = (noOrder.amount * noOrder.price) / ONE;

    _paySellerWithFees(maker, taker, feeConfig, recipients, collateral, yesOrder, noOrder, yesNotional, noNotional);
  }

  function _applyTakerFees(
    Order calldata maker,
    Order calldata taker,
    FeeConfig calldata feeConfig,
    FeeRecipients calldata recipients,
    IERC20 collateral
  ) internal {
    uint256 makerNotional = (maker.amount * maker.price) / ONE;
    uint256 takerNotional = (taker.amount * taker.price) / ONE;

    uint256 makerRebate = (makerNotional * feeConfig.makerFeeBps) / BPS;
    uint256 takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    (uint256 treasuryFee, uint256 distributorFee, uint256 networkFee) = _splitFees(takerFee, feeConfig);

    uint256 takerPayment = makerRebate + takerFee;
    if (takerPayment > 0) {
      collateral.safeTransferFrom(taker.trader, address(this), takerPayment);
    }

    if (makerRebate > 0) {
      collateral.safeTransfer(maker.trader, makerRebate);
    }
    _distributeFees(collateral, recipients, treasuryFee, distributorFee, networkFee);
  }

  function _paySellerWithFees(
    Order calldata maker,
    Order calldata taker,
    FeeConfig calldata feeConfig,
    FeeRecipients calldata recipients,
    IERC20 collateral,
    Order calldata yesOrder,
    Order calldata noOrder,
    uint256 yesNotional,
    uint256 noNotional
  ) internal {
    uint256 makerNotional = (maker.amount * maker.price) / ONE;
    uint256 takerNotional = (taker.amount * taker.price) / ONE;

    uint256 makerRebate = (makerNotional * feeConfig.makerFeeBps) / BPS;
    uint256 takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    (uint256 treasuryFee, uint256 distributorFee, uint256 networkFee) = _splitFees(takerFee, feeConfig);

    address makerTrader = maker.trader;
    address takerTrader = taker.trader;

    uint256 makerProceeds = makerTrader == yesOrder.trader ? yesNotional : noNotional;
    uint256 takerProceeds = takerTrader == yesOrder.trader ? yesNotional : noNotional;

    if (makerRebate > 0) {
      makerProceeds += makerRebate;
    }
    if (takerFee + makerRebate > 0) {
      require(takerProceeds >= takerFee + makerRebate, "fees exceed proceeds");
      takerProceeds -= (takerFee + makerRebate);
    }

    collateral.safeTransfer(yesOrder.trader, makerTrader == yesOrder.trader ? makerProceeds : takerProceeds);
    collateral.safeTransfer(noOrder.trader, makerTrader == noOrder.trader ? makerProceeds : takerProceeds);

    _distributeFees(collateral, recipients, treasuryFee, distributorFee, networkFee);
  }

  function _splitFees(uint256 takerFee, FeeConfig calldata feeConfig)
    internal
    pure
    returns (
      uint256 treasuryFee,
      uint256 distributorFee,
      uint256 networkFee
    )
  {
    treasuryFee = (takerFee * feeConfig.treasuryBps) / BPS;
    distributorFee = (takerFee * feeConfig.distributorBps) / BPS;
    networkFee = takerFee - treasuryFee - distributorFee;
  }

  function _distributeFees(
    IERC20 collateral,
    FeeRecipients calldata recipients,
    uint256 treasuryFee,
    uint256 distributorFee,
    uint256 networkFee
  ) internal {
    if (treasuryFee > 0) {
      collateral.safeTransfer(recipients.treasury, treasuryFee);
    }
    if (distributorFee > 0) {
      collateral.safeTransfer(recipients.distributor, distributorFee);
    }
    if (networkFee > 0) {
      collateral.safeTransfer(recipients.network, networkFee);
    }
  }

  function _requireMarketOpen(uint256 marketId) internal view {
    require(manager.getMarketState(marketId) == IMyriadMarketManager.MarketState.open, "market closed");
    require(!manager.isMarketPaused(marketId), "market paused");
    require(manager.getMarketExecutionMode(marketId) == 1, "not clob");
  }
}
