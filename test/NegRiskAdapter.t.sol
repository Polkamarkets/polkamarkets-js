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

/// @notice Minimal oracle stub for tests: lets us program per-market outcomes.
contract MockMarketOracle is IMarketOracle {
  mapping(uint256 => int256) public outcomes;
  mapping(uint256 => bool) public isResolved;

  function initialize(uint256, bytes calldata) external override {}

  function setResult(uint256 marketId, int256 outcome, bool resolved_) external {
    outcomes[marketId] = outcome;
    isResolved[marketId] = resolved_;
  }

  function getResult(uint256 marketId) external view override returns (int256, bool) {
    return (outcomes[marketId], isResolved[marketId]);
  }
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

    collateral.mint(address(exchange), amount);
    vm.startPrank(address(exchange));
    collateral.approve(address(adapter), amount);

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
    adapter.adminResolveEvent(eventId, 1);

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
    adapter.adminResolveEvent(eventId, -1);

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
      collateral.approve(address(exchange), type(uint256).max);
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

    vm.expectRevert(MyriadCTFExchange.PriceSumBelowOne.selector);
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
      collateral.approve(address(exchange), type(uint256).max);
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

    uint256 aliceBefore = collateral.balanceOf(alice);
    uint256 bobBefore = collateral.balanceOf(bob);
    uint256 charlieBefore = collateral.balanceOf(charlie);

    exchange.matchCrossMarketOrders(orders, sigs, amount);

    uint256 aliceSpent = aliceBefore - collateral.balanceOf(alice);
    uint256 bobSpent = bobBefore - collateral.balanceOf(bob);
    uint256 charlieSpent = charlieBefore - collateral.balanceOf(charlie);

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
    assertEq(collateral.balanceOf(address(feeModule)), totalFees, "feeModule received fees");
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
      collateral.approve(address(exchange), type(uint256).max);
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

    uint256 aliceBefore = collateral.balanceOf(alice);
    uint256 bobBefore = collateral.balanceOf(bob);
    uint256 charlieBefore = collateral.balanceOf(charlie);
    uint256 feeModuleBefore = collateral.balanceOf(address(feeModule));

    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);

    // Each buyer pays their own notional — no free tokens
    uint256 aliceNotional = (fillAmount * price0) / ONE;
    uint256 bobNotional = (fillAmount * price1) / ONE;
    uint256 charlieNotional = (fillAmount * price2) / ONE;

    assertEq(aliceBefore - collateral.balanceOf(alice), aliceNotional, "alice pays her notional");
    assertEq(bobBefore - collateral.balanceOf(bob), bobNotional, "bob pays his notional");
    assertEq(charlieBefore - collateral.balanceOf(charlie), charlieNotional, "charlie pays his notional");

    // All three received their YES tokens
    for (uint256 i = 0; i < 3; i++) {
      assertEq(conditionalTokens.balanceOf(users[i], conditionalTokens.getTokenId(marketIds[i], Outcomes.YES)), fillAmount);
    }

    // Surplus = totalNotional - fillAmount = 130 - 100 = 30 → sent to feeModule
    uint256 surplus = (aliceNotional + bobNotional + charlieNotional) - fillAmount;
    assertEq(surplus, 30 ether, "surplus is 30");
    assertEq(collateral.balanceOf(address(feeModule)) - feeModuleBefore, surplus, "feeModule received surplus");

    // Nothing stuck in exchange (neither underlying nor wcol)
    assertEq(collateral.balanceOf(address(exchange)), 0, "exchange has no stuck underlying");
    assertEq(wcol.balanceOf(address(exchange)), 0, "exchange has no stuck wcol");
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
      collateral.approve(address(exchange), type(uint256).max);
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
      collateral.approve(address(exchange), type(uint256).max);
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

    uint256 aliceBefore = collateral.balanceOf(alice);
    uint256 bobBefore = collateral.balanceOf(bob);
    uint256 charlieBefore = collateral.balanceOf(charlie);
    uint256 feeModuleBefore = collateral.balanceOf(address(feeModule));

    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);

    // Each buyer pays notional + their respective fee
    uint256 aliceNotional = (fillAmount * price0) / ONE;
    uint256 aliceFee = (aliceNotional * 100) / BPS; // 1% maker
    assertEq(aliceBefore - collateral.balanceOf(alice), aliceNotional + aliceFee, "alice pays notional + maker fee");

    uint256 bobNotional = (fillAmount * price1) / ONE;
    uint256 bobFee = (bobNotional * 100) / BPS; // 1% maker
    assertEq(bobBefore - collateral.balanceOf(bob), bobNotional + bobFee, "bob pays notional + maker fee");

    uint256 charlieNotional = (fillAmount * price2) / ONE;
    uint256 charlieFee = (charlieNotional * 200) / BPS; // 2% taker
    assertEq(charlieBefore - collateral.balanceOf(charlie), charlieNotional + charlieFee, "charlie pays notional + taker fee");

    // feeModule receives surplus + all fees
    uint256 surplus = (aliceNotional + bobNotional + charlieNotional) - fillAmount;
    uint256 totalFees = aliceFee + bobFee + charlieFee;
    assertEq(
      collateral.balanceOf(address(feeModule)) - feeModuleBefore,
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
      collateral.approve(address(exchange), type(uint256).max);
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

    uint256 feeModuleBefore = collateral.balanceOf(address(feeModule));

    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);

    // No surplus, no fees → feeModule balance unchanged
    assertEq(collateral.balanceOf(address(feeModule)), feeModuleBefore, "no surplus when priceSum == ONE");
    assertEq(collateral.balanceOf(address(exchange)), 0, "exchange has no stuck underlying");
    assertEq(wcol.balanceOf(address(exchange)), 0, "exchange has no stuck wcol");
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
      collateral.approve(address(exchange), type(uint256).max);
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

    uint256 charlieBefore = collateral.balanceOf(charlie);

    // Should not revert despite rounding shortfall
    exchange.matchCrossMarketOrders(orders, sigs, fillAmount);

    // All buyers received their tokens
    for (uint256 i = 0; i < 3; i++) {
      assertEq(conditionalTokens.balanceOf(users[i], conditionalTokens.getTokenId(marketIds[i], Outcomes.YES)), fillAmount);
    }

    // Charlie (taker) paid 1 wei more than naive notional to cover rounding
    uint256 naiveNotional = (fillAmount * price2) / ONE;
    uint256 charlieActualPaid = charlieBefore - collateral.balanceOf(charlie);
    assertGt(charlieActualPaid, naiveNotional, "taker absorbed rounding dust");
    assertLe(charlieActualPaid - naiveNotional, 2, "dust is at most N-1 wei");

    // No stuck funds
    assertEq(collateral.balanceOf(address(exchange)), 0, "exchange has no stuck underlying");
    assertEq(wcol.balanceOf(address(exchange)), 0, "exchange has no stuck wcol");
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
      collateral.approve(address(exchange), type(uint256).max);
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

    vm.expectRevert(MyriadCTFExchange.InsufficientCollateral.selector);
    exchange.matchCrossMarketOrders(orders, sigs, 100 ether);
  }

  function testCrossMarketInsufficientAllowanceReverts() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();
    for (uint256 i = 0; i < 3; i++) _setUniformFees(marketIds[i], 100, 200);

    uint256 fundAmount = 500 ether;
    for (uint256 i = 0; i < 3; i++) {
      address user = i == 0 ? alice : (i == 1 ? bob : charlie);
      collateral.mint(user, fundAmount);
      if (i < 2) {
        vm.prank(user);
        collateral.approve(address(exchange), type(uint256).max);
      }
      // charlie does NOT approve exchange
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

    vm.expectRevert(MyriadCTFExchange.InsufficientAllowance.selector);
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

    vm.expectRevert(MyriadCTFExchange.BelowMinAmount.selector);
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
      collateral.approve(address(exchange), type(uint256).max);
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

    vm.expectRevert(MyriadCTFExchange.DustRemainder.selector);
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
      collateral.approve(address(exchange), type(uint256).max);
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

    // Payouts must sum to <= ONE (event-level solvency invariant).
    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = ONE / 2;
    yesPayouts[1] = ONE / 2;
    yesPayouts[2] = 0;

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

    // Payouts must sum to <= ONE (event-level solvency invariant).
    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = (40 * ONE) / 100;
    yesPayouts[1] = (30 * ONE) / 100;
    yesPayouts[2] = (30 * ONE) / 100;

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
    adapter.adminResolveEvent(eventId, 0);

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

  /// @notice Regression for H-01: voiding a neg-risk event with YES payouts that
  ///         sum above ONE would leave unbacked wcol in circulation that could be
  ///         used to drain later wrapper deposits. The adapter must reject this.
  function testVoidEventOverAllocatedReverts() public {
    (bytes32 eventId,) = _createThreeOutcomeEvent();
    uint256 amount = 100 ether;

    // Reproduce the bad-debt setup: Alice splits + converts so the adapter
    // mints unbacked wcol against the NO inventory it now holds.
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    assertEq(adapter.mintedWcolPerEvent(eventId), 200 ether);

    // 50/50/50 sums to 1.5 ONE — over-allocated.
    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = ONE / 2;
    yesPayouts[1] = ONE / 2;
    yesPayouts[2] = ONE / 2;

    vm.warp(block.timestamp + 2 days);
    vm.expectRevert("event payouts overallocated");
    adapter.voidEvent(eventId, yesPayouts);

    // Event remains unresolved — no state was mutated.
    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertFalse(resolved);
    assertEq(winningIndex, -2);
  }

  function testVoidEventPerPayoutCapReverts() public {
    (bytes32 eventId,) = _createThreeOutcomeEvent();

    // Individual payout above ONE is rejected before the underflow on NO side.
    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = ONE + 1;
    yesPayouts[1] = 0;
    yesPayouts[2] = 0;

    vm.warp(block.timestamp + 2 days);
    vm.expectRevert("yes payout > 1e18");
    adapter.voidEvent(eventId, yesPayouts);
  }

  // =========================================================================
  // Access control tests
  // =========================================================================

  function testMintAllYesTokensOnlyExchangeReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    uint256 amount = 10 ether;
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    vm.expectRevert("only exchange");
    adapter.mintAllYesTokens(eventId, amount, alice);
    vm.stopPrank();
  }

  function testRedeemNOPositionsNotAdminReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    vm.warp(block.timestamp + 2 days);
    adapter.adminResolveEvent(eventId, 0);

    vm.prank(alice);
    vm.expectRevert("not admin");
    adapter.redeemNOPositions(eventId);
  }

  function testRedeemNOPositionsDoubleCallReverts() public {
    (bytes32 eventId, ) = _createThreeOutcomeEvent();
    vm.warp(block.timestamp + 2 days);
    adapter.adminResolveEvent(eventId, 0);

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

  function testWrapOnlyAdapter() public {
    uint256 amount = 100 ether;
    collateral.mint(alice, amount);

    vm.startPrank(alice);
    collateral.approve(address(wcol), amount);
    vm.expectRevert(WrappedCollateral.OnlyAdapter.selector);
    wcol.wrap(amount);
    vm.stopPrank();
  }

  function testUnwrapIsPublic() public {
    uint256 amount = 100 ether;

    // Mimic a user receiving wcol via CT.redeemPosition: adapter-mints wcol
    // to alice; back it with matching underlying on the wcol contract.
    vm.prank(address(adapter));
    wcol.adapterMint(alice, amount);
    collateral.mint(address(wcol), amount);
    assertEq(wcol.balanceOf(alice), amount);
    assertEq(collateral.balanceOf(alice), 0);

    vm.prank(alice);
    wcol.unwrap(amount);
    assertEq(wcol.balanceOf(alice), 0);
    assertEq(collateral.balanceOf(alice), amount);
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
  // Per-market resolution of neg-risk markets (Phase A: !negRisk guards lifted)
  // =========================================================================

  function testResolveNegRiskMarketIndividually() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 4);

    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketIds[2], int256(Outcomes.NO), true);

    vm.prank(alice);
    int256 outcome = adapter.resolveEventMarket(eventId, 2);
    assertEq(outcome, int256(Outcomes.NO));
    assertEq(uint8(manager.getMarketState(marketIds[2])), uint8(IMyriadMarketManager.MarketState.resolved));

    for (uint256 i = 0; i < marketIds.length; i++) {
      if (i == 2) continue;
      assertTrue(uint8(manager.getMarketState(marketIds[i])) != uint8(IMyriadMarketManager.MarketState.resolved));
    }
  }

  function testResolveNegRiskMarketRevertsWhenOracleNotReady() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId,) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    vm.expectRevert("oracle: not resolved");
    adapter.resolveEventMarket(eventId, 1);
  }

  function testDirectResolveOnNegRiskRevertsAtManager() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);
    oracle.setResult(marketIds[0], int256(Outcomes.NO), true);

    vm.expectRevert("use resolveEvent for neg risk");
    manager.resolveMarket(marketIds[0]);
  }

  function testDirectAdminResolveOnNegRiskRevertsAtManager() public {
    (, uint256[] memory marketIds) = _createThreeOutcomeEvent();

    vm.warp(block.timestamp + 2 days);

    vm.expectRevert("use resolveEvent");
    manager.adminResolveMarket(marketIds[0], int256(Outcomes.YES));
  }

  function testAdminResolveEventMarketAllowed() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();

    vm.warp(block.timestamp + 2 days);

    adapter.adminResolveEventMarket(eventId, 0, int256(Outcomes.YES));
    assertEq(manager.getMarketResolvedOutcome(marketIds[0]), int256(Outcomes.YES));
  }

  function testAdminResolveEventMarketNotAdminReverts() public {
    (bytes32 eventId,) = _createThreeOutcomeEvent();

    vm.warp(block.timestamp + 2 days);

    vm.prank(alice);
    vm.expectRevert("not resolution admin");
    adapter.adminResolveEventMarket(eventId, 0, int256(Outcomes.YES));
  }

  function testAdminResolveEventMarketRejectsSecondYes() public {
    (bytes32 eventId, uint256[] memory marketIds) = _createThreeOutcomeEvent();

    vm.warp(block.timestamp + 2 days);

    // First admin YES finalizes the event and force-resolves the other markets to NO.
    adapter.adminResolveEventMarket(eventId, 0, int256(Outcomes.YES));
    assertEq(manager.getMarketResolvedOutcome(marketIds[1]), int256(Outcomes.NO));
    assertEq(manager.getMarketResolvedOutcome(marketIds[2]), int256(Outcomes.NO));

    // A second admin YES is rejected because the event is already finalized.
    vm.expectRevert("already resolved");
    adapter.adminResolveEventMarket(eventId, 1, int256(Outcomes.YES));
  }

  function testResolveEventMarketRejectsSecondYes() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketIds[0], int256(Outcomes.YES), true);
    oracle.setResult(marketIds[1], int256(Outcomes.YES), true);

    // The first YES finalizes the event and force-resolves the second oracle's
    // market to NO before the second call can even reach manager.resolveMarket.
    adapter.resolveEventMarket(eventId, 0);
    assertEq(manager.getMarketResolvedOutcome(marketIds[1]), int256(Outcomes.NO));

    vm.expectRevert("already resolved");
    adapter.resolveEventMarket(eventId, 1);
  }

  function testMidCompetitionResolutionFlow() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 4);

    vm.warp(block.timestamp + 2 days);

    // Two teams eliminated mid-competition — resolve as NO progressively via admin.
    adapter.adminResolveEventMarket(eventId, 0, int256(Outcomes.NO));
    adapter.adminResolveEventMarket(eventId, 1, int256(Outcomes.NO));

    // Final winner emerges and the YES per-market call finalizes the event,
    // force-resolving market 3 to NO atomically.
    oracle.setResult(marketIds[2], int256(Outcomes.YES), true);
    adapter.resolveEventMarket(eventId, 2);

    assertEq(manager.getMarketResolvedOutcome(marketIds[3]), int256(Outcomes.NO));

    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, 2);
  }

  function testResolveEventMarket_YesForcesOthersToNoAndFinalizes() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketIds[0], int256(Outcomes.YES), true);
    adapter.resolveEventMarket(eventId, 0);

    assertEq(manager.getMarketResolvedOutcome(marketIds[0]), int256(Outcomes.YES));
    assertEq(manager.getMarketResolvedOutcome(marketIds[1]), int256(Outcomes.NO));
    assertEq(manager.getMarketResolvedOutcome(marketIds[2]), int256(Outcomes.NO));

    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, 0);
  }

  function testResolveEventMarket_PreResolvedNoIsNotReResolved() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    // Pre-resolve market 1 as NO via its oracle.
    oracle.setResult(marketIds[1], int256(Outcomes.NO), true);
    adapter.resolveEventMarket(eventId, 1);

    // YES on market 0 should force market 2 to NO and skip the already-resolved market 1.
    oracle.setResult(marketIds[0], int256(Outcomes.YES), true);
    adapter.resolveEventMarket(eventId, 0);

    assertEq(manager.getMarketResolvedOutcome(marketIds[0]), int256(Outcomes.YES));
    assertEq(manager.getMarketResolvedOutcome(marketIds[1]), int256(Outcomes.NO));
    assertEq(manager.getMarketResolvedOutcome(marketIds[2]), int256(Outcomes.NO));

    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, 0);
  }

  function testResolveEventMarket_EmitsForcedNoForUnresolvedConstituents() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketIds[0], int256(Outcomes.YES), true);

    vm.expectEmit(true, false, false, true);
    emit NegRiskAdapter.EventMarketForcedNo(eventId, 1, marketIds[1]);
    vm.expectEmit(true, false, false, true);
    emit NegRiskAdapter.EventMarketForcedNo(eventId, 2, marketIds[2]);
    vm.expectEmit(true, false, false, true);
    emit NegRiskAdapter.EventResolved(eventId, 0);

    adapter.resolveEventMarket(eventId, 0);
  }

  // =========================================================================
  // Permissionless event resolution (Phase B)
  // =========================================================================

  function testResolveEventPermissionless_AllResolved() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 4);

    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketIds[0], int256(Outcomes.NO), true);
    oracle.setResult(marketIds[1], int256(Outcomes.YES), true);
    oracle.setResult(marketIds[2], int256(Outcomes.NO), true);
    oracle.setResult(marketIds[3], int256(Outcomes.NO), true);

    // Resolve the NO market first, then the YES market — the YES call
    // atomically force-resolves remaining markets (2, 3) to NO and finalizes.
    adapter.resolveEventMarket(eventId, 0);
    adapter.resolveEventMarket(eventId, 1);

    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, 1);
    assertEq(manager.getMarketResolvedOutcome(marketIds[2]), int256(Outcomes.NO));
    assertEq(manager.getMarketResolvedOutcome(marketIds[3]), int256(Outcomes.NO));
  }

  function testResolveEventPermissionless_NoYes_AllNo() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    for (uint256 i = 0; i < 3; i++) {
      oracle.setResult(marketIds[i], int256(Outcomes.NO), true);
      adapter.resolveEventMarket(eventId, i);
    }

    adapter.resolveEvent(eventId);

    (,, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertEq(winningIndex, -1);
  }

  function testResolveEventPermissionless_RevertsWhenMarketUnresolved() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketIds[0], int256(Outcomes.NO), true);
    adapter.resolveEventMarket(eventId, 0);
    // markets 1, 2 unresolved

    vm.expectRevert("market !resolved");
    adapter.resolveEvent(eventId);
  }

  /// @notice The adapter encodes mutual exclusivity forward: the first YES
  ///         finalizes the event and force-resolves the other markets to NO
  ///         before any second YES oracle can ever land. The original wedge —
  ///         where a dual-YES race left the second market permanently
  ///         unresolvable — is structurally unreachable.
  function testResolveEventPermissionless_RejectsSecondYesUpstream() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    oracle.setResult(marketIds[0], int256(Outcomes.YES), true);
    oracle.setResult(marketIds[1], int256(Outcomes.YES), true);
    adapter.resolveEventMarket(eventId, 0);

    // Second market was force-resolved to NO inside the first call; the event is finalized.
    assertEq(manager.getMarketResolvedOutcome(marketIds[1]), int256(Outcomes.NO));
    assertEq(manager.getMarketResolvedOutcome(marketIds[2]), int256(Outcomes.NO));

    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, 0);

    // A redundant second call is rejected because the event is already resolved.
    vm.expectRevert("already resolved");
    adapter.resolveEventMarket(eventId, 1);
  }

  function testResolveEventPermissionless_RevertsWhenAlreadyResolved() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);
    for (uint256 i = 0; i < 3; i++) {
      oracle.setResult(marketIds[i], int256(Outcomes.NO), true);
      adapter.resolveEventMarket(eventId, i);
    }
    adapter.resolveEvent(eventId);

    vm.expectRevert("already resolved");
    adapter.resolveEvent(eventId);
  }

  // =========================================================================
  // Admin event resolution overrides (Phase B)
  // =========================================================================

  function testAdminResolveEvent_FinalizesAllNoEvent() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 4);

    vm.warp(block.timestamp + 2 days);

    // Markets 0 and 2 pre-resolved NO via per-market — event remains unresolved
    // because there's no YES yet to trigger finalization.
    oracle.setResult(marketIds[0], int256(Outcomes.NO), true);
    oracle.setResult(marketIds[2], int256(Outcomes.NO), true);
    adapter.resolveEventMarket(eventId, 0);
    adapter.resolveEventMarket(eventId, 2);

    // Admin finalizes with the all-NO ("Other won") outcome, force-resolving the rest.
    adapter.adminResolveEvent(eventId, -1);

    for (uint256 i = 0; i < 4; i++) {
      assertEq(manager.getMarketResolvedOutcome(marketIds[i]), int256(Outcomes.NO));
    }

    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, -1);
  }

  function testAdminResolveEvent_RevertsWhenEventAlreadyResolved() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 4);

    vm.warp(block.timestamp + 2 days);

    // A per-market YES atomically finalizes the event — adminResolveEvent is no
    // longer needed and would conflict with the already-resolved state.
    oracle.setResult(marketIds[0], int256(Outcomes.YES), true);
    adapter.resolveEventMarket(eventId, 0);

    vm.expectRevert("already resolved");
    adapter.adminResolveEvent(eventId, 2);
  }

  function testVoidEventStillStrict() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);

    vm.warp(block.timestamp + 2 days);

    // market 0 pre-resolved
    oracle.setResult(marketIds[0], int256(Outcomes.NO), true);
    adapter.resolveEventMarket(eventId, 0);

    // Sum to ONE so the solvency check passes and the loop reaches market 0.
    uint256[] memory yesPayouts = new uint256[](3);
    yesPayouts[0] = ONE / 2;
    yesPayouts[1] = ONE / 4;
    yesPayouts[2] = ONE / 4;

    // adminVoidMarket on the already-resolved market 0 reverts inside the loop
    vm.expectRevert("resolved");
    adapter.voidEvent(eventId, yesPayouts);
  }

  // =========================================================================
  // wcol redemption integrity after mixed-order resolution (Phase B)
  // =========================================================================

  function testRedeemNOPositionsAfterMixedResolution() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 4);
    uint256 amount = 100 ether;

    // Alice splits in outcome 0 and converts → YES(0..3); adapter holds NO(0..3)
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    // Adapter minted (n-1)*amount = 3 * 100 = 300 wcol
    uint256 mintedBefore = adapter.mintedWcolPerEvent(eventId);
    assertEq(mintedBefore, 3 * amount);

    vm.warp(block.timestamp + 2 days);

    // Outcome 2 wins. Resolve markets 0, 1, 3 as NO via per-market path; the
    // YES on market 2 then finalizes the event and force-resolves anything
    // remaining (none here — all NOs already in) to NO.
    oracle.setResult(marketIds[0], int256(Outcomes.NO), true);
    oracle.setResult(marketIds[1], int256(Outcomes.NO), true);
    oracle.setResult(marketIds[2], int256(Outcomes.YES), true);
    oracle.setResult(marketIds[3], int256(Outcomes.NO), true);
    adapter.resolveEventMarket(eventId, 0);
    adapter.resolveEventMarket(eventId, 1);
    adapter.resolveEventMarket(eventId, 3);
    adapter.resolveEventMarket(eventId, 2);

    (,, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertEq(winningIndex, 2);

    // Alice redeems winning YES(2) → gets `amount` wcol
    vm.prank(alice);
    conditionalTokens.redeemPosition(marketIds[2]);
    assertEq(wcol.balanceOf(alice), amount);

    // Adapter cleans up: redeems its NO positions, burns the 300 minted, sends excess to treasury
    adapter.redeemNOPositions(eventId);
    assertEq(adapter.mintedWcolPerEvent(eventId), 0);
    assertTrue(adapter.noPositionsRedeemed(eventId));

    // Alice unwraps her wcol → underlying
    vm.prank(alice);
    wcol.unwrap(amount);
    assertEq(collateral.balanceOf(alice), amount);

    // Treasury should have received nothing extra: alice's deposit (amount) flowed through
    // the YES(2) winning side. The 3 NO redemptions netted exactly the 3*amount minted.
    assertEq(collateral.balanceOf(treasury), 0);
  }

  /// @notice Original audit scenario: two oracles independently return YES for
  ///         mutually exclusive constituents (an upstream invariant violation).
  ///         The forward-invariant fix ensures the first YES finalizes the event
  ///         and forces the others to NO, so `redeemNOPositions` runs without any
  ///         admin intervention.
  function testRedeemNOPositions_WorksAfterDualYesScenario() public {
    MockMarketOracle oracle = new MockMarketOracle();
    (bytes32 eventId, uint256[] memory marketIds) = _createEventWithOracle(address(oracle), 3);
    uint256 amount = 100 ether;

    // Alice creates NO positions in the adapter via split + convert.
    collateral.mint(alice, amount);
    vm.startPrank(alice);
    collateral.approve(address(adapter), amount);
    adapter.splitPosition(eventId, 0, amount);
    conditionalTokens.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(eventId, 0, amount);
    vm.stopPrank();

    vm.warp(block.timestamp + 2 days);

    // Two oracles report YES for the same event — the upstream fault scenario.
    oracle.setResult(marketIds[0], int256(Outcomes.YES), true);
    oracle.setResult(marketIds[1], int256(Outcomes.YES), true);

    // First-mover wins: m0 YES, m1 and m2 forced NO atomically, event finalized.
    adapter.resolveEventMarket(eventId, 0);

    (, bool resolved, int256 winningIndex,,) = adapter.getEvent(eventId);
    assertTrue(resolved);
    assertEq(winningIndex, 0);

    // The previously-wedging redeemNOPositions call now succeeds with no admin.
    adapter.redeemNOPositions(eventId);
    assertTrue(adapter.noPositionsRedeemed(eventId));
    assertEq(adapter.mintedWcolPerEvent(eventId), 0);
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

  function _createEventWithOracle(address oracle, uint256 outcomeCount)
    internal
    returns (bytes32 eventId, uint256[] memory marketIds)
  {
    PredictionMarketV3ManagerCLOB.CreateMarketParams[] memory params =
      new PredictionMarketV3ManagerCLOB.CreateMarketParams[](outcomeCount);
    for (uint256 i = 0; i < outcomeCount; i++) {
      params[i] = PredictionMarketV3ManagerCLOB.CreateMarketParams({
        closesAt: block.timestamp + 1 days,
        question: string(abi.encodePacked("Outcome ", _u2s(i))),
        image: "",
        feeModule: address(feeModule),
        oracle: oracle,
        oracleData: ""
      });
    }

    eventId = adapter.createEvent("Generic event", params);
    marketIds = adapter.getEventMarkets(eventId);
  }

  function _u2s(uint256 v) private pure returns (string memory) {
    if (v == 0) return "0";
    uint256 t = v; uint256 d;
    while (t != 0) { d++; t /= 10; }
    bytes memory b = new bytes(d);
    while (v != 0) { d--; b[d] = bytes1(uint8(48 + v % 10)); v /= 10; }
    return string(b);
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
