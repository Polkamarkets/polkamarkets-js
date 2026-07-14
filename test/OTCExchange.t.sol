// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OTCExchange} from "../contracts/OTCExchange.sol";
import {AdminRegistry} from "../contracts/AdminRegistry.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

// --------------------------------- Mocks ----------------------------------- //

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev ERC-20 that skims 1% on transfer, to exercise the fee-on-transfer guard.
contract FeeOnTransferERC20 is ERC20 {
    address constant SINK = address(0xdEaD);
    uint256 constant FEE_BPS = 100;
    constructor() ERC20("Fee On Transfer", "FOT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) { super._update(from, to, value); return; }
        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, SINK, fee);
    }
}

/// @dev Mirrors Myriad's ConditionalTokens: tokenId = (marketId << 1) | outcome,
///      manager exposed as a public immutable-style getter.
contract MockConditionalTokens is ERC1155 {
    address public manager;
    constructor(address _manager) ERC1155("https://example/{id}") { manager = _manager; }
    function getTokenId(uint256 marketId, uint256 outcome) public pure returns (uint256) {
        return (marketId << 1) | outcome;
    }
    function mint(address to, uint256 marketId, uint256 outcome, uint256 amount) external {
        _mint(to, getTokenId(marketId, outcome), amount, "");
    }
}

contract MockMarketManager {
    mapping(uint256 => bool) public tradeable;
    function setTradeable(uint256 marketId, bool value) external { tradeable[marketId] = value; }
    function isMarketTradeable(uint256 marketId) external view returns (bool) { return tradeable[marketId]; }
}

// --------------------------------- Tests ----------------------------------- //

