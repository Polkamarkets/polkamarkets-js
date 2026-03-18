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

/// @dev Minimal interface for the NegRiskAdapter, used by cross-market matching.
interface INegRiskAdapter {
  function mintAllYesTokens(bytes32 eventId, uint256 amount, address recipient) external;
  function getEventOutcomeCount(bytes32 eventId) external view returns (uint256);
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
    address old = negRiskAdapter;
    negRiskAdapter = _adapter;
    emit NegRiskAdapterUpdated(old, _adapter);
  }

  function setCallbackGasLimit(uint256 _limit) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    require(_limit >= 50_000, "limit too low");
    emit CallbackGasLimitUpdated(callbackGasLimit, _limit);
    callbackGasLimit = _limit;
  }

  function setMinOrderAmount(uint256 _amount) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    uint256 old = minOrderAmount;
    minOrderAmount = _amount;
    emit MinOrderAmountUpdated(old, _amount);
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

    IFeeModule _feeModule = IFeeModule(feeModule);

    FeeConfig memory feeConfig;
    if (maker.side != taker.side) {
      (feeConfig.makerFeeBps, feeConfig.takerFeeBps) =
        _feeModule.getFeesAtPrice(maker.marketId, maker.price);
    } else {
      (feeConfig.makerFeeBps, ) = _feeModule.getFeesAtPrice(maker.marketId, maker.price);
      (, feeConfig.takerFeeBps) = _feeModule.getFeesAtPrice(maker.marketId, taker.price);
    }

    (uint256 makerFee, uint256 takerFee) = _matchOrders(maker, makerSig, taker, takerSig, fillAmount, feeConfig);

    uint256 totalFees = makerFee + takerFee;
    if (totalFees > 0) {
      address token = address(manager.getMarketCollateral(maker.marketId));
      _feeModule.accrueFees(token, totalFees);
    }
  }

  /// @notice Match one taker against multiple makers in a single transaction.
  ///         Each maker can have a different price (and therefore different fees).
  ///         The taker is validated once; its filledAmounts is incremented by the
  ///         sum of all individual fills. One OrdersMatched event per maker fill.
  /// @dev    Unlike matchOrdersWithFees where taker.minFillAmount constrains each
  ///         individual fill, here it constrains the aggregate across all makers.
  ///         Individual fills may be below minFillAmount if their sum satisfies it.
  ///         Uses a two-pass approach: all makers are validated and balance-checked
  ///         before any settlement, so a single unfunded maker causes a cheap revert
  ///         without wasting gas on prior settlements.
  function matchMultipleOrdersWithFees(
    Order[] calldata makers,
    bytes[] calldata makerSigs,
    uint256[] calldata fillAmounts,
    Order calldata taker,
    bytes calldata takerSig
  ) external whenNotPaused nonReentrant {
    require(registry.hasRole(registry.OPERATOR_ROLE(), msg.sender), "not operator");
    uint256 n = makers.length;
    require(n > 0, "no makers");
    require(makerSigs.length == n, "sig count");
    require(fillAmounts.length == n, "fill count");

    _validateOrder(taker, takerSig);
    bytes32 takerHash = hashOrder(taker);

    IFeeModule _feeModule = IFeeModule(feeModule);

    bytes32[] memory makerHashes = new bytes32[](n);
    uint8[] memory matchTypes = new uint8[](n);
    FeeConfig[] memory feeConfigs = new FeeConfig[](n);
    uint256 totalTakerFill;

    for (uint256 i = 0; i < n; i++) {
      require(makers[i].marketId == taker.marketId, "market mismatch");

      if (makers[i].side != taker.side) {
        (feeConfigs[i].makerFeeBps, feeConfigs[i].takerFeeBps) =
          _feeModule.getFeesAtPrice(makers[i].marketId, makers[i].price);
      } else {
        (feeConfigs[i].makerFeeBps, ) = _feeModule.getFeesAtPrice(makers[i].marketId, makers[i].price);
        (, feeConfigs[i].takerFeeBps) = _feeModule.getFeesAtPrice(makers[i].marketId, taker.price);
      }

      totalTakerFill += fillAmounts[i];

      (makerHashes[i], matchTypes[i]) = _validateMatch(
        makers[i], makerSigs[i], taker, fillAmounts[i], feeConfigs[i]
      );
    }

    uint256 takerFilledBefore = filledAmounts[takerHash];
    uint256 takerFilledAfter = takerFilledBefore + totalTakerFill;
    require(takerFilledAfter <= taker.amount, "taker overfill");
    require(taker.minFillAmount == 0 || totalTakerFill >= taker.minFillAmount, "below taker min fill");
    filledAmounts[takerHash] = takerFilledAfter;

    if (minOrderAmount > 0) {
      uint256 takerRemaining = taker.amount - takerFilledAfter;
      require(takerRemaining == 0 || takerRemaining >= minOrderAmount, "taker dust remainder");
    }

    uint256 totalFees;
    uint256 cumulativeFill;
    for (uint256 i = 0; i < n; i++) {
      cumulativeFill += fillAmounts[i];

      (uint256 makerFee, uint256 takerFee) = _settleMatch(
        makers[i], taker, makerHashes[i], takerHash, matchTypes[i],
        takerFilledBefore + cumulativeFill, fillAmounts[i], feeConfigs[i]
      );

      totalFees += makerFee + takerFee;
    }

    if (totalFees > 0) {
      address token = address(manager.getMarketCollateral(taker.marketId));
      _feeModule.accrueFees(token, totalFees);
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

    address _adapter = negRiskAdapter;
    require(_adapter != address(0), "no adapter");
    require(orders.length >= 2, "need >= 2 orders");
    require(signatures.length == orders.length, "sig count");
    require(fillAmount > 0, "fill 0");

    IMyriadMarketManager _manager = manager;
    ConditionalTokens _ct = conditionalTokens;
    IFeeModule _feeModule = IFeeModule(feeModule);

    // Derive eventId from the first order, then verify ALL orders belong to it.
    bytes32 eventId = _manager.getEventId(orders[0].marketId);
    require(eventId != bytes32(0), "not neg risk");

    {
      uint256 expectedCount = INegRiskAdapter(_adapter).getEventOutcomeCount(eventId);
      require(orders.length == expectedCount, "must match all outcomes");
    }

    uint256 priceSum;
    bytes32[] memory orderHashes = new bytes32[](orders.length);
    uint256[] memory currentFilled = new uint256[](orders.length);

    for (uint256 i = 0; i < orders.length; i++) {
      Order calldata order = orders[i];
      require(order.side == Side.Buy, "not buy");
      require(order.outcomeId == Outcomes.YES, "not YES");
      require(order.price > 0 && order.price <= ONE, "bad price");
      require(_manager.getEventId(order.marketId) == eventId, "event mismatch");
      require(_manager.isNegRisk(order.marketId), "not neg risk");

      _requireMarketOpen(order.marketId);
      _validateOrder(order, signatures[i]);

      bytes32 h = hashOrder(order);
      orderHashes[i] = h;
      currentFilled[i] = filledAmounts[h];
      require(currentFilled[i] + fillAmount <= order.amount, "overfill");
      require(order.minFillAmount == 0 || fillAmount >= order.minFillAmount, "below min fill");

      for (uint256 j = 0; j < i; j++) {
        require(order.marketId != orders[j].marketId, "dup market");
      }

      priceSum += order.price;
    }

    require(priceSum >= ONE, "price sum < 1");

    // Collect wcol from each buyer: notional + fee.
    // Convention: last order = taker, all others = makers.
    IERC20 collateral = _manager.getMarketCollateral(orders[0].marketId);
    uint256 totalFees;
    uint256 takerIdx = orders.length - 1;

    uint256[] memory required = new uint256[](orders.length);
    uint256 totalNotional;
    for (uint256 i = 0; i < orders.length; i++) {
      uint256 notional = (fillAmount * orders[i].price) / ONE;
      if (i == takerIdx && totalNotional + notional < fillAmount) {
        notional = fillAmount - totalNotional;
      }
      require(notional > 0, "notional 0");
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

      required[i] = notional + fee;
      _checkCollateralBalance(orders[i].trader, collateral, required[i]);
    }

    for (uint256 i = 0; i < orders.length; i++) {
      collateral.safeTransferFrom(orders[i].trader, address(this), required[i]);
    }

    // Mint full fillAmount shares
    collateral.forceApprove(_adapter, fillAmount);
    INegRiskAdapter(_adapter).mintAllYesTokens(eventId, fillAmount, address(this));

    // Distribute YES tokens (fillAmount per outcome) to each buyer
    for (uint256 i = 0; i < orders.length; i++) {
      uint256 tokenId = _ct.getTokenId(orders[i].marketId, Outcomes.YES);
      _safeTransferWithGasCap(address(this), orders[i].trader, tokenId, fillAmount);

      uint256 newFill = currentFilled[i] + fillAmount;
      filledAmounts[orderHashes[i]] = newFill;

      if (minOrderAmount > 0) {
        uint256 remaining = orders[i].amount - newFill;
        require(remaining == 0 || remaining >= minOrderAmount, "dust remainder");
      }

      emit CrossMarketOrderFilled(orderHashes[i], eventId, orders[i].marketId, fillAmount, newFill);
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
    require(takerFilled + fillAmount <= taker.amount, "taker overfill");
    require(taker.minFillAmount == 0 || fillAmount >= taker.minFillAmount, "below taker min fill");

    (bytes32 makerHash, uint8 matchType) = _validateMatch(maker, makerSig, taker, fillAmount, feeConfig);

    takerFilled += fillAmount;
    filledAmounts[takerHash] = takerFilled;

    if (minOrderAmount > 0) {
      uint256 takerRemaining = taker.amount - takerFilled;
      require(takerRemaining == 0 || takerRemaining >= minOrderAmount, "taker dust remainder");
    }

    (makerFee, takerFee) = _settleMatch(maker, taker, makerHash, takerHash, matchType, takerFilled, fillAmount, feeConfig);
  }

  /// @dev Validates a maker against a taker: checks signatures, prices, fills,
  ///      and balances. No state modifications. Used as the first pass in
  ///      matchMultipleOrdersWithFees to catch invalid/unfunded makers before
  ///      any expensive settlement work.
  function _validateMatch(
    Order calldata maker,
    bytes calldata makerSig,
    Order calldata taker,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal view returns (bytes32 makerHash, uint8 matchType) {
    _validateFeeConfig(feeConfig);
    _validateOrder(maker, makerSig);

    require(maker.trader != taker.trader, "self trade");
    require(maker.price > 0 && taker.price > 0, "bad price");
    require(maker.price <= ONE && taker.price <= ONE, "price > 1");
    require(fillAmount > 0, "fill 0");

    makerHash = hashOrder(maker);

    uint256 makerFilled = filledAmounts[makerHash];
    require(makerFilled + fillAmount <= maker.amount, "maker overfill");
    require(maker.minFillAmount == 0 || fillAmount >= maker.minFillAmount, "below maker min fill");

    if (maker.side != taker.side) {
      matchType = 0;
      uint256 notional = (fillAmount * maker.price) / ONE;
      IERC20 col = manager.getMarketCollateral(maker.marketId);
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
      IERC20 col = manager.getMarketCollateral(maker.marketId);
      _checkCollateralBalance(maker.trader, col, makerNotional + (makerNotional * feeConfig.makerFeeBps) / BPS);
      _checkCollateralBalance(taker.trader, col, takerNotional + (takerNotional * feeConfig.takerFeeBps) / BPS);
    } else {
      matchType = 2;
      ConditionalTokens _ct = conditionalTokens;
      _checkTokenBalance(maker.trader, _ct.getTokenId(maker.marketId, maker.outcomeId), fillAmount);
      _checkTokenBalance(taker.trader, _ct.getTokenId(taker.marketId, taker.outcomeId), fillAmount);
    }
  }

  /// @dev Executes settlement for a validated maker-taker pair. Writes filledAmounts,
  ///      dispatches the appropriate settlement type, and emits OrdersMatched.
  ///      Must be called after _validateMatch.
  function _settleMatch(
    Order calldata maker,
    Order calldata taker,
    bytes32 makerHash,
    bytes32 takerHash,
    uint8 matchType,
    uint256 takerCumulativeFill,
    uint256 fillAmount,
    FeeConfig memory feeConfig
  ) internal returns (uint256 makerFee, uint256 takerFee) {
    uint256 makerFilled = filledAmounts[makerHash] + fillAmount;
    filledAmounts[makerHash] = makerFilled;

    if (minOrderAmount > 0) {
      uint256 makerRemaining = maker.amount - makerFilled;
      require(makerRemaining == 0 || makerRemaining >= minOrderAmount, "maker dust remainder");
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
    require(order.trader != address(0), "trader 0");
    require(order.amount > 0, "amount 0");
    require(minOrderAmount == 0 || order.amount >= minOrderAmount, "below min amount");
    require(order.expiration == 0 || order.expiration > block.timestamp, "expired");
    require(order.outcomeId < 2, "bad outcome");

    bytes32 orderHash = hashOrder(order);
    require(!orderInvalidated[orderHash], "invalidated");

    require(
      SignatureChecker.isValidSignatureNow(order.trader, orderHash, signature),
      "invalid signature"
    );
  }

  function _validateFeeConfig(FeeConfig memory feeConfig) internal pure {
    require(feeConfig.makerFeeBps <= BPS, "maker fee");
    require(feeConfig.takerFeeBps <= BPS, "taker fee");
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
      revert("transfer failed");
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
    require(maker.side == Side.Buy && taker.side == Side.Buy, "side mismatch");
    require(maker.outcomeId != taker.outcomeId, "same outcome");
    _requireMarketOpen(maker.marketId);

    (Order calldata outcome0Order, Order calldata outcome1Order) = maker.outcomeId == Outcomes.YES ? (maker, taker) : (taker, maker);
    require(outcome0Order.price + outcome1Order.price == ONE, "price sum");

    IERC20 collateral = manager.getMarketCollateral(maker.marketId);

    uint256 makerNotional = (fillAmount * maker.price) / ONE;
    uint256 takerNotional = fillAmount - makerNotional;
    require(makerNotional > 0 && takerNotional > 0, "notional 0");

    makerFee = (makerNotional * feeConfig.makerFeeBps) / BPS;
    takerFee = (takerNotional * feeConfig.takerFeeBps) / BPS;
    uint256 totalProtocolFees = makerFee + takerFee;

    // Each buyer pays notional + fee
    collateral.safeTransferFrom(maker.trader, address(this), makerNotional + makerFee);
    collateral.safeTransferFrom(taker.trader, address(this), takerNotional + takerFee);

    ConditionalTokens _ct = conditionalTokens;
    collateral.forceApprove(address(_ct), fillAmount);
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

    (Order calldata outcome0Order, Order calldata outcome1Order) = maker.outcomeId == Outcomes.YES ? (maker, taker) : (taker, maker);
    require(outcome0Order.price + outcome1Order.price == ONE, "price sum");

    ConditionalTokens _ct = conditionalTokens;
    uint256 outcome0TokenId = _ct.getTokenId(maker.marketId, Outcomes.YES);
    uint256 outcome1TokenId = _ct.getTokenId(maker.marketId, Outcomes.NO);

    // Transfer outcome tokens to exchange before merging
    _ct.safeTransferFrom(outcome0Order.trader, address(this), outcome0TokenId, fillAmount, "");
    _ct.safeTransferFrom(outcome1Order.trader, address(this), outcome1TokenId, fillAmount, "");

    // Merge: burns both outcome tokens, releases collateral to this contract
    _ct.mergePositions(maker.marketId, fillAmount);

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

  /// @dev Early balance + allowance check so a front-runner who moves funds
  ///      causes a cheap revert before expensive SSTORE / settlement work.
  function _checkCollateralBalance(
    address trader,
    IERC20 collateral,
    uint256 required
  ) internal view {
    require(collateral.balanceOf(trader) >= required, "insufficient collateral");
    require(collateral.allowance(trader, address(this)) >= required, "insufficient allowance");
  }

  function _checkTokenBalance(
    address trader,
    uint256 tokenId,
    uint256 required
  ) internal view {
    require(conditionalTokens.balanceOf(trader, tokenId) >= required, "insufficient tokens");
    require(conditionalTokens.isApprovedForAll(trader, address(this)), "tokens not approved");
  }

  function _requireMarketOpen(uint256 marketId) internal view {
    require(manager.isMarketTradeable(marketId), "market not tradeable");
  }
}
