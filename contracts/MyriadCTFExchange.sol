// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

import "./AdminRegistry.sol";
import "./ConditionalTokens.sol";
import "./IMyriadMarketManager.sol";

/// @dev Minimal interface consumed by the exchange. FeeModule implements these.
interface IFeeModule {
  /// @notice Return (makerFeeBps, takerFeeBps) for a given market price.
  function getFeesAtPrice(uint256 marketId, uint256 price) external view returns (uint16 makerBps, uint16 takerBps);

  /// @notice Record `amount` of `token` as accrued protocol fees.
  ///         Caller must have already transferred the tokens to FeeModule.
  function accrueFees(address token, uint256 amount) external;
}

/// @dev Minimal interface for the NegRiskAdapter, used by cross-market matching.
interface INegRiskAdapter {
  function mintAllYesTokens(bytes32 eventId, uint256 amount, address recipient) external;
  function getEventOutcomeCount(bytes32 eventId) external view returns (uint256);
}

/// @title MyriadCTFExchange
/// @notice On-chain settlement engine for matched signed orders with partial fill support.
///         Buyer fees are added on top of notional; seller fees are deducted from proceeds.
///         Shares always transfer in full (fillAmount), never reduced by fees.
contract MyriadCTFExchange is Initializable, ReentrancyGuardUpgradeable, PausableUpgradeable, ERC1155Holder, UUPSUpgradeable, EIP712Upgradeable {
  using SafeERC20 for IERC20;

  enum Side {
    Buy,
    Sell
  }

  struct Order {
    address trader;
    uint256 marketId;
    uint8 outcomeId; // 0 = outcome 0, 1 = outcome 1
    Side side;
    uint256 amount;       // max shares for this order
    uint256 price;        // collateral per share, 1e18 precision
    uint256 minFillAmount; // minimum fill size; 0 = no minimum (slippage protection)
    uint256 nonce;
    uint256 expiration;
  }

  struct FeeConfig {
    uint256 makerFeeBps;
    uint256 takerFeeBps;
  }

  bytes32 private constant ORDER_TYPEHASH =
    keccak256(
      "Order(address trader,uint256 marketId,uint8 outcomeId,uint8 side,uint256 amount,uint256 price,uint256 minFillAmount,uint256 nonce,uint256 expiration)"
    );
  uint256 private constant ONE = 1e18;
  uint256 private constant BPS = 10000;

  AdminRegistry public registry;
  IMyriadMarketManager public manager;
  ConditionalTokens public conditionalTokens;
  address public feeModule;

  /// @notice NegRiskAdapter address for cross-market matching.
  address public negRiskAdapter;

  /// @notice Tracks cancellations — once true, the order can never be matched.
  mapping(bytes32 => bool) public orderInvalidated;

  /// @notice Cumulative fill amount per order hash (supports partial fills).
  mapping(bytes32 => uint256) public filledAmounts;

  event OrderCancelled(bytes32 indexed orderHash, address indexed trader);
  event OrdersMatched(
    bytes32 makerHash,
    bytes32 takerHash,
    address indexed maker,
    address indexed taker,
    uint256 indexed marketId,
    uint8 matchType, // 0 = direct, 1 = mint, 2 = merge
    uint256 fillAmount,
    uint256 makerAmountFilled,
    uint256 takerAmountFilled,
    uint256 makerFee,
    uint256 takerFee
  );
  event CrossMarketOrderFilled(
    bytes32 indexed orderHash,
    bytes32 indexed eventId,
    uint256 marketId,
    uint256 fillAmount,
    uint256 totalFilled
  );

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(
    IMyriadMarketManager _manager,
    ConditionalTokens _conditionalTokens,
    address _feeModule,
    AdminRegistry _registry
  ) public initializer {
    require(address(_manager) != address(0), "manager 0");
    require(address(_conditionalTokens) != address(0), "ct 0");
    require(_feeModule != address(0), "fee module 0");
    require(address(_registry) != address(0), "registry 0");

    __ReentrancyGuard_init();
    __Pausable_init();
    __UUPSUpgradeable_init();
    __EIP712_init("MyriadCTFExchange", "1");

    manager = _manager;
    conditionalTokens = _conditionalTokens;
    feeModule = _feeModule;
    registry = _registry;
  }

  function _authorizeUpgrade(address) internal view override {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
  }

  // ─── Emergency controls ───────────────────────────────────────────────

  function pause() external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    _pause();
  }

  function unpause() external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    _unpause();
  }

  function setNegRiskAdapter(address _adapter) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    negRiskAdapter = _adapter;
  }

  // ─── Order management ────────────────────────────────────────────────

  function cancelOrders(Order[] calldata orders) external {
    for (uint256 i = 0; i < orders.length; i++) {
      Order calldata order = orders[i];
      require(order.trader == msg.sender, "not trader");
      bytes32 orderHash = hashOrder(order);
      require(!orderInvalidated[orderHash], "already cancelled");
      orderInvalidated[orderHash] = true;
      emit OrderCancelled(orderHash, msg.sender);
    }
  }

  // ─── Settlement entry point ──────────────────────────────────────────

  /// @notice Match two signed orders, filling `fillAmount` shares.
  ///         Only callable by an address holding OPERATOR_ROLE.
  ///         Fee rates are looked up from FeeModule based on order prices.
  function matchOrdersWithFees(
    Order calldata maker,
    bytes calldata makerSig,
    Order calldata taker,
    bytes calldata takerSig,
    uint256 fillAmount
  ) external whenNotPaused nonReentrant {
    require(registry.hasRole(registry.OPERATOR_ROLE(), msg.sender), "not operator");
    require(maker.marketId == taker.marketId, "market mismatch");

    FeeConfig memory feeConfig;
    if (maker.side != taker.side) {
      (feeConfig.makerFeeBps, feeConfig.takerFeeBps) =
        IFeeModule(feeModule).getFeesAtPrice(maker.marketId, maker.price);
    } else {
      (feeConfig.makerFeeBps, ) = IFeeModule(feeModule).getFeesAtPrice(maker.marketId, maker.price);
      (, feeConfig.takerFeeBps) = IFeeModule(feeModule).getFeesAtPrice(maker.marketId, taker.price);
    }

    (uint256 makerFee, uint256 takerFee) = _matchOrders(maker, makerSig, taker, takerSig, fillAmount, feeConfig);

    uint256 totalFees = makerFee + takerFee;
    if (totalFees > 0) {
      address token = address(manager.getMarketCollateral(maker.marketId));
      IFeeModule(feeModule).accrueFees(token, totalFees);
    }
  }

  // ─── Cross-market settlement ─────────────────────────────────────────

  /// @notice Match BUY YES orders across different outcome markets in the same
  ///         neg risk event. All orders must be BUY side, outcome 0 (YES), for
  ///         distinct markets belonging to the same event. Prices must sum to >= ONE.
  ///         The NegRiskAdapter mints YES tokens via split + convert.
  ///         Same-trader orders across different outcomes are intentionally allowed,
  ///         as a trader may legitimately want YES exposure on multiple outcomes.
  function matchCrossMarketOrders(
    Order[] calldata orders,
    bytes[] calldata signatures,
    uint256 fillAmount
  ) external whenNotPaused nonReentrant {
    require(registry.hasRole(registry.OPERATOR_ROLE(), msg.sender), "not operator");
    require(negRiskAdapter != address(0), "no adapter");
    require(orders.length >= 2, "need >= 2 orders");
    require(signatures.length == orders.length, "sig count");
    require(fillAmount > 0, "fill 0");

    // Derive eventId from the first order, then verify ALL orders belong to it.
    bytes32 eventId = manager.getEventId(orders[0].marketId);
    require(eventId != bytes32(0), "not neg risk");

    {
      uint256 expectedCount = INegRiskAdapter(negRiskAdapter).getEventOutcomeCount(eventId);
      require(orders.length == expectedCount, "must match all outcomes");
    }

    uint256 priceSum;

    for (uint256 i = 0; i < orders.length; i++) {
      Order calldata order = orders[i];
      require(order.side == Side.Buy, "not buy");
      require(order.outcomeId == 0, "not YES");
      require(order.price > 0 && order.price <= ONE, "bad price");
      // Verify every order's market maps to the same eventId
      require(manager.getEventId(order.marketId) == eventId, "event mismatch");
      require(manager.isNegRisk(order.marketId), "not neg risk");

      _requireMarketOpen(order.marketId);
      _validateOrder(order, signatures[i]);

      bytes32 orderHash = hashOrder(order);
      require(filledAmounts[orderHash] + fillAmount <= order.amount, "overfill");
      require(order.minFillAmount == 0 || fillAmount >= order.minFillAmount, "below min fill");

      for (uint256 j = 0; j < i; j++) {
        require(order.marketId != orders[j].marketId, "dup market");
      }

      priceSum += order.price;
    }

    require(priceSum >= ONE, "price sum < 1");

    // Collect wcol from each buyer: notional + fee.
    // Convention: last order = taker, all others = makers.
    IERC20 collateral = manager.getMarketCollateral(orders[0].marketId);
    uint256 totalFees;
    uint256 takerIdx = orders.length - 1;

    uint256 notionalSoFar;
    for (uint256 i = 0; i < orders.length; i++) {
      uint256 notional;
      if (i == orders.length - 1) {
        notional = notionalSoFar >= fillAmount ? 0 : fillAmount - notionalSoFar;
      } else {
        notional = (fillAmount * orders[i].price) / ONE;
        notionalSoFar += notional;
        require(notional > 0, "notional 0");
      }

      uint256 fee;
      if (i == takerIdx) {
        (, uint16 takerBps) = IFeeModule(feeModule).getFeesAtPrice(orders[i].marketId, orders[i].price);
        fee = (notional * takerBps) / BPS;
      } else {
        (uint16 makerBps, ) = IFeeModule(feeModule).getFeesAtPrice(orders[i].marketId, orders[i].price);
        fee = (notional * makerBps) / BPS;
      }
      totalFees += fee;

      // Each buyer pays notional + fee
      collateral.safeTransferFrom(orders[i].trader, address(this), notional + fee);
    }

    // Mint full fillAmount shares
    collateral.forceApprove(negRiskAdapter, fillAmount);
    INegRiskAdapter(negRiskAdapter).mintAllYesTokens(eventId, fillAmount, address(this));

    // Distribute YES tokens (fillAmount per outcome) to each buyer
    for (uint256 i = 0; i < orders.length; i++) {
      uint256 tokenId = conditionalTokens.getTokenId(orders[i].marketId, 0);
      conditionalTokens.safeTransferFrom(address(this), orders[i].trader, tokenId, fillAmount, "");

      bytes32 orderHash = hashOrder(orders[i]);
      filledAmounts[orderHash] += fillAmount;

      emit CrossMarketOrderFilled(orderHash, eventId, orders[i].marketId, fillAmount, filledAmounts[orderHash]);
    }

    // Accrue fees
    if (totalFees > 0) {
      collateral.safeTransfer(feeModule, totalFees);
      IFeeModule(feeModule).accrueFees(address(collateral), totalFees);
    }
  }

  // ─── View helpers ─────────────────────────────────────────────────────

  function hashOrder(Order calldata order) public view returns (bytes32) {
    return
      _hashTypedDataV4(
        keccak256(
          abi.encode(
            ORDER_TYPEHASH,
            order.trader,
            order.marketId,
            order.outcomeId,
            order.side,
            order.amount,
            order.price,
            order.minFillAmount,
            order.nonce,
            order.expiration
          )
        )
      );
  }

  function DOMAIN_SEPARATOR() external view returns (bytes32) {
    return _domainSeparatorV4();
  }

  function getOrderStatus(bytes32 orderHash) external view returns (uint256 filled, bool invalidated) {
    return (filledAmounts[orderHash], orderInvalidated[orderHash]);
  }

  // ─── Internal settlement ─────────────────────────────────────────────

  function _matchOrders(
    Order calldata maker,
    bytes calldata makerSig,
    Order calldata taker,
    bytes calldata takerSig,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 makerFee, uint256 takerFee) {
    _validateFeeConfig(feeConfig);
    _validateOrder(maker, makerSig);
    _validateOrder(taker, takerSig);

    require(maker.trader != taker.trader, "self trade");
    require(maker.price > 0 && taker.price > 0, "bad price");
    require(maker.price <= ONE && taker.price <= ONE, "price > 1");
    require(fillAmount > 0, "fill 0");

    bytes32 makerHash = hashOrder(maker);
    bytes32 takerHash = hashOrder(taker);

    require(filledAmounts[makerHash] + fillAmount <= maker.amount, "maker overfill");
    require(filledAmounts[takerHash] + fillAmount <= taker.amount, "taker overfill");

    require(maker.minFillAmount == 0 || fillAmount >= maker.minFillAmount, "below maker min fill");
    require(taker.minFillAmount == 0 || fillAmount >= taker.minFillAmount, "below taker min fill");

    filledAmounts[makerHash] += fillAmount;
    filledAmounts[takerHash] += fillAmount;

    uint8 matchType;
    if (maker.side != taker.side) {
      matchType = 0; // direct
      (makerFee, takerFee) = _settleDirectMatch(maker, taker, fillAmount, feeConfig);
    } else if (maker.side == Side.Buy) {
      matchType = 1; // mint
      (makerFee, takerFee) = _settleMintMatch(maker, taker, fillAmount, feeConfig);
    } else {
      matchType = 2; // merge
      (makerFee, takerFee) = _settleMergeMatch(maker, taker, fillAmount, feeConfig);
    }

    emit OrdersMatched(
      makerHash,
      takerHash,
      maker.trader,
      taker.trader,
      maker.marketId,
      matchType,
      fillAmount,
      filledAmounts[makerHash],
      filledAmounts[takerHash],
      makerFee,
      takerFee
    );
  }

  function _validateOrder(Order calldata order, bytes calldata signature) internal view {
    require(order.trader != address(0), "trader 0");
    require(order.amount > 0, "amount 0");
    require(order.expiration == 0 || order.expiration >= block.timestamp, "expired");
    require(order.outcomeId < 2, "bad outcome");

    bytes32 orderHash = hashOrder(order);
    require(!orderInvalidated[orderHash], "invalidated");

    (address signer, ECDSA.RecoverError recoverError, ) = ECDSA.tryRecover(orderHash, signature);
    require(recoverError == ECDSA.RecoverError.NoError, "invalid signature");
    require(signer == order.trader, "signer mismatch");
  }

  function _validateFeeConfig(FeeConfig memory feeConfig) internal pure {
    require(feeConfig.makerFeeBps <= BPS, "maker fee");
    require(feeConfig.takerFeeBps <= BPS, "taker fee");
  }

  /// @dev Direct match: BUY vs SELL (same outcome).
  ///      Buyer pays notional + buyerFee, receives full fillAmount shares.
  ///      Seller provides fillAmount shares, receives notional - sellerFee.
  function _settleDirectMatch(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 makerFee, uint256 takerFee) {
    require(maker.outcomeId == taker.outcomeId, "outcome mismatch");

    if (maker.side == Side.Buy) {
      require(taker.side == Side.Sell, "side mismatch");
      require(maker.price >= taker.price, "price mismatch");
    } else {
      require(taker.side == Side.Buy, "side mismatch");
      require(maker.price <= taker.price, "price mismatch");
    }

    _requireMarketOpen(maker.marketId);

    uint256 notional = (fillAmount * maker.price) / ONE;
    require(notional > 0, "notional 0");

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);

    address buyer = maker.side == Side.Buy ? maker.trader : taker.trader;
    address seller = maker.side == Side.Sell ? maker.trader : taker.trader;

    // makerFee/takerFee are the fees attributable to each role regardless of buy/sell side
    makerFee = (notional * feeConfig.makerFeeBps) / BPS;
    takerFee = (notional * feeConfig.takerFeeBps) / BPS;

    uint256 buyerFee = maker.side == Side.Buy ? makerFee : takerFee;
    uint256 sellerFee = maker.side == Side.Sell ? makerFee : takerFee;
    uint256 sellerProceeds = notional - sellerFee;

    // Buyer pays notional + fee
    collateral.safeTransferFrom(buyer, address(this), notional + buyerFee);

    // Full shares transfer
    conditionalTokens.safeTransferFrom(
      seller,
      buyer,
      conditionalTokens.getTokenId(maker.marketId, maker.outcomeId),
      fillAmount,
      ""
    );

    // Seller receives notional - fee
    collateral.safeTransfer(seller, sellerProceeds);

    uint256 totalProtocolFees = makerFee + takerFee;
    if (totalProtocolFees > 0) {
      collateral.safeTransfer(feeModule, totalProtocolFees);
    }
  }

  /// @dev Mint match: two BUY orders for opposite outcomes.
  ///      Each buyer pays their notional + fee. Full fillAmount shares are minted
  ///      and distributed. Fees go to FeeModule separately.
  function _settleMintMatch(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 makerFee, uint256 takerFee) {
    require(maker.side == Side.Buy && taker.side == Side.Buy, "side mismatch");
    require(maker.outcomeId != taker.outcomeId, "same outcome");
    _requireMarketOpen(maker.marketId);

    (Order calldata outcome0Order, Order calldata outcome1Order) = maker.outcomeId == 0 ? (maker, taker) : (taker, maker);
    require(outcome0Order.price + outcome1Order.price == ONE, "price sum");

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);

    uint256 makerNotional = (fillAmount * maker.price) / ONE;
    uint256 takerNotional = fillAmount - makerNotional;
    require(makerNotional > 0 && takerNotional > 0, "notional 0");

    makerFee = (makerNotional * feeConfig.makerFeeBps) / BPS;
    takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    require(makerNotional + makerFee <= fillAmount, "cost exceeds value");
    require(takerNotional + takerFee <= fillAmount, "cost exceeds value");
    uint256 totalProtocolFees = makerFee + takerFee;

    // Each buyer pays notional + fee
    collateral.safeTransferFrom(maker.trader, address(this), makerNotional + makerFee);
    collateral.safeTransferFrom(taker.trader, address(this), takerNotional + takerFee);

    collateral.forceApprove(address(conditionalTokens), fillAmount);
    conditionalTokens.splitPosition(maker.marketId, fillAmount);

    // Each buyer receives fillAmount shares of their outcome token
    conditionalTokens.safeTransferFrom(
      address(this), outcome0Order.trader,
      conditionalTokens.getTokenId(maker.marketId, 0), fillAmount, ""
    );
    conditionalTokens.safeTransferFrom(
      address(this), outcome1Order.trader,
      conditionalTokens.getTokenId(maker.marketId, 1), fillAmount, ""
    );

    // Fees to FeeModule
    if (totalProtocolFees > 0) {
      collateral.safeTransfer(feeModule, totalProtocolFees);
    }
  }

  /// @dev Merge match: two SELL orders for opposite outcomes. Both sellers send
  ///      their outcome tokens; the exchange merges them back to collateral and
  ///      distributes proceeds minus fees.
  function _settleMergeMatch(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 makerFee, uint256 takerFee) {
    require(maker.side == Side.Sell && taker.side == Side.Sell, "side mismatch");
    require(maker.outcomeId != taker.outcomeId, "same outcome");
    _requireMarketOpen(maker.marketId);

    (Order calldata outcome0Order, Order calldata outcome1Order) = maker.outcomeId == 0 ? (maker, taker) : (taker, maker);
    require(outcome0Order.price + outcome1Order.price == ONE, "price sum");

    uint256 outcome0TokenId = conditionalTokens.getTokenId(maker.marketId, 0);
    uint256 outcome1TokenId = conditionalTokens.getTokenId(maker.marketId, 1);

    // Transfer outcome tokens to exchange before merging
    conditionalTokens.safeTransferFrom(outcome0Order.trader, address(this), outcome0TokenId, fillAmount, "");
    conditionalTokens.safeTransferFrom(outcome1Order.trader, address(this), outcome1TokenId, fillAmount, "");

    // Merge: burns both outcome tokens, releases collateral to this contract
    conditionalTokens.mergePositions(maker.marketId, fillAmount);

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);

    uint256 outcome0Notional = (fillAmount * outcome0Order.price) / ONE;
    uint256 outcome1Notional = fillAmount - outcome0Notional;
    require(outcome0Notional > 0 && outcome1Notional > 0, "notional 0");

    (makerFee, takerFee) = _paySellerWithFees(maker, taker, fillAmount, feeConfig, collateral, outcome0Order, outcome1Order, outcome0Notional, outcome1Notional);
  }

  /// @dev Fee deduction for merge matches — each seller's fee is deducted from their proceeds.
  function _paySellerWithFees(
    Order calldata maker,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig,
    IERC20 collateral,
    Order calldata outcome0Order,
    Order calldata outcome1Order,
    uint256 outcome0Notional,
    uint256 outcome1Notional
  ) internal returns (uint256 makerFee, uint256 takerFee) {
    uint256 makerNotional = (fillAmount * maker.price) / ONE;
    uint256 takerNotional = fillAmount - makerNotional;

    makerFee = (makerNotional * feeConfig.makerFeeBps) / BPS;
    takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    uint256 totalProtocolFees = makerFee + takerFee;

    address makerTrader = maker.trader;
    address takerTrader = taker.trader;

    uint256 makerProceeds = makerTrader == outcome0Order.trader ? outcome0Notional : outcome1Notional;
    uint256 takerProceeds = takerTrader == outcome0Order.trader ? outcome0Notional : outcome1Notional;

    require(makerProceeds >= makerFee, "maker fees exceed proceeds");
    makerProceeds -= makerFee;

    require(takerProceeds >= takerFee, "taker fees exceed proceeds");
    takerProceeds -= takerFee;

    collateral.safeTransfer(outcome0Order.trader, makerTrader == outcome0Order.trader ? makerProceeds : takerProceeds);
    collateral.safeTransfer(outcome1Order.trader, makerTrader == outcome1Order.trader ? makerProceeds : takerProceeds);

    if (totalProtocolFees > 0) {
      collateral.safeTransfer(feeModule, totalProtocolFees);
    }
  }

  function _requireMarketOpen(uint256 marketId) internal view {
    require(manager.getMarketState(marketId) == IMyriadMarketManager.MarketState.open, "market closed");
    require(!manager.isMarketPaused(marketId), "market paused");
  }
}
