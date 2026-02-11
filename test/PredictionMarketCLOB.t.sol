// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../contracts/AdminRegistry.sol";
import "../contracts/PredictionMarketV3ManagerCLOB.sol";
import "../contracts/ConditionalTokens.sol";
import "../contracts/MyriadCTFExchange.sol";
import "../contracts/FeeModule.sol";

contract MockERC20 is ERC20 {
  constructor() ERC20("Collateral", "COL") {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

contract MockRealitio {
  uint256 public counter;
  mapping(bytes32 => bytes32) public results;

  function askQuestionERC20(
    uint256,
    string calldata,
    address,
    uint32,
    uint32,
    uint256,
    uint256
  ) external returns (bytes32) {
    counter++;
    return bytes32(counter);
  }

  function resultFor(bytes32 questionId) external view returns (bytes32) {
    return results[questionId];
  }

  function setResult(bytes32 questionId, bytes32 answer) external {
    results[questionId] = answer;
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
  MockRealitio internal realitio;

  address internal admin;
  address internal operator;
  address internal maker;
  address internal taker;
  address internal treasury;
  address internal distributor;
  address internal network;

  uint256 internal makerPk = 0xA11CE;
  uint256 internal takerPk = 0xB0B;

  function setUp() public {
    admin = address(this);
    operator = address(this);
    maker = vm.addr(makerPk);
    taker = vm.addr(takerPk);
    treasury = address(0x1111);
    distributor = address(0x2222);
    network = address(0x3333);

    collateral = new MockERC20();
    realitio = new MockRealitio();

    registry = new AdminRegistry(admin);
    manager = new PredictionMarketV3ManagerCLOB(
      registry,
      IRealityETH_ERC20(address(realitio)),
      IERC20(address(collateral))
    );
    conditionalTokens = new ConditionalTokens(registry, IMyriadMarketManager(address(manager)));

    uint256 deployerNonce = vm.getNonce(address(this));
    address predictedExchange = vm.computeCreateAddress(address(this), deployerNonce + 1);

    feeModule = new FeeModule(registry, MyriadCTFExchange(predictedExchange));
    exchange = new MyriadCTFExchange(IMyriadMarketManager(address(manager)), conditionalTokens, address(feeModule));

    // set exchange in conditional tokens
    conditionalTokens.setExchange(address(exchange));

    // grant roles
    registry.grantRole(registry.MARKET_ADMIN_ROLE(), admin);
    registry.grantRole(registry.FEE_ADMIN_ROLE(), admin);
    registry.grantRole(registry.OPERATOR_ROLE(), operator);

    // fee recipients and split
    feeModule.setFeeRecipients(treasury, distributor, network);
    feeModule.setFeeSplit(5000, 3000, 2000); // 50/30/20

    // create market
    PredictionMarketV3ManagerCLOB.CreateMarketParams memory params = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: "Will it rain?",
      image: "ipfs://img",
      arbitrator: address(0x9999),
      realitioTimeout: 1 hours,
      executionMode: PredictionMarketV3ManagerCLOB.ExecutionMode.CLOB,
      feeModule: address(feeModule)
    });
    manager.createMarket(params);

    // set market fees
    feeModule.setMarketFees(0, 100, 200); // maker 1%, taker 2%
  }

  // =========================================================================
  // Full-fill tests (fillAmount == order.amount, backward compatible)
  // =========================================================================

  function testMintMatchBuys() public {
    uint256 amount = 100 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 1
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId: 0,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 2
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);
    uint256 treasuryBefore = collateral.balanceOf(treasury);
    uint256 distributorBefore = collateral.balanceOf(distributor);
    uint256 networkBefore = collateral.balanceOf(network);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    uint256 yesId = conditionalTokens.getTokenId(0, 0);
    uint256 noId = conditionalTokens.getTokenId(0, 1);

    assertEq(conditionalTokens.balanceOf(maker, yesId), amount);
    assertEq(conditionalTokens.balanceOf(taker, noId), amount);

    uint256 makerNotional = (amount * priceYes) / ONE;
    uint256 takerNotional = (amount * priceNo) / ONE;
    uint256 makerFee = (makerNotional * 100) / BPS;
    uint256 takerFee = (takerNotional * 200) / BPS;
    uint256 totalProtocolFees = makerFee + takerFee;

    // Flat fees: each participant pays their own fee (no rebates)
    uint256 expectedMaker = makerBefore - makerNotional - makerFee;
    uint256 expectedTaker = takerBefore - takerNotional - takerFee;

    assertEq(collateral.balanceOf(maker), expectedMaker);
    assertEq(collateral.balanceOf(taker), expectedTaker);

    // Fee recipients split the total collected fee pot (50/30/20)
    uint256 expectedTreasury = treasuryBefore + (totalProtocolFees * 5000) / BPS;
    uint256 expectedDistributor = distributorBefore + (totalProtocolFees * 3000) / BPS;
    uint256 expectedNetwork = networkBefore + totalProtocolFees - (totalProtocolFees * 5000) / BPS - (totalProtocolFees * 3000) / BPS;

    assertEq(collateral.balanceOf(treasury), expectedTreasury);
    assertEq(collateral.balanceOf(distributor), expectedDistributor);
    assertEq(collateral.balanceOf(network), expectedNetwork);
  }

  function testDirectMatchBuySell() public {
    uint256 amount = 50 ether;
    uint256 priceSell = (55 * ONE) / 100;
    uint256 priceBuy = (60 * ONE) / 100;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(0, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Sell,
      amount: amount,
      price: priceSell,
      nonce: 3
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceBuy,
      nonce: 4
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    uint256 yesId = conditionalTokens.getTokenId(0, 0);

    assertEq(conditionalTokens.balanceOf(taker, yesId), amount);

    uint256 notional = (amount * priceSell) / ONE;
    uint256 makerFee = (notional * 100) / BPS;
    uint256 takerFee = (notional * 200) / BPS;

    // Maker (seller) receives notional minus their own fee
    assertEq(collateral.balanceOf(maker), makerBefore + notional - makerFee);
    // Taker (buyer) pays notional plus their own fee
    assertEq(collateral.balanceOf(taker), takerBefore - notional - takerFee);
  }

  function testMergeMatchSells() public {
    uint256 amount = 25 ether;
    uint256 priceYes = (52 * ONE) / 100;
    uint256 priceNo = ONE - priceYes;

    address sellerYes = maker;
    address sellerNo = taker;

    collateral.mint(sellerYes, 1000 ether);
    collateral.mint(sellerNo, 1000 ether);

    vm.startPrank(sellerYes);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(0, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.startPrank(sellerNo);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(0, amount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: sellerYes,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Sell,
      amount: amount,
      price: priceYes,
      nonce: 5
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: sellerNo,
      marketId: 0,
      outcome: 1,
      side: MyriadCTFExchange.Side.Sell,
      amount: amount,
      price: priceNo,
      nonce: 6
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 yesBefore = collateral.balanceOf(sellerYes);
    uint256 noBefore = collateral.balanceOf(sellerNo);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount);

    uint256 yesNotional = (amount * priceYes) / ONE;
    uint256 noNotional = (amount * priceNo) / ONE;
    uint256 makerFee = (yesNotional * 100) / BPS;
    uint256 takerFee = (noNotional * 200) / BPS;

    // Merge match: each seller's fee deducted from their own USDC proceeds
    assertEq(collateral.balanceOf(sellerYes), yesBefore + yesNotional - makerFee);
    assertEq(collateral.balanceOf(sellerNo), noBefore + noNotional - takerFee);
  }

  // =========================================================================
  // Partial fill tests
  // =========================================================================

  function testPartialFillMint() public {
    uint256 makerAmount = 100 ether;
    uint256 takerAmount = 40 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;
    uint256 fillAmount = 40 ether; // fill the smaller order fully

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: makerAmount,
      price: priceYes,
      nonce: 10
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId: 0,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: takerAmount,
      price: priceNo,
      nonce: 11
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fillAmount);

    uint256 yesId = conditionalTokens.getTokenId(0, 0);
    uint256 noId = conditionalTokens.getTokenId(0, 1);

    // Each side receives fillAmount shares of their outcome
    assertEq(conditionalTokens.balanceOf(maker, yesId), fillAmount);
    assertEq(conditionalTokens.balanceOf(taker, noId), fillAmount);

    // Check filledAmounts on-chain
    bytes32 makerHash = exchange.hashOrder(makerOrder);
    bytes32 takerHash = exchange.hashOrder(takerOrder);
    assertEq(exchange.filledAmounts(makerHash), fillAmount);
    assertEq(exchange.filledAmounts(takerHash), fillAmount);

    // Maker is NOT invalidated — can still be filled more
    assertFalse(exchange.orderInvalidated(makerHash));
    // Taker is fully filled but also not invalidated (just can't fill more due to filledAmounts check)
    assertFalse(exchange.orderInvalidated(takerHash));

    // Collateral checks: each side paid fillAmount * price + fee
    uint256 makerNotional = (fillAmount * priceYes) / ONE;
    uint256 takerNotional = (fillAmount * priceNo) / ONE;
    uint256 makerFee = (makerNotional * 100) / BPS;
    uint256 takerFee = (takerNotional * 200) / BPS;

    assertEq(collateral.balanceOf(maker), makerBefore - makerNotional - makerFee);
    assertEq(collateral.balanceOf(taker), takerBefore - takerNotional - takerFee);
  }

  function testPartialFillThenSecondFill() public {
    uint256 makerAmount = 100 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

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

    // Maker places a large YES buy order for 100 shares
    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: makerAmount,
      price: priceYes,
      nonce: 20
    });

    // First taker: 40 shares
    MyriadCTFExchange.Order memory taker1Order = _buildOrder({
      trader: taker,
      marketId: 0,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: 40 ether,
      price: priceNo,
      nonce: 21
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory taker1Sig = _signOrder(taker1Order, takerPk);

    // First fill: 40 shares
    feeModule.matchOrdersWithFees(makerOrder, makerSig, taker1Order, taker1Sig, 40 ether);

    bytes32 makerHash = exchange.hashOrder(makerOrder);
    assertEq(exchange.filledAmounts(makerHash), 40 ether);

    // Second taker: another 60 shares to fill the rest
    MyriadCTFExchange.Order memory taker2Order = _buildOrder({
      trader: taker,
      marketId: 0,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: 60 ether,
      price: priceNo,
      nonce: 22
    });
    bytes memory taker2Sig = _signOrder(taker2Order, takerPk);

    // Second fill: 60 shares (fills the rest of maker's 100)
    feeModule.matchOrdersWithFees(makerOrder, makerSig, taker2Order, taker2Sig, 60 ether);

    assertEq(exchange.filledAmounts(makerHash), 100 ether);

    // Maker should have 100 YES shares total
    uint256 yesId = conditionalTokens.getTokenId(0, 0);
    assertEq(conditionalTokens.balanceOf(maker, yesId), 100 ether);
  }

  function testOverfillReverts() public {
    uint256 amount = 50 ether;
    uint256 priceYes = (60 * ONE) / 100;
    uint256 priceNo = (40 * ONE) / 100;

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

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceYes,
      nonce: 30
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId: 0,
      outcome: 1,
      side: MyriadCTFExchange.Side.Buy,
      amount: amount,
      price: priceNo,
      nonce: 31
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    // fillAmount > order amount should revert
    vm.expectRevert("maker overfill");
    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, amount + 1);
  }

  function testPartialFillDirect() public {
    uint256 makerAmount = 100 ether;
    uint256 takerAmount = 30 ether;
    uint256 priceSell = (55 * ONE) / 100;
    uint256 priceBuy = (60 * ONE) / 100;
    uint256 fillAmount = 30 ether;

    collateral.mint(maker, 1000 ether);
    collateral.mint(taker, 1000 ether);

    vm.startPrank(maker);
    collateral.approve(address(conditionalTokens), type(uint256).max);
    conditionalTokens.splitPosition(0, makerAmount);
    conditionalTokens.setApprovalForAll(address(exchange), true);
    vm.stopPrank();

    vm.startPrank(taker);
    collateral.approve(address(exchange), type(uint256).max);
    vm.stopPrank();

    MyriadCTFExchange.Order memory makerOrder = _buildOrder({
      trader: maker,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Sell,
      amount: makerAmount,
      price: priceSell,
      nonce: 40
    });
    MyriadCTFExchange.Order memory takerOrder = _buildOrder({
      trader: taker,
      marketId: 0,
      outcome: 0,
      side: MyriadCTFExchange.Side.Buy,
      amount: takerAmount,
      price: priceBuy,
      nonce: 41
    });

    bytes memory makerSig = _signOrder(makerOrder, makerPk);
    bytes memory takerSig = _signOrder(takerOrder, takerPk);

    uint256 makerBefore = collateral.balanceOf(maker);
    uint256 takerBefore = collateral.balanceOf(taker);

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig, fillAmount);

    uint256 yesId = conditionalTokens.getTokenId(0, 0);
    assertEq(conditionalTokens.balanceOf(taker, yesId), fillAmount);

    // Execution price = maker's price (seller's ask)
    uint256 notional = (fillAmount * priceSell) / ONE;
    uint256 makerFee = (notional * 100) / BPS;
    uint256 takerFee = (notional * 200) / BPS;

    // Seller receives notional - fee
    assertEq(collateral.balanceOf(maker), makerBefore + notional - makerFee);
    // Buyer pays notional + fee
    assertEq(collateral.balanceOf(taker), takerBefore - notional - takerFee);

    // Maker still has 70 remaining
    bytes32 makerHash = exchange.hashOrder(makerOrder);
    assertEq(exchange.filledAmounts(makerHash), fillAmount);
    assertFalse(exchange.orderInvalidated(makerHash));
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  function _buildOrder(
    address trader,
    uint256 marketId,
    uint8 outcome,
    MyriadCTFExchange.Side side,
    uint256 amount,
    uint256 price,
    uint256 nonce
  ) internal view returns (MyriadCTFExchange.Order memory) {
    return
      MyriadCTFExchange.Order({
        trader: trader,
        marketId: marketId,
        outcome: outcome,
        side: side,
        amount: amount,
        price: price,
        nonce: nonce,
        expiration: 0
      });
  }

  function _signOrder(MyriadCTFExchange.Order memory order, uint256 pk) internal view returns (bytes memory) {
    bytes32 digest = exchange.hashOrder(order);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }
}
