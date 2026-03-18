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
import "../contracts/Outcomes.sol";

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
  address internal maker2;
  address internal treasury;

  uint256 internal makerPk = 0xA11CE;
  uint256 internal takerPk = 0xB0B;
  uint256 internal maker2Pk = 0xC4A;

  uint256 internal marketId;

  function setUp() public {
    admin = address(this);
    operator = address(this);
    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);
    maker2 = vm.addr(maker2Pk);
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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 1);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 2);

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

    MyriadCTFExchange.Order memory sellOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, outcome0Price, 20);
    MyriadCTFExchange.Order memory buyOrder = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 21);
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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, outcome0Price, 30);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Sell, amount, outcome1Price, 31);
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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 40);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 41);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 50);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 51);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 60);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 61);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    exchange.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    vm.expectRevert("taker overfill");
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

    MyriadCTFExchange.Order memory sellOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, outcome0Price, 80);
    MyriadCTFExchange.Order memory buyOrder = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 81);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 90);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 91);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 100);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 101);

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
    MyriadCTFExchange.Order memory order = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 10 ether, (50 * ONE) / 100, 110);

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = order;

    vm.startPrank(maker);
    exchange.cancelOrders(toCancel);

    vm.expectRevert("already cancelled");
    exchange.cancelOrders(toCancel);
    vm.stopPrank();
  }

  function testCancelSomeoneElsesOrderReverts() public {
    MyriadCTFExchange.Order memory order = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 10 ether, (50 * ONE) / 100, 120);

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

    MyriadCTFExchange.Order memory order1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 130);
    MyriadCTFExchange.Order memory order2 = _buildOrder(maker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 131);

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
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 141);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 150);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 151);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, zeroFeeMarketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 170);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, zeroFeeMarketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 171);

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

    MyriadCTFExchange.Order memory buyOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 182);
    MyriadCTFExchange.Order memory sellOrder = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, (50 * ONE) / 100, 183);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 190);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 191);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("market not tradeable");
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

    manager.adminResolveMarket(marketId, int256(Outcomes.YES));

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 200);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 201);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("market not tradeable");
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
    vm.warp(block.timestamp + 2 days);

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
    vm.warp(block.timestamp + 2 days);

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

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 210);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 211);
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), amount);

    vm.warp(block.timestamp + 2 days);

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

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 220);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 221);
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), amount);

    vm.warp(block.timestamp + 2 days);

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

    vm.warp(block.timestamp + 2 days);

    uint256 outcome0Payout = (60 * ONE) / 100;
    uint256 outcome1Payout = ONE - outcome0Payout;
    manager.adminVoidMarket(marketId, outcome0Payout, outcome1Payout);

    uint256 makerBefore = collateral.balanceOf(maker);

    vm.prank(maker);
    conditionalTokens.redeemVoided(marketId);

    assertEq(collateral.balanceOf(maker), makerBefore + amount);
  }

  function testRedeemVoidedNoBalanceReverts() public {
    vm.warp(block.timestamp + 2 days);
    manager.adminVoidMarket(marketId, (50 * ONE) / 100, (50 * ONE) / 100);

    vm.prank(maker);
    vm.expectRevert("no balance");
    conditionalTokens.redeemVoided(marketId);
  }

  function testRedeemVoidedNotVoidedReverts() public {
    vm.warp(block.timestamp + 2 days);
    manager.adminResolveMarket(marketId, int256(Outcomes.YES));

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

    vm.warp(block.timestamp + 2 days);

    manager.adminVoidMarket(marketId, (50 * ONE) / 100, (50 * ONE) / 100);

    vm.prank(maker);
    conditionalTokens.redeemVoided(marketId);

    vm.prank(maker);
    vm.expectRevert("no balance");
    conditionalTokens.redeemVoided(marketId);
  }

  function testAdminVoidBeforeCloseReverts() public {
    vm.expectRevert("market not closed");
    manager.adminVoidMarket(marketId, (50 * ONE) / 100, (50 * ONE) / 100);
  }

  function testSetClosesAt() public {
    uint256 newClosesAt = block.timestamp + 3 days;
    manager.adminSetClosesAt(marketId, newClosesAt);
    assertEq(manager.getMarketClosesAt(marketId), newClosesAt);
  }

  function testSetClosesAtToNowAndVoid() public {
    manager.adminSetClosesAt(marketId, block.timestamp);

    manager.adminVoidMarket(marketId, (50 * ONE) / 100, (50 * ONE) / 100);
    assertEq(uint8(manager.getMarketState(marketId)), uint8(IMyriadMarketManager.MarketState.resolved));
  }

  function testSetClosesAtPastReverts() public {
    vm.warp(block.timestamp + 1 hours);
    vm.expectRevert("close in past");
    manager.adminSetClosesAt(marketId, block.timestamp - 1);
  }

  function testSetClosesAtResolvedReverts() public {
    vm.warp(block.timestamp + 2 days);
    manager.adminResolveMarket(marketId, int256(Outcomes.YES));

    vm.expectRevert("resolved");
    manager.adminSetClosesAt(marketId, block.timestamp + 1 days);
  }

  function testSetClosesAtNotAdminReverts() public {
    vm.prank(maker);
    vm.expectRevert("not market admin");
    manager.adminSetClosesAt(marketId, block.timestamp + 2 days);
  }

  function testSetNegRiskAdapterEmitsEvent() public {
    address oldAdapter = manager.negRiskAdapter();
    address newAdapter = address(0xADA);
    vm.expectEmit(true, true, false, false, address(manager));
    emit PredictionMarketV3ManagerCLOB.NegRiskAdapterUpdated(oldAdapter, newAdapter);
    manager.setNegRiskAdapter(newAdapter);
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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 240);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 241);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 250);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 251);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 260);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 261);

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    vm.expectRevert("market not tradeable");
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

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 300);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 301);
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

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 320);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 321);
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

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 400);
    MyriadCTFExchange.Order memory t1 = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 401);
    exchange.matchOrdersWithFees(m1, _signOrder(m1, makerPk), t1, _signOrder(t1, takerPk), amount);

    uint256 feesAfterFirst = collateral.balanceOf(address(feeModule));
    assertTrue(feesAfterFirst > 0, "should have fees after first match");

    MyriadCTFExchange.Order memory m2 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 402);
    MyriadCTFExchange.Order memory t2 = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 403);
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

  function testOracleVoidOutcomeReverts() public {
    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketId, -1, true);

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

    int256 result = manager.adminResolveMarket(marketId, int256(Outcomes.YES));
    assertEq(result, 0);
    assertEq(manager.getMarketResolvedOutcome(marketId), 0);
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
    manager.adminResolveMarket(marketId, int256(Outcomes.YES));

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

    manager.adminResolveMarket(newMarket, int256(Outcomes.NO));
    assertEq(manager.getMarketResolvedOutcome(newMarket), 1);
  }

  // =========================================================================
  // Oracle integration: end-to-end tests
  // =========================================================================

  function testOracleVoidedOutcomeResolvesViaAdmin() public {
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "Oracle voided?",
      image: "",
      feeModule: address(feeModule),
      oracle: address(oracle),
      oracleData: abi.encode("init")
    });
    uint256 mid = manager.createMarket(params);

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

    _setUniformFees(mid, 0, 0);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, mid, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 4000);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, mid, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 4001);
    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), amount);

    vm.warp(block.timestamp + 2 days);

    oracle.setResult(mid, -1, true);

    vm.expectRevert("invalid outcome");
    manager.resolveMarket(mid);

    uint256 payout0 = (50 * ONE) / 100;
    uint256 payout1 = (50 * ONE) / 100;
    int256 result = manager.adminVoidMarket(mid, payout0, payout1);
    assertEq(result, -1);
    assertEq(uint8(manager.getMarketState(mid)), uint8(IMyriadMarketManager.MarketState.resolved));
    assertEq(manager.getMarketResolvedOutcome(mid), -1);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    vm.prank(maker);
    conditionalTokens.redeemVoided(mid);
    vm.prank(taker);
    conditionalTokens.redeemVoided(mid);

    assertEq(collateral.balanceOf(maker), makerBefore + (amount * 50) / 100);
    assertEq(collateral.balanceOf(taker), takerBefore + (amount * 50) / 100);
  }

  function testResolveMarketId0Reverts() public {
    vm.expectRevert(bytes("!m"));
    manager.resolveMarket(0);

    vm.expectRevert(bytes("!m"));
    manager.adminResolveMarket(0, int256(Outcomes.YES));

    vm.expectRevert(bytes("!m"));
    manager.adminVoidMarket(0, (50 * ONE) / 100, (50 * ONE) / 100);

    vm.expectRevert(bytes("!m"));
    manager.getMarketState(0);
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

    MyriadCTFExchange.Order memory makerOrder = _buildOrderWithMinFill(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 50 ether, 500);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 501);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 510);
    MyriadCTFExchange.Order memory takerOrder = _buildOrderWithMinFill(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 30 ether, 511);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 520);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 521);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 600);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 601);

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, outcome0Price, 610);
    MyriadCTFExchange.Order memory takerOrder = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, outcome1Price, 611);

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

    MyriadCTFExchange.Order memory order = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 10 ether, (50 * ONE) / 100, 620);

    MyriadCTFExchange.Order[] memory toCancel = new MyriadCTFExchange.Order[](1);
    toCancel[0] = order;

    vm.prank(maker);
    exchange.cancelOrders(toCancel);

    bytes32 orderHash = exchange.hashOrder(order);
    assertTrue(exchange.orderInvalidated(orderHash));
  }

  // setCallbackGasLimit
  // =========================================================================

  function testSetCallbackGasLimit() public {
    assertEq(exchange.callbackGasLimit(), 100_000);

    exchange.setCallbackGasLimit(200_000);
    assertEq(exchange.callbackGasLimit(), 200_000);
  }

  function testSetCallbackGasLimitEmitsEvent() public {
    vm.expectEmit(false, false, false, true);
    emit MyriadCTFExchange.CallbackGasLimitUpdated(100_000, 250_000);
    exchange.setCallbackGasLimit(250_000);
  }

  function testSetCallbackGasLimitNotAdminReverts() public {
    vm.prank(taker);
    vm.expectRevert("not admin");
    exchange.setCallbackGasLimit(200_000);
  }

  function testSetCallbackGasLimitTooLowReverts() public {
    vm.expectRevert("limit too low");
    exchange.setCallbackGasLimit(49_999);
  }

  function testSetCallbackGasLimitMinimumAllowed() public {
    exchange.setCallbackGasLimit(50_000);
    assertEq(exchange.callbackGasLimit(), 50_000);
  }

  function testMatchStillWorksAfterGasLimitChange() public {
    exchange.setCallbackGasLimit(200_000);

    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, amount);
    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 1100);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 1101);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), amount);

    uint256 tokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    assertEq(conditionalTokens.balanceOf(taker, tokenId), amount);
  }

  // =========================================================================
  // matchMultipleOrdersWithFees
  // =========================================================================

  function testMatchMultipleDirect() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);

    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, amount);
    vm.prank(maker2);
    conditionalTokens.splitPosition(marketId, amount);

    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(maker2);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 300);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 301);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price, 302);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = amount;
    fills[1] = amount;

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, _signOrder(t, takerPk));

    uint256 tokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    assertEq(conditionalTokens.balanceOf(taker, tokenId), 200 ether);

    assertEq(exchange.filledAmounts(exchange.hashOrder(m1)), amount);
    assertEq(exchange.filledAmounts(exchange.hashOrder(m2)), amount);

    assertEq(exchange.filledAmounts(exchange.hashOrder(t)), 200 ether);
  }

  function testMatchMultipleDifferentPrices() public {
    uint256 price1 = (50 * ONE) / 100;
    uint256 price2 = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);

    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, 50 ether);
    vm.prank(maker2);
    conditionalTokens.splitPosition(marketId, 80 ether);

    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(maker2);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 50 ether, price1, 400);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 80 ether, price2, 401);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 130 ether, price2, 402);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = 50 ether;
    fills[1] = 80 ether;

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, _signOrder(t, takerPk));

    uint256 tokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    assertEq(conditionalTokens.balanceOf(taker, tokenId), 130 ether);
    assertEq(exchange.filledAmounts(exchange.hashOrder(t)), 130 ether);
  }

  function testMatchMultipleMintMatch() public {
    uint256 price1 = (60 * ONE) / 100;
    uint256 price2 = (40 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(maker2);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 50 ether, price1, 500);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 50 ether, price1, 501);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 100 ether, price2, 502);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = 50 ether;
    fills[1] = 50 ether;

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, _signOrder(t, takerPk));

    uint256 tokenId0 = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    uint256 tokenId1 = conditionalTokens.getTokenId(marketId, Outcomes.NO);
    assertEq(conditionalTokens.balanceOf(maker, tokenId0), 50 ether);
    assertEq(conditionalTokens.balanceOf(maker2, tokenId0), 50 ether);
    assertEq(conditionalTokens.balanceOf(taker, tokenId1), 100 ether);
    assertEq(exchange.filledAmounts(exchange.hashOrder(t)), 100 ether);
  }

  function testMatchMultiplePartialFill() public {
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, 200 ether);
    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 200 ether, price, 600);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price, 601);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = 80 ether;

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, _signOrder(t, takerPk));

    assertEq(exchange.filledAmounts(exchange.hashOrder(m)), 80 ether);
    assertEq(exchange.filledAmounts(exchange.hashOrder(t)), 80 ether);

    fills[0] = 120 ether;
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, _signOrder(t, takerPk));

    assertEq(exchange.filledAmounts(exchange.hashOrder(m)), 200 ether);
    assertEq(exchange.filledAmounts(exchange.hashOrder(t)), 200 ether);
  }

  function testMatchMultipleTakerOverfillReverts() public {
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, 100 ether);
    vm.prank(maker2);
    conditionalTokens.splitPosition(marketId, 100 ether);
    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(maker2);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 700);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 701);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 150 ether, price, 702);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = 100 ether;
    fills[1] = 100 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("taker overfill");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleMakerOverfillReverts() public {
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, 100 ether);
    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 50 ether, price, 800);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price, 801);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = 60 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("maker overfill");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleEmptyMakersReverts() public {
    uint256 price = (60 * ONE) / 100;
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 900);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](0);
    bytes[] memory makerSigs = new bytes[](0);
    uint256[] memory fills = new uint256[](0);
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("no makers");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleLengthMismatchReverts() public {
    uint256 price = (60 * ONE) / 100;
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 910);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 911);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = 50 ether;
    fills[1] = 50 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("fill count");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleSelfTradeReverts() public {
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, 100 ether);
    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 920);
    MyriadCTFExchange.Order memory t = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 921);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = 100 ether;
    bytes memory takerSig = _signOrder(t, makerPk);

    vm.expectRevert("self trade");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleMarketMismatchReverts() public {
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params2 = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "Will it snow?",
      image: "",
      feeModule: address(feeModule),
      oracle: address(0),
      oracleData: ""
    });
    uint256 marketId2 = manager.createMarket(params2);

    uint256 price = (60 * ONE) / 100;
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId2, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 930);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 931);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = 100 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("market mismatch");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleTakerMinFillEnforced() public {
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, 100 ether);
    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 940);
    MyriadCTFExchange.Order memory t = _buildOrderWithMinFill(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 80 ether, 941);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = 50 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("below taker min fill");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleTakerMinFillSatisfiedByAggregate() public {
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, 50 ether);
    vm.prank(maker2);
    conditionalTokens.splitPosition(marketId, 50 ether);
    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(maker2);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 50 ether, price, 950);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 50 ether, price, 951);
    MyriadCTFExchange.Order memory t = _buildOrderWithMinFill(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 80 ether, 952);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = 50 ether;
    fills[1] = 50 ether;

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, _signOrder(t, takerPk));

    assertEq(exchange.filledAmounts(exchange.hashOrder(t)), 100 ether);
  }

  function testMatchMultipleFeesAccrued() public {
    uint256 price = (60 * ONE) / 100;
    uint256 amount = 100 ether;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.prank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    vm.prank(maker);
    conditionalTokens.splitPosition(marketId, amount);
    vm.prank(maker2);
    conditionalTokens.splitPosition(marketId, amount);
    vm.prank(maker);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(maker2);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    uint256 feeModuleBefore = collateral.balanceOf(address(feeModule));

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 960);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 961);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price, 962);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = amount;
    fills[1] = amount;

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, _signOrder(t, takerPk));

    uint256 feeModuleAfter = collateral.balanceOf(address(feeModule));
    uint256 notionalPerFill = (amount * price) / ONE;
    uint256 expectedFees = 2 * ((notionalPerFill * 100) / BPS + (notionalPerFill * 200) / BPS);
    assertEq(feeModuleAfter - feeModuleBefore, expectedFees);
  }

  function testMatchMultipleNotOperatorReverts() public {
    uint256 price = (60 * ONE) / 100;
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 970);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 971);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = 100 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.prank(taker);
    vm.expectRevert("not operator");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleMergeMatch() public {
    uint256 amount = 100 ether;
    uint256 makerPrice = (60 * ONE) / 100;
    uint256 takerPrice = (40 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    conditionalTokens.splitPosition(marketId, amount);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    conditionalTokens.splitPosition(marketId, amount);
    vm.stopPrank();

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, makerPrice, 4000);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Sell, amount, takerPrice, 4001);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = amount;

    uint256 makerColBefore = collateral.balanceOf(maker);
    uint256 takerColBefore = collateral.balanceOf(taker);

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, _signOrder(t, takerPk));

    uint256 tokenId0 = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    uint256 tokenId1 = conditionalTokens.getTokenId(marketId, Outcomes.NO);
    assertEq(conditionalTokens.balanceOf(maker, tokenId0), 0);
    assertEq(conditionalTokens.balanceOf(taker, tokenId1), 0);

    uint256 makerNotional = (amount * makerPrice) / ONE;
    uint256 takerNotional = amount - makerNotional;
    uint256 makerFee = (makerNotional * 100) / BPS;
    uint256 takerFee = (takerNotional * 200) / BPS;

    assertEq(collateral.balanceOf(maker), makerColBefore + makerNotional - makerFee);
    assertEq(collateral.balanceOf(taker), takerColBefore + takerNotional - takerFee);

    assertEq(exchange.filledAmounts(exchange.hashOrder(m)), amount);
    assertEq(exchange.filledAmounts(exchange.hashOrder(t)), amount);
  }

  function testMatchMultipleDustRemainderMakerReverts() public {
    exchange.setMinOrderAmount(50 ether);

    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 100 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 4100);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price, 4101);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = 60 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("maker dust remainder");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleDustRemainderTakerReverts() public {
    exchange.setMinOrderAmount(50 ether);

    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 100 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.startPrank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 100 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 4110);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 4111);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 4112);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = 30 ether;
    fills[1] = 30 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("taker dust remainder");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultiplePrefilledMaker() public {
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 2000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 3000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 200 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.startPrank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 100 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 200 ether, price, 4200);
    MyriadCTFExchange.Order memory t1 = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 50 ether, price, 4201);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t1, _signOrder(t1, takerPk), 50 ether);
    assertEq(exchange.filledAmounts(exchange.hashOrder(m)), 50 ether);

    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 100 ether, price, 4202);
    MyriadCTFExchange.Order memory t2 = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 4203);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = 50 ether;
    fills[1] = 50 ether;

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t2, _signOrder(t2, takerPk));

    assertEq(exchange.filledAmounts(exchange.hashOrder(m)), 100 ether);
    assertEq(exchange.filledAmounts(exchange.hashOrder(m2)), 50 ether);
    assertEq(exchange.filledAmounts(exchange.hashOrder(t2)), 100 ether);
  }

  function testMatchMultipleInsufficientCollateralReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 4300);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 4301);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = amount;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("insufficient collateral");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  function testMatchMultipleInsufficientTokensReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(taker, 1000 ether);

    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 4400);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 4401);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](1);
    makers[0] = m;
    bytes[] memory makerSigs = new bytes[](1);
    makerSigs[0] = _signOrder(m, makerPk);
    uint256[] memory fills = new uint256[](1);
    fills[0] = amount;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("insufficient tokens");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);
  }

  // =========================================================================
  // Two-pass grief protection (matchMultipleOrdersWithFees)
  // =========================================================================

  function testMatchMultipleSecondMakerNoCollateralReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 200 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 5001);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 5002);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price, 5003);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = amount;
    fills[1] = amount;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("insufficient tokens");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);

    bytes32 m1Hash = exchange.hashOrder(m1);
    assertEq(exchange.filledAmounts(m1Hash), 0, "maker1 should not be filled");
  }

  function testMatchMultipleSecondMakerInvalidSignatureReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 200 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.startPrank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 200 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 5011);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 5012);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price, 5013);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, makerPk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = amount;
    fills[1] = amount;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("invalid signature");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);

    bytes32 m1Hash = exchange.hashOrder(m1);
    assertEq(exchange.filledAmounts(m1Hash), 0, "maker1 should not be filled");
  }

  function testMatchMultipleTwoPassSettlesCorrectly() public {
    uint256 amount = 50 ether;
    uint256 price1 = (60 * ONE) / 100;
    uint256 price2 = (55 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 200 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.startPrank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 200 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 5021);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 5022);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price1, 5023);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = amount;
    fills[1] = amount;
    bytes memory takerSig = _signOrder(t, takerPk);

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);

    bytes32 m1Hash = exchange.hashOrder(m1);
    bytes32 m2Hash = exchange.hashOrder(m2);
    bytes32 tHash = exchange.hashOrder(t);

    assertEq(exchange.filledAmounts(m1Hash), amount, "maker1 filled");
    assertEq(exchange.filledAmounts(m2Hash), amount, "maker2 filled");
    assertEq(exchange.filledAmounts(tHash), 2 * amount, "taker filled");
  }

  function testMatchMultipleMakerOverfillCaughtInPass1() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 2000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 200 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.startPrank(maker2);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, 200 ether);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 5031);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, 50 ether, price, 5032);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 200 ether, price, 5033);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = amount;
    fills[1] = 60 ether;
    bytes memory takerSig = _signOrder(t, takerPk);

    vm.expectRevert("maker overfill");
    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);

    bytes32 m1Hash = exchange.hashOrder(m1);
    assertEq(exchange.filledAmounts(m1Hash), 0, "maker1 should not be filled");
  }

  function testMatchMultipleMintTwoPassSettles() public {
    uint256 amount = 50 ether;
    uint256 price = (60 * ONE) / 100;
    uint256 cpPrice = ONE - price;

    collateral.mint(maker, 1000 ether);
    collateral.mint(maker2, 1000 ether);
    collateral.mint(taker, 2000 ether);

    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(maker2);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m1 = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 5041);
    MyriadCTFExchange.Order memory m2 = _buildOrder(maker2, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 5042);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 200 ether, cpPrice, 5043);

    MyriadCTFExchange.Order[] memory makers = new MyriadCTFExchange.Order[](2);
    makers[0] = m1;
    makers[1] = m2;
    bytes[] memory makerSigs = new bytes[](2);
    makerSigs[0] = _signOrder(m1, makerPk);
    makerSigs[1] = _signOrder(m2, maker2Pk);
    uint256[] memory fills = new uint256[](2);
    fills[0] = amount;
    fills[1] = amount;
    bytes memory takerSig = _signOrder(t, takerPk);

    exchange.matchMultipleOrdersWithFees(makers, makerSigs, fills, t, takerSig);

    bytes32 m1Hash = exchange.hashOrder(m1);
    bytes32 m2Hash = exchange.hashOrder(m2);
    bytes32 tHash = exchange.hashOrder(t);

    assertEq(exchange.filledAmounts(m1Hash), amount, "maker1 filled");
    assertEq(exchange.filledAmounts(m2Hash), amount, "maker2 filled");
    assertEq(exchange.filledAmounts(tHash), 2 * amount, "taker filled");

    uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    assertEq(conditionalTokens.balanceOf(maker, yesTokenId), amount, "maker1 YES tokens");
    assertEq(conditionalTokens.balanceOf(maker2, yesTokenId), amount, "maker2 YES tokens");
  }

  // =========================================================================
  // Front-run protection (early balance checks)
  // =========================================================================

  function testDirectMatchInsufficientCollateralReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    // taker has NO collateral (buyer in this case)

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 3001);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 3002);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert("insufficient collateral");
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  function testDirectMatchInsufficientTokensReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(taker, 1000 ether);
    // maker is selling but has NO tokens

    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 3003);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 3004);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert("insufficient tokens");
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  function testDirectMatchInsufficientAllowanceReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    // taker has collateral but NO allowance to exchange

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 3005);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 3006);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert("insufficient allowance");
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  function testMintMatchInsufficientCollateralReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    // taker has NO collateral

    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 3007);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, amount, ONE - price, 3008);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert("insufficient collateral");
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  function testMergeMatchInsufficientTokensReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    // Give maker outcome0 tokens, but taker has NO outcome1 tokens
    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();
    vm.prank(taker);
    conditionalTokens.setApprovalForAll(address(exchange), true);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 3009);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Sell, amount, ONE - price, 3010);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert("insufficient tokens");
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  function testSellerTokensNotApprovedReverts() public {
    uint256 amount = 100 ether;
    uint256 price = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(marketId, amount);
    // maker does NOT approve exchange for tokens
    vm.stopPrank();
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price, 3011);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price, 3012);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert("tokens not approved");
    exchange.matchOrdersWithFees(m, mSig, t, tSig, amount);
  }

  // =========================================================================
  // Min order amount & dust remainder
  // =========================================================================

  function testSetMinOrderAmount() public {
    assertEq(exchange.minOrderAmount(), 0);

    exchange.setMinOrderAmount(1 ether);
    assertEq(exchange.minOrderAmount(), 1 ether);
  }

  function testSetMinOrderAmountEmitsEvent() public {
    vm.expectEmit(false, false, false, true);
    emit MyriadCTFExchange.MinOrderAmountUpdated(0, 5 ether);
    exchange.setMinOrderAmount(5 ether);
  }

  function testSetMinOrderAmountNotAdminReverts() public {
    vm.prank(taker);
    vm.expectRevert("not admin");
    exchange.setMinOrderAmount(1 ether);
  }

  function testSetMinOrderAmountZeroAllowed() public {
    exchange.setMinOrderAmount(1 ether);
    exchange.setMinOrderAmount(0);
    assertEq(exchange.minOrderAmount(), 0);
  }

  function testBelowMinAmountReverts() public {
    exchange.setMinOrderAmount(10 ether);

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    uint256 price = (50 * ONE) / 100;
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 5 ether, price, 2001);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 5 ether, price, 2002);

    bytes memory mSig = _signOrder(m, makerPk);
    bytes memory tSig = _signOrder(t, takerPk);

    vm.expectRevert("below min amount");
    exchange.matchOrdersWithFees(m, mSig, t, tSig, 5 ether);
  }

  function testAboveMinAmountWorks() public {
    exchange.setMinOrderAmount(10 ether);

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    uint256 price = (50 * ONE) / 100;
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 20 ether, price, 2003);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 20 ether, price, 2004);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), 20 ether);

    bytes32 mHash = exchange.hashOrder(m);
    assertEq(exchange.filledAmounts(mHash), 20 ether);
  }

  function testDustRemainderMakerReverts() public {
    exchange.setMinOrderAmount(10 ether);

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    uint256 price = (50 * ONE) / 100;
    // maker has 25 ether order, fill 20 => remaining 5 < minOrderAmount(10)
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 25 ether, price, 2005);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 20 ether, price, 2006);

    bytes memory mSig_ = _signOrder(m, makerPk);
    bytes memory tSig_ = _signOrder(t, takerPk);

    vm.expectRevert("maker dust remainder");
    exchange.matchOrdersWithFees(m, mSig_, t, tSig_, 20 ether);
  }

  function testDustRemainderTakerReverts() public {
    exchange.setMinOrderAmount(10 ether);

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    uint256 price = (50 * ONE) / 100;
    // taker has 25 ether order, fill 20 => remaining 5 < minOrderAmount(10)
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 20 ether, price, 2007);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 25 ether, price, 2008);

    bytes memory mSig_ = _signOrder(m, makerPk);
    bytes memory tSig_ = _signOrder(t, takerPk);

    vm.expectRevert("taker dust remainder");
    exchange.matchOrdersWithFees(m, mSig_, t, tSig_, 20 ether);
  }

  function testExactRemainderAtMinAllowed() public {
    exchange.setMinOrderAmount(10 ether);

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    uint256 price = (50 * ONE) / 100;
    // maker has 30 ether, fill 20 => remaining 10 == minOrderAmount, should pass
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 30 ether, price, 2009);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 20 ether, price, 2010);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), 20 ether);

    bytes32 mHash = exchange.hashOrder(m);
    assertEq(exchange.filledAmounts(mHash), 20 ether);
  }

  function testFullFillRemainderZeroAllowed() public {
    exchange.setMinOrderAmount(10 ether);

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    uint256 price = (50 * ONE) / 100;
    // fill exactly 20 ether on 20 ether order => remaining 0, always allowed
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 20 ether, price, 2011);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 20 ether, price, 2012);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), 20 ether);

    bytes32 mHash = exchange.hashOrder(m);
    assertEq(exchange.filledAmounts(mHash), 20 ether);
  }

  function testNoMinAmountNoRestriction() public {
    // minOrderAmount == 0 (default): no restriction on remainder
    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);
    vm.prank(maker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.prank(taker);
    collateral.approve(address(exchange), type(uint256).max);

    uint256 price = (50 * ONE) / 100;
    // fill 1 ether on 100 ether order => small remainder, should work since minOrderAmount == 0
    MyriadCTFExchange.Order memory m = _buildOrder(maker, marketId, Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price, 2013);
    MyriadCTFExchange.Order memory t = _buildOrder(taker, marketId, Outcomes.NO, MyriadCTFExchange.Side.Buy, 100 ether, price, 2014);

    exchange.matchOrdersWithFees(m, _signOrder(m, makerPk), t, _signOrder(t, takerPk), 1 ether);

    bytes32 mHash = exchange.hashOrder(m);
    assertEq(exchange.filledAmounts(mHash), 1 ether);
  }

  // =========================================================================
  // Helpers
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
    return
      MyriadCTFExchange.Order({
        trader: trader,
        marketId: marketId_,
        outcomeId: uint8(outcome),
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
    uint256 outcome,
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
        outcomeId: uint8(outcome),
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
