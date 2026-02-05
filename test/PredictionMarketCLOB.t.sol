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
    feeModule.setTakerFeeSplit(5000, 3000, 2000); // 50/30/20

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

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig);

    uint256 yesId = conditionalTokens.getTokenId(0, 0);
    uint256 noId = conditionalTokens.getTokenId(0, 1);

    assertEq(conditionalTokens.balanceOf(maker, yesId), amount);
    assertEq(conditionalTokens.balanceOf(taker, noId), amount);

    uint256 makerNotional = (amount * priceYes) / ONE;
    uint256 takerNotional = (amount * priceNo) / ONE;
    uint256 makerRebate = (makerNotional * 100) / BPS;
    uint256 takerFee = (takerNotional * 200) / BPS;

    uint256 expectedMaker = makerBefore - makerNotional + makerRebate;
    uint256 expectedTaker = takerBefore - takerNotional - takerFee - makerRebate;

    assertEq(collateral.balanceOf(maker), expectedMaker);
    assertEq(collateral.balanceOf(taker), expectedTaker);

    uint256 expectedTreasury = treasuryBefore + (takerFee * 5000) / BPS;
    uint256 expectedDistributor = distributorBefore + (takerFee * 3000) / BPS;
    uint256 expectedNetwork = networkBefore + takerFee - (takerFee * 5000) / BPS - (takerFee * 3000) / BPS;

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

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig);

    uint256 yesId = conditionalTokens.getTokenId(0, 0);

    assertEq(conditionalTokens.balanceOf(taker, yesId), amount);

    uint256 notional = (amount * priceSell) / ONE;
    uint256 makerRebate = (notional * 100) / BPS;
    uint256 takerFee = (notional * 200) / BPS;

    assertEq(collateral.balanceOf(maker), makerBefore + notional + makerRebate);
    assertEq(collateral.balanceOf(taker), takerBefore - notional - makerRebate - takerFee);
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

    feeModule.matchOrdersWithFees(makerOrder, makerSig, takerOrder, takerSig);

    uint256 yesNotional = (amount * priceYes) / ONE;
    uint256 noNotional = (amount * priceNo) / ONE;
    uint256 makerRebate = (yesNotional * 100) / BPS;
    uint256 takerFee = (noNotional * 200) / BPS;

    assertEq(collateral.balanceOf(sellerYes), yesBefore + yesNotional + makerRebate);
    assertEq(collateral.balanceOf(sellerNo), noBefore + noNotional - makerRebate - takerFee);
  }

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
