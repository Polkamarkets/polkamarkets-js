// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {AdminRegistry} from "./AdminRegistry.sol";

/// @notice Minimal interface for Myriad's conditional-token (ERC-1155) contract.
interface IConditionalTokens is IERC1155 {
    /// @dev Returns the ERC-1155 token id for a given (marketId, outcome).
    ///      Computed as (marketId << 1) | outcome and NOT validated upstream —
    ///      callers must range-check outcome themselves.
    function getTokenId(uint256 marketId, uint256 outcome) external view returns (uint256);

    /// @dev The market manager bound to this token contract (public immutable upstream).
    function manager() external view returns (address);
}

/// @notice Minimal interface for Myriad's market manager contract (resolution source).
interface IMarketManager {
    /// @dev True only while state == open && block.timestamp < closesAt && !paused;
    ///      false once resolved / voided / past close / paused. Reverts ("!m") for
    ///      market ids that don't exist.
    function isMarketTradeable(uint256 marketId) external view returns (bool);
}

/**
 * @title OTCExchange
 * @notice Two-sided peer-to-peer OTC desk for prediction-market conditional tokens (ERC-1155).
 *
 *         A maker posts an order and escrows their leg:
 *           - Sell (Ask): escrow conditional tokens, name a collateral price.
 *           - Buy  (Bid): escrow collateral, name the conditional tokens wanted.
 *         Any taker fills it in full in one atomic transaction — or, if the maker
 *         named an allowedTaker (a directed order), only that wallet can fill. The
 *         collateral leg pays an optional fee to the protocol and the remainder to
 *         whoever is selling. No intermediary holds custody beyond the open-order
 *         escrow, and there is no matching engine — a taker chooses an order and
 *         hits it.
 *
 *         Gas is paid by the maker on createOrder and by the taker on fillOrder.
 *
 * @dev    Orders are all-or-nothing. The fee rate is snapshotted into each order at
 *         creation, so changing the live rate never affects existing orders. Orders
 *         on markets that are not tradeable (resolved / voided / closed / paused)
 *         can neither be created nor filled. allowedTaker restricts who may fill,
 *         never what moves — escrow and settlement paths are identical for open
 *         and directed orders. The restriction is public on-chain (execution
 *         safety, not privacy).
 *
 *         Governance lives in the shared AdminRegistry (same instance as the CLOB
 *         stack): DEFAULT_ADMIN_ROLE gates allow-lists, minimum order size, and
 *         pause; FEE_ADMIN_ROLE gates fee rate, recipient, and withdrawals —
 *         mirroring MyriadCTFExchange / FeeModule. Admin hand-off is the registry's
 *         two-step proposeAdmin/acceptAdmin.
 *
 *         THIS CODE IS UNAUDITED. Have it independently audited before mainnet use.
 */
