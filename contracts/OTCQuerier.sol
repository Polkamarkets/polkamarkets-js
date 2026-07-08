// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OTCExchange} from "./OTCExchange.sol";

/// @notice Minimal manager view surface the lens needs for derived fields.
interface IOTCManagerViews {
    function isMarketTradeable(uint256 marketId) external view returns (bool);
    function isNegRisk(uint256 marketId) external view returns (bool);
    function getEventId(uint256 marketId) external view returns (bytes32);
}

/// @notice Side filter for queries: Sell-only, Buy-only, or Any.
enum SideFilter { Sell, Buy, Any }

/// @notice View-friendly projection of an OTC Order, enriched with in-lens derived fields.
struct OrderView {
    uint256 orderId;
    uint8   side;               // 0 = Sell (Ask), 1 = Buy (Bid)
    address maker;
    address allowedTaker;       // 0 = open to anyone; else the only wallet that can fill
    address conditionalToken;
    uint256 marketId;
    uint256 outcome;            // 0 = YES, 1 = NO (Myriad CLOB markets are binary)
    uint256 tokenId;
    uint256 tokenAmount;
    address collateralToken;
    uint256 collateralAmount;
    uint256 feeBps;
    uint64  expiry;
    uint8   status;             // 0 = Open, 1 = Filled, 2 = Cancelled
    // ── derived in-lens ──
    bool    marketTradeable;    // manager.isMarketTradeable(marketId)
    bool    isNegRisk;          // manager.isNegRisk(marketId) — UI surfaces/flags
    bytes32 eventId;            // manager.getEventId(marketId) — 0x0 for standalone
                                // markets; groups neg-risk sub-markets under their event
    uint8   collateralDecimals; // IERC20Metadata(collateralToken).decimals()
}

/**
 * @title OTCQuerier
 * @notice Stateless, read-only "lens" over {OTCExchange} for order discovery.
 *
 *         Holds no funds and no privileged roles; it reads the core contract's
 *         already-public state and packages paginated, pre-filtered results for
 *         `eth_call`. The pattern mirrors Polkamarkets' own
 *         `PredictionMarketV3Querier`: an immutable core reference, no ownership,
 *         and purpose-built view structs with in-lens derived fields.
 *
 * @dev    Every order's `marketId` was validated tradeable at create time, so it
 *         necessarily exists on its manager — no try/catch needed around the
 *         manager views. Directed-order hiding is presentation-level only: the
 *         `fillableBy` filter excludes directed orders from the public marketplace
 *         (`address(0)`) or includes those directed at a connected wallet; the raw
 *         `getOrders` feed and the by-maker / by-taker / by-ids batches return
 *         directed orders regardless, since maker management, "Offers to me", and
 *         direct order links depend on it.
 */
