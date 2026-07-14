// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OTCExchange} from "../contracts/OTCExchange.sol";
import {OTCQuerier, OrderView, SideFilter} from "../contracts/OTCQuerier.sol";
import {AdminRegistry} from "../contracts/AdminRegistry.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

// --------------------------------- Mocks ----------------------------------- //

contract QCollateral is ERC20 {
    uint8 private immutable _decimals;
    constructor(uint8 d) ERC20("Q Collateral", "QCOL") { _decimals = d; }
    function decimals() public view override returns (uint8) { return _decimals; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract QConditionalTokens is ERC1155 {
    address public manager;
    constructor(address _manager) ERC1155("https://example/{id}") { manager = _manager; }
    function getTokenId(uint256 marketId, uint256 outcome) public pure returns (uint256) {
        return (marketId << 1) | outcome;
    }
    function mint(address to, uint256 marketId, uint256 outcome, uint256 amount) external {
        _mint(to, getTokenId(marketId, outcome), amount, "");
    }
}

/// @dev Manager mock exposing the full view surface the lens derives from.
contract QMarketManager {
    mapping(uint256 => bool) public tradeable;
    mapping(uint256 => bool) public negRisk;
    mapping(uint256 => bytes32) public eventIdOf;

    function setTradeable(uint256 marketId, bool value) external { tradeable[marketId] = value; }
    function setNegRisk(uint256 marketId, bool value) external { negRisk[marketId] = value; }
    function setEventId(uint256 marketId, bytes32 value) external { eventIdOf[marketId] = value; }

    function isMarketTradeable(uint256 marketId) external view returns (bool) { return tradeable[marketId]; }
    function isNegRisk(uint256 marketId) external view returns (bool) { return negRisk[marketId]; }
    function getEventId(uint256 marketId) external view returns (bytes32) { return eventIdOf[marketId]; }
}

// --------------------------------- Tests ----------------------------------- //

contract OTCQuerierTest is Test {
    OTCExchange internal otc;
    OTCQuerier internal lens;
    QConditionalTokens internal ct;
    QMarketManager internal manager;
    QCollateral internal collateral;

    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");

    uint256 internal constant MARKET = 3;
    uint256 internal constant MARKET_B = 7;
    uint256 internal constant OUTCOME = 0;
    uint256 internal constant TOKEN_AMOUNT = 100e18;
    uint256 internal constant COLLATERAL_AMOUNT = 50e6; // 6-decimal collateral
    uint8 internal constant COLLATERAL_DECIMALS = 6;

    function setUp() public {
        manager = new QMarketManager();
        ct = new QConditionalTokens(address(manager));
        collateral = new QCollateral(COLLATERAL_DECIMALS);
        otc = new OTCExchange(
            new AdminRegistry(admin), feeRecipient, 0,
            address(ct), address(manager), address(collateral), 0
        );
        lens = new OTCQuerier(otc);

        manager.setTradeable(MARKET, true);
        manager.setTradeable(MARKET_B, true);
    }

    // Creates a Sell order on `market`, optionally directed at `directedTo`.
    function _sell(uint256 market, address directedTo) internal returns (uint256 id) {
        ct.mint(maker, market, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(maker);
        ct.setApprovalForAll(address(otc), true);
        id = otc.createOrder(
            OTCExchange.Side.Sell, address(ct), market, OUTCOME, TOKEN_AMOUNT,
            address(collateral), COLLATERAL_AMOUNT, 0, directedTo
        );
        vm.stopPrank();
    }

    // Creates a Sell order on `market` with an expiry, optionally directed.
    function _sellExpiring(uint256 market, uint64 expiry, address directedTo) internal returns (uint256 id) {
        ct.mint(maker, market, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(maker);
        ct.setApprovalForAll(address(otc), true);
        id = otc.createOrder(
            OTCExchange.Side.Sell, address(ct), market, OUTCOME, TOKEN_AMOUNT,
            address(collateral), COLLATERAL_AMOUNT, expiry, directedTo
        );
        vm.stopPrank();
    }

    // Creates a Buy order on `market`, open to anyone.
    function _buy(uint256 market) internal returns (uint256 id) {
        collateral.mint(maker, COLLATERAL_AMOUNT);
        vm.startPrank(maker);
        collateral.approve(address(otc), type(uint256).max);
        id = otc.createOrder(
            OTCExchange.Side.Buy, address(ct), market, OUTCOME, TOKEN_AMOUNT,
            address(collateral), COLLATERAL_AMOUNT, 0, address(0)
        );
        vm.stopPrank();
    }

    function test_ImmutableCoreReference() public view {
        assertEq(lens.otc(), address(otc), "otc ref");
        assertEq(address(lens.otcExchange()), address(otc), "otc ref (typed)");
    }

    function test_GetOrders_WindowAndDerivedFields() public {
        manager.setNegRisk(MARKET, true);
        manager.setEventId(MARKET, bytes32(uint256(0xABCD)));
        uint256 id = _sell(MARKET, address(0));

        assertEq(lens.totalOrders(), 1, "total");
        (OrderView[] memory page, uint256 nextCursor) = lens.getOrders(0, 10);
        assertEq(page.length, 1, "one order");
        assertEq(nextCursor, 1, "sentinel at end");

        OrderView memory v = page[0];
        assertEq(v.orderId, id);
        assertEq(v.side, uint8(OTCExchange.Side.Sell));
        assertEq(v.maker, maker);
        assertEq(v.tokenId, ct.getTokenId(MARKET, OUTCOME));
        assertEq(v.collateralAmount, COLLATERAL_AMOUNT);
        assertTrue(v.marketTradeable, "derived tradeable");
        assertTrue(v.isNegRisk, "derived negRisk");
        assertEq(v.eventId, bytes32(uint256(0xABCD)), "derived eventId");
        assertEq(v.collateralDecimals, COLLATERAL_DECIMALS, "derived decimals");
    }

    function test_GetOrders_Pagination() public {
        for (uint256 i = 0; i < 5; i++) _sell(MARKET, address(0));

        (OrderView[] memory p1, uint256 c1) = lens.getOrders(0, 2);
        assertEq(p1.length, 2);
        assertEq(c1, 2);
        assertEq(p1[0].orderId, 0);
        assertEq(p1[1].orderId, 1);

        (OrderView[] memory p2, uint256 c2) = lens.getOrders(c1, 2);
        assertEq(p2.length, 2);
        assertEq(c2, 4);

        (OrderView[] memory p3, uint256 c3) = lens.getOrders(c2, 2);
        assertEq(p3.length, 1, "last partial page");
        assertEq(c3, 5, "sentinel");

        (OrderView[] memory p4, uint256 c4) = lens.getOrders(c3, 2);
        assertEq(p4.length, 0, "past end");
        assertEq(c4, 5);
    }

    function test_GetOrders_LimitZeroDefaultsToMax() public {
        for (uint256 i = 0; i < 3; i++) _sell(MARKET, address(0));

        // limit == 0 means MAX_LIMIT on the raw feed, same as the filtered reads.
        (OrderView[] memory page, uint256 nextCursor) = lens.getOrders(0, 0);
        assertEq(page.length, 3, "limit 0 pages at MAX_LIMIT");
        assertEq(nextCursor, 3, "sentinel");
    }

    function test_GetOpenOrders_HidesDirectedFromPublic() public {
        _sell(MARKET, address(0));   // public
        _sell(MARKET, taker);        // directed at taker

        // Public marketplace (fillableBy == 0): only the open order.
        (OrderView[] memory pub,) = lens.getOpenOrders(SideFilter.Any, address(0), 0, 100);
        assertEq(pub.length, 1, "public sees only open order");
        assertEq(pub[0].allowedTaker, address(0));

        // Connected wallet == taker: public + directed-at-me.
        (OrderView[] memory mine,) = lens.getOpenOrders(SideFilter.Any, taker, 0, 100);
        assertEq(mine.length, 2, "taker sees public + reserved");

        // A stranger only sees the public order.
        (OrderView[] memory stranger,) = lens.getOpenOrders(SideFilter.Any, makeAddr("x"), 0, 100);
        assertEq(stranger.length, 1);
    }

    function test_GetOpenOrders_SideFilter() public {
        _sell(MARKET, address(0));
        _buy(MARKET);

        (OrderView[] memory asks,) = lens.getOpenOrders(SideFilter.Sell, address(0), 0, 100);
        assertEq(asks.length, 1);
        assertEq(asks[0].side, uint8(OTCExchange.Side.Sell));

        (OrderView[] memory bids,) = lens.getOpenOrders(SideFilter.Buy, address(0), 0, 100);
        assertEq(bids.length, 1);
        assertEq(bids[0].side, uint8(OTCExchange.Side.Buy));

        (OrderView[] memory any,) = lens.getOpenOrders(SideFilter.Any, address(0), 0, 100);
        assertEq(any.length, 2);
    }

    function test_GetOpenOrders_ExcludesNonOpen() public {
        uint256 id = _sell(MARKET, address(0));
        vm.prank(maker);
        otc.cancelOrder(id);

        (OrderView[] memory page,) = lens.getOpenOrders(SideFilter.Any, address(0), 0, 100);
        assertEq(page.length, 0, "cancelled excluded");
    }

    function test_OpenOrderListings_ExcludeExpired() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 expiring = _sellExpiring(MARKET, expiry, address(0));
        uint256 perpetual = _sell(MARKET, address(0));

        // Before expiry both are listed.
        (OrderView[] memory before,) = lens.getOpenOrders(SideFilter.Any, address(0), 0, 100);
        assertEq(before.length, 2, "both listed before expiry");

        vm.warp(expiry + 1);

        // Expired order drops out of the marketplace and per-market listings
        // (fillOrder on it would revert), the perpetual one remains.
        (OrderView[] memory open,) = lens.getOpenOrders(SideFilter.Any, address(0), 0, 100);
        assertEq(open.length, 1, "expired excluded from open orders");
        assertEq(open[0].orderId, perpetual);

        (OrderView[] memory byMarket,) = lens.getOrdersByMarket(address(ct), MARKET, SideFilter.Any, address(0), 0, 100);
        assertEq(byMarket.length, 1, "expired excluded per-market");
        assertEq(byMarket[0].orderId, perpetual);

        // The maker still sees it (needed to cancel and reclaim escrow).
        (OrderView[] memory mine,) = lens.getOrdersByMaker(maker, 0, 100);
        assertEq(mine.length, 2, "maker still sees expired order");
        assertEq(mine[0].orderId, expiring);
    }

    function test_GetOrdersByTaker_IncludesExpired() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 directed = _sellExpiring(MARKET, expiry, taker);
        vm.warp(expiry + 1);

        // "Offers to me" keeps expired offers visible (shown as expired, not hidden).
        (OrderView[] memory offers,) = lens.getOrdersByTaker(taker, 0, 100);
        assertEq(offers.length, 1, "expired directed order still visible to taker");
        assertEq(offers[0].orderId, directed);
    }

    function test_GetOrdersByMaker_AnyStatusIncludingDirected() public {
        _sell(MARKET, address(0));
        uint256 directed = _sell(MARKET, taker);
        // A different maker's order should not appear.
        address maker2 = makeAddr("maker2");
        ct.mint(maker2, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(maker2);
        ct.setApprovalForAll(address(otc), true);
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, address(0));
        vm.stopPrank();

        (OrderView[] memory page,) = lens.getOrdersByMaker(maker, 0, 100);
        assertEq(page.length, 2, "both of maker's orders, incl directed");
        assertEq(page[1].orderId, directed);
    }

    function test_GetOrdersByTaker_OffersToMe() public {
        _sell(MARKET, address(0));      // public, not directed
        uint256 d1 = _sell(MARKET, taker);
        uint256 d2 = _sell(MARKET_B, taker);
        _sell(MARKET, makeAddr("other")); // directed at someone else

        (OrderView[] memory page,) = lens.getOrdersByTaker(taker, 0, 100);
        assertEq(page.length, 2, "only orders directed at taker");
        assertEq(page[0].orderId, d1);
        assertEq(page[1].orderId, d2);
    }

    function test_GetOrdersByTaker_ZeroReturnsNothing() public {
        _sell(MARKET, address(0));
        (OrderView[] memory page,) = lens.getOrdersByTaker(address(0), 0, 100);
        assertEq(page.length, 0, "taker=0 is meaningless");
    }

    function test_GetOrdersByMarket_TwoSidedAndScoped() public {
        _sell(MARKET, address(0));
        _buy(MARKET);
        _sell(MARKET_B, address(0)); // different market, excluded

        (OrderView[] memory both,) = lens.getOrdersByMarket(address(ct), MARKET, SideFilter.Any, address(0), 0, 100);
        assertEq(both.length, 2, "bids + asks for the market");

        (OrderView[] memory asks,) = lens.getOrdersByMarket(address(ct), MARKET, SideFilter.Sell, address(0), 0, 100);
        assertEq(asks.length, 1);
        assertEq(asks[0].marketId, MARKET);
    }

    function test_GetOrdersByMarket_RespectsFillableBy() public {
        _sell(MARKET, address(0));
        _sell(MARKET, taker); // directed

        (OrderView[] memory pub,) = lens.getOrdersByMarket(address(ct), MARKET, SideFilter.Any, address(0), 0, 100);
        assertEq(pub.length, 1, "directed hidden from public book");

        (OrderView[] memory mine,) = lens.getOrdersByMarket(address(ct), MARKET, SideFilter.Any, taker, 0, 100);
        assertEq(mine.length, 2, "taker sees reserved too");
    }

    function test_GetOrdersByIds() public {
        uint256 a = _sell(MARKET, address(0));
        uint256 b = _buy(MARKET);

        uint256[] memory ids = new uint256[](2);
        ids[0] = b;
        ids[1] = a;
        OrderView[] memory views = lens.getOrdersByIds(ids);
        assertEq(views.length, 2);
        assertEq(views[0].orderId, b);
        assertEq(views[0].side, uint8(OTCExchange.Side.Buy));
        assertEq(views[1].orderId, a);
        assertEq(views[1].side, uint8(OTCExchange.Side.Sell));
    }

    function test_DerivedTradeableReflectsResolution() public {
        uint256 id = _sell(MARKET, address(0));
        manager.setTradeable(MARKET, false); // market resolves after creation

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        OrderView[] memory views = lens.getOrdersByIds(ids);
        assertFalse(views[0].marketTradeable, "reflects live resolution");
    }
}