contract OTCExchange is ReentrancyGuardTransient, Pausable, ERC1155Holder {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000; // 100% = 10_000 bps
    uint256 public constant MAX_FEE_BPS = 1_000;      // hard cap: 10%

    /// @notice Sell = maker offers conditional tokens for collateral (an "Ask").
    ///         Buy  = maker offers collateral for conditional tokens (a "Bid").
    enum Side { Sell, Buy }
    enum OrderStatus { Open, Filled, Cancelled }

    struct Order {
        Side side;
        address maker;             // creator of the order
        address allowedTaker;      // 0 = anyone may fill; else the only wallet that can fill
        address conditionalToken;  // ERC-1155 contract traded
        uint256 marketId;          // Myriad market id
        uint256 outcome;           // outcome index within the market (0 = YES, 1 = NO)
        uint256 tokenId;           // derived ERC-1155 id == getTokenId(marketId, outcome)
        uint256 tokenAmount;       // amount of conditional tokens
        address collateralToken;   // ERC-20 collateral
        uint256 collateralAmount;  // total collateral
        uint256 feeBps;            // fee rate snapshotted at creation time
        uint64 expiry;             // unix timestamp; 0 = never expires
        OrderStatus status;
    }

    /// @notice Shared role registry (same instance as the CLOB stack).
    AdminRegistry public immutable registry;

    /// @dev conditional-token contract => allowed for trading
    mapping(address => bool) public allowedConditionalToken;
    /// @dev conditional-token contract => market manager used for resolution checks
    mapping(address => address) public marketManagerOf;
    /// @dev collateral ERC-20 => allowed as payment
    mapping(address => bool) public allowedCollateral;

    /// @notice Minimum order.tokenAmount; 0 = no minimum. Mirrors MyriadCTFExchange's
    ///         minOrderAmount (shares-denominated). No remainder rule is needed here —
    ///         OTC orders are all-or-nothing.
    uint256 public minOrderAmount;

    /// @dev current fee rate (bps) applied to NEW orders only
    uint256 public feeBps;
    /// @dev where withdrawn fees are sent
    address public feeRecipient;
    /// @dev collateral token => fees accrued and withdrawable
    mapping(address => uint256) public accruedFees;

    /// @dev incrementing id for the next order
    uint256 public nextOrderId;
    /// @dev orderId => Order
    mapping(uint256 => Order) public orders;

    // ------------------------------- Errors ------------------------------- //

    error NotAdmin();
    error NotFeeAdmin();
    error ZeroAddress();
    error FeeTooHigh();
    error ManagerMismatch();
    error ManagerNotSet();
    error ConditionalTokenNotAllowed();
    error CollateralNotAllowed();
    error InvalidOutcome();
    error ZeroAmount();
    error BelowMinAmount();
    error InvalidExpiry();
    error SelfTrade();
    error OrderNotFound();
    error OrderNotOpen();
    error NotMaker();
    error NotAllowedTaker();
    error OrderExpired();
    error MarketNotTradeable();
    error NotAuthorized();
    error CollateralShort();
    error InsufficientAccruedFees();

    // ------------------------------- Events ------------------------------- //

    event OrderCreated(
        uint256 indexed orderId,
        Side side,
        address indexed maker,
        address indexed conditionalToken,
        uint256 marketId,
        uint256 outcome,
        uint256 tokenId,
        uint256 tokenAmount,
        address collateralToken,
        uint256 collateralAmount,
        uint256 feeBps,
        uint64 expiry,
        address allowedTaker
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed maker,
        address indexed taker,
        Side side,
        address conditionalToken,
        uint256 marketId,
        uint256 outcome,
        uint256 tokenId,
        uint256 tokenAmount,
        address collateralToken,
        uint256 collateralAmount,
        uint256 feeAmount,
        uint256 collateralToSeller
    );
    event OrderCancelled(uint256 indexed orderId, address indexed maker);
    event AllowedTakerUpdated(uint256 indexed orderId, address indexed oldTaker, address indexed newTaker);

    event ConditionalTokenAllowed(address indexed conditionalToken, address indexed manager, bool allowed);
    event CollateralAllowed(address indexed collateralToken, bool allowed);
    event MinOrderAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeesWithdrawn(address indexed collateralToken, address indexed to, uint256 amount);

    /**
     * @param _registry        shared AdminRegistry (governance + two-step admin hand-off)
     * @param _feeRecipient    initial fee recipient
     * @param _feeBps          initial fee rate in basis points (0 allowed, <= MAX_FEE_BPS)
     * @param _conditionalToken initial allow-listed conditional-token (ERC-1155) contract
     * @param _manager         market manager bound to _conditionalToken; must equal
     *                         _conditionalToken.manager() — asserted on-chain
     * @param _collateral      initial allow-listed collateral ERC-20
     * @param _minOrderAmount  initial minimum order.tokenAmount (0 = no minimum)
     */
    constructor(
        AdminRegistry _registry,
        address _feeRecipient,
        uint256 _feeBps,
        address _conditionalToken,
        address _manager,
        address _collateral,
        uint256 _minOrderAmount
    ) {
        if (address(_registry) == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        registry = _registry;
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;

        _allowConditionalToken(_conditionalToken, _manager);
        _setCollateralAllowed(_collateral, true);

        minOrderAmount = _minOrderAmount;
        emit MinOrderAmountUpdated(0, _minOrderAmount);
    }

    // ------------------------------- Roles -------------------------------- //

    function _requireAdmin() internal view {
        if (!registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender)) revert NotAdmin();
    }

    function _requireFeeAdmin() internal view {
        if (!registry.hasRole(registry.FEE_ADMIN_ROLE(), msg.sender)) revert NotFeeAdmin();
    }

    // ------------------------------- Admin -------------------------------- //

    /// @notice Allow a conditional-token contract and bind its resolution manager.
    /// @dev    The manager must match the one the token itself is bound to
    ///         (ConditionalTokens exposes it as a public immutable).
    function allowConditionalToken(address conditionalToken, address manager) external {
        _requireAdmin();
        _allowConditionalToken(conditionalToken, manager);
    }

    function _allowConditionalToken(address conditionalToken, address manager) internal {
        if (conditionalToken == address(0)) revert ZeroAddress();
        if (manager == address(0)) revert ZeroAddress();
        if (IConditionalTokens(conditionalToken).manager() != manager) revert ManagerMismatch();
        allowedConditionalToken[conditionalToken] = true;
        marketManagerOf[conditionalToken] = manager;
        emit ConditionalTokenAllowed(conditionalToken, manager, true);
    }

    /// @notice Disallow a conditional-token contract for new orders. Existing escrow
    ///         is unaffected and resting orders remain fillable — pause() as well if
    ///         fills must stop.
    function disallowConditionalToken(address conditionalToken) external {
        _requireAdmin();
        allowedConditionalToken[conditionalToken] = false;
        emit ConditionalTokenAllowed(conditionalToken, marketManagerOf[conditionalToken], false);
    }

    /// @notice Allow or disallow a collateral ERC-20.
    function setCollateralAllowed(address collateralToken, bool allowed) external {
        _requireAdmin();
        _setCollateralAllowed(collateralToken, allowed);
    }

    function _setCollateralAllowed(address collateralToken, bool allowed) internal {
        if (collateralToken == address(0)) revert ZeroAddress();
        allowedCollateral[collateralToken] = allowed;
        emit CollateralAllowed(collateralToken, allowed);
    }

    /// @notice Update the minimum order size (in conditional-token amount).
    ///         Only affects orders created AFTER this call; 0 disables the minimum.
    function setMinOrderAmount(uint256 newAmount) external {
        _requireAdmin();
        emit MinOrderAmountUpdated(minOrderAmount, newAmount);
        minOrderAmount = newAmount;
    }

    /// @notice Update the fee rate. Only affects orders created AFTER this call.
    function setFeeBps(uint256 newFeeBps) external {
        _requireFeeAdmin();
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeBpsUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    /// @notice Update the fee recipient.
    function setFeeRecipient(address newRecipient) external {
        _requireFeeAdmin();
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Withdraw accrued fees for a collateral token to the fee recipient.
    function withdrawFees(address collateralToken, uint256 amount) external nonReentrant {
        _requireFeeAdmin();
        uint256 available = accruedFees[collateralToken];
        if (amount > available) revert InsufficientAccruedFees();
        accruedFees[collateralToken] = available - amount;
        IERC20(collateralToken).safeTransfer(feeRecipient, amount);
        emit FeesWithdrawn(collateralToken, feeRecipient, amount);
    }

    function pause() external { _requireAdmin(); _pause(); }
    function unpause() external { _requireAdmin(); _unpause(); }

    // ------------------------- Core: create / fill ------------------------ //

    /**
     * @notice Post an order and escrow the maker's leg.
     * @dev    A Sell maker must `setApprovalForAll(otc, true)` on the conditional
     *         token first; a Buy maker must `approve(otc, collateralAmount)` on the
     *         collateral token first. The market must be tradeable at creation time.
     * @param  allowedTaker 0 = open to anyone; non-zero reserves the order for that
     *         wallet (a directed order) in this same transaction.
     * @return orderId the id of the newly created order
     */
    function createOrder(
        Side side,
        address conditionalToken,
        uint256 marketId,
        uint256 outcome,
        uint256 tokenAmount,
        address collateralToken,
        uint256 collateralAmount,
        uint64 expiry,
        address allowedTaker
    ) external whenNotPaused nonReentrant returns (uint256 orderId) {
        if (!allowedConditionalToken[conditionalToken]) revert ConditionalTokenNotAllowed();
        if (!allowedCollateral[collateralToken]) revert CollateralNotAllowed();
        // Myriad CLOB markets are strictly binary (0 = YES, 1 = NO). getTokenId does
        // NOT validate outcome — an out-of-range value derives a tokenId belonging to
        // a DIFFERENT market, which would bypass the declared-market tradeability guard.
        if (outcome > 1) revert InvalidOutcome();
        if (tokenAmount == 0 || collateralAmount == 0) revert ZeroAmount();
        if (minOrderAmount != 0 && tokenAmount < minOrderAmount) revert BelowMinAmount();
        if (expiry != 0 && expiry <= block.timestamp) revert InvalidExpiry();
        if (allowedTaker == msg.sender) revert SelfTrade();
        if (!_isTradeable(conditionalToken, marketId)) revert MarketNotTradeable();

        uint256 tokenId = IConditionalTokens(conditionalToken).getTokenId(marketId, outcome);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            side: side,
            maker: msg.sender,
            allowedTaker: allowedTaker,
            conditionalToken: conditionalToken,
            marketId: marketId,
            outcome: outcome,
            tokenId: tokenId,
            tokenAmount: tokenAmount,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            feeBps: feeBps, // snapshot of the current rate
            expiry: expiry,
            status: OrderStatus.Open
        });

        // Escrow the maker's leg (interaction last).
        if (side == Side.Sell) {
            // Seller escrows the conditional tokens being sold.
            IConditionalTokens(conditionalToken).safeTransferFrom(
                msg.sender, address(this), tokenId, tokenAmount, ""
            );
        } else {
            // Buyer escrows the collateral being offered; guard fee-on-transfer.
            IERC20 c = IERC20(collateralToken);
            uint256 balBefore = c.balanceOf(address(this));
            c.safeTransferFrom(msg.sender, address(this), collateralAmount);
            if (c.balanceOf(address(this)) - balBefore < collateralAmount) revert CollateralShort();
        }

        emit OrderCreated(
            orderId, side, msg.sender, conditionalToken, marketId, outcome,
            tokenId, tokenAmount, collateralToken, collateralAmount, feeBps, expiry, allowedTaker
        );
    }

    /**
     * @notice Set, change, or clear the wallet allowed to fill an open order.
     * @dev    Maker only. address(0) re-opens the order to anyone. No escrow moves.
     *         A redirect racing a fill is benign: whichever transaction lands first
     *         wins and the loser reverts with no transfer.
     */
    function setAllowedTaker(uint256 orderId, address newTaker) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.maker == address(0)) revert OrderNotFound();
        if (o.status != OrderStatus.Open) revert OrderNotOpen();
        if (msg.sender != o.maker) revert NotMaker();
        if (newTaker == o.maker) revert SelfTrade();
        emit AllowedTakerUpdated(orderId, o.allowedTaker, newTaker);
        o.allowedTaker = newTaker;
    }

    /**
     * @notice Fill an open order in full.
     * @dev    Filling a Sell order: taker must `approve(otc, collateralAmount)` first.
     *         Filling a Buy order:  taker must `setApprovalForAll(otc, true)` first.
     *         The market must still be tradeable at fill time. For a directed order,
     *         only the allowed taker may call.
     */
    function fillOrder(uint256 orderId) external whenNotPaused nonReentrant {
        Order storage o = orders[orderId];
        if (o.maker == address(0)) revert OrderNotFound();
        if (o.status != OrderStatus.Open) revert OrderNotOpen();
        if (msg.sender == o.maker) revert SelfTrade();
        if (o.allowedTaker != address(0) && msg.sender != o.allowedTaker) revert NotAllowedTaker();
        if (o.expiry != 0 && block.timestamp > o.expiry) revert OrderExpired();
        if (!_isTradeable(o.conditionalToken, o.marketId)) revert MarketNotTradeable();

        // Effects first.
        o.status = OrderStatus.Filled;

        uint256 feeAmount = (o.collateralAmount * o.feeBps) / BPS_DENOMINATOR;
        uint256 collateralToSeller = o.collateralAmount - feeAmount;
        accruedFees[o.collateralToken] += feeAmount;

        IERC20 c = IERC20(o.collateralToken);

        if (o.side == Side.Sell) {
            // Maker = seller (tokens escrowed). Taker = buyer, pays collateral now.
            uint256 balBefore = c.balanceOf(address(this));
            c.safeTransferFrom(msg.sender, address(this), o.collateralAmount);
            if (c.balanceOf(address(this)) - balBefore < o.collateralAmount) revert CollateralShort();

            c.safeTransfer(o.maker, collateralToSeller);
            IConditionalTokens(o.conditionalToken).safeTransferFrom(
                address(this), msg.sender, o.tokenId, o.tokenAmount, ""
            );
        } else {
            // Maker = buyer (collateral escrowed). Taker = seller, delivers tokens now.
            IConditionalTokens(o.conditionalToken).safeTransferFrom(
                msg.sender, o.maker, o.tokenId, o.tokenAmount, ""
            );
            c.safeTransfer(msg.sender, collateralToSeller);
        }

        emit OrderFilled(
            orderId, o.maker, msg.sender, o.side, o.conditionalToken, o.marketId, o.outcome,
            o.tokenId, o.tokenAmount, o.collateralToken, o.collateralAmount, feeAmount, collateralToSeller
        );
    }

    /**
     * @notice Cancel an open order and return the escrowed leg to the maker.
     * @dev    Callable by the maker at any time, or by anyone once the order has
     *         expired (the escrow always returns to the maker regardless of caller).
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.maker == address(0)) revert OrderNotFound();
        if (o.status != OrderStatus.Open) revert OrderNotOpen();
        if (msg.sender != o.maker && (o.expiry == 0 || block.timestamp <= o.expiry)) {
            revert NotAuthorized();
        }

        o.status = OrderStatus.Cancelled;

        if (o.side == Side.Sell) {
            IConditionalTokens(o.conditionalToken).safeTransferFrom(
                address(this), o.maker, o.tokenId, o.tokenAmount, ""
            );
        } else {
            IERC20(o.collateralToken).safeTransfer(o.maker, o.collateralAmount);
        }

        emit OrderCancelled(orderId, o.maker);
    }

    // ------------------------------- Views -------------------------------- //

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function _isTradeable(address conditionalToken, uint256 marketId) internal view returns (bool) {
        address manager = marketManagerOf[conditionalToken];
        if (manager == address(0)) revert ManagerNotSet();
        return IMarketManager(manager).isMarketTradeable(marketId);
    }
}
