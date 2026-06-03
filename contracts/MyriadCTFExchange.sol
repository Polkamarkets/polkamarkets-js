// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

import "./AdminRegistry.sol";
import "./ConditionalTokens.sol";
import "./IMyriadMarketManager.sol";
import "./Outcomes.sol";

/// @dev Minimal interface consumed by the exchange. FeeModule implements these.
interface IFeeModule {
  /// @notice Return (makerFeeBps, takerFeeBps) for a given market price.
  function getFeesAtPrice(uint256 marketId, uint256 price) external view returns (uint16 makerBps, uint16 takerBps);

  /// @notice Record `amount` of `token` as accrued protocol fees.
  ///         Caller must have already transferred the tokens to FeeModule.
  function accrueFees(address token, uint256 amount) external;
}

/// @dev Minimal interface for the NegRiskAdapter.
interface INegRiskAdapter {
  function mintAllYesTokens(bytes32 eventId, uint256 amount, address recipient) external;
  function getEventOutcomeCount(bytes32 eventId) external view returns (uint256);
  function underlying() external view returns (IERC20);
  function wrapForExchange(uint256 amount) external;
}

/// @dev Minimal interface for WrappedCollateral.
interface IWrappedCollateral {
  function unwrap(uint256 amount) external;
}

/// @title MyriadCTFExchange
/// @notice On-chain settlement engine for matched signed orders with partial fill support.
///         Buyer fees are added on top of notional; seller fees are deducted from proceeds.
///         Shares always transfer in full (fillAmount), never reduced by fees.
contract MyriadCTFExchange is Initializable, ReentrancyGuardTransientUpgradeable, PausableUpgradeable, ERC1155Holder, UUPSUpgradeable, EIP712Upgradeable {
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
  uint256 private constant DEFAULT_CALLBACK_GAS_LIMIT = 100_000;

  AdminRegistry public registry;
  IMyriadMarketManager public manager;
  ConditionalTokens public conditionalTokens;
  address public feeModule;

  /// @notice NegRiskAdapter address for cross-market matching.
  address public negRiskAdapter;

  /// @notice Tracks cancellations — once true, the order can never be matched.
  mapping(bytes32 orderHash => bool) public orderInvalidated;

  /// @notice Cumulative fill amount per order hash (supports partial fills).
  mapping(bytes32 orderHash => uint256 filled) public filledAmounts;

  /// @notice Gas cap for ERC-1155 safeTransferFrom callbacks (EIP-7702 griefing protection).
  uint256 public callbackGasLimit;

  /// @notice Minimum order.amount; also minimum remainder after a partial fill.
  uint256 public minOrderAmount;

  event CallbackGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
  event MinOrderAmountUpdated(uint256 oldAmount, uint256 newAmount);
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
  event NegRiskAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
  event SurplusCollected(bytes32 indexed eventId, uint256 amount);

  error ZeroManager();
  error ZeroCT();
  error ZeroFeeModule();
  error ZeroRegistry();
  error NotAdmin();
  error LimitTooLow();
  error NotTrader();
  error AlreadyCancelled();
  error NotOperator();
  error MarketMismatch();
  error NoMakers();
  error SigCount();
  error FillCount();
  error TakerOverfill();
  error BelowTakerMinFill();
  error TakerDustRemainder();
  error NoAdapter();
  error NeedAtLeastTwoOrders();
  error ZeroFill();
  error NotNegRisk();
  error MustMatchAllOutcomes();
  error NotBuy();
  error NotYes();
  error BadPrice();
  error EventMismatch();
  error Overfill();
  error BelowMinFill();
  error DuplicateMarket();
  error PriceSumBelowOne();
  error PriceSumAboveOne();
  error ZeroNotional();
  error DustRemainder();
  error SelfTrade();
  error PriceAboveOne();
  error MakerOverfill();
  error BelowMakerMinFill();
  error MakerDustRemainder();
  error ZeroTrader();
  error ZeroAmount();
  error BelowMinAmount();
  error OrderExpired();
  error BadOutcome();
  error OrderInvalidated();
  error InvalidSignature();
  error MakerFeeExceeds();
  error TakerFeeExceeds();
  error TransferFailed();
  error OutcomeMismatch();
  error SideMismatch();
  error PriceMismatch();
  error SameOutcome();
  error MakerFeesExceedProceeds();
  error TakerFeesExceedProceeds();
  error InsufficientCollateral();
  error InsufficientAllowance();
  error InsufficientTokens();
  error TokensNotApproved();
  error MarketNotTradeable();

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
    if (address(_manager) == address(0)) revert ZeroManager();
    if (address(_conditionalTokens) == address(0)) revert ZeroCT();
    if (_feeModule == address(0)) revert ZeroFeeModule();
    if (address(_registry) == address(0)) revert ZeroRegistry();

    __Pausable_init();
    __UUPSUpgradeable_init();
    __EIP712_init("MyriadCTFExchange", "1");

    manager = _manager;
    conditionalTokens = _conditionalTokens;
    feeModule = _feeModule;
    registry = _registry;
    callbackGasLimit = DEFAULT_CALLBACK_GAS_LIMIT;
  }

  function _authorizeUpgrade(address) internal view override {
    _requireAdmin();
  }

  // ─── Emergency controls ───────────────────────────────────────────────

  function pause() external {
    _requireAdmin();
    _pause();
  }

  function unpause() external {
    _requireAdmin();
    _unpause();
  }

  function setNegRiskAdapter(address _adapter) external {
    _requireAdmin();
    address old = negRiskAdapter;
    negRiskAdapter = _adapter;
    emit NegRiskAdapterUpdated(old, _adapter);
  }

  function setCallbackGasLimit(uint256 _limit) external {
    _requireAdmin();
    if (_limit < 50_000) revert LimitTooLow();
    emit CallbackGasLimitUpdated(callbackGasLimit, _limit);
    callbackGasLimit = _limit;
  }

  function setMinOrderAmount(uint256 _amount) external {
    _requireAdmin();
    uint256 old = minOrderAmount;
    minOrderAmount = _amount;
    emit MinOrderAmountUpdated(old, _amount);
  }

  // ─── Order management ────────────────────────────────────────────────

  function cancelOrders(Order[] calldata orders) external {
    for (uint256 i = 0; i < orders.length;) {
      Order calldata order = orders[i];
      if (order.trader != msg.sender) revert NotTrader();
      bytes32 orderHash = hashOrder(order);
      if (orderInvalidated[orderHash]) revert AlreadyCancelled();
      orderInvalidated[orderHash] = true;
      emit OrderCancelled(orderHash, msg.sender);
      unchecked { ++i; }
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
    _requireOperator();
    if (maker.marketId != taker.marketId) revert MarketMismatch();

    IFeeModule _feeModule = IFeeModule(feeModule);

    FeeConfig memory feeConfig;
    if (maker.side != taker.side) {
      (feeConfig.makerFeeBps, feeConfig.takerFeeBps) =
        _feeModule.getFeesAtPrice(maker.marketId, maker.price);
    } else {
      (feeConfig.makerFeeBps, ) = _feeModule.getFeesAtPrice(maker.marketId, maker.price);
      (, feeConfig.takerFeeBps) = _feeModule.getFeesAtPrice(maker.marketId, ONE - maker.price);
    }

    (uint256 makerFee, uint256 takerFee) = _matchOrders(maker, makerSig, taker, takerSig, fillAmount, feeConfig);

    uint256 totalFees = makerFee + takerFee;
    if (totalFees > 0) {
      (IERC20 tradeToken, , , ) = _marketCollaterals(maker.marketId);
      _feeModule.accrueFees(address(tradeToken), totalFees);
    }
  }

  /// @notice Match one taker against multiple makers in a single transaction.
  ///         Each maker can have a different price (and therefore different fees).
  ///         The taker is validated once; its filledAmounts is incremented by the
  ///         sum of all individual fills. One OrdersMatched event per maker fill.
  /// @dev    Unlike matchOrdersWithFees where taker.minFillAmount constrains each
  ///         individual fill, here it constrains the aggregate across all makers.
  ///         Individual fills may be below minFillAmount if their sum satisfies it.
  function matchMultipleOrdersWithFees(
    Order[] calldata makers,
    bytes[] calldata makerSigs,
    uint256[] calldata fillAmounts,
    Order calldata taker,
    bytes calldata takerSig
  ) external whenNotPaused nonReentrant {
    _requireOperator();
    uint256 n = makers.length;
    if (n == 0) revert NoMakers();
    if (makerSigs.length != n) revert SigCount();
    if (fillAmounts.length != n) revert FillCount();

    _validateOrder(taker, takerSig);
    bytes32 takerHash = hashOrder(taker);

    IFeeModule _feeModule = IFeeModule(feeModule);
    uint256 totalTakerFill;
    uint256 totalFees;
    uint256 takerFilledBefore = filledAmounts[takerHash];

    for (uint256 i = 0; i < n;) {
      if (makers[i].marketId != taker.marketId) revert MarketMismatch();

      FeeConfig memory feeConfig;
      if (makers[i].side != taker.side) {
        (feeConfig.makerFeeBps, feeConfig.takerFeeBps) =
          _feeModule.getFeesAtPrice(makers[i].marketId, makers[i].price);
      } else {
        (feeConfig.makerFeeBps, ) = _feeModule.getFeesAtPrice(makers[i].marketId, makers[i].price);
        (, feeConfig.takerFeeBps) = _feeModule.getFeesAtPrice(makers[i].marketId, ONE - makers[i].price);
      }

      totalTakerFill += fillAmounts[i];

      (uint256 makerFee, uint256 takerFee) = _matchOrdersSingleValidation(
        makers[i], makerSigs[i], taker, takerHash, takerFilledBefore + totalTakerFill, fillAmounts[i], feeConfig
      );

      totalFees += makerFee + takerFee;
      unchecked { ++i; }
    }

    uint256 takerFilledAfter = takerFilledBefore + totalTakerFill;
    if (takerFilledAfter > taker.amount) revert TakerOverfill();
    if (taker.minFillAmount != 0 && totalTakerFill < taker.minFillAmount) revert BelowTakerMinFill();
    filledAmounts[takerHash] = takerFilledAfter;

    if (minOrderAmount > 0) {
      uint256 takerRemaining = taker.amount - takerFilledAfter;
      if (takerRemaining != 0 && takerRemaining < minOrderAmount) revert TakerDustRemainder();
    }

    if (totalFees > 0) {
      (IERC20 tradeToken, , , ) = _marketCollaterals(taker.marketId);
      _feeModule.accrueFees(address(tradeToken), totalFees);
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
    _requireOperator();

    address _adapter = negRiskAdapter;
    if (_adapter == address(0)) revert NoAdapter();
    if (orders.length < 2) revert NeedAtLeastTwoOrders();
    if (signatures.length != orders.length) revert SigCount();
    if (fillAmount == 0) revert ZeroFill();

    IMyriadMarketManager _manager = manager;
    ConditionalTokens _ct = conditionalTokens;
    IFeeModule _feeModule = IFeeModule(feeModule);

    // Derive eventId from the first order, then verify ALL orders belong to it.
    bytes32 eventId = _manager.getEventId(orders[0].marketId);
    if (eventId == bytes32(0)) revert NotNegRisk();

    {
      uint256 expectedCount = INegRiskAdapter(_adapter).getEventOutcomeCount(eventId);
      if (orders.length != expectedCount) revert MustMatchAllOutcomes();
    }

    uint256 priceSum;
    bytes32[] memory orderHashes = new bytes32[](orders.length);
    uint256[] memory currentFilled = new uint256[](orders.length);

    for (uint256 i = 0; i < orders.length;) {
      Order calldata order = orders[i];
      if (order.side != Side.Buy) revert NotBuy();
      if (order.outcomeId != Outcomes.YES) revert NotYes();
      if (order.price == 0 || order.price > ONE) revert BadPrice();
      if (_manager.getEventId(order.marketId) != eventId) revert EventMismatch();
      if (!_manager.isNegRisk(order.marketId)) revert NotNegRisk();

      _requireMarketOpen(order.marketId);
      _validateOrder(order, signatures[i]);

      bytes32 h = hashOrder(order);
      orderHashes[i] = h;
      currentFilled[i] = filledAmounts[h];
      if (currentFilled[i] + fillAmount > order.amount) revert Overfill();
      if (order.minFillAmount != 0 && fillAmount < order.minFillAmount) revert BelowMinFill();

      for (uint256 j = 0; j < i;) {
        if (order.marketId == orders[j].marketId) revert DuplicateMarket();
        unchecked { ++j; }
      }

      priceSum += order.price;
      unchecked { ++i; }
    }

    if (priceSum < ONE) revert PriceSumBelowOne();

    // Collect tradeToken from each buyer: notional + fee.
    // Convention: last order = taker, all others = makers.
    (IERC20 collateral, , , ) = _marketCollaterals(orders[0].marketId);
    uint256 totalFees;
    uint256 takerIdx = orders.length - 1;

    uint256 totalNotional;
    for (uint256 i = 0; i < orders.length;) {
      uint256 notional = (fillAmount * orders[i].price) / ONE;
      if (i == takerIdx && totalNotional + notional < fillAmount) {
        notional = fillAmount - totalNotional;
      }
      if (notional == 0) revert ZeroNotional();
      totalNotional += notional;

      uint256 fee;
      if (i == takerIdx) {
        (, uint16 takerBps) = _feeModule.getFeesAtPrice(orders[i].marketId, orders[i].price);
        fee = (notional * takerBps) / BPS;
      } else {
        (uint16 makerBps, ) = _feeModule.getFeesAtPrice(orders[i].marketId, orders[i].price);
        fee = (notional * makerBps) / BPS;
      }
      totalFees += fee;

      uint256 required = notional + fee;
      _checkCollateralBalance(orders[i].trader, collateral, required);
      collateral.safeTransferFrom(orders[i].trader, address(this), required);
      unchecked { ++i; }
    }

    // Mint full fillAmount shares
    collateral.forceApprove(_adapter, fillAmount);
    INegRiskAdapter(_adapter).mintAllYesTokens(eventId, fillAmount, address(this));

    // Distribute YES tokens (fillAmount per outcome) to each buyer
    for (uint256 i = 0; i < orders.length;) {
      uint256 tokenId = _ct.getTokenId(orders[i].marketId, Outcomes.YES);
      _safeTransferWithGasCap(address(this), orders[i].trader, tokenId, fillAmount);

      uint256 newFill = currentFilled[i] + fillAmount;
      filledAmounts[orderHashes[i]] = newFill;

      if (minOrderAmount > 0) {
        uint256 remaining = orders[i].amount - newFill;
        if (remaining != 0 && remaining < minOrderAmount) revert DustRemainder();
      }

      emit CrossMarketOrderFilled(orderHashes[i], eventId, orders[i].marketId, fillAmount, newFill);
      unchecked { ++i; }
    }

    // Send surplus (priceSum > ONE overage) + fees to feeModule
    uint256 surplus = totalNotional - fillAmount;
    uint256 toFeeModule = totalFees + surplus;
    if (toFeeModule > 0) {
      collateral.safeTransfer(address(_feeModule), toFeeModule);
      _feeModule.accrueFees(address(collateral), toFeeModule);
    }
    if (surplus > 0) {
      emit SurplusCollected(eventId, surplus);
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
    _validateOrder(taker, takerSig);

    bytes32 takerHash = hashOrder(taker);
    uint256 takerFilled = filledAmounts[takerHash];
    if (takerFilled + fillAmount > taker.amount) revert TakerOverfill();
    if (taker.minFillAmount != 0 && fillAmount < taker.minFillAmount) revert BelowTakerMinFill();

    takerFilled += fillAmount;
    filledAmounts[takerHash] = takerFilled;

    if (minOrderAmount > 0) {
      uint256 takerRemaining = taker.amount - takerFilled;
      if (takerRemaining != 0 && takerRemaining < minOrderAmount) revert TakerDustRemainder();
    }

    (makerFee, takerFee) = _matchOrdersSingleValidation(
      maker, makerSig, taker, takerHash, takerFilled, fillAmount, feeConfig
    );
  }

  /// @dev Like _matchOrders but the taker is pre-validated and its filledAmounts
  ///      is managed by the caller. Used by matchMultipleOrdersWithFees.
  /// @param takerCumulativeFill The taker's cumulative fill INCLUDING this fill,
  ///        used for the OrdersMatched event's takerAmountFilled field.
  function _matchOrdersSingleValidation(
    Order calldata maker,
    bytes calldata makerSig,
    Order calldata taker,
    bytes32 takerHash,
    uint256 takerCumulativeFill,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 makerFee, uint256 takerFee) {
    _validateFeeConfig(feeConfig);
    _validateOrder(maker, makerSig);

    if (maker.trader == taker.trader) revert SelfTrade();
    if (maker.price == 0 || taker.price == 0) revert BadPrice();
    if (maker.price > ONE || taker.price > ONE) revert PriceAboveOne();
    if (fillAmount == 0) revert ZeroFill();

    bytes32 makerHash = hashOrder(maker);

    uint256 makerFilled = filledAmounts[makerHash];
    if (makerFilled + fillAmount > maker.amount) revert MakerOverfill();
    if (maker.minFillAmount != 0 && fillAmount < maker.minFillAmount) revert BelowMakerMinFill();

    uint8 matchType;
    if (maker.side != taker.side) {
      matchType = 0;
      uint256 notional = (fillAmount * maker.price) / ONE;
      (IERC20 col, , , ) = _marketCollaterals(maker.marketId);
      bool makerIsBuyer = maker.side == Side.Buy;
      address buyer = makerIsBuyer ? maker.trader : taker.trader;
      address seller = makerIsBuyer ? taker.trader : maker.trader;
      uint256 buyerFeeBps = makerIsBuyer ? feeConfig.makerFeeBps : feeConfig.takerFeeBps;
      _checkCollateralBalance(buyer, col, notional + (notional * buyerFeeBps) / BPS);
      _checkTokenBalance(seller, conditionalTokens.getTokenId(maker.marketId, maker.outcomeId), fillAmount);
    } else if (maker.side == Side.Buy) {
      matchType = 1;
      uint256 makerNotional = (fillAmount * maker.price) / ONE;
      uint256 takerNotional = fillAmount - makerNotional;
      (IERC20 col, , , ) = _marketCollaterals(maker.marketId);
      _checkCollateralBalance(maker.trader, col, makerNotional + (makerNotional * feeConfig.makerFeeBps) / BPS);
      _checkCollateralBalance(taker.trader, col, takerNotional + (takerNotional * feeConfig.takerFeeBps) / BPS);
    } else {
      matchType = 2;
      ConditionalTokens _ct = conditionalTokens;
      _checkTokenBalance(maker.trader, _ct.getTokenId(maker.marketId, maker.outcomeId), fillAmount);
      _checkTokenBalance(taker.trader, _ct.getTokenId(taker.marketId, taker.outcomeId), fillAmount);
    }

    makerFilled += fillAmount;
    filledAmounts[makerHash] = makerFilled;

    if (minOrderAmount > 0) {
      uint256 makerRemaining = maker.amount - makerFilled;
      if (makerRemaining != 0 && makerRemaining < minOrderAmount) revert MakerDustRemainder();
    }

    if (matchType == 0) {
      (makerFee, takerFee) = _settleDirectMatch(maker, taker, fillAmount, feeConfig);
    } else if (matchType == 1) {
      (makerFee, takerFee) = _settleMintMatch(maker, taker, fillAmount, feeConfig);
    } else {
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
      makerFilled,
      takerCumulativeFill,
      makerFee,
      takerFee
    );
  }

  function _validateOrder(Order calldata order, bytes calldata signature) internal view {
    if (order.trader == address(0)) revert ZeroTrader();
    if (order.amount == 0) revert ZeroAmount();
    if (minOrderAmount != 0 && order.amount < minOrderAmount) revert BelowMinAmount();
    if (order.expiration != 0 && order.expiration <= block.timestamp) revert OrderExpired();
    if (order.outcomeId >= 2) revert BadOutcome();

    bytes32 orderHash = hashOrder(order);
    if (orderInvalidated[orderHash]) revert OrderInvalidated();

    if (!SignatureChecker.isValidSignatureNow(order.trader, orderHash, signature)) revert InvalidSignature();
  }

  function _validateFeeConfig(FeeConfig memory feeConfig) internal pure {
    if (feeConfig.makerFeeBps > BPS) revert MakerFeeExceeds();
    if (feeConfig.takerFeeBps > BPS) revert TakerFeeExceeds();
  }

  /// @dev Gas-capped ERC-1155 transfer to an arbitrary trader.
  ///      Caps total gas for the safeTransferFrom call so that the recipient's
  ///      onERC1155Received callback cannot consume unbounded gas (EIP-7702 griefing).
  function _safeTransferWithGasCap(
    address from,
    address to,
    uint256 id,
    uint256 amount
  ) internal {
    (bool success, bytes memory returndata) = address(conditionalTokens).call{gas: callbackGasLimit}(
      abi.encodeCall(conditionalTokens.safeTransferFrom, (from, to, id, amount, ""))
    );
    if (!success) {
      if (returndata.length > 0) {
        assembly ("memory-safe") { revert(add(returndata, 32), mload(returndata)) }
      }
      revert TransferFailed();
    }
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
    if (maker.outcomeId != taker.outcomeId) revert OutcomeMismatch();

    if (maker.side == Side.Buy) {
      if (taker.side != Side.Sell) revert SideMismatch();
      if (maker.price < taker.price) revert PriceMismatch();
    } else {
      if (taker.side != Side.Buy) revert SideMismatch();
      if (maker.price > taker.price) revert PriceMismatch();
    }

    _requireMarketOpen(maker.marketId);

    uint256 notional = (fillAmount * maker.price) / ONE;
    if (notional == 0) revert ZeroNotional();

    (IERC20 collateral, , , ) = _marketCollaterals(maker.marketId);

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
    ConditionalTokens _ct = conditionalTokens;
    _safeTransferWithGasCap(
      seller,
      buyer,
      _ct.getTokenId(maker.marketId, maker.outcomeId),
      fillAmount
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
    if (maker.side != Side.Buy || taker.side != Side.Buy) revert SideMismatch();
    if (maker.outcomeId == taker.outcomeId) revert SameOutcome();
    _requireMarketOpen(maker.marketId);

    (Order calldata outcome0Order, Order calldata outcome1Order) = maker.outcomeId == Outcomes.YES ? (maker, taker) : (taker, maker);
    if (outcome0Order.price + outcome1Order.price < ONE) revert PriceSumBelowOne();

    (IERC20 tradeToken, IERC20 ctToken, bool isNegRiskFlow, address _adapter) = _marketCollaterals(maker.marketId);

    uint256 makerNotional = (fillAmount * maker.price) / ONE;
    uint256 takerNotional = fillAmount - makerNotional;
    if (makerNotional == 0 || takerNotional == 0) revert ZeroNotional();

    makerFee = (makerNotional * feeConfig.makerFeeBps) / BPS;
    takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    uint256 totalProtocolFees = makerFee + takerFee;

    // Each buyer pays notional + fee
    tradeToken.safeTransferFrom(maker.trader, address(this), makerNotional + makerFee);
    tradeToken.safeTransferFrom(taker.trader, address(this), takerNotional + takerFee);

    ConditionalTokens _ct = conditionalTokens;
    if (isNegRiskFlow) {
      tradeToken.forceApprove(_adapter, fillAmount);
      INegRiskAdapter(_adapter).wrapForExchange(fillAmount);
    }
    ctToken.forceApprove(address(_ct), fillAmount);
    _ct.splitPosition(maker.marketId, fillAmount);

    // Each buyer receives fillAmount shares of their outcome token
    _safeTransferWithGasCap(
      address(this), outcome0Order.trader,
      _ct.getTokenId(maker.marketId, Outcomes.YES), fillAmount
    );
    _safeTransferWithGasCap(
      address(this), outcome1Order.trader,
      _ct.getTokenId(maker.marketId, Outcomes.NO), fillAmount
    );

    // Fees to FeeModule
    if (totalProtocolFees > 0) {
      tradeToken.safeTransfer(feeModule, totalProtocolFees);
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
    if (maker.side != Side.Sell || taker.side != Side.Sell) revert SideMismatch();
    if (maker.outcomeId == taker.outcomeId) revert SameOutcome();
    _requireMarketOpen(maker.marketId);

    (Order calldata outcome0Order, Order calldata outcome1Order) = maker.outcomeId == Outcomes.YES ? (maker, taker) : (taker, maker);
    if (outcome0Order.price + outcome1Order.price > ONE) revert PriceSumAboveOne();

    ConditionalTokens _ct = conditionalTokens;
    uint256 outcome0TokenId = _ct.getTokenId(maker.marketId, Outcomes.YES);
    uint256 outcome1TokenId = _ct.getTokenId(maker.marketId, Outcomes.NO);

    // Transfer outcome tokens to exchange before merging
    _ct.safeTransferFrom(outcome0Order.trader, address(this), outcome0TokenId, fillAmount, "");
    _ct.safeTransferFrom(outcome1Order.trader, address(this), outcome1TokenId, fillAmount, "");

    // Merge: burns both outcome tokens, releases ctToken to this contract
    _ct.mergePositions(maker.marketId, fillAmount);

    (IERC20 tradeToken, IERC20 ctToken, bool isNegRiskFlow, ) = _marketCollaterals(maker.marketId);
    if (isNegRiskFlow) {
      IWrappedCollateral(address(ctToken)).unwrap(fillAmount);
    }

    uint256 makerNotional = (fillAmount * maker.price) / ONE;
    uint256 takerNotional = fillAmount - makerNotional;
    uint256 outcome0Notional = maker.outcomeId == Outcomes.YES ? makerNotional : takerNotional;
    uint256 outcome1Notional = maker.outcomeId == Outcomes.YES ? takerNotional : makerNotional;
    if (outcome0Notional == 0 || outcome1Notional == 0) revert ZeroNotional();

    (makerFee, takerFee) = _paySellerWithFees(
      maker,
      feeConfig,
      tradeToken,
      outcome0Order,
      outcome1Order,
      outcome0Notional,
      outcome1Notional
    );
  }

  /// @dev Fee deduction for merge matches — each seller's fee is deducted from their proceeds.
  function _paySellerWithFees(
    Order calldata maker,
    FeeConfig memory feeConfig,
    IERC20 collateral,
    Order calldata outcome0Order,
    Order calldata outcome1Order,
    uint256 outcome0Notional,
    uint256 outcome1Notional
  ) internal returns (uint256 makerFee, uint256 takerFee) {
    bool makerIsOutcome0 = maker.outcomeId == Outcomes.YES;

    uint256 makerNotional = makerIsOutcome0 ? outcome0Notional : outcome1Notional;
    uint256 takerNotional = makerIsOutcome0 ? outcome1Notional : outcome0Notional;

    makerFee = (makerNotional * feeConfig.makerFeeBps) / BPS;
    takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    uint256 totalProtocolFees = makerFee + takerFee;

    uint256 makerProceeds = makerNotional;
    uint256 takerProceeds = takerNotional;

    if (makerProceeds < makerFee) revert MakerFeesExceedProceeds();
    makerProceeds -= makerFee;

    if (takerProceeds < takerFee) revert TakerFeesExceedProceeds();
    takerProceeds -= takerFee;

    collateral.safeTransfer(outcome0Order.trader, makerIsOutcome0 ? makerProceeds : takerProceeds);
    collateral.safeTransfer(outcome1Order.trader, makerIsOutcome0 ? takerProceeds : makerProceeds);

    if (totalProtocolFees > 0) {
      collateral.safeTransfer(feeModule, totalProtocolFees);
    }
  }

  /// @dev Early balance + allowance check so a front-runner who moves funds
  ///      causes a cheap revert before expensive SSTORE / settlement work.
  function _checkCollateralBalance(
    address trader,
    IERC20 collateral,
    uint256 required
  ) internal view {
    if (collateral.balanceOf(trader) < required) revert InsufficientCollateral();
    if (collateral.allowance(trader, address(this)) < required) revert InsufficientAllowance();
  }

  /// @dev Returns the token traders pay in (tradeToken) and the token CT pulls
  ///      on split/merge (ctToken). They differ on neg risk markets: traders
  ///      hold underlying, CT holds wcol; the exchange bridges via the adapter.
  function _marketCollaterals(uint256 marketId)
    internal
    view
    returns (IERC20 tradeToken, IERC20 ctToken, bool isNegRiskFlow, address adapter)
  {
    ctToken = manager.getMarketCollateral(marketId);
    adapter = negRiskAdapter;
    isNegRiskFlow = adapter != address(0) && manager.isNegRisk(marketId);
    tradeToken = isNegRiskFlow ? INegRiskAdapter(adapter).underlying() : ctToken;
  }

  function _checkTokenBalance(
    address trader,
    uint256 tokenId,
    uint256 required
  ) internal view {
    if (conditionalTokens.balanceOf(trader, tokenId) < required) revert InsufficientTokens();
    if (!conditionalTokens.isApprovedForAll(trader, address(this))) revert TokensNotApproved();
  }

  function _requireAdmin() internal view {
    if (!registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender)) revert NotAdmin();
  }

  function _requireOperator() internal view {
    if (!registry.hasRole(registry.OPERATOR_ROLE(), msg.sender)) revert NotOperator();
  }

  function _requireMarketOpen(uint256 marketId) internal view {
    if (!manager.isMarketTradeable(marketId)) revert MarketNotTradeable();
  }
}
