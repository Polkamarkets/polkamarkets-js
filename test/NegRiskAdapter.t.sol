// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../contracts/AdminRegistry.sol";
import "../contracts/PredictionMarketV3ManagerCLOB.sol";
import "../contracts/ConditionalTokens.sol";
import "../contracts/MyriadCTFExchange.sol";
import "../contracts/FeeModule.sol";
import "../contracts/IMyriadMarketManager.sol";
import "../contracts/WrappedCollateral.sol";
import "../contracts/NegRiskAdapter.sol";
import "../contracts/IMarketOracle.sol";
import "../contracts/Outcomes.sol";

contract MockERC20NR is ERC20 {
  constructor() ERC20("Collateral", "COL") {}
  function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract NegRiskAdapterTest is Test, ERC1155Holder {
  uint256 private constant ONE = 1e18;
  uint256 private constant BPS = 10000;

  AdminRegistry internal registry;
  PredictionMarketV3ManagerCLOB internal manager;
  ConditionalTokens internal conditionalTokens;
  MyriadCTFExchange internal exchange;
  FeeModule internal feeModule;
  MockERC20NR internal collateral;
  WrappedCollateral internal wcol;
  NegRiskAdapter internal adapter;

  address internal admin;
  address internal operator;
  address internal treasury;
  address internal alice;
  address internal bob;
  address internal charlie;

  uint256 internal alicePk = 0xA11CE;
  uint256 internal bobPk = 0xB0B;
  uint256 internal charliePk = 0xC4A;

  function setUp() public {
    admin = address(this);
    operator = address(this);
    treasury = address(0xBEEF);
    alice = vm.addr(alicePk);
    bob = vm.addr(bobPk);
    charlie = vm.addr(charliePk);

    collateral = new MockERC20NR();

    registry = new AdminRegistry(admin);
    PredictionMarketV3ManagerCLOB managerImpl = new PredictionMarketV3ManagerCLOB();
    manager = PredictionMarketV3ManagerCLOB(address(new ERC1967Proxy(
      address(managerImpl),
      abi.encodeCall(PredictionMarketV3ManagerCLOB.initialize, (registry, IERC20(address(collateral))))
    )));
    conditionalTokens = new ConditionalTokens(registry, IMyriadMarketManager(address(manager)));
    FeeModule feeModuleImpl = new FeeModule();
    feeModule = FeeModule(address(new ERC1967Proxy(
      address(feeModuleImpl),
      abi.encodeCall(FeeModule.initialize, (registry, treasury))
    )));
    MyriadCTFExchange exchangeImpl = new MyriadCTFExchange();
    exchange = MyriadCTFExchange(address(new ERC1967Proxy(
      address(exchangeImpl),
      abi.encodeCall(MyriadCTFExchange.initialize, (
        IMyriadMarketManager(address(manager)), conditionalTokens, address(feeModule), registry
      ))
    )));

    feeModule.setExchange(address(exchange));

    registry.grantRole(registry.MARKET_ADMIN_ROLE(), admin);
    registry.grantRole(registry.FEE_ADMIN_ROLE(), admin);
    registry.grantRole(registry.OPERATOR_ROLE(), operator);
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), admin);

    // Deploy WrappedCollateral and NegRiskAdapter
    // Predict adapter address for wcol constructor
    uint64 nonce = vm.getNonce(address(this));
    address predictedAdapter = vm.computeCreateAddress(address(this), nonce + 1);

    wcol = new WrappedCollateral(IERC20(address(collateral)), predictedAdapter);
    adapter = new NegRiskAdapter(
      registry,
      manager,
      conditionalTokens,
      wcol,
      treasury
    );
    require(address(adapter) == predictedAdapter, "adapter address mismatch");

    manager.setNegRiskAdapter(address(adapter));
    exchange.setNegRiskAdapter(address(adapter));
    adapter.setExchange(address(exchange));

    registry.grantRole(registry.MARKET_ADMIN_ROLE(), address(adapter));
    registry.grantRole(registry.RESOLUTION_ADMIN_ROLE(), address(adapter));
  }

  // =========================================================================
  // Event creation
  // =========================================================================

  function testCreateEvent() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();

    assertEq(marketIds.length, 3);

    (uint256 outcomeCount, bool resolved, int256 winningIndex, uint256[] memory ids,) = adapter.getEvent(eventId);
    assertEq(outcomeCount, 3);
    assertFalse(resolved);
    assertEq(winningIndex, -2); // unresolved sentinel
    assertEq(ids.length, 3);

    for (uint256 i = 0; i < 3; i++) {
      assertTrue(manager.isNegRisk(ids[i]));
      assertEq(manager.getEventId(ids[i]), eventId);
      assertEq(address(manager.getMarketCollateral(ids[i])), address(wcol));
    }
  }

  function testCreateEventRequiresAtLeast2Outcomes() public {
    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](1);
    params[0] = _mkParam("Only");
    vm.expectRevert("need >= 2 outcomes");
    adapter.createEvent("Duplicate event", params);
  }

  function testCreateEventClosesAtMismatchReverts() public {
    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](3);
    params[0] = _mkParam("Trump");
    params[1] = _mkParam("Harris");
    params[2] = PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 2 days,
      question: "Biden",
      image: "",
      feeModule: address(feeModule),
      oracle: address(0),
      oracleData: ""
    });
    vm.expectRevert("closesAt mismatch");
    adapter.createEvent("Who will win?", params);
  }

  // =========================================================================
  // Split / Merge
  // =========================================================================

  function testSplitAndMerge() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    collateral.mint(alice, amount);

    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    vm.stopPrank();

    uint256 yesTokenId = conditionalTokens.getTokenId(marketIds[0], Outcomes.YES);
    uint256 noTokenId = conditionalTokens.getTokenId(marketIds[0], Outcomes.NO);

    assertEq(conditionalTokens.balanceOf(alice, yesTokenId), amount);
    assertEq(conditionalTokens.balanceOf(alice, noTokenId), amount);
    assertEq(collateral.balanceOf(alice), 0);

    // Merge back
    vm.startPrank(alice);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.mergePositions(eventId, 0, amount);
    vm.stopPrank();

    assertEq(conditionalTokens.balanceOf(alice, yesTokenId), 0);
    assertEq(conditionalTokens.balanceOf(alice, noTokenId), 0);
    assertEq(collateral.balanceOf(alice), amount);
  }

  // =========================================================================
  // Convert
  // =========================================================================

  function testConvertPositions() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 50 ether;

    // Give alice NO tokens for outcome 0 (split, then she only uses the NO side)
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);

    // Alice now has YES(0) + NO(0). She converts NO(0) → YES(1) + YES(2)
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    // Alice should have YES(0), YES(1), YES(2) — one of each
    for (uint256 i = 0; i < 3; i++) {
      uint256 yesTokenId = conditionalTokens.getTokenId(marketIds[i], Outcomes.YES);
      assertEq(conditionalTokens.balanceOf(alice, yesTokenId), amount, "missing YES token");
    }

    // Alice should have no NO tokens for outcome 0
    uint256 noTokenId0 = conditionalTokens.getTokenId(marketIds[0], Outcomes.NO);
    assertEq(conditionalTokens.balanceOf(alice, noTokenId0), 0);

    // Adapter should hold NO tokens for all 3 markets
    for (uint256 i = 0; i < 3; i++) {
      uint256 noTokenId = conditionalTokens.getTokenId(marketIds[i], Outcomes.NO);
      assertEq(conditionalTokens.balanceOf(address(adapter), noTokenId), amount);
    }

    // Minted wcol should be tracked
    assertEq(adapter.mintedWcolPerEvent(eventId), 2 * amount);
  }

  // =========================================================================
  // MintAllYesTokens (used by exchange for cross-market matching)
  // =========================================================================

  function testMintAllYesTokens() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 30 ether;

    // Mint wcol to the exchange (simulating what happens during cross-market match)
    collateral.mint(address(exchange), amount);
    vm.startPrank(address(exchange));
    collateral.approve(address(wcol), amount);
    wcol.wrap(amount);
    IERC20(address(wcol)).approve(address(adapter), amount);

    adapter.mintAllYesTokens(eventId, amount, address(exchange));
    vm.stopPrank();

    // Exchange (recipient) should have YES for all 3 outcomes
    for (uint256 i = 0; i < 3; i++) {
      uint256 yesTokenId = conditionalTokens.getTokenId(marketIds[i], Outcomes.YES);
      assertEq(conditionalTokens.balanceOf(address(exchange), yesTokenId), amount);
    }

    // Adapter holds NO for all 3 outcomes
    for (uint256 i = 0; i < 3; i++) {
      uint256 noTokenId = conditionalTokens.getTokenId(marketIds[i], Outcomes.NO);
      assertEq(conditionalTokens.balanceOf(address(adapter), noTokenId), amount);
    }

    // Minted = (3-1) * 30 = 60 ether
    assertEq(adapter.mintedWcolPerEvent(eventId), 2 * amount);
  }

  // =========================================================================
  // Resolution: named outcome wins
  // =========================================================================

  function testResolveNamedOutcome() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Alice splits in outcome 0 and converts → YES(0), YES(1), YES(2)
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    // Fast-forward past market close
    vm.warp(block.timestamp + 2 days);

    // Resolve: outcome 1 wins
    adapter.resolveEvent(eventId, 1);

    (,bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, 1);

    // Market 0 should be resolved with outcome 1 (NO wins)
    assertEq(manager.getMarketResolvedOutcome(marketIds[0]), 1);
    // Market 1 should be resolved with outcome 0 (YES wins)
    assertEq(manager.getMarketResolvedOutcome(marketIds[1]), 0);
    // Market 2 should be resolved with outcome 1 (NO wins)
    assertEq(manager.getMarketResolvedOutcome(marketIds[2]), 1);

    // Alice redeems YES(1) → gets collateral
    uint256 yesTokenId1 = conditionalTokens.getTokenId(marketIds[1], Outcomes.YES);
    uint256 aliceYes1Balance = conditionalTokens.balanceOf(alice, yesTokenId1);
    assertEq(aliceYes1Balance, amount);

    vm.prank(alice);
    conditionalTokens.redeemPosition(marketIds[1]);

    // Alice gets wcol, needs to unwrap
    uint256 aliceWcol = wcol.balanceOf(alice);
    assertEq(aliceWcol, amount);
    vm.prank(alice);
    wcol.unwrap(amount);
    assertEq(collateral.balanceOf(alice), amount);

    // Adapter redeems NO positions and cleans up
    adapter.redeemNOPositions(eventId);
    assertEq(adapter.mintedWcolPerEvent(eventId), 0);
  }

  // =========================================================================
  // Resolution: "Other" wins (all resolve NO)
  // =========================================================================

  function testResolveOtherWins() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Bob splits in outcome 0, keeps YES(0) and NO(0)
    collateral.mint(bob, amount);
    vm.startPrank(bob);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    vm.stopPrank();

    vm.warp(block.timestamp + 2 days);

    // Resolve: "Other" wins (-1)
    adapter.resolveEvent(eventId, -1);

    // All markets should resolve with outcome 1 (NO wins)
    for (uint256 i = 0; i < 3; i++) {
      assertEq(manager.getMarketResolvedOutcome(marketIds[i]), 1);
    }

    // Bob's YES(0) is worthless, but NO(0) is redeemable
    uint256 noTokenId0 = conditionalTokens.getTokenId(marketIds[0], Outcomes.NO);
    uint256 bobNo0 = conditionalTokens.balanceOf(bob, noTokenId0);
    assertEq(bobNo0, amount);

    vm.prank(bob);
    conditionalTokens.redeemPosition(marketIds[0]);

    uint256 bobWcol = wcol.balanceOf(bob);
    assertEq(bobWcol, amount);
    vm.prank(bob);
    wcol.unwrap(amount);
    assertEq(collateral.balanceOf(bob), amount);
  }

  // =========================================================================
  // Cross-market matching via exchange
  // =========================================================================

  function testCrossMarketMatch() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Set fees for all markets
    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 100, 200); // 1% maker, 2% taker
    }

    // Give alice, bob, charlie collateral and wcol
    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    // Prices: 0.45 + 0.35 + 0.20 = 1.00
    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order memory order0 = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price0, 1);
    MyriadCTFExchange.Order memory order1 = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price1, 2);
    MyriadCTFExchange.Order memory order2 = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price2, 3);

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = order0;
    orders[1] = order1;
    orders[2] = order2;

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(order0, alicePk);
    sigs[1] = _signOrder(order1, bobPk);
    sigs[2] = _signOrder(order2, charliePk);

    exchange.matchCrossMarketOrders(orders, sigs, amount);

    // Full shares minted — fees added on top of each party's notional
    assertEq(conditionalTokens.balanceOf(alice, conditionalTokens.getTokenId(marketIds[0], Outcomes.YES)), amount);
    assertEq(conditionalTokens.balanceOf(bob, conditionalTokens.getTokenId(marketIds[1], Outcomes.YES)), amount);
    assertEq(conditionalTokens.balanceOf(charlie, conditionalTokens.getTokenId(marketIds[2], Outcomes.YES)), amount);

    bytes32 hash0 = exchange.hashOrder(order0);
    assertEq(exchange.filledAmounts(hash0), amount);
  }

  function testCrossMarketMatchPriceSumNot1Reverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();

    // Prices don't sum to 1
    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (19 * ONE) / 100; // sum = 0.99

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, 10 ether, price0, 1);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, 10 ether, price1, 2);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, 10 ether, price2, 3);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    vm.expectRevert("price sum < 1");
    exchange.matchCrossMarketOrders(orders, sigs, 10 ether);
  }

  // =========================================================================
  // Cross-market maker/taker fee distinction
  // =========================================================================

  function testCrossMarketMakerTakerFees() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Set distinct maker/taker fees: 1% maker, 3% taker
    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 100, 300);
    }

    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    // Prices: 0.40 + 0.30 + 0.30 = 1.00
    uint256 price0 = (40 * ONE) / 100;
    uint256 price1 = (30 * ONE) / 100;
    uint256 price2 = (30 * ONE) / 100;

    // Last order (charlie) is the taker, charged takerBps (3%)
    // First two (alice, bob) are makers, charged makerBps (1%)
    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price0, 10);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price1, 20);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price2, 30);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    uint256 aliceBefore = wcol.balanceOf(alice);
    uint256 bobBefore = wcol.balanceOf(bob);
    uint256 charlieBefore = wcol.balanceOf(charlie);

    exchange.matchCrossMarketOrders(orders, sigs, amount);

    uint256 aliceSpent = aliceBefore - wcol.balanceOf(alice);
    uint256 bobSpent = bobBefore - wcol.balanceOf(bob);
    uint256 charlieSpent = charlieBefore - wcol.balanceOf(charlie);

    uint256 aliceNotional = (amount * price0) / ONE;
    uint256 aliceFee = (aliceNotional * 100) / BPS;
    assertEq(aliceSpent, aliceNotional + aliceFee, "alice pays notional + fee");

    uint256 bobNotional = (amount * price1) / ONE;
    uint256 bobFee = (bobNotional * 100) / BPS;
    assertEq(bobSpent, bobNotional + bobFee, "bob pays notional + fee");

    uint256 charlieNotional = (amount * price2) / ONE;
    uint256 charlieFee = (charlieNotional * 300) / BPS;
    assertEq(charlieSpent, charlieNotional + charlieFee, "charlie pays notional + fee");

    uint256 totalFees = aliceFee + bobFee + charlieFee;
    assertEq(wcol.balanceOf(address(feeModule)), totalFees, "feeModule received fees");
  }

  // =========================================================================
  // Cross-market surplus (priceSum > ONE)
  // =========================================================================

  function testCrossMarketSurplusGoesToFeeModule() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 fillAmount = 100 ether;

    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 0, 0);
    }

    uint256 fundAmount = 200 ether;
    address[3] memory users = [alice, bob, charlie];
    uint256[3] memory pks = [alicePk, bobPk, charliePk];
    for (uint256 i = 0; i < 3; i++) {
      collateral.mint(users[i], fundAmount);
      vm.startPrank(users[i]);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    // priceSum = 0.60 + 0.60 + 0.10 = 1.30
    uint256 price0 = (60 * ONE) / 100;
    uint256 price1 = (60 * ONE) / 100;
    uint256 price2 = (10 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price0, 200);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price1, 201);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price2, 202);

    bytes[] memory sigs = new bytes[](3);
    for (uint256 i = 0; i < 3; i++) {
      sigs[i] = _signOrder(orders[i], pks[i]);
    }

    uint256 aliceBefore = wcol.balanceOf(alice);
    uint256 bobBefore = wcol.balanceOf(bob);
    uint256 charlieBefore = wcol.balanceOf(charlie);
    uint256 feeModuleBefore = wcol.balanceOf(address(feeModule));

    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);

    // Each buyer pays their own notional — no free tokens
    uint256 aliceNotional = (fillAmount * price0) / ONE;
    uint256 bobNotional = (fillAmount * price1) / ONE;
    uint256 charlieNotional = (fillAmount * price2) / ONE;

    assertEq(aliceBefore - wcol.balanceOf(alice), aliceNotional, "alice pays her notional");
    assertEq(bobBefore - wcol.balanceOf(bob), bobNotional, "bob pays his notional");
    assertEq(charlieBefore - wcol.balanceOf(charlie), charlieNotional, "charlie pays his notional");

    // All three received their YES tokens
    for (uint256 i = 0; i < 3; i++) {
      assertEq(conditionalTokens.balanceOf(users[i], conditionalTokens.getTokenId(marketIds[i], Outcomes.YES)), fillAmount);
    }

    // Surplus = totalNotional - fillAmount = 130 - 100 = 30 → sent to feeModule
    uint256 surplus = (aliceNotional + bobNotional + charlieNotional) - fillAmount;
    assertEq(surplus, 30 ether, "surplus is 30");
    assertEq(wcol.balanceOf(address(feeModule)) - feeModuleBefore, surplus, "feeModule received surplus");

    // Nothing stuck in exchange
    assertEq(wcol.balanceOf(address(exchange)), 0, "exchange has no stuck funds");
  }

  function testCrossMarketSurplusEmitsEvent() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 fillAmount = 100 ether;

    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 0, 0);
    }

    uint256 fundAmount = 200 ether;
    address[3] memory users = [alice, bob, charlie];
    uint256[3] memory pks = [alicePk, bobPk, charliePk];
    for (uint256 i = 0; i < 3; i++) {
      collateral.mint(users[i], fundAmount);
      vm.startPrank(users[i]);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    bytes32 eventId = manager.getEventId(marketIds[0]);

    // priceSum = 0.50 + 0.40 + 0.30 = 1.20
    uint256 price0 = (50 * ONE) / 100;
    uint256 price1 = (40 * ONE) / 100;
    uint256 price2 = (30 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price0, 300);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price1, 301);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price2, 302);

    bytes[] memory sigs = new bytes[](3);
    for (uint256 i = 0; i < 3; i++) {
      sigs[i] = _signOrder(orders[i], pks[i]);
    }

    uint256 expectedSurplus = (fillAmount * price0) / ONE + (fillAmount * price1) / ONE + (fillAmount * price2) / ONE - fillAmount;

    vm.expectEmit(true, false, false, true, address(exchange));
    emit MyriadCTFExchange.SurplusCollected(eventId, expectedSurplus);

    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);
  }

  function testCrossMarketSurplusWithFees() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 fillAmount = 100 ether;

    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 100, 200); // 1% maker, 2% taker
    }

    uint256 fundAmount = 200 ether;
    address[3] memory users = [alice, bob, charlie];
    uint256[3] memory pks = [alicePk, bobPk, charliePk];
    for (uint256 i = 0; i < 3; i++) {
      collateral.mint(users[i], fundAmount);
      vm.startPrank(users[i]);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    // priceSum = 0.50 + 0.40 + 0.20 = 1.10
    uint256 price0 = (50 * ONE) / 100;
    uint256 price1 = (40 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price0, 400);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price1, 401);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price2, 402);

    bytes[] memory sigs = new bytes[](3);
    for (uint256 i = 0; i < 3; i++) {
      sigs[i] = _signOrder(orders[i], pks[i]);
    }

    uint256 aliceBefore = wcol.balanceOf(alice);
    uint256 bobBefore = wcol.balanceOf(bob);
    uint256 charlieBefore = wcol.balanceOf(charlie);
    uint256 feeModuleBefore = wcol.balanceOf(address(feeModule));

    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);

    // Each buyer pays notional + their respective fee
    uint256 aliceNotional = (fillAmount * price0) / ONE;
    uint256 aliceFee = (aliceNotional * 100) / BPS; // 1% maker
    assertEq(aliceBefore - wcol.balanceOf(alice), aliceNotional + aliceFee, "alice pays notional + maker fee");

    uint256 bobNotional = (fillAmount * price1) / ONE;
    uint256 bobFee = (bobNotional * 100) / BPS; // 1% maker
    assertEq(bobBefore - wcol.balanceOf(bob), bobNotional + bobFee, "bob pays notional + maker fee");

    uint256 charlieNotional = (fillAmount * price2) / ONE;
    uint256 charlieFee = (charlieNotional * 200) / BPS; // 2% taker
    assertEq(charlieBefore - wcol.balanceOf(charlie), charlieNotional + charlieFee, "charlie pays notional + taker fee");

    // feeModule receives surplus + all fees
    uint256 surplus = (aliceNotional + bobNotional + charlieNotional) - fillAmount;
    uint256 totalFees = aliceFee + bobFee + charlieFee;
    assertEq(
      wcol.balanceOf(address(feeModule)) - feeModuleBefore,
      surplus + totalFees,
      "feeModule received surplus + fees"
    );
  }

  function testCrossMarketNoSurplusWhenPriceSumExactlyOne() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 fillAmount = 100 ether;

    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 0, 0);
    }

    uint256 fundAmount = 200 ether;
    address[3] memory users = [alice, bob, charlie];
    uint256[3] memory pks = [alicePk, bobPk, charliePk];
    for (uint256 i = 0; i < 3; i++) {
      collateral.mint(users[i], fundAmount);
      vm.startPrank(users[i]);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    // priceSum = 0.45 + 0.35 + 0.20 = 1.00 exactly
    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price0, 500);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price1, 501);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price2, 502);

    bytes[] memory sigs = new bytes[](3);
    for (uint256 i = 0; i < 3; i++) {
      sigs[i] = _signOrder(orders[i], pks[i]);
    }

    uint256 feeModuleBefore = wcol.balanceOf(address(feeModule));

    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);

    // No surplus, no fees → feeModule balance unchanged
    assertEq(wcol.balanceOf(address(feeModule)), feeModuleBefore, "no surplus when priceSum == ONE");
    assertEq(wcol.balanceOf(address(exchange)), 0, "exchange has no stuck funds");
  }

  function testCrossMarketRoundingShortfallHandled() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    // fillAmount that causes rounding: (1e18+1) * 0.45e18 / 1e18 rounds down
    uint256 fillAmount = 1 ether + 1;

    for (uint256 i = 0; i < 3; i++) {
      _setUniformFees(marketIds[i], 0, 0);
    }

    uint256 fundAmount = 10 ether;
    address[3] memory users = [alice, bob, charlie];
    uint256[3] memory pks = [alicePk, bobPk, charliePk];
    for (uint256 i = 0; i < 3; i++) {
      collateral.mint(users[i], fundAmount);
      vm.startPrank(users[i]);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    // priceSum = 0.45 + 0.35 + 0.20 = 1.00 exactly
    // With fillAmount = 1e18+1, naive notionals:
    //   floor((1e18+1) * 0.45e18 / 1e18) = 450000000000000000
    //   floor((1e18+1) * 0.35e18 / 1e18) = 350000000000000000
    //   floor((1e18+1) * 0.20e18 / 1e18) = 200000000000000000
    //   sum = 1e18, short by 1 wei — taker absorbs it
    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price0, 600);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price1, 601);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, fillAmount, price2, 602);

    bytes[] memory sigs = new bytes[](3);
    for (uint256 i = 0; i < 3; i++) {
      sigs[i] = _signOrder(orders[i], pks[i]);
    }

    uint256 charlieBefore = wcol.balanceOf(charlie);

    // Should not revert despite rounding shortfall
    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);

    // All buyers received their tokens
    for (uint256 i = 0; i < 3; i++) {
      assertEq(conditionalTokens.balanceOf(users[i], conditionalTokens.getTokenId(marketIds[i], Outcomes.YES)), fillAmount);
    }

    // Charlie (taker) paid 1 wei more than naive notional to cover rounding
    uint256 naiveNotional = (fillAmount * price2) / ONE;
    uint256 charlieActualPaid = charlieBefore - wcol.balanceOf(charlie);
    assertGt(charlieActualPaid, naiveNotional, "taker absorbed rounding dust");
    assertLe(charlieActualPaid - naiveNotional, 2, "dust is at most N-1 wei");

    // No stuck funds
    assertEq(wcol.balanceOf(address(exchange)), 0, "exchange has no stuck funds");
  }

  // =========================================================================
  // Cross-market front-run protection
  // =========================================================================

  function testCrossMarketInsufficientCollateralReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 200);

    uint256 fundAmount = 500 ether;
    // Fund alice and bob but NOT charlie
    for (uint256 i = 0; i < 2; i++) {
      address user = i == 0 ? alice : bob;
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      vm.stopPrank();
    }
    // charlie approves but has no funds
    vm.prank(charlie);
    IERC20(address(wcol)).approve(address(exchange), type(uint256).max);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price0, 1);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price1, 2);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price2, 3);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    vm.expectRevert("insufficient collateral");
    exchange.matchCrossMarketOrders(orders, sigs, 100 ether);
  }

  function testCrossMarketInsufficientAllowanceReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 200);

    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      if (i < 2) {
        IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      }
      // charlie does NOT approve exchange
      vm.stopPrank();
    }

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price0, 1);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price1, 2);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, 100 ether, price2, 3);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    vm.expectRevert("insufficient allowance");
    exchange.matchCrossMarketOrders(orders, sigs, 100 ether);
  }

  // =========================================================================
  // Cross-market min order amount & dust remainder
  // =========================================================================

  function testCrossMarketBelowMinAmountReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 200);

    exchange.setMinOrderAmount(10 ether);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, 5 ether, price0, 1);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, 5 ether, price1, 2);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, 5 ether, price2, 3);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    vm.expectRevert("below min amount");
    exchange.matchCrossMarketOrders(orders, sigs, 5 ether);
  }

  function testCrossMarketDustRemainderReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 200);

    exchange.setMinOrderAmount(10 ether);

    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    // alice has 25 ether order, fill 20 => remaining 5 < minOrderAmount(10)
    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, 25 ether, price0, 1);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, 20 ether, price1, 2);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, 20 ether, price2, 3);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    vm.expectRevert("dust remainder");
    exchange.matchCrossMarketOrders(orders, sigs, 20 ether);
  }

  function testCrossMarketExactRemainderAtMinAllowed() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 200);

    exchange.setMinOrderAmount(10 ether);

    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    // alice has 30 ether order, fill 20 => remaining 10 == minOrderAmount
    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, 30 ether, price0, 1);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, 20 ether, price1, 2);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, 20 ether, price2, 3);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    exchange.matchCrossMarketOrders(orders, sigs, 20 ether);

    bytes32 hash0 = exchange.hashOrder(orders[0]);
    assertEq(exchange.filledAmounts(hash0), 20 ether);
  }

  // =========================================================================
  // Cross-market merge (SELL YES)
  // =========================================================================

  function _setupBuyThenSell(
    uint256[] memory marketIds,
    uint256 amount
  ) internal returns (MyriadCTFExchange.Order[] memory buyOrders) {
    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 200);

    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    buyOrders = new MyriadCTFExchange.Order[](3);
    buyOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price0, 100);
    buyOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price1, 101);
    buyOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price2, 102);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(buyOrders[0], alicePk);
    sigs[1] = _signOrder(buyOrders[1], bobPk);
    sigs[2] = _signOrder(buyOrders[2], charliePk);

    exchange.matchCrossMarketOrders(buyOrders, sigs, amount);
  }

  function testMergeCrossMarketMatch() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 200);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 201);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 202);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);

    assertEq(conditionalTokens.balanceOf(alice, conditionalTokens.getTokenId(marketIds[0], Outcomes.YES)), 0);
    assertEq(conditionalTokens.balanceOf(bob, conditionalTokens.getTokenId(marketIds[1], Outcomes.YES)), 0);
    assertEq(conditionalTokens.balanceOf(charlie, conditionalTokens.getTokenId(marketIds[2], Outcomes.YES)), 0);

    bytes32 hash0 = exchange.hashOrder(sellOrders[0]);
    assertEq(exchange.filledAmounts(hash0), amount);
  }

  function testMergeCrossMarketPriceSumOver1Reverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (21 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 300);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 301);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 302);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    vm.expectRevert("price sum > 1");
    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);
  }

  function testMergeCrossMarketNotSellReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price0, 400);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 401);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 402);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    vm.expectRevert("not sell");
    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);
  }

  function testMergeCrossMarketInsufficientTokensReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    // Transfer away bob's YES tokens so he can't sell
    uint256 bobTokenId = conditionalTokens.getTokenId(marketIds[1], Outcomes.YES);
    vm.prank(bob);
    conditionalTokens.safeTransferFrom(bob, treasury, bobTokenId, amount, "");

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 500);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 501);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 502);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    vm.expectRevert("insufficient tokens");
    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);
  }

  function testMergeCrossMarketFeesCollected() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 600);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 601);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 602);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    uint256 feeModuleBefore = wcol.balanceOf(address(feeModule));

    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);

    uint256 feeModuleAfter = wcol.balanceOf(address(feeModule));
    assertTrue(feeModuleAfter > feeModuleBefore, "fees should be collected");
  }

  function testMergeCrossMarketSurplus() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (40 * ONE) / 100;
    uint256 price1 = (30 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 700);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 701);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 702);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);

    bytes32 hash0 = exchange.hashOrder(sellOrders[0]);
    assertEq(exchange.filledAmounts(hash0), amount);
  }

  function testMergeCrossMarketPartialFill() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;
    uint256 fillAmount = 40 ether;

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 800);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 801);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 802);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    exchange.mergeCrossMarketOrders(sellOrders, sigs, fillAmount);

    assertEq(conditionalTokens.balanceOf(alice, conditionalTokens.getTokenId(marketIds[0], Outcomes.YES)), amount - fillAmount);
    bytes32 hash0 = exchange.hashOrder(sellOrders[0]);
    assertEq(exchange.filledAmounts(hash0), fillAmount);
  }

  function testMergeCrossMarketMakerTakerFees() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    // Override fees after setup (which sets 1%/2%) to 1% maker / 3% taker
    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 300);

    uint256 price0 = (40 * ONE) / 100;
    uint256 price1 = (30 * ONE) / 100;
    uint256 price2 = (30 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 1100);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 1101);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 1102);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    uint256 aliceBefore = wcol.balanceOf(alice);
    uint256 bobBefore = wcol.balanceOf(bob);
    uint256 charlieBefore = wcol.balanceOf(charlie);
    uint256 feeModuleBefore = wcol.balanceOf(address(feeModule));

    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);

    uint256 aliceNotional = (amount * price0) / ONE;
    uint256 aliceFee = (aliceNotional * 100) / BPS;
    assertEq(wcol.balanceOf(alice) - aliceBefore, aliceNotional - aliceFee, "alice receives notional - makerFee");

    uint256 bobNotional = (amount * price1) / ONE;
    uint256 bobFee = (bobNotional * 100) / BPS;
    assertEq(wcol.balanceOf(bob) - bobBefore, bobNotional - bobFee, "bob receives notional - makerFee");

    uint256 charlieNotional = (amount * price2) / ONE;
    uint256 charlieFee = (charlieNotional * 300) / BPS;
    assertEq(wcol.balanceOf(charlie) - charlieBefore, charlieNotional - charlieFee, "charlie receives notional - takerFee");

    uint256 totalFees = aliceFee + bobFee + charlieFee;
    assertEq(wcol.balanceOf(address(feeModule)) - feeModuleBefore, totalFees, "feeModule received exact fees");
  }

  function testMergeCrossMarketSurplusEmitsEvent() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (40 * ONE) / 100;
    uint256 price1 = (30 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 1200);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 1201);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 1202);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    bytes32 eventId = manager.getEventId(marketIds[0]);
    uint256 expectedSurplus = amount - ((amount * price0) / ONE + (amount * price1) / ONE + (amount * price2) / ONE);

    vm.expectEmit(true, false, false, true, address(exchange));
    emit MyriadCTFExchange.SurplusCollected(eventId, expectedSurplus);

    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);
  }

  function testMergeCrossMarketSurplusWithFees() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 200);

    _setupBuyThenSell(marketIds, amount);

    uint256 price0 = (40 * ONE) / 100;
    uint256 price1 = (30 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 1300);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 1301);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 1302);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    uint256 feeModuleBefore = wcol.balanceOf(address(feeModule));

    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);

    uint256 n0 = (amount * price0) / ONE;
    uint256 n1 = (amount * price1) / ONE;
    uint256 n2 = (amount * price2) / ONE;
    uint256 totalNotional = n0 + n1 + n2;
    uint256 surplus = amount - totalNotional;
    uint256 fee0 = (n0 * 100) / BPS;
    uint256 fee1 = (n1 * 100) / BPS;
    uint256 fee2 = (n2 * 200) / BPS;
    uint256 totalFees = fee0 + fee1 + fee2;

    assertEq(wcol.balanceOf(address(feeModule)) - feeModuleBefore, surplus + totalFees, "feeModule gets surplus + fees");
  }

  function testMergeCrossMarketTokensNotApprovedReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);

    // Charlie revokes ERC-1155 approval for exchange
    vm.prank(charlie);
    conditionalTokens.setApprovalForAll(address(exchange), false);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 1400);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 1401);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 1402);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    vm.expectRevert("tokens not approved");
    exchange.mergeCrossMarketOrders(sellOrders, sigs, amount);
  }

  function testMergeCrossMarketBelowMinAmountReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    exchange.setMinOrderAmount(10 ether);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory orders = new MyriadCTFExchange.Order[](3);
    orders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, 5 ether, price0, 1500);
    orders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, 5 ether, price1, 1501);
    orders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, 5 ether, price2, 1502);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(orders[0], alicePk);
    sigs[1] = _signOrder(orders[1], bobPk);
    sigs[2] = _signOrder(orders[2], charliePk);

    vm.expectRevert("below min amount");
    exchange.mergeCrossMarketOrders(orders, sigs, 5 ether);
  }

  function testMergeCrossMarketDustRemainderReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);
    exchange.setMinOrderAmount(10 ether);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, 25 ether, price0, 1600);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, 20 ether, price1, 1601);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, 20 ether, price2, 1602);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    vm.expectRevert("dust remainder");
    exchange.mergeCrossMarketOrders(sellOrders, sigs, 20 ether);
  }

  function testMergeCrossMarketExactRemainderAtMinAllowed() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    _setupBuyThenSell(marketIds, amount);
    exchange.setMinOrderAmount(10 ether);

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, 30 ether, price0, 1700);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, 20 ether, price1, 1701);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, 20 ether, price2, 1702);

    bytes[] memory sigs = new bytes[](3);
    sigs[0] = _signOrder(sellOrders[0], alicePk);
    sigs[1] = _signOrder(sellOrders[1], bobPk);
    sigs[2] = _signOrder(sellOrders[2], charliePk);

    exchange.mergeCrossMarketOrders(sellOrders, sigs, 20 ether);

    bytes32 hash0 = exchange.hashOrder(sellOrders[0]);
    assertEq(exchange.filledAmounts(hash0), 20 ether);
  }

  function testMergeAllYesTokensOnlyExchangeReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();

    vm.prank(alice);
    vm.expectRevert("only exchange");
    adapter.mergeAllYesTokens(eventId, 10 ether);
  }

  function testMergeCrossMarketRoundTrip() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 0, 0);

    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      vm.startPrank(user);
      collateral.approve(address(wcol), fundAmount);
      wcol.wrap(fundAmount);
      IERC20(address(wcol)).approve(address(exchange), type(uint256).max);
      conditionalTokens.setApprovalForAll(address(exchange), true);
      vm.stopPrank();
    }

    uint256 price0 = (45 * ONE) / 100;
    uint256 price1 = (35 * ONE) / 100;
    uint256 price2 = (20 * ONE) / 100;

    uint256 aliceBefore = wcol.balanceOf(alice);
    uint256 bobBefore = wcol.balanceOf(bob);
    uint256 charlieBefore = wcol.balanceOf(charlie);

    // BUY mint
    MyriadCTFExchange.Order[] memory buyOrders = new MyriadCTFExchange.Order[](3);
    buyOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price0, 1800);
    buyOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price1, 1801);
    buyOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Buy, amount, price2, 1802);

    bytes[] memory buySigs = new bytes[](3);
    buySigs[0] = _signOrder(buyOrders[0], alicePk);
    buySigs[1] = _signOrder(buyOrders[1], bobPk);
    buySigs[2] = _signOrder(buyOrders[2], charliePk);

    exchange.matchCrossMarketOrders(buyOrders, buySigs, amount);

    // SELL merge at same prices
    MyriadCTFExchange.Order[] memory sellOrders = new MyriadCTFExchange.Order[](3);
    sellOrders[0] = _buildOrder(alice, marketIds[0], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price0, 1900);
    sellOrders[1] = _buildOrder(bob, marketIds[1], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price1, 1901);
    sellOrders[2] = _buildOrder(charlie, marketIds[2], Outcomes.YES, MyriadCTFExchange.Side.Sell, amount, price2, 1902);

    bytes[] memory sellSigs = new bytes[](3);
    sellSigs[0] = _signOrder(sellOrders[0], alicePk);
    sellSigs[1] = _signOrder(sellOrders[1], bobPk);
    sellSigs[2] = _signOrder(sellOrders[2], charliePk);

    exchange.mergeCrossMarketOrders(sellOrders, sellSigs, amount);

    // With 0% fees and priceSum == ONE, each trader should get back exactly what they paid
    assertEq(wcol.balanceOf(alice), aliceBefore, "alice wcol unchanged after round-trip");
    assertEq(wcol.balanceOf(bob), bobBefore, "bob wcol unchanged after round-trip");
    assertEq(wcol.balanceOf(charlie), charlieBefore, "charlie wcol unchanged after round-trip");

    // All YES tokens should be gone
    assertEq(conditionalTokens.balanceOf(alice, conditionalTokens.getTokenId(marketIds[0], Outcomes.YES)), 0);
    assertEq(conditionalTokens.balanceOf(bob, conditionalTokens.getTokenId(marketIds[1], Outcomes.YES)), 0);
    assertEq(conditionalTokens.balanceOf(charlie, conditionalTokens.getTokenId(marketIds[2], Outcomes.YES)), 0);
  }

  // =========================================================================
  // Void event
  // =========================================================================

  function testVoidEvent5050() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    vm.stopPrank();

    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = ONE / 2;
    yesPayouts[1] = ONE / 2;
    yesPayouts[2] = ONE / 2;

    vm.warp(block.timestamp + 2 days);
    adapter.voidEvent(eventId, yesPayouts);

    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, -2);

    for (uint256 i = 0; i < 3; i++) {
      assertEq(manager.getMarketResolvedOutcome(marketIds[i]), -1);
    }

    // Alice redeems voided position for market 0 (has YES + NO)
    vm.prank(alice);
    conditionalTokens.redeemVoided(marketIds[0]);

    uint256 aliceWcol = wcol.balanceOf(alice);
    assertEq(aliceWcol, amount);
    vm.prank(alice);
    wcol.unwrap(amount);
    assertEq(collateral.balanceOf(alice), amount);
  }

  function testVoidEventAsymmetricPayouts() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Alice splits in outcome 0 and converts → YES(0), YES(1), YES(2)
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = (60 * ONE) / 100;
    yesPayouts[1] = (30 * ONE) / 100;
    yesPayouts[2] = (10 * ONE) / 100;

    vm.warp(block.timestamp + 2 days);
    adapter.voidEvent(eventId, yesPayouts);

    // Alice holds YES for all 3 markets, redeem each
    for (uint256 i = 0; i < 3; i++) {
      vm.prank(alice);
      conditionalTokens.redeemVoided(marketIds[i]);
    }

    uint256 aliceWcol = wcol.balanceOf(alice);
    uint256 expected = (amount * 60) / 100 + (amount * 30) / 100 + (amount * 10) / 100;
    assertEq(aliceWcol, expected);
  }

  function testVoidEventRedeemNOPositions() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Alice splits and converts → adapter holds NO tokens + minted wcol
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    uint256 mintedBefore = adapter.mintedWcolPerEvent(eventId);
    assertGt(mintedBefore, 0);

    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = (50 * ONE) / 100;
    yesPayouts[1] = (50 * ONE) / 100;
    yesPayouts[2] = (50 * ONE) / 100;

    vm.warp(block.timestamp + 2 days);
    adapter.voidEvent(eventId, yesPayouts);

    // Adapter redeems its NO positions from voided markets
    adapter.redeemNOPositions(eventId);
    assertEq(adapter.mintedWcolPerEvent(eventId), 0);
    assertTrue(adapter.noPositionsRedeemed(eventId));
  }

  function testVoidEventLengthMismatchReverts() public {
    (bytes32 eventId,) = _createThreeOutcomeEvent();

    uint256[] memory yesPayouts = new uint256[](2);
    yesPayouts[0] = ONE / 2;
    yesPayouts[1] = ONE / 2;

    vm.expectRevert("length mismatch");
    adapter.voidEvent(eventId, yesPayouts);
  }

  function testVoidEventAlreadyResolvedReverts() public {
    (bytes32 eventId,) = _createThreeOutcomeEvent();
    vm.warp(block.timestamp + 2 days);
    adapter.resolveEvent(eventId, 0);

    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = ONE / 2;
    yesPayouts[1] = ONE / 2;
    yesPayouts[2] = ONE / 2;

    vm.expectRevert("already resolved");
    adapter.voidEvent(eventId, yesPayouts);
  }

  function testVoidEventNotResolutionAdminReverts() public {
    (bytes32 eventId,) = _createThreeOutcomeEvent();

    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = ONE / 2;
    yesPayouts[1] = ONE / 2;
    yesPayouts[2] = ONE / 2;

    vm.prank(alice);
    vm.expectRevert("not resolution admin");
    adapter.voidEvent(eventId, yesPayouts);
  }

  function testAdminVoidNegRiskDirectlyReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();

    vm.expectRevert("use adapter for neg risk");
    manager.adminVoidMarket(marketIds[0], ONE / 2, ONE / 2);
  }

  // =========================================================================
  // Access control tests
  // =========================================================================

  function testMintAllYesTokensOnlyExchangeReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    uint256 amount = 10 ether;
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(wcol), amount);
    wcol.wrap(amount);
    IERC20(address(wcol)).approve(address(adapter), amount);
    vm.expectRevert("only exchange");
    adapter.mintAllYesTokens(eventId, amount, alice);
    vm.stopPrank();
  }

  function testRedeemNOPositionsNotAdminReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    vm.warp(block.timestamp + 2 days);
    adapter.resolveEvent(eventId, 0);

    vm.prank(alice);
    vm.expectRevert("not admin");
    adapter.redeemNOPositions(eventId);
  }

  function testRedeemNOPositionsDoubleCallReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    vm.warp(block.timestamp + 2 days);
    adapter.resolveEvent(eventId, 0);

    adapter.redeemNOPositions(eventId);

    vm.expectRevert("already redeemed");
    adapter.redeemNOPositions(eventId);
  }

  // =========================================================================
  // Setter event tests
  // =========================================================================

  function testSetTreasuryEmitsEvent() public {
    address oldTreasury = adapter.treasury();
    address newTreasury = address(0xBEEF);
    vm.expectEmit(true, true, false, false, address(adapter));
    emit NegRiskAdapter.TreasuryUpdated(oldTreasury, newTreasury);
    adapter.setTreasury(newTreasury);
  }

  function testSetExchangeEmitsEvent() public {
    address oldExchange = adapter.exchange();
    address newExchange = address(0xCAFE);
    vm.expectEmit(true, true, false, false, address(adapter));
    emit NegRiskAdapter.ExchangeUpdated(oldExchange, newExchange);
    adapter.setExchange(newExchange);
  }

  // =========================================================================
  // WrappedCollateral tests
  // =========================================================================

  function testWrapUnwrap() public {
    uint256 amount = 100 ether;
    collateral.mint(alice, amount);

    vm.startPrank(alice);
    collateral.approve(address(wcol), amount);
    wcol.wrap(amount);
    assertEq(wcol.balanceOf(alice), amount);
    assertEq(collateral.balanceOf(alice), 0);

    wcol.unwrap(amount);
    assertEq(wcol.balanceOf(alice), 0);
    assertEq(collateral.balanceOf(alice), amount);
    vm.stopPrank();
  }

  function testAdapterMintOnlyAdapter() public {
    vm.expectRevert(WrappedCollateral.OnlyAdapter.selector);
    wcol.adapterMint(alice, 100 ether);
  }

  function testAdapterBurnOnlyAdapter() public {
    vm.expectRevert(WrappedCollateral.OnlyAdapter.selector);
    wcol.adapterBurn(alice, 100 ether);
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  function _createThreeOutcomeEvent() internal returns (bytes32 eventId, uint256[] memory marketIds) {
    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](3);
    params[0] = _mkParam("Trump");
    params[1] = _mkParam("Harris");
    params[2] = _mkParam("Biden");

    eventId = adapter.createEvent("Who will win?", params);
    marketIds = adapter.getEventMarkets(eventId);
  }

  function _mkParam(string memory question) internal view returns (PredictionMarketV3ManagerCLOB.CreateMarketParams memory) {
    return PredictionMarketV3ManagerCLOB.CreateMarketParams({
      closesAt: block.timestamp + 1 days,
      question: question,
      image: "",
      feeModule: address(feeModule),
      oracle: address(0),
      oracleData: ""
    });
  }

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