contract OTCExchangeTest is Test {
    OTCExchange internal otc;
    AdminRegistry internal registry;
    MockConditionalTokens internal ct;
    MockMarketManager internal manager;
    MockERC20 internal collateral;

    address internal admin = makeAddr("admin");
    address internal feeAdmin = makeAddr("feeAdmin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant MARKET = 1;
    uint256 internal constant OUTCOME = 0;
    uint256 internal constant TOKEN_AMOUNT = 100e18;
    uint256 internal constant COLLATERAL_AMOUNT = 50e18;
    uint256 internal constant START_FEE_BPS = 100; // 1%

    function setUp() public {
        vm.warp(1_000_000);
        manager = new MockMarketManager();
        ct = new MockConditionalTokens(address(manager));
        collateral = new MockERC20();

        registry = new AdminRegistry(admin);
        bytes32 feeAdminRole = registry.FEE_ADMIN_ROLE();
        vm.prank(admin);
        registry.grantRole(feeAdminRole, feeAdmin);

        otc = new OTCExchange(
            registry, feeRecipient, START_FEE_BPS,
            address(ct), address(manager), address(collateral), 0
        );

        manager.setTradeable(MARKET, true);
    }

    function _tokenId() internal view returns (uint256) {
        return ct.getTokenId(MARKET, OUTCOME);
    }

    // helpers
    function _createSell() internal returns (uint256 id) {
        id = _createSellDirected(address(0));
    }

    function _createSellDirected(address taker) internal returns (uint256 id) {
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        id = otc.createOrder(
            OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT,
            address(collateral), COLLATERAL_AMOUNT, 0, taker
        );
        vm.stopPrank();
    }

    function _createBuy() internal returns (uint256 id) {
        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        id = otc.createOrder(
            OTCExchange.Side.Buy, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT,
            address(collateral), COLLATERAL_AMOUNT, 0, address(0)
        );
        vm.stopPrank();
    }

    // ---- Constructor wiring ----

    function test_ConstructorSeedsConfig() public view {
        assertEq(address(otc.registry()), address(registry), "registry");
        assertTrue(otc.allowedConditionalToken(address(ct)), "ct allowed");
        assertEq(otc.marketManagerOf(address(ct)), address(manager), "manager bound");
        assertTrue(otc.allowedCollateral(address(collateral)), "collateral allowed");
        assertEq(otc.feeRecipient(), feeRecipient, "fee recipient");
        assertEq(otc.feeBps(), START_FEE_BPS, "fee bps");
        assertEq(otc.minOrderAmount(), 0, "min order");
    }

    function test_ConstructorRevertsOnManagerMismatch() public {
        MockMarketManager other = new MockMarketManager();
        vm.expectRevert(OTCExchange.ManagerMismatch.selector);
        new OTCExchange(
            registry, feeRecipient, START_FEE_BPS,
            address(ct), address(other), address(collateral), 0
        );
    }

    // ---- Sell (Ask): maker escrows tokens, taker pays collateral ----

    function test_Sell_CreateEscrowsTokens() public {
        uint256 id = _createSell();
        assertEq(ct.balanceOf(address(otc), _tokenId()), TOKEN_AMOUNT, "escrow");
        OTCExchange.Order memory o = otc.getOrder(id);
        assertEq(uint8(o.side), uint8(OTCExchange.Side.Sell));
        assertEq(o.maker, seller);
        assertEq(o.allowedTaker, address(0), "open to anyone");
        assertEq(o.feeBps, START_FEE_BPS, "fee snapshot");
    }

    function test_Sell_FillPaysSellerAndDelivers() public {
        uint256 id = _createSell();
        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        otc.fillOrder(id);
        vm.stopPrank();

        uint256 fee = (COLLATERAL_AMOUNT * START_FEE_BPS) / 10_000;
        assertEq(collateral.balanceOf(seller), COLLATERAL_AMOUNT - fee, "seller proceeds");
        assertEq(otc.accruedFees(address(collateral)), fee, "fee accrued");
        assertEq(ct.balanceOf(buyer, _tokenId()), TOKEN_AMOUNT, "buyer got tokens");
        assertEq(ct.balanceOf(address(otc), _tokenId()), 0, "escrow released");
    }

    function test_Sell_FillEmitsFullTradeDetail() public {
        // OrderFilled mirrors OrdersMatched's richness: the API ingests fills
        // from the event alone, no getOrder read.
        uint256 id = _createSell();
        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);

        uint256 fee = (COLLATERAL_AMOUNT * START_FEE_BPS) / 10_000;
        vm.expectEmit(true, true, true, true, address(otc));
        emit OTCExchange.OrderFilled(
            id, seller, buyer, OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME,
            _tokenId(), TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT,
            fee, COLLATERAL_AMOUNT - fee
        );
        otc.fillOrder(id);
        vm.stopPrank();
    }

    function test_Sell_CancelReturnsTokens() public {
        uint256 id = _createSell();
        vm.expectEmit(true, true, false, true, address(otc));
        emit OTCExchange.OrderCancelled(id, seller);
        vm.prank(seller);
        otc.cancelOrder(id);
        assertEq(ct.balanceOf(seller, _tokenId()), TOKEN_AMOUNT, "returned");
    }

    // ---- Buy (Bid): maker escrows collateral, taker delivers tokens ----

    function test_Buy_CreateEscrowsCollateral() public {
        uint256 id = _createBuy();
        assertEq(collateral.balanceOf(address(otc)), COLLATERAL_AMOUNT, "escrow");
        OTCExchange.Order memory o = otc.getOrder(id);
        assertEq(uint8(o.side), uint8(OTCExchange.Side.Buy));
        assertEq(o.maker, buyer);
    }

    function test_Buy_FillDeliversTokensAndPaysSeller() public {
        uint256 id = _createBuy();
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        otc.fillOrder(id);
        vm.stopPrank();

        uint256 fee = (COLLATERAL_AMOUNT * START_FEE_BPS) / 10_000;
        assertEq(ct.balanceOf(buyer, _tokenId()), TOKEN_AMOUNT, "maker (buyer) got tokens");
        assertEq(collateral.balanceOf(seller), COLLATERAL_AMOUNT - fee, "seller proceeds");
        assertEq(otc.accruedFees(address(collateral)), fee, "fee accrued");
        assertEq(collateral.balanceOf(address(otc)), fee, "only fee remains");
    }

    function test_Buy_CancelReturnsCollateral() public {
        uint256 id = _createBuy();
        vm.prank(buyer);
        otc.cancelOrder(id);
        assertEq(collateral.balanceOf(buyer), COLLATERAL_AMOUNT, "returned");
    }

    function test_Buy_CreateRevertsOnFeeOnTransferCollateral() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        vm.prank(admin);
        otc.setCollateralAllowed(address(fot), true);

        fot.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        fot.approve(address(otc), type(uint256).max);
        vm.expectRevert(OTCExchange.CollateralShort.selector);
        otc.createOrder(
            OTCExchange.Side.Buy, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT,
            address(fot), COLLATERAL_AMOUNT, 0, address(0)
        );
        vm.stopPrank();
    }

    // ---- Directed orders ----

    function test_Directed_OnlyAllowedTakerCanFill() public {
        uint256 id = _createSellDirected(buyer);

        address stranger = makeAddr("stranger");
        collateral.mint(stranger, COLLATERAL_AMOUNT);
        vm.startPrank(stranger);
        collateral.approve(address(otc), type(uint256).max);
        vm.expectRevert(OTCExchange.NotAllowedTaker.selector);
        otc.fillOrder(id);
        vm.stopPrank();

        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        otc.fillOrder(id);
        vm.stopPrank();
        assertEq(ct.balanceOf(buyer, _tokenId()), TOKEN_AMOUNT, "designated taker filled");
    }

    function test_Directed_MakerCanRedirectAndReopen() public {
        uint256 id = _createSellDirected(buyer);

        // Redirect to another wallet: original taker locked out.
        address other = makeAddr("other");
        vm.prank(seller);
        otc.setAllowedTaker(id, other);

        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        vm.expectRevert(OTCExchange.NotAllowedTaker.selector);
        otc.fillOrder(id);
        vm.stopPrank();

        // Clearing to address(0) re-opens the order to anyone.
        vm.prank(seller);
        otc.setAllowedTaker(id, address(0));
        vm.prank(buyer);
        otc.fillOrder(id);
        assertEq(ct.balanceOf(buyer, _tokenId()), TOKEN_AMOUNT, "open again");
    }

    function test_Directed_OnlyMakerCanSetAllowedTaker() public {
        uint256 id = _createSell();
        vm.prank(buyer);
        vm.expectRevert(OTCExchange.NotMaker.selector);
        otc.setAllowedTaker(id, buyer);
    }

    function test_Directed_CannotSetOnFilledOrder() public {
        uint256 id = _createSell();
        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        otc.fillOrder(id);
        vm.stopPrank();

        vm.prank(seller);
        vm.expectRevert(OTCExchange.OrderNotOpen.selector);
        otc.setAllowedTaker(id, buyer);
    }

    function test_Create_RevertsWhenTakerIsMaker() public {
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        vm.expectRevert(OTCExchange.SelfTrade.selector);
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, seller);
        vm.stopPrank();
    }

    function test_Fill_RevertsWhenMakerFillsOwnOrder() public {
        // Self-trade guard, mirroring MyriadCTFExchange's SelfTrade: a maker
        // self-fill would only burn fee and fabricate volume.
        uint256 id = _createSell();
        collateral.mint(seller, COLLATERAL_AMOUNT);
        vm.startPrank(seller);
        collateral.approve(address(otc), type(uint256).max);
        vm.expectRevert(OTCExchange.SelfTrade.selector);
        otc.fillOrder(id);
        vm.stopPrank();
    }

    // ---- shared guards ----

    function test_Create_RevertsOnInvalidOutcome() public {
        // outcome 2 would derive a tokenId belonging to a different market
        // ((MARKET << 1) | 2), so it must be rejected outright.
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        vm.expectRevert(OTCExchange.InvalidOutcome.selector);
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, 2, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, address(0));
        vm.stopPrank();
    }

    function test_Create_RevertsBelowMinOrderAmount() public {
        vm.prank(admin);
        otc.setMinOrderAmount(TOKEN_AMOUNT + 1);

        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        vm.expectRevert(OTCExchange.BelowMinAmount.selector);
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, address(0));
        vm.stopPrank();
    }

    function test_SetMinOrderAmount_AdminOnlyAndZeroDisables() public {
        vm.prank(seller);
        vm.expectRevert(OTCExchange.NotAdmin.selector);
        otc.setMinOrderAmount(1e18);

        vm.prank(admin);
        otc.setMinOrderAmount(TOKEN_AMOUNT + 1);
        assertEq(otc.minOrderAmount(), TOKEN_AMOUNT + 1, "min set");

        // Zero disables the minimum entirely; the order goes through again.
        vm.prank(admin);
        otc.setMinOrderAmount(0);
        uint256 id = _createSell();
        assertEq(otc.getOrder(id).tokenAmount, TOKEN_AMOUNT, "created with min disabled");
    }

    function test_Allow_RevertsOnManagerMismatch() public {
        MockMarketManager other = new MockMarketManager();
        vm.prank(admin);
        vm.expectRevert(OTCExchange.ManagerMismatch.selector);
        otc.allowConditionalToken(address(ct), address(other));
    }

    function test_Create_RevertWhenMarketNotTradeable() public {
        manager.setTradeable(MARKET, false);
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        vm.expectRevert(OTCExchange.MarketNotTradeable.selector);
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, address(0));
        vm.stopPrank();
    }

    function test_Fill_RevertWhenMarketResolvedAfterCreate() public {
        uint256 id = _createSell();
        manager.setTradeable(MARKET, false);
        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        vm.expectRevert(OTCExchange.MarketNotTradeable.selector);
        otc.fillOrder(id);
        vm.stopPrank();
    }

    function test_Fill_RevertsOrderNotFound() public {
        vm.prank(buyer);
        vm.expectRevert(OTCExchange.OrderNotFound.selector);
        otc.fillOrder(999);
    }

    function test_Fill_UsesSnapshottedFee() public {
        uint256 id = _createSell();
        vm.prank(feeAdmin);
        otc.setFeeBps(500); // raise live fee AFTER creation
        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        otc.fillOrder(id);
        vm.stopPrank();
        uint256 fee = (COLLATERAL_AMOUNT * START_FEE_BPS) / 10_000; // still 1%
        assertEq(otc.accruedFees(address(collateral)), fee, "old rate honored");
    }

    function test_Cancel_AnyoneAfterExpiry() public {
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        uint256 id = otc.createOrder(
            OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT,
            address(collateral), COLLATERAL_AMOUNT, uint64(block.timestamp + 100), address(0)
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 101);
        vm.prank(buyer); // a non-maker
        otc.cancelOrder(id);
        assertEq(ct.balanceOf(seller, _tokenId()), TOKEN_AMOUNT, "returned to maker");
    }

    function test_Pause_BlocksCreate() public {
        vm.prank(admin);
        otc.pause();
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        vm.expectRevert(); // EnforcedPause
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, address(0));
        vm.stopPrank();
    }

    function test_WithdrawFees() public {
        uint256 id = _createSell();
        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        otc.fillOrder(id);
        vm.stopPrank();

        uint256 fee = otc.accruedFees(address(collateral));
        vm.prank(feeAdmin);
        otc.withdrawFees(address(collateral), fee);
        assertEq(collateral.balanceOf(feeRecipient), fee, "recipient paid");
    }

    // ---- Role separation (mirrors MyriadCTFExchange / FeeModule gating) ----

    function test_Roles_FeeAdminCannotPauseOrConfigure() public {
        vm.startPrank(feeAdmin);
        vm.expectRevert(OTCExchange.NotAdmin.selector);
        otc.pause();
        vm.expectRevert(OTCExchange.NotAdmin.selector);
        otc.setMinOrderAmount(1);
        vm.expectRevert(OTCExchange.NotAdmin.selector);
        otc.setCollateralAllowed(address(collateral), false);
        vm.stopPrank();
    }

    function test_Roles_DefaultAdminCannotTouchFees() public {
        vm.startPrank(admin);
        vm.expectRevert(OTCExchange.NotFeeAdmin.selector);
        otc.setFeeBps(200);
        vm.expectRevert(OTCExchange.NotFeeAdmin.selector);
        otc.setFeeRecipient(admin);
        vm.expectRevert(OTCExchange.NotFeeAdmin.selector);
        otc.withdrawFees(address(collateral), 0);
        vm.stopPrank();
    }

    function test_Roles_StrangerCannotSetFee() public {
        vm.prank(seller);
        vm.expectRevert(OTCExchange.NotFeeAdmin.selector);
        otc.setFeeBps(200);
    }
}