contract OTCQuerier {
    /// @dev Address of the OTCExchange this lens reads from (immutable).
    OTCExchange public immutable otcExchange;

    /// @notice Max orders returned in a single page (response-size guard).
    uint256 public constant MAX_LIMIT = 500;
    /// @notice Max orders scanned per filtered call before yielding a resume cursor.
    uint256 public constant MAX_SCAN = 5_000;

    enum FilterKind { Open, ByMaker, ByTaker, ByMarket }

    struct Filter {
        FilterKind kind;
        SideFilter side;
        address account;          // maker (ByMaker) or taker (ByTaker)
        address fillableBy;       // Open / ByMarket eligibility filter
        address conditionalToken; // ByMarket
        uint256 marketId;         // ByMarket
    }

    /// @dev protocol is immutable and has no ownership
    constructor(OTCExchange _otcExchange) {
        otcExchange = _otcExchange;
    }

    /// @notice Address of the OTCExchange this lens reads from.
    function otc() external view returns (address) {
        return address(otcExchange);
    }

    /// @notice Total number of orders ever created (== OTCExchange.nextOrderId).
    function totalOrders() public view returns (uint256) {
        return otcExchange.nextOrderId();
    }

    // ------------------------------ Reads --------------------------------- //

    /// @notice Contiguous page of orders by id window (all sides, all statuses,
    ///         public and directed alike — the raw feed).
    function getOrders(uint256 cursor, uint256 limit)
        external
        view
        returns (OrderView[] memory page, uint256 nextCursor)
    {
        uint256 total = totalOrders();
        if (cursor >= total || limit == 0) {
            return (new OrderView[](0), total);
        }
        if (limit > MAX_LIMIT) limit = MAX_LIMIT;

        uint256 end = cursor + limit;
        if (end > total) end = total;

        uint256 count = end - cursor;
        page = new OrderView[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = _toView(cursor + i);
        }
        nextCursor = end;
    }

    /// @notice Open orders, optionally restricted to one side, filtered by fill
    ///         eligibility. fillableBy == address(0): public orders only (the
    ///         marketplace default — directed orders are excluded). fillableBy set:
    ///         public orders PLUS orders directed at that address.
    function getOpenOrders(SideFilter side, address fillableBy, uint256 cursor, uint256 limit)
        external
        view
        returns (OrderView[] memory page, uint256 nextCursor)
    {
        Filter memory f = Filter(FilterKind.Open, side, address(0), fillableBy, address(0), 0);
        return _scan(cursor, limit, f);
    }

    /// @notice Orders created by a given maker (any side, any status, incl. directed).
    function getOrdersByMaker(address maker, uint256 cursor, uint256 limit)
        external
        view
        returns (OrderView[] memory page, uint256 nextCursor)
    {
        Filter memory f = Filter(FilterKind.ByMaker, SideFilter.Any, maker, address(0), address(0), 0);
        return _scan(cursor, limit, f);
    }

    /// @notice Orders directed at a given taker (any side, any status) — powers the
    ///         "Offers to me" view.
    function getOrdersByTaker(address taker, uint256 cursor, uint256 limit)
        external
        view
        returns (OrderView[] memory page, uint256 nextCursor)
    {
        Filter memory f = Filter(FilterKind.ByTaker, SideFilter.Any, taker, address(0), address(0), 0);
        return _scan(cursor, limit, f);
    }

    /// @notice Open orders for a given (conditionalToken, marketId), optionally one
    ///         side, same fillableBy semantics as getOpenOrders. Returning both
    ///         sides is what powers a per-market two-sided view (bids vs asks).
    function getOrdersByMarket(
        address conditionalToken,
        uint256 marketId,
        SideFilter side,
        address fillableBy,
        uint256 cursor,
        uint256 limit
    ) external view returns (OrderView[] memory page, uint256 nextCursor) {
        Filter memory f = Filter(FilterKind.ByMarket, side, address(0), fillableBy, conditionalToken, marketId);
        return _scan(cursor, limit, f);
    }

    /// @notice Explicit lookups (order/fill page / freshness re-check / direct links
    ///         to directed orders) — plural-batch convention. Returns any order by
    ///         id, public or directed.
    function getOrdersByIds(uint256[] calldata ids) external view returns (OrderView[] memory) {
        OrderView[] memory views = new OrderView[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            views[i] = _toView(ids[i]);
        }
        return views;
    }

    // ------------------------------ Internal ------------------------------ //

    /// @dev Forward-scans the id space from `cursor`, collecting up to `limit`
    ///      matches or until MAX_SCAN ids are examined or the feed is exhausted.
    ///      Filtered pages may be shorter than `limit`; `nextCursor == totalOrders`
    ///      signals the end of the feed.
    function _scan(uint256 cursor, uint256 limit, Filter memory f)
        internal
        view
        returns (OrderView[] memory page, uint256 nextCursor)
    {
        uint256 total = totalOrders();
        if (limit == 0 || limit > MAX_LIMIT) limit = MAX_LIMIT;

        OrderView[] memory buffer = new OrderView[](limit);
        uint256 matched = 0;
        uint256 scanned = 0;
        uint256 id = cursor;

        while (id < total && matched < limit && scanned < MAX_SCAN) {
            OTCExchange.Order memory o = otcExchange.getOrder(id);
            if (_matches(o, f)) {
                buffer[matched] = _toViewFromOrder(id, o);
                matched++;
            }
            unchecked {
                id++;
                scanned++;
            }
        }

        page = new OrderView[](matched);
        for (uint256 i = 0; i < matched; i++) {
            page[i] = buffer[i];
        }
        // If the scan reached the end of the feed, signal it with the sentinel;
        // otherwise return the next id to resume from.
        nextCursor = id >= total ? total : id;
    }

    function _matches(OTCExchange.Order memory o, Filter memory f) internal pure returns (bool) {
        if (f.kind == FilterKind.ByMaker) {
            return o.maker == f.account;
        }
        if (f.kind == FilterKind.ByTaker) {
            // taker == 0 would match every open order — meaningless for "offers to me".
            return f.account != address(0) && o.allowedTaker == f.account;
        }

        // Open and ByMarket both require an open, side-matching, fill-eligible order.
        if (o.status != OTCExchange.OrderStatus.Open) return false;
        if (!_sideMatches(o.side, f.side)) return false;
        if (!_fillableBy(o.allowedTaker, f.fillableBy)) return false;

        if (f.kind == FilterKind.ByMarket) {
            return o.conditionalToken == f.conditionalToken && o.marketId == f.marketId;
        }
        return true; // FilterKind.Open
    }

    function _sideMatches(OTCExchange.Side side, SideFilter filter) internal pure returns (bool) {
        if (filter == SideFilter.Any) return true;
        if (filter == SideFilter.Sell) return side == OTCExchange.Side.Sell;
        return side == OTCExchange.Side.Buy;
    }

    /// @dev fillableBy == 0: public orders only (allowedTaker == 0). Otherwise:
    ///      public orders plus orders directed at `fillableBy`.
    function _fillableBy(address allowedTaker, address fillableBy) internal pure returns (bool) {
        if (allowedTaker == address(0)) return true;
        return fillableBy != address(0) && allowedTaker == fillableBy;
    }

    function _toView(uint256 orderId) internal view returns (OrderView memory) {
        return _toViewFromOrder(orderId, otcExchange.getOrder(orderId));
    }

    function _toViewFromOrder(uint256 orderId, OTCExchange.Order memory o)
        internal
        view
        returns (OrderView memory v)
    {
        v.orderId = orderId;
        v.side = uint8(o.side);
        v.maker = o.maker;
        v.allowedTaker = o.allowedTaker;
        v.conditionalToken = o.conditionalToken;
        v.marketId = o.marketId;
        v.outcome = o.outcome;
        v.tokenId = o.tokenId;
        v.tokenAmount = o.tokenAmount;
        v.collateralToken = o.collateralToken;
        v.collateralAmount = o.collateralAmount;
        v.feeBps = o.feeBps;
        v.expiry = o.expiry;
        v.status = uint8(o.status);

        // An unset maker means the id has never been used — leave derived fields zeroed.
        if (o.maker == address(0)) {
            return v;
        }

        address manager = otcExchange.marketManagerOf(o.conditionalToken);
        if (manager != address(0)) {
            IOTCManagerViews m = IOTCManagerViews(manager);
            v.marketTradeable = m.isMarketTradeable(o.marketId);
            v.isNegRisk = m.isNegRisk(o.marketId);
            v.eventId = m.getEventId(o.marketId);
        }
        if (o.collateralToken != address(0)) {
            v.collateralDecimals = IERC20Metadata(o.collateralToken).decimals();
        }
    }
}
