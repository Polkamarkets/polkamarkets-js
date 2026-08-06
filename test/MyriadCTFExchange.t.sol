// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../contracts/AdminRegistry.sol";
import "../contracts/PredictionMarketV3ManagerCLOB.sol";
import "../contracts/ConditionalTokens.sol";
import "../contracts/MyriadCTFExchange.sol";
import "../contracts/FeeModule.sol";
import "../contracts/IMyriadMarketManager.sol";
import "../contracts/Outcomes.sol";

contract MockERC20 is ERC20 {
  constructor() ERC20("Collateral", "COL") {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @dev Mock contract wallet that burns all available gas in onERC1155Received.
///      Also implements ERC-1271 so it can be used as a trader with the exchange.
contract GasGriefingWallet {
  mapping(uint256 => uint256) private _junk;
  uint256 private _counter;

  function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
    return 0x1626ba7e; // ERC-1271 magic value
  }

  function onERC1155Received(address, address, uint256, uint256, bytes calldata)
    external returns (bytes4)
  {
    while (gasleft() > 5000) {
      _junk[_counter++] = gasleft();
    }
    return this.onERC1155Received.selector;
  }

  function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
    external pure returns (bytes4)
  {
    return this.onERC1155BatchReceived.selector;
  }
}

contract MyriadCTFExchangeTest is Test {
  uint256 private constant ONE = 1e18;
  uint256 private constant BPS = 10000;

  AdminRegistry                 internal registry;
  PredictionMarketV3ManagerCLOB internal manager;
  ConditionalTokens             internal conditionalTokens;
  MyriadCTFExchange             internal exchange;
  FeeModule                     internal feeModule;
  MockERC20                     internal collateral;

  address internal admin;
  address internal operator;
  address internal treasury;

  uint256 internal makerPk = 0xA11CE;
  uint256 internal takerPk = 0xB0B;
  uint256 internal thirdPk = 0xDEAD;

  address internal maker;
  address internal taker;
  address internal thirdParty;

  uint256 internal marketId;

  function setUp() public {
    admin       = address(this);
    operator    = address(this);
    treasury    = address(0xBEEF);
    maker       = vm.addr(makerPk);
    taker       = vm.addr(takerPk);
    thirdParty  = vm.addr(thirdPk);

    collateral = new MockERC20();
    registry   = new AdminRegistry(admin);

    // Deploy Manager via UUPS proxy
    PredictionMarketV3ManagerCLOB managerImpl = new PredictionMarketV3ManagerCLOB();
    ERC1967Proxy managerProxy = new ERC1967Proxy(
      address(managerImpl),
      abi.encodeCall(
        PredictionMarketV3ManagerCLOB.initialize,
        (registry, IERC20(address(collateral)))
      )
    );
    manager = PredictionMarketV3ManagerCLOB(address(managerProxy));

    conditionalTokens = new ConditionalTokens(registry, IMyriadMarketManager(address(manager)));

    // Deploy FeeModule via UUPS proxy
    FeeModule feeModuleImpl = new FeeModule();
    ERC1967Proxy feeModuleProxy = new ERC1967Proxy(
      address(feeModuleImpl),
      abi.encodeCall(FeeModule.initialize, (registry, treasury))
    );
    feeModule = FeeModule(address(feeModuleProxy));

    // Deploy Exchange via UUPS proxy
    MyriadCTFExchange exchangeImpl = new MyriadCTFExchange();
    ERC1967Proxy exchangeProxy = new ERC1967Proxy(
      address(exchangeImpl),
      abi.encodeCall(MyriadCTFExchange.initialize, (
        IMyriadMarketManager(address(manager)),
        conditionalTokens,
        address(feeModule),
        registry
      ))
    );
    exchange = MyriadCTFExchange(address(exchangeProxy));

    feeModule.setExchange(address(exchange));

    registry.grantRole(registry.MARKET_ADMIN_ROLE(),     admin);
    registry.grantRole(registry.FEE_ADMIN_ROLE(),        admin);
    registry.grantRole(registry.OPERATOR_ROLE(),         operator);
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), admin);

    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params =
      PredictionMarketV3ManagerCLOB.CreateMarketParams({
        closesAt:   block.timestamp + 1 days,
        question:   "Will it rain?",
        image:      "ipfs://img",
        feeModule:  address(feeModule),
        oracle:     address(0),
        oracleData: ""
      });
    marketId = manager.createMarket(params);

    _setUniformFees(marketId, 100, 200);
  }

  // =========================================================================
  // Helpers (identical to PredictionMarketCLOB.t.sol)
  // =========================================================================

  function _buildOrder(
    address trader,
    uint256 marketId_,
    uint256 outcome,
    MyriadCTFExchange.Side side,
    uint256 amount,
    uint256 price,
    uint256 nonce
  ) internal pure returns (MyriadCTFExchange.Order memory) {
    return MyriadCTFExchange.Order({
      trader:        trader,
      marketId:      marketId_,
      outcomeId:     uint8(outcome),
      side:          side,
      amount:        amount,
      price:         price,
      minFillAmount: 0,
      nonce:         nonce,
      expiration:    0
    });
  }

  function _signOrder(MyriadCTFExchange.Order memory order, uint256 pk)
    internal view returns (bytes memory)
  {
    bytes32 digest = exchange.hashOrder(order);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  function _setUniformFees(uint256 mktId, uint64 makerBps, uint64 takerBps) internal {
    FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
    tiers[0] = FeeModule.FeeTier({
      maxPrice:    uint128(ONE),
      makerFeeBps: makerBps,
      takerFeeBps: takerBps
    });
    feeModule.setMarketFees(mktId, tiers);
  }

  /// @dev Approve collateral + conditionalTokens for the exchange on behalf of user.
  function _approveAll(address user) internal {
    vm.startPrank(user);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
  }

  // =========================================================================
  // Access control
  // =========================================================================

  function testMatchOrdersWithFeesByNonOperatorReverts() public {
    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, (60 * ONE) / 100, 1);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 100 ether, (40 * ONE) / 100, 2);

    // Pre-compute signatures before any prank
    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    address nonOperator = address(0xBAD);
    vm.prank(nonOperator);
    vm.expectRevert(MyriadCTFExchange.NotOperator.selector);
    exchange.matchOrdersWithFees(m, mSig, t, tSig, 100 ether);
  }

  function testSetNegRiskAdapterByNonAdminReverts() public {
    vm.prank(address(0xBAD));
    vm.expectRevert(MyriadCTFExchange.NotAdmin.selector);
    exchange.setNegRiskAdapter(address(0x1234));
  }

  function testSetNegRiskAdapterByAdminSucceeds() public {
    address adapter = address(0x5678);
    exchange.setNegRiskAdapter(adapter);
    assertEq(exchange.negRiskAdapter(), adapter);
  }

  function testSetNegRiskAdapterEmitsEvent() public {
    address oldAdapter = exchange.negRiskAdapter();
    address newAdapter = address(0xADA);
    vm.expectEmit(true, true, false, false, address(exchange));
    emit MyriadCTFExchange.NegRiskAdapterUpdated(oldAdapter, newAdapter);
    exchange.setNegRiskAdapter(newAdapter);
  }

  function testInitializeWithZeroManagerReverts() public {
    MyriadCTFExchange impl = new MyriadCTFExchange();
    vm.expectRevert(MyriadCTFExchange.ZeroManager.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeCall(MyriadCTFExchange.initialize, (
        IMyriadMarketManager(address(0)),
        conditionalTokens,
        address(feeModule),
        registry
      ))
    );
  }

  function testInitializeWithZeroConditionalTokensReverts() public {
    MyriadCTFExchange impl = new MyriadCTFExchange();
    vm.expectRevert(MyriadCTFExchange.ZeroCT.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeCall(MyriadCTFExchange.initialize, (
        IMyriadMarketManager(address(manager)),
        ConditionalTokens(address(0)),
        address(feeModule),
        registry
      ))
    );
  }

  function testInitializeWithZeroFeeModuleReverts() public {
    MyriadCTFExchange impl = new MyriadCTFExchange();
    vm.expectRevert(MyriadCTFExchange.ZeroFeeModule.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeCall(MyriadCTFExchange.initialize, (
        IMyriadMarketManager(address(manager)),
        conditionalTokens,
        address(0),
        registry
      ))
    );
  }

  function testInitializeWithZeroRegistryReverts() public {
    MyriadCTFExchange impl = new MyriadCTFExchange();
    vm.expectRevert(MyriadCTFExchange.ZeroRegistry.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeCall(MyriadCTFExchange.initialize, (
        IMyriadMarketManager(address(manager)),
        conditionalTokens,
        address(feeModule),
        AdminRegistry(address(0))
      ))
    );
  }

  // =========================================================================
  // Hash / view functions
  // =========================================================================

  function testHashOrderDifferentTraders() public view {
    MyriadCTFExchange.Order memory o1 = _buildOrder(maker,  marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 1);
    MyriadCTFExchange.Order memory o2 = _buildOrder(taker,  marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 1);
    assertTrue(exchange.hashOrder(o1) != exchange.hashOrder(o2));
  }

  function testHashOrderDifferentMarketIds() public view {
    MyriadCTFExchange.Order memory o1 = _buildOrder(maker, 1, Outcomes.YES, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 1);
    MyriadCTFExchange.Order memory o2 = _buildOrder(maker, 2, Outcomes.YES, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 1);
    assertTrue(exchange.hashOrder(o1) != exchange.hashOrder(o2));
  }

  function testHashOrderDifferentOutcomeIds() public view {
    MyriadCTFExchange.Order memory o1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 1);
    MyriadCTFExchange.Order memory o2 = _buildOrder(maker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 1);
    assertTrue(exchange.hashOrder(o1) != exchange.hashOrder(o2));
  }

  function testHashOrderDifferentNonces() public view {
    MyriadCTFExchange.Order memory o1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 1);
    MyriadCTFExchange.Order memory o2 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 2);
    assertTrue(exchange.hashOrder(o1) != exchange.hashOrder(o2));
  }

  function testDomainSeparatorIsNonZero() public view {
    bytes32 ds = exchange.DOMAIN_SEPARATOR();
    assertTrue(ds != bytes32(0));
  }

  function testGetOrderStatusInitiallyEmpty() public view {
    MyriadCTFExchange.Order memory o = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 1 ether, ONE / 2, 100);
    bytes32 h = exchange.hashOrder(o);
    (uint256 filled, bool invalidated) = exchange.getOrderStatus(h);
    assertEq(filled, 0);
    assertFalse(invalidated);
  }

  function testGetOrderStatusAfterPartialFill() public {
    uint256 amount = 100 ether;
    uint256 fill   = 40 ether;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, (60 * ONE) / 100, 200);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, (40 * ONE) / 100, 201);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), fill);

    bytes32 mHash = exchange.hashOrder(m);
    (uint256 filled, bool invalidated) = exchange.getOrderStatus(mHash);
    assertEq(filled, fill);
    assertFalse(invalidated);
  }

  function testGetOrderStatusAfterCancel() public {
    MyriadCTFExchange.Order memory o = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 10 ether, ONE / 2, 300);

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = o;

    vm.prank(maker);
    exchange.cancelOrders(toCancel);

    bytes32 h = exchange.hashOrder(o);
    (uint256 filled, bool invalidated) = exchange.getOrderStatus(h);
    assertEq(filled, 0);
    assertTrue(invalidated);
  }

  // =========================================================================
  // Signature validation
  // =========================================================================

  function testBadSignatureWrongSignerReverts() public {
    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    uint256 amount = 100 ether;
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, (60 * ONE) / 100, 400);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, (40 * ONE) / 100, 401);

    // Sign maker order with the wrong private key (thirdPk instead of makerPk)
    bytes memory badSig  = _signOrder(m, thirdPk);
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert(MyriadCTFExchange.InvalidSignature.selector);
    exchange.matchOrdersWithFees(m, badSig, t, takerSig, amount);
  }

  function testInvalidSignatureBytesReverts() public {
    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    uint256 amount = 100 ether;
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, (60 * ONE) / 100, 410);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, (40 * ONE) / 100, 411);

    // All-zero 65 bytes: ECDSA.tryRecover will return RecoverError != NoError
    bytes memory zeroSig  = new bytes(65);
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert(MyriadCTFExchange.InvalidSignature.selector);
    exchange.matchOrdersWithFees(m, zeroSig, t, takerSig, amount);
  }

  function testTraderZeroAddressReverts() public {
    uint256 amount = 100 ether;
    MyriadCTFExchange.Order memory m = _buildOrder(address(0), marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, (60 * ONE) / 100, 420);
    MyriadCTFExchange.Order memory t = _buildOrder(taker,      marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, (40 * ONE) / 100, 421);

    // Sign m with makerPk (order has trader=address(0), so validate will fail at "trader 0")
    bytes memory makerSig = _signOrder(m, makerPk);
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert(MyriadCTFExchange.ZeroTrader.selector);
    exchange.matchOrdersWithFees(m, makerSig, t, takerSig, amount);
  }

  function testAmountZeroOrderReverts() public {
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 0, (60 * ONE) / 100, 430);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 100 ether, (40 * ONE) / 100, 431);

    bytes memory makerSig = _signOrder(m, makerPk);
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert(MyriadCTFExchange.ZeroAmount.selector);
    exchange.matchOrdersWithFees(m, makerSig, t, takerSig, 100 ether);
  }

  function testBadOutcomeIdReverts() public {
    // outcomeId = 2 is invalid (must be < 2)
    MyriadCTFExchange.Order memory m = MyriadCTFExchange.Order({
      trader:        maker,
      marketId:      marketId,
      outcomeId:     2,
      side:          MyriadCTFExchange.Side.Buy,
      amount:        100 ether,
      price:         (60 * ONE) / 100,
      minFillAmount: 0,
      nonce:         440,
      expiration:    0
    });
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 100 ether, (40 * ONE) / 100, 441);

    bytes memory makerSig = _signOrder(m, makerPk);
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert(MyriadCTFExchange.BadOutcome.selector);
    exchange.matchOrdersWithFees(m, makerSig, t, takerSig, 100 ether);
  }

  function testOrderExpiredAtExactTimestampReverts() public {
    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    uint256 expiry = block.timestamp + 1 hours;

    MyriadCTFExchange.Order memory m = MyriadCTFExchange.Order({
      trader:        maker,
      marketId:      marketId,
      outcomeId:     uint8(Outcomes.YES),
      side:          MyriadCTFExchange.Side.Buy,
      amount:        100 ether,
      price:         (60 * ONE) / 100,
      minFillAmount: 0,
      nonce:         450,
      expiration:    expiry
    });
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 100 ether, (40 * ONE) / 100, 451);

    bytes memory makerSig = _signOrder(m, makerPk);
    bytes memory takerSig = _signOrder(t, takerPk);

    // Warp to exactly the expiration timestamp — order should be expired
    vm.warp(expiry);
    vm.expectRevert(MyriadCTFExchange.OrderExpired.selector);
    exchange.matchOrdersWithFees(m, makerSig, t, takerSig, 100 ether);
  }

  function testOrderValidBeforeExpiration() public {
    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    uint256 expiry = block.timestamp + 1 hours;

    MyriadCTFExchange.Order memory m = MyriadCTFExchange.Order({
      trader:        maker,
      marketId:      marketId,
      outcomeId:     uint8(Outcomes.YES),
      side:          MyriadCTFExchange.Side.Buy,
      amount:        100 ether,
      price:         (60 * ONE) / 100,
      minFillAmount: 0,
      nonce:         452,
      expiration:    expiry
    });
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 100 ether, (40 * ONE) / 100, 453);

    bytes memory makerSig = _signOrder(m, makerPk);
    bytes memory takerSig = _signOrder(t, takerPk);

    // One second before expiry — order should succeed
    vm.warp(expiry - 1);
    exchange.matchOrdersWithFees(m, makerSig, t, takerSig, 100 ether);
  }

  // =========================================================================
  // Order matching validation
  // =========================================================================

  function testMarketMismatchReverts() public {
    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    // Create a second market so we have two valid market IDs
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params =
      PredictionMarketV3ManagerCLOB.CreateMarketParams({
        closesAt:   block.timestamp + 1 days,
        question:   "Second market?",
        image:      "ipfs://img2",
        feeModule:  address(feeModule),
        oracle:     address(0),
        oracleData: ""
      });
    uint256 market2 = manager.createMarket(params);
    _setUniformFees(market2, 100, 200);

    uint256 amount = 100 ether;
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, (60 * ONE) / 100, 500);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, market2, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, (40 * ONE) / 100, 501);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert(MyriadCTFExchange.MarketMismatch.selector);
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  function testDirectMatchMakerSellerTakerBuyer() public {
    // maker = SELL outcome0, taker = BUY outcome0
    uint256 amount = 50 ether;
    uint256 price  = (55 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    // Maker must have outcome0 tokens to sell
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, amount);

    uint256 outcome0Id = (marketId << 1) | Outcomes.YES;
    assertEq(conditionalTokens.balanceOf(maker, outcome0Id), amount);

    MyriadCTFExchange.Order memory sellOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 510);
    MyriadCTFExchange.Order memory buyOrder  = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy,  amount, price, 511);

    bytes memory sellSig = _signOrder(sellOrder, makerPk);
    bytes memory buySig  = _signOrder(buyOrder,  takerPk);

    uint256 notional   = (amount * price) / ONE;
    uint256 sellerFee  = (notional * 100) / BPS; // maker fee bps = 100
    uint256 buyerFee   = (notional * 200) / BPS; // taker fee bps = 200

    uint256 makerColBefore = collateral.balanceOf(maker);
    uint256 takerColBefore = collateral.balanceOf(taker);

    exchange.matchOrdersWithFees(sellOrder, sellSig, buyOrder, buySig, amount);

    // Seller (maker): tokens gone, received notional - sellerFee
    assertEq(conditionalTokens.balanceOf(maker, outcome0Id), 0);
    assertEq(collateral.balanceOf(maker), makerColBefore + notional - sellerFee);

    // Buyer (taker): paid notional + buyerFee, received tokens
    assertEq(conditionalTokens.balanceOf(taker, outcome0Id), amount);
    assertEq(collateral.balanceOf(taker), takerColBefore - notional - buyerFee);
  }

  function testDirectMatchBuyPriceLessThanSellPriceReverts() public {
    uint256 amount    = 50 ether;
    uint256 buyPrice  = (40 * ONE) / 100;
    uint256 sellPrice = (50 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    vm.stopPrank();

    // BUY maker vs SELL taker: require maker.price >= taker.price
    MyriadCTFExchange.Order memory buyOrder  = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy,  amount, buyPrice,  520);
    MyriadCTFExchange.Order memory sellOrder = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, sellPrice, 521);

    bytes memory buySig  = _signOrder(buyOrder,  makerPk);
    bytes memory sellSig = _signOrder(sellOrder, takerPk);

    vm.expectRevert(MyriadCTFExchange.PriceMismatch.selector);
    exchange.matchOrdersWithFees(buyOrder, buySig, sellOrder, sellSig, amount);
  }

  function testDirectMatchOutcomeMismatchReverts() public {
    // maker BUY outcome0, taker SELL outcome1 => outcome mismatch
    uint256 amount = 50 ether;
    uint256 price  = (50 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    vm.stopPrank();

    MyriadCTFExchange.Order memory buyOrder  = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy,  amount, price, 530);
    MyriadCTFExchange.Order memory sellOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Sell, amount, price, 531);

    bytes memory buySig  = _signOrder(buyOrder,  makerPk);
    bytes memory sellSig = _signOrder(sellOrder, takerPk);

    vm.expectRevert(MyriadCTFExchange.OutcomeMismatch.selector);
    exchange.matchOrdersWithFees(buyOrder, buySig, sellOrder, sellSig, amount);
  }

  function testMintMatchPriceSumBelowOneReverts() public {
    uint256 amount = 100 ether;
    // prices sum to 0.9 instead of 1.0
    uint256 outcome0Price = (50 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 540);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 541);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert(MyriadCTFExchange.PriceSumBelowOne.selector);
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  function testMergeMatchPriceSumAboveOneReverts() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (50 * ONE) / 100;
    uint256 outcome1Price = (60 * ONE) / 100; // sum = 1.1, not 1.0

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, amount);
    vm.prank(taker);
    conditionalTokens.splitPosition(marketId, amount);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, outcome0Price, 550);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Sell, amount, outcome1Price, 551);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert(MyriadCTFExchange.PriceSumAboveOne.selector);
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  // =========================================================================
  // Mint match — success paths
  // =========================================================================

  /// @dev maker BUY outcome0 @ 60c, taker BUY outcome1 @ 40c.
  ///      Verifies both buyers receive the correct outcome tokens, pay the correct
  ///      collateral (notional + role-based fee), and that the event is emitted.
  function testMintMatchSuccess() public {
    uint256 fillAmount = 100 ether;
    uint256 makerPrice = (60 * ONE) / 100;
    uint256 takerPrice = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, makerPrice, 600);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, fillAmount, takerPrice, 601);

    // Fee math: makerBps=100, takerBps=200 (set in setUp)
    uint256 makerNotional = (fillAmount * makerPrice) / ONE; // 60e18
    uint256 takerNotional = fillAmount - makerNotional;       // 40e18
    uint256 makerFee      = (makerNotional * 100) / BPS;     // 0.6e18
    uint256 takerFee      = (takerNotional * 200) / BPS;     // 0.8e18

    uint256 makerColBefore = collateral.balanceOf(maker);
    uint256 takerColBefore = collateral.balanceOf(taker);

    bytes32 mHash = exchange.hashOrder(m);
    bytes32 tHash = exchange.hashOrder(t);

    vm.expectEmit(true, true, true, true, address(exchange));
    emit MyriadCTFExchange.OrdersMatched(
      mHash, tHash,
      maker, taker, marketId,
      1,           // matchType = mint
      fillAmount,
      fillAmount,  // makerAmountFilled (cumulative)
      fillAmount,  // takerAmountFilled (cumulative)
      makerFee, takerFee
    );
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), fillAmount);

    // Maker paid (makerNotional + makerFee), received outcome0 tokens
    assertEq(collateral.balanceOf(maker), makerColBefore - makerNotional - makerFee);
    assertEq(conditionalTokens.balanceOf(maker, conditionalTokens.getTokenId(marketId, Outcomes.YES)), fillAmount);

    // Taker paid (takerNotional + takerFee), received outcome1 tokens
    assertEq(collateral.balanceOf(taker), takerColBefore - takerNotional - takerFee);
    assertEq(conditionalTokens.balanceOf(taker, conditionalTokens.getTokenId(marketId, Outcomes.NO)), fillAmount);

    // Fees forwarded to feeModule
    assertEq(collateral.balanceOf(address(feeModule)), makerFee + takerFee);

    // filledAmounts updated for both orders
    (uint256 mFilled, ) = exchange.getOrderStatus(mHash);
    (uint256 tFilled, ) = exchange.getOrderStatus(tHash);
    assertEq(mFilled, fillAmount);
    assertEq(tFilled, fillAmount);
  }

  /// @dev Mint match with priceSum > ONE: the taker's limit (0.50) exceeds the
  ///      complement of the maker's price (1 − 0.60 = 0.40). The taker must be
  ///      charged the COMPLEMENT, capturing the price improvement — the same
  ///      convention matchCrossMarketOrders follows for its taker leg. Guards
  ///      the behavior enabled by ebaecc1 (allow mint above one), previously
  ///      only exercised at priceSum == ONE where the two formulas coincide.
  function testMintMatchTakerPriceImprovement() public {
    uint256 fillAmount = 100 ether;
    uint256 makerPrice = (60 * ONE) / 100;
    uint256 takerPrice = (50 * ONE) / 100; // sum 1.10 — crossed by 0.10

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, makerPrice, 650);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, fillAmount, takerPrice, 651);

    uint256 makerNotional = (fillAmount * makerPrice) / ONE; // 60e18
    uint256 takerNotional = fillAmount - makerNotional;      // 40e18, NOT 50e18
    uint256 makerFee      = (makerNotional * 100) / BPS;
    uint256 takerFee      = (takerNotional * 200) / BPS;

    uint256 makerColBefore = collateral.balanceOf(maker);
    uint256 takerColBefore = collateral.balanceOf(taker);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), fillAmount);

    assertEq(collateral.balanceOf(maker), makerColBefore - makerNotional - makerFee, "maker pays limit notional");
    assertEq(collateral.balanceOf(taker), takerColBefore - takerNotional - takerFee, "taker pays complement, not limit");
    assertEq(conditionalTokens.balanceOf(maker, conditionalTokens.getTokenId(marketId, Outcomes.YES)), fillAmount);
    assertEq(conditionalTokens.balanceOf(taker, conditionalTokens.getTokenId(marketId, Outcomes.NO)), fillAmount);
    assertEq(collateral.balanceOf(address(feeModule)), makerFee + takerFee, "fees only, no surplus");
    assertEq(collateral.balanceOf(address(exchange)), 0, "exchange has no stuck collateral");
  }

  /// @dev Two sequential partial fills of the same mint-match orders.
  ///      Confirms cumulative filledAmounts and token balances accumulate correctly.
  function testMintMatchPartialFill() public {
    uint256 orderSize  = 200 ether;
    uint256 firstFill  = 80 ether;
    uint256 secondFill = 60 ether;
    uint256 makerPrice = (60 * ONE) / 100;
    uint256 takerPrice = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, orderSize, makerPrice, 610);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, orderSize, takerPrice, 611);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    exchange.matchOrdersWithFees(m, mSig, t, tSig, firstFill);
    exchange.matchOrdersWithFees(m, mSig, t, tSig, secondFill);

    bytes32 mHash = exchange.hashOrder(m);
    bytes32 tHash = exchange.hashOrder(t);
    (uint256 mFilled, ) = exchange.getOrderStatus(mHash);
    (uint256 tFilled, ) = exchange.getOrderStatus(tHash);
    assertEq(mFilled, firstFill + secondFill);
    assertEq(tFilled, firstFill + secondFill);

    // Each buyer has accumulated tokens across both fills
    assertEq(conditionalTokens.balanceOf(maker, conditionalTokens.getTokenId(marketId, Outcomes.YES)), firstFill + secondFill);
    assertEq(conditionalTokens.balanceOf(taker, conditionalTokens.getTokenId(marketId, Outcomes.NO)), firstFill + secondFill);
  }

  // =========================================================================
  // Merge match — success paths
  // =========================================================================

  /// @dev maker SELL outcome0 @ 60c, taker SELL outcome1 @ 40c.
  ///      Verifies outcome tokens are burned, each seller receives notional minus
  ///      their role-based fee, and fees reach the feeModule.
  function testMergeMatchSuccess() public {
    uint256 fillAmount = 100 ether;
    uint256 makerPrice = (60 * ONE) / 100;
    uint256 takerPrice = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    // Each trader splits to obtain both outcome tokens; each will sell one side.
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, fillAmount);
    vm.prank(taker);
    conditionalTokens.splitPosition(marketId, fillAmount);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, fillAmount, makerPrice, 700);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Sell, fillAmount, takerPrice, 701);

    // Fee math: makerBps=100, takerBps=200
    uint256 makerNotional = (fillAmount * makerPrice) / ONE; // 60e18
    uint256 takerNotional = fillAmount - makerNotional;       // 40e18
    uint256 makerFee      = (makerNotional * 100) / BPS;     // 0.6e18
    uint256 takerFee      = (takerNotional * 200) / BPS;     // 0.8e18

    // Measure collateral after splits (each paid fillAmount for their tokens)
    uint256 makerColBefore = collateral.balanceOf(maker);
    uint256 takerColBefore = collateral.balanceOf(taker);

    bytes32 mHash = exchange.hashOrder(m);
    bytes32 tHash = exchange.hashOrder(t);

    vm.expectEmit(true, true, true, true, address(exchange));
    emit MyriadCTFExchange.OrdersMatched(
      mHash, tHash,
      maker, taker, marketId,
      2,           // matchType = merge
      fillAmount,
      fillAmount,  // makerAmountFilled (cumulative)
      fillAmount,  // takerAmountFilled (cumulative)
      makerFee, takerFee
    );
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), fillAmount);

    // Outcome tokens burned by the exchange during merge
    assertEq(conditionalTokens.balanceOf(maker, conditionalTokens.getTokenId(marketId, Outcomes.YES)), 0);
    assertEq(conditionalTokens.balanceOf(taker, conditionalTokens.getTokenId(marketId, Outcomes.NO)), 0);

    // Maker (outcome0 seller) receives makerNotional - makerFee
    assertEq(collateral.balanceOf(maker), makerColBefore + makerNotional - makerFee);

    // Taker (outcome1 seller) receives takerNotional - takerFee
    assertEq(collateral.balanceOf(taker), takerColBefore + takerNotional - takerFee);

    // Fees forwarded to feeModule
    assertEq(collateral.balanceOf(address(feeModule)), makerFee + takerFee);
  }

  /// @dev maker SELL outcome1 @ 40c, taker SELL outcome0 @ 60c (reversed outcome roles).
  ///      Verifies the outcome0/outcome1 ordering logic inside _settleMergeMatch correctly
  ///      maps each seller to their proceeds regardless of who is maker vs taker.
  function testMergeMatchMakerHoldsOutcome1() public {
    uint256 fillAmount = 100 ether;
    uint256 makerPrice = (40 * ONE) / 100; // maker sells outcome1 @ 40c
    uint256 takerPrice = (60 * ONE) / 100; // taker sells outcome0 @ 60c

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, fillAmount);
    vm.prank(taker);
    conditionalTokens.splitPosition(marketId, fillAmount);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Sell, fillAmount, makerPrice, 800);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, fillAmount, takerPrice, 801);

    // Fee math: makerBps=100, takerBps=200
    // _paySellerWithFees uses (fillAmount * maker.price) for makerNotional
    uint256 makerNotional = (fillAmount * makerPrice) / ONE; // 40e18
    uint256 takerNotional = fillAmount - makerNotional;       // 60e18
    uint256 makerFee      = (makerNotional * 100) / BPS;     // 0.4e18
    uint256 takerFee      = (takerNotional * 200) / BPS;     // 1.2e18

    uint256 makerColBefore = collateral.balanceOf(maker);
    uint256 takerColBefore = collateral.balanceOf(taker);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), fillAmount);

    // Outcome tokens burned by the exchange during merge
    assertEq(conditionalTokens.balanceOf(maker, conditionalTokens.getTokenId(marketId, Outcomes.NO)), 0);
    assertEq(conditionalTokens.balanceOf(taker, conditionalTokens.getTokenId(marketId, Outcomes.YES)), 0);

    // Proceeds = each seller's outcome notional minus their role fee.
    // Because prices sum to 1: makerNotional == outcome1Notional, takerNotional == outcome0Notional.
    assertEq(collateral.balanceOf(maker), makerColBefore + makerNotional - makerFee);
    assertEq(collateral.balanceOf(taker), takerColBefore + takerNotional - takerFee);

    // Fees forwarded to feeModule
    assertEq(collateral.balanceOf(address(feeModule)), makerFee + takerFee);
  }

  // =========================================================================
  // Gas-capped ERC-1155 transfers
  // =========================================================================

  /// @dev Simulate EIP-7702: an EOA signs an order normally (ECDSA), then gets
  ///      griefing code etched onto it. When safeTransferFrom delivers tokens,
  ///      the callback fires but gas is capped by _safeTransferWithGasCap.
  function testGasGriefingEIP7702BoundedInMintMatch() public {
    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    _approveAll(maker);
    _approveAll(taker);

    uint256 amount = 50 ether;
    uint256 makerPrice = (60 * ONE) / 100;
    uint256 takerPrice = (40 * ONE) / 100;

    // Maker signs order as a normal EOA
    MyriadCTFExchange.Order memory m = _buildOrder(
      maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, makerPrice, 900
    );
    MyriadCTFExchange.Order memory t = _buildOrder(
      taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, takerPrice, 901
    );

    bytes memory makerSig = _signOrder(m, makerPk);
    bytes memory takerSig = _signOrder(t, takerPk);

    // Simulate EIP-7702: etch griefing code onto maker's EOA address.
    // Now maker.code.length > 0, so safeTransferFrom will call onERC1155Received.
    GasGriefingWallet griefer = new GasGriefingWallet();
    vm.etch(maker, address(griefer).code);

    uint256 gasBefore = gasleft();
    exchange.matchOrdersWithFees(m, makerSig, t, takerSig, amount);
    uint256 gasUsed = gasBefore - gasleft();

    // Match succeeded — maker received tokens despite griefing callback
    uint256 tokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    assertEq(conditionalTokens.balanceOf(maker, tokenId), amount);

    // Gas bounded — without the cap, the griefing callback would consume
    // millions of gas writing to storage. With the cap, total stays under 1M.
    assertLt(gasUsed, 1_000_000);
  }
}
