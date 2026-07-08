// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OTCExchange} from "../contracts/OTCExchange.sol";

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
    MockConditionalTokens internal ct;
    MockMarketManager internal manager;
    MockERC20 internal collateral;

    address internal admin = makeAddr("admin");
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
        otc = new OTCExchange(admin, feeRecipient, START_FEE_BPS);

        vm.startPrank(admin);
        otc.allowConditionalToken(address(ct), address(manager));
        otc.setCollateralAllowed(address(collateral), true);
        vm.stopPrank();

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

    function test_Sell_CancelReturnsTokens() public {
        uint256 id = _createSell();
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
        vm.expectRevert(bytes("collateral short"));
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
        vm.expectRevert(bytes("not allowed taker"));
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
        vm.expectRevert(bytes("not allowed taker"));
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
        vm.expectRevert(bytes("not maker"));
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
        vm.expectRevert(bytes("order not open"));
        otc.setAllowedTaker(id, buyer);
    }

    function test_Create_RevertsWhenTakerIsMaker() public {
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        vm.expectRevert(bytes("taker=maker"));
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, seller);
        vm.stopPrank();
    }

    // ---- shared guards ----

    function test_Create_RevertsOnInvalidOutcome() public {
        // outcome 2 would derive a tokenId belonging to a different market
        // ((MARKET << 1) | 2), so it must be rejected outright.
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        vm.expectRevert(bytes("bad outcome"));
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, 2, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, address(0));
        vm.stopPrank();
    }

    function test_Allow_RevertsOnManagerMismatch() public {
        MockMarketManager other = new MockMarketManager();
        vm.prank(admin);
        vm.expectRevert(bytes("manager mismatch"));
        otc.allowConditionalToken(address(ct), address(other));
    }

    function test_Create_RevertWhenMarketNotTradeable() public {
        manager.setTradeable(MARKET, false);
        ct.mint(seller, MARKET, OUTCOME, TOKEN_AMOUNT);
        vm.startPrank(seller);
        ct.setApprovalForAll(address(otc), true);
        vm.expectRevert(bytes("market not tradeable"));
        otc.createOrder(OTCExchange.Side.Sell, address(ct), MARKET, OUTCOME, TOKEN_AMOUNT, address(collateral), COLLATERAL_AMOUNT, 0, address(0));
        vm.stopPrank();
    }

    function test_Fill_RevertWhenMarketResolvedAfterCreate() public {
        uint256 id = _createSell();
        manager.setTradeable(MARKET, false);
        collateral.mint(buyer, COLLATERAL_AMOUNT);
        vm.startPrank(buyer);
        collateral.approve(address(otc), type(uint256).max);
        vm.expectRevert(bytes("market not tradeable"));
        otc.fillOrder(id);
        vm.stopPrank();
    }

    function test_Fill_UsesSnapshottedFee() public {
        uint256 id = _createSell();
        vm.prank(admin);
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
        vm.prank(admin);
        otc.withdrawFees(address(collateral), fee);
        assertEq(collateral.balanceOf(feeRecipient), fee, "recipient paid");
    }

    function test_OnlyAdminCanSetFee() public {
        vm.prank(seller);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        otc.setFeeBps(200);
    }
}
