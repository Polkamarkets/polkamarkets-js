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
import "../contracts/IMarketOracle.sol";

contract MockERC20 is ERC20 {
  constructor() ERC20("Collateral", "COL") {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @dev A controllable oracle for testing. Allows setting the result externally.
contract MockOracle is IMarketOracle {
  struct Result {
    int256 outcome;
    bool resolved;
    bool initialized;
  }

  mapping(uint256 => Result) public results;

  function initialize(uint256 marketId, bytes calldata) external override {
    results[marketId].initialized = true;
  }

  function getResult(uint256 marketId) external view override returns (int256 outcome, bool resolved) {
    Result storage r = results[marketId];
    return (r.outcome, r.resolved);
  }

  function setResult(uint256 marketId, int256 outcome, bool resolved) external {
    results[marketId] = Result({outcome: outcome, resolved: resolved, initialized: true});
  }
}

contract PredictionMarketCLOBTest is Test {
  uint256 private constant ONE = 1e18;
  uint256 private constant BPS = 10000;

  AdminRegistry internal registry;
  PredictionMarketV3ManagerCLOB internal manager;
  ConditionalTokens internal conditionalTokens;
  MyriadCTFExchange internal exchange;
  FeeModule internal feeModule;
  MockERC20 internal collateral;
  MockOracle internal oracle;

  address internal admin;
  address internal operator;
  address internal maker;
  address internal taker;
  address internal treasury;

  uint256 internal makerPk = 0xA11CE;
  uint256 internal takerPk = 0xB0B;

  uint256 internal marketId;

  function setUp() public {
    admin = address(this);
    operator = address(this);
    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);
    treasury = address(0xBEEF);

    collateral = new MockERC20();
    oracle = new MockOracle();

    registry = new AdminRegistry(admin);

    // Deploy Manager via UUPS proxy
    PredictionMarketV3ManagerCLOB managerImpl = new PredictionMarketV3ManagerCLOB();
    ERC1967Proxy managerProxy = new ERC1967Proxy(
      address(managerImpl),
      abi.encodeCall(PredictionMarketV3ManagerCLOB.initialize, (registry, IERC20(address(collateral))))
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
        IMyriadMarketManager(address(manager)), conditionalTokens, address(feeModule), registry
      ))
    );
    exchange = MyriadCTFExchange(address(exchangeProxy));

    feeModule.setExchange(address(exchange));

    registry.grantRole(registry.MARKET_ADMIN_ROLE(), admin);
    registry.grantRole(registry.FEE_ADMIN_ROLE(), admin);
    registry.grantRole(registry.OPERATOR_ROLE(), operator);
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), admin);

    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "Will it rain?",
      image: "ipfs://img",
      feeModule: address(feeModule),
      oracle: address(oracle),
      oracleData: abi.encode("init")
    });
    marketId = manager.createMarket(params);

    _setUniformFees(marketId, 100, 200);
  }

  // =========================================================================
  // Full-fill tests
  // =========================================================================

  function testMintMatchBuys() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 1);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 2);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    exchange.matchOrdersWithFees(makerOrder, _signOrder(makerOrder, makerPk), takerOrder, _signOrder(takerOrder, takerPk), amount);

    uint256 makerNotional = (amount * outcome0Price) / ONE;
    uint256 takerNotional = amount - makerNotional;

    uint256 makerFee = (makerNotional * 100) / BPS;
    uint256 takerFee = (takerNotional * 200) / BPS;
    uint256 totalFees = makerFee + takerFee;

    // Fees added on top of notional — full shares minted
    assertEq(collateral.balanceOf(maker), makerBefore - makerNotional - makerFee);
    assertEq(collateral.balanceOf(taker), takerBefore - takerNotional - takerFee);

    uint256 outcome0TokenId = (marketId << 1) | 0;
    uint256 outcome1TokenId = (marketId << 1) | 1;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), amount);
    assertEq(conditionalTokens.balanceOf(taker, outcome1TokenId), amount);

    assertEq(collateral.balanceOf(address(feeModule)), totalFees);
  }

  function testDirectMatchBuySell() public {
    uint256 amount = 50 ether;
    uint256 outcome0Price = (55 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    conditionalTokens.splitPosition(marketId, amount);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    uint256 outcome0TokenId = (marketId << 1) | 0;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), amount);

    MyriadCTFExchange.Order memory sellOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Sell, amount, outcome0Price, 20);
    MyriadCTFExchange.Order memory buyOrder = _buildOrder(taker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 21);
    exchange.matchOrdersWithFees(sellOrder, _signOrder(sellOrder, makerPk), buyOrder, _signOrder(buyOrder, takerPk), amount);

    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), 0);
    assertEq(conditionalTokens.balanceOf(taker, outcome0TokenId), amount);
  }

  function testMergeMatchSells() public {
    uint256 amount = 80 ether;
    uint256 outcome0Price = (50 * ONE) / 100;
    uint256 outcome1Price = (50 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, amount);
    vm.prank(taker);
    conditionalTokens.splitPosition(marketId, amount);

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Sell, amount, outcome0Price, 30);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Sell, amount, outcome1Price, 31);
    exchange.matchOrdersWithFees(makerOrder, _signOrder(makerOrder, makerPk), takerOrder, _signOrder(takerOrder, takerPk), amount);

    uint256 outcome0TokenId = (marketId << 1) | 0;
    uint256 outcome1TokenId = (marketId << 1) | 1;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), 0);
    assertEq(conditionalTokens.balanceOf(taker, outcome1TokenId), 0);
  }

  // =========================================================================
  // Partial-fill tests
  // =========================================================================

  function testPartialFillMint() public {
    uint256 amount = 100 ether;
    uint256 fill = 40 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 40);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 41);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fill);

    uint256 outcome0TokenId = (marketId << 1) | 0;
    uint256 outcome1TokenId = (marketId << 1) | 1;

    // Full shares minted — fees added on top
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), fill);
    assertEq(conditionalTokens.balanceOf(taker, outcome1TokenId), fill);

    bytes32 makerHash = exchange.hashOrder(makerOrder);
    bytes32 takerHash = exchange.hashOrder(takerOrder);
    assertEq(exchange.filledAmounts(makerHash), fill);
    assertEq(exchange.filledAmounts(takerHash), fill);
  }

  function testPartialFillThenSecondFill() public {
    uint256 amount = 100 ether;
    uint256 fill1 = 40 ether;
    uint256 fill2 = 60 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 50);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 51);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fill1);
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fill2);

    uint256 totalFill = fill1 + fill2;

    uint256 outcome0TokenId = (marketId << 1) | 0;
    uint256 outcome1TokenId = (marketId << 1) | 1;

    // Full shares minted for each fill
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), totalFill);
    assertEq(conditionalTokens.balanceOf(taker, outcome1TokenId), totalFill);

    bytes32 makerHash = exchange.hashOrder(makerOrder);
    assertEq(exchange.filledAmounts(makerHash), totalFill);
  }

  function testOverfillReverts() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 60);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 61);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    vm.expectRevert("maker overfill");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 2 ether);
  }

  function testPartialFillDirect() public {
    uint256 amount = 100 ether;
    uint256 fill = 30 ether;
    uint256 outcome0Price = (55 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    conditionalTokens.splitPosition(marketId, amount);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory sellOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Sell, amount, outcome0Price, 80);
    MyriadCTFExchange.Order memory buyOrder = _buildOrder(taker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 81);

    exchange.matchOrdersWithFees(sellOrder, _signOrder(sellOrder, makerPk), buyOrder, _signOrder(buyOrder, takerPk), fill);

    uint256 outcome0TokenId = (marketId << 1) | 0;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), amount - fill);
    assertEq(conditionalTokens.balanceOf(taker, outcome0TokenId), fill);
  }

  // =========================================================================
  // Cancellation tests
  // =========================================================================

  function testCancelThenFillReverts() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 90);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 91);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = makerOrder;
    vm.prank(maker);
    exchange.cancelOrders(toCancel);

    vm.expectRevert("invalidated");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testPartialFillThenCancelThenFillReverts() public {
    uint256 amount = 100 ether;
    uint256 fill1 = 40 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 100);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 101);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fill1);

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = makerOrder;
    vm.prank(maker);
    exchange.cancelOrders(toCancel);

    vm.expectRevert("invalidated");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fill1);
  }

  function testCancelAlreadyCancelledReverts() public {
    MyriadCTFExchange.Order memory order = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, 10 ether, (50 * ONE) / 100, 110);

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = order;

    vm.startPrank(maker);
    exchange.cancelOrders(toCancel);

    vm.expectRevert("already cancelled");
    exchange.cancelOrders(toCancel);
    vm.stopPrank();
  }

  function testCancelSomeoneElsesOrderReverts() public {
    MyriadCTFExchange.Order memory order = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, 10 ether, (50 * ONE) / 100, 120);

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = order;

    vm.prank(taker);
    vm.expectRevert("not trader");
    exchange.cancelOrders(toCancel);
  }

  // =========================================================================
  // Edge cases
  // =========================================================================

  function testSelfTradeReverts() public {
    uint256 amount = 10 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory order1 = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 130);
    MyriadCTFExchange.Order memory order2 = _buildOrder(maker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 131);

    bytes memory sig1 = _signOrder(order1, makerPk);
    bytes memory sig2 = _signOrder(order2, makerPk);

    vm.expectRevert("self trade");
    exchange.matchOrdersWithFees(order1, sig1, order2, sig2, amount);
  }

  function testExpiredOrderReverts() public {
    uint256 amount = 10 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = MyriadCTFExchange.Order({
      trader: maker,
      marketId: marketId,
      outcomeId: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: outcome0Price,
      minFillAmount: 0,
      nonce: 140,
      expiration: block.timestamp + 1
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 141);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.warp(block.timestamp + 2);

    vm.expectRevert("expired");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testMarketIndexStartsAt1() public view {
    assertEq(marketId, 1);
  }

  function testFillAmountOneWeiReverts() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 150);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 151);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("notional 0");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 1);
  }

  function testZeroFeeMarket() public {
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "Zero fee market?",
      image: "ipfs://img2",
      feeModule: address(feeModule),
      oracle: address(oracle),
      oracleData: abi.encode("init")
    });
    uint256 zeroFeeMarketId = manager.createMarket(params);
    _setUniformFees(zeroFeeMarketId, 0, 0);

    uint256 amount = 50 ether;
    uint256 outcome0Price = (70 * ONE) / 100;
    uint256 outcome1Price = (30 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, zeroFeeMarketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 170);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, zeroFeeMarketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 171);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    exchange.matchOrdersWithFees(makerOrder, _signOrder(makerOrder, makerPk), takerOrder, _signOrder(takerOrder, takerPk), amount);

    uint256 makerNotional = (amount * outcome0Price) / ONE;
    uint256 takerNotional = amount - makerNotional;

    assertEq(collateral.balanceOf(maker), makerBefore - makerNotional);
    assertEq(collateral.balanceOf(taker), takerBefore - takerNotional);
    assertEq(feeModule.accruedFees(address(collateral)), 0);
    assertEq(collateral.balanceOf(address(feeModule)), 0);
  }

  function testOverlappingPricesDirectMatch() public {
    uint256 amount = 20 ether;
    uint256 outcome0Price = (70 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.prank(taker);
    conditionalTokens.splitPosition(marketId, amount);

    MyriadCTFExchange.Order memory buyOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 182);
    MyriadCTFExchange.Order memory sellOrder = _buildOrder(taker, marketId, 0, MyriadCTFExchange.Side.Sell, amount, (50 * ONE) / 100, 183);

    exchange.matchOrdersWithFees(buyOrder, _signOrder(buyOrder, makerPk), sellOrder, _signOrder(sellOrder, takerPk), amount);

    uint256 outcome0TokenId = (marketId << 1) | 0;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), amount);
    assertEq(conditionalTokens.balanceOf(taker, outcome0TokenId), 0);
  }

  function testClosedMarketReverts() public {
    uint256 amount = 10 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    vm.warp(block.timestamp + 2 days);

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 190);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 191);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("market closed");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testResolvedMarketReverts() public {
    uint256 amount = 10 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.stopPrank();

    manager.adminResolveMarket(marketId, 0);

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 200);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 201);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("market closed");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testAdminResolveInvalidOutcomeReverts() public {
    vm.expectRevert("invalid outcome");
    manager.adminResolveMarket(marketId, 2);

    vm.expectRevert("invalid outcome");
    manager.adminResolveMarket(marketId, -2);

    vm.expectRevert("invalid outcome");
    manager.adminResolveMarket(marketId, -1);
  }

  function testAdminVoidMarket() public {
    uint256 outcome0Payout = (60 * ONE) / 100;
    uint256 outcome1Payout = ONE - outcome0Payout;

    int256 result = manager.adminVoidMarket(marketId, outcome0Payout, outcome1Payout);
    assertEq(result, -1);

    assertEq(uint8(manager.getMarketState(marketId)), uint8(IMyriadMarketManager.MarketState.resolved));
    assertEq(manager.getMarketResolvedOutcome(marketId), -1);

    (uint256 storedOutcome0, uint256 storedOutcome1) = manager.getVoidedPayouts(marketId);
    assertEq(storedOutcome0, outcome0Payout);
    assertEq(storedOutcome1, outcome1Payout);
  }

  function testAdminVoidMarketBadPayoutsReverts() public {
    vm.expectRevert("payouts must sum to 1e18");
    manager.adminVoidMarket(marketId, (50 * ONE) / 100, (60 * ONE) / 100);

    vm.expectRevert("payouts must sum to 1e18");
    manager.adminVoidMarket(marketId, 0, 0);
  }

  function testRedeemVoided5050() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 210);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 211);
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), amount);

    // Full shares minted with new fee model
    manager.adminVoidMarket(marketId, (50 * ONE) / 100, (50 * ONE) / 100);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    vm.prank(maker);
    conditionalTokens.redeemVoided(marketId);
    vm.prank(taker);
    conditionalTokens.redeemVoided(marketId);

    assertEq(collateral.balanceOf(maker), makerBefore + (amount * 50) / 100);
    assertEq(collateral.balanceOf(taker), takerBefore + (amount * 50) / 100);
  }

  function testRedeemVoidedAsymmetric() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 220);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 221);
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), amount);

    // Full shares minted with new fee model
    uint256 outcome0Payout = (70 * ONE) / 100;
    uint256 outcome1Payout = ONE - outcome0Payout;
    manager.adminVoidMarket(marketId, outcome0Payout, outcome1Payout);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    vm.prank(maker);
    conditionalTokens.redeemVoided(marketId);
    vm.prank(taker);
    conditionalTokens.redeemVoided(marketId);

    assertEq(collateral.balanceOf(maker), makerBefore + (amount * 70) / 100);
    assertEq(collateral.balanceOf(taker), takerBefore + (amount * 30) / 100);
  }

  function testRedeemVoidedBothSides() public {
    uint256 amount = 100 ether;

    collateral.mint(maker, 1000 ether);
    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    vm.stopPrank();

    uint256 outcome0Payout = (60 * ONE) / 100;
    uint256 outcome1Payout = ONE - outcome0Payout;
    manager.adminVoidMarket(marketId, outcome0Payout, outcome1Payout);

    uint256 makerBefore = collateral.balanceOf(maker);

    vm.prank(maker);
    conditionalTokens.redeemVoided(marketId);

    assertEq(collateral.balanceOf(maker), makerBefore + amount);
  }

  function testRedeemVoidedNoBalanceReverts() public {
    manager.adminVoidMarket(marketId, (50 * ONE) / 100, (50 * ONE) / 100);

    vm.prank(maker);
    vm.expectRevert("no balance");
    conditionalTokens.redeemVoided(marketId);
  }

  function testRedeemVoidedNotVoidedReverts() public {
    manager.adminResolveMarket(marketId, 0);

    vm.prank(maker);
    vm.expectRevert("not voided");
    conditionalTokens.redeemVoided(marketId);
  }

  function testRedeemVoidedDoubleRedeemReverts() public {
    uint256 amount = 100 ether;

    collateral.mint(maker, 1000 ether);
    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    vm.stopPrank();

    manager.adminVoidMarket(marketId, (50 * ONE) / 100, (50 * ONE) / 100);

    vm.prank(maker);
    conditionalTokens.redeemVoided(marketId);

    vm.prank(maker);
    vm.expectRevert("no balance");
    conditionalTokens.redeemVoided(marketId);
  }

  function testFillZeroReverts() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 240);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 241);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("fill 0");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 0);
  }

  function testDustFreeNotionals() public {
    uint256 amount = 33 ether;
    uint256 outcome0Price = (33 * ONE) / 100;
    uint256 outcome1Price = (67 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 250);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 251);

    exchange.matchOrdersWithFees(makerOrder, _signOrder(makerOrder, makerPk), takerOrder, _signOrder(takerOrder, takerPk), amount);

    // Full shares minted — fees added on top
    uint256 outcome0TokenId = (marketId << 1) | 0;
    uint256 outcome1TokenId = (marketId << 1) | 1;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), amount);
    assertEq(conditionalTokens.balanceOf(taker, outcome1TokenId), amount);
  }

  function testPausedMarketReverts() public {
    uint256 amount = 10 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    manager.pauseMarket(marketId, true);

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 260);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 261);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("market paused");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    manager.pauseMarket(marketId, false);

    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  // =========================================================================
  // Fee withdrawal tests
  // =========================================================================

  function testWithdrawFees() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 300);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 301);
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), amount);

    uint256 totalFees = collateral.balanceOf(address(feeModule));
    assertTrue(totalFees > 0, "fees should be > 0");

    feeModule.withdrawFees(address(collateral), totalFees);

    assertEq(collateral.balanceOf(treasury), totalFees);
    assertEq(collateral.balanceOf(address(feeModule)), 0);
    assertEq(feeModule.accruedFees(address(collateral)), 0);
  }

  function testWithdrawNoFeesReverts() public {
    vm.expectRevert("insufficient fees");
    feeModule.withdrawFees(address(collateral), 1);
  }

  function testSetTreasuryToZeroReverts() public {
    vm.expectRevert("treasury 0");
    feeModule.setTreasury(address(0));
  }

  function testWithdrawNotFeeAdminReverts() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 320);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 321);
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), amount);

    uint256 totalFees = collateral.balanceOf(address(feeModule));
    vm.prank(maker);
    vm.expectRevert("not fee admin");
    feeModule.withdrawFees(address(collateral), totalFees);
  }

  function testFeesAccumulateAcrossMultipleMatches() public {
    uint256 amount = 50 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 5000 ether);
    collateral.mint(taker, 5000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 400);
    MyriadCTFExchange.Order memory t1 = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 401);
    exchange.matchOrdersWithFees(m1, _signOrder(m1, makerPk), t1, _signOrder(t1, takerPk), amount);

    uint256 feesAfterFirst = collateral.balanceOf(address(feeModule));
    assertTrue(feesAfterFirst > 0, "should have fees after first match");

    MyriadCTFExchange.Order memory m2 = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 402);
    MyriadCTFExchange.Order memory t2 = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 403);
    exchange.matchOrdersWithFees(m2, _signOrder(m2, makerPk), t2, _signOrder(t2, takerPk), amount);

    uint256 feesAfterSecond = collateral.balanceOf(address(feeModule));
    assertEq(feesAfterSecond, feesAfterFirst * 2);

    uint256 totalAccrued = feeModule.accruedFees(address(collateral));
    assertEq(totalAccrued, feesAfterSecond);

    feeModule.withdrawFees(address(collateral), totalAccrued);
    assertEq(collateral.balanceOf(treasury), totalAccrued);
    assertEq(collateral.balanceOf(address(feeModule)), 0);
  }

  // =========================================================================
  // Oracle resolution tests
  // =========================================================================

  function testOracleResolveMarket() public {
    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketId, 0, true);
    int256 result = manager.resolveMarket(marketId);
    assertEq(result, 0);
    assertEq(uint8(manager.getMarketState(marketId)), uint8(IMyriadMarketManager.MarketState.resolved));
    assertEq(manager.getMarketResolvedOutcome(marketId), 0);
  }

  function testOracleResolveOutcome1() public {
    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketId, 1, true);
    int256 result = manager.resolveMarket(marketId);
    assertEq(result, 1);
    assertEq(manager.getMarketResolvedOutcome(marketId), 1);
  }

  function testOracleNotResolvedReverts() public {
    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketId, 0, false);

    vm.expectRevert("oracle: not resolved");
    manager.resolveMarket(marketId);
  }

  function testOracleInvalidOutcomeReverts() public {
    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketId, 5, true);

    vm.expectRevert("invalid outcome");
    manager.resolveMarket(marketId);
  }

  function testResolveMarketNotClosedReverts() public {
    oracle.setResult(marketId, 0, true);

    vm.expectRevert("!closed");
    manager.resolveMarket(marketId);
  }

  function testResolveMarketNoOracleReverts() public {
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "No oracle market",
      image: "",
      feeModule: address(feeModule),
      oracle: address(0),
      oracleData: ""
    });
    uint256 noOracleMarket = manager.createMarket(params);

    vm.warp(block.timestamp + 2 days);

    vm.expectRevert("no oracle");
    manager.resolveMarket(noOracleMarket);
  }

  function testAdminResolveBypassesOracle() public {
    oracle.setResult(marketId, 1, true);

    int256 result = manager.adminResolveMarket(marketId, 0);
    assertEq(result, 0);
    assertEq(manager.getMarketResolvedOutcome(marketId), 0);
  }

  function testAdminResolveBeforeCloseRevertsForNonDefaultAdmin() public {
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), maker);

    vm.prank(maker);
    vm.expectRevert("market not closed");
    manager.adminResolveMarket(marketId, 0);
  }

  function testAdminResolveAfterCloseSucceedsForResolutionAdmin() public {
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), maker);

    vm.warp(block.timestamp + 2 days);
    vm.prank(maker);
    int256 result = manager.adminResolveMarket(marketId, 0);
    assertEq(result, 0);
  }

  function testUpdateMarketOracle() public {
    MockOracle newOracle = new MockOracle();

    manager.updateMarketOracle(marketId, address(newOracle), abi.encode("new init"));
    assertEq(manager.getMarketOracle(marketId), address(newOracle));

    vm.warp(block.timestamp + 2 days);
    newOracle.setResult(marketId, 1, true);
    int256 result = manager.resolveMarket(marketId);
    assertEq(result, 1);
  }

  function testUpdateOracleNotAdminReverts() public {
    MockOracle newOracle = new MockOracle();

    vm.prank(maker);
    vm.expectRevert("not market admin");
    manager.updateMarketOracle(marketId, address(newOracle), "");
  }

  function testUpdateOracleResolvedReverts() public {
    manager.adminResolveMarket(marketId, 0);

    MockOracle newOracle = new MockOracle();
    vm.expectRevert("resolved");
    manager.updateMarketOracle(marketId, address(newOracle), "");
  }

  function testCreateMarketWithoutOracle() public {
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "No oracle needed",
      image: "",
      feeModule: address(feeModule),
      oracle: address(0),
      oracleData: ""
    });
    uint256 newMarket = manager.createMarket(params);
    assertEq(manager.getMarketOracle(newMarket), address(0));

    manager.adminResolveMarket(newMarket, 1);
    assertEq(manager.getMarketResolvedOutcome(newMarket), 1);
  }

  // =========================================================================
  // Slippage protection (minFillAmount) tests
  // =========================================================================

  function testMinFillAmountEnforced() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrderWithMinFill(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 50 ether, 500);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 501);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("below maker min fill");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 49 ether);

    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 50 ether);

    // Full shares minted
    uint256 outcome0TokenId = (marketId << 1) | 0;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), 50 ether);
  }

  function testTakerMinFillAmountEnforced() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 510);
    MyriadCTFExchange.Order memory takerOrder = _buildOrderWithMinFill(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 30 ether, 511);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("below taker min fill");
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 29 ether);

    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, 30 ether);
  }

  function testMinFillZeroMeansNoMinimum() public {
    uint256 amount = 100 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 520);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 521);

    uint256 fill = 2 ether;
    exchange.matchOrdersWithFees(makerOrder, _signOrder(makerOrder, makerPk), takerOrder, _signOrder(takerOrder, takerPk), fill);

    // Full shares minted
    uint256 outcome0TokenId = (marketId << 1) | 0;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), fill);
  }

  // =========================================================================
  // Exchange pause/unpause tests
  // =========================================================================

  function testExchangePauseBlocksMatching() public {
    uint256 amount = 10 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    exchange.pause();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 600);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 601);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);
  }

  function testExchangeUnpauseResumesMatching() public {
    uint256 amount = 10 ether;
    uint256 outcome0Price = (60 * ONE) / 100;
    uint256 outcome1Price = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    exchange.pause();
    exchange.unpause();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 610);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, 1, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 611);

    exchange.matchOrdersWithFees(makerOrder, _signOrder(makerOrder, makerPk), takerOrder, _signOrder(takerOrder, takerPk), amount);

    // Full shares minted — fees added on top
    uint256 outcome0TokenId = (marketId << 1) | 0;
    assertEq(conditionalTokens.balanceOf(maker, outcome0TokenId), amount);
  }

  function testPauseNotAdminReverts() public {
    vm.prank(maker);
    vm.expectRevert("not admin");
    exchange.pause();
  }

  function testUnpauseNotAdminReverts() public {
    exchange.pause();

    vm.prank(maker);
    vm.expectRevert("not admin");
    exchange.unpause();
  }

  function testCancelOrdersWhilePaused() public {
    exchange.pause();

    MyriadCTFExchange.Order memory order = _buildOrder(maker, marketId, 0, MyriadCTFExchange.Side.Buy, 10 ether, (50 * ONE) / 100, 620);

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = order;

    vm.prank(maker);
    exchange.cancelOrders(toCancel);

    bytes32 orderHash = exchange.hashOrder(order);
    assertTrue(exchange.orderInvalidated(orderHash));
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  function _buildOrder(
    address trader,
    uint256 marketId_,
    uint8 outcome,
    MyriadCTFExchange.Side side,
    uint256 amount,
    uint256 price,
    uint256 nonce
  ) internal pure returns (MyriadCTFExchange.Order memory) {
    return
      MyriadCTFExchange.Order({
        trader: trader,
        marketId: marketId_,
        outcomeId: outcome,
        side: side,
        amount: amount,
        price: price,
        minFillAmount: 0,
        nonce: nonce,
        expiration: 0
      });
  }

  function _buildOrderWithMinFill(
    address trader,
    uint256 marketId_,
    uint8 outcome,
    MyriadCTFExchange.Side side,
    uint256 amount,
    uint256 price,
    uint256 minFill,
    uint256 nonce
  ) internal pure returns (MyriadCTFExchange.Order memory) {
    return
      MyriadCTFExchange.Order({
        trader: trader,
        marketId: marketId_,
        outcomeId: outcome,
        side: side,
        amount: amount,
        price: price,
        minFillAmount: minFill,
        nonce: nonce,
        expiration: 0
      });
  }

  function _signOrder(MyriadCTFExchange.Order memory order, uint256 pk) internal view returns (bytes memory) {
    bytes32 digest = exchange.hashOrder(order);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  function _setUniformFees(uint256 mktId, uint64 makerBps, uint64 takerBps) internal {
    FeeModule.FeeTier[] memory tiers = new FeeModule.FeeTier[](1);
    tiers[0] = FeeModule.FeeTier({maxPrice: uint128(ONE), makerFeeBps: makerBps, takerFeeBps: takerBps});
    feeModule.setMarketFees(mktId, tiers);
  }
}
