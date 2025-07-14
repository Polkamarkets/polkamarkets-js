// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Contract imports
import "../contracts/PredictionMarketV3_4.sol";
import "../contracts/PredictionMarketV3Manager.sol";
import "../contracts/WETH.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import {RealityETH_ERC20_v3_0} from "@reality.eth/contracts/development/contracts/RealityETH_ERC20-3.0.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PredictionMarketV3Test is Test {
    address public pmv34Implementation;
    PredictionMarketV3_4 public predictionMarket;
    PredictionMarketV3Manager public manager;
    RealityETH_ERC20_v3_0 public realitio;
    ERC20PresetMinterPauser public tokenERC20;
    ERC20PresetMinterPauser public managerTokenERC20;
    WETH public weth;

    address public user;
    address public treasury = address(0x123);
    address public distributor = address(0x456);

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant VALUE = 0.01 ether;

    event MarketCreated(
        address indexed user,
        uint256 indexed marketId,
        uint256 outcomes,
        string question,
        string image,
        address token
    );

    // Allow test contract to receive ETH
    receive() external payable {}

    function setUp() public {
        user = address(this);

        // Deploy contracts
        weth = new WETH();
        tokenERC20 = new ERC20PresetMinterPauser("Test Token", "TEST");
        managerTokenERC20 = new ERC20PresetMinterPauser("Manager Token", "MTEST");
        realitio = new RealityETH_ERC20_v3_0();

        // Deploy prediction market
        pmv34Implementation = address(new PredictionMarketV3_4());
        bytes memory initData = abi.encodeCall(PredictionMarketV3_4.initialize, IWETH(address(weth)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(pmv34Implementation),
            initData
        );
        predictionMarket = PredictionMarketV3_4(payable(address(proxy)));

        // Setup manager
        manager = new PredictionMarketV3Manager(address(predictionMarket), IERC20(address(managerTokenERC20)), 1 ether, address(realitio));
        managerTokenERC20.mint(user, 1000 ether);
        managerTokenERC20.approve(address(manager), type(uint256).max);
        manager.createLand(IERC20(address(tokenERC20)), IERC20(address(managerTokenERC20)));

        // Allow manager in prediction market
        predictionMarket.setAllowedManager(address(manager), true);

        // Setup tokens
        tokenERC20.mint(user, 1000 ether);
        tokenERC20.approve(address(predictionMarket), type(uint256).max);

        // Fund user with ETH for WETH tests
        vm.deal(user, INITIAL_BALANCE);
    }

    function testContractDeployment() public view {
        assertTrue(address(predictionMarket) != address(0));
        assertTrue(address(manager) != address(0));
        assertTrue(address(realitio) != address(0));
        assertTrue(address(tokenERC20) != address(0));
        assertTrue(address(weth) != address(0));

        assertEq(address(predictionMarket.WETH()), address(weth));
    }

    function testCreateMarket() public {
        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: IERC20(address(tokenERC20)),
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ in 30 days?",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        vm.expectEmit(true, true, false, false);
        emit MarketCreated(user, 0, 2, desc.question, desc.image, address(tokenERC20));

        uint256 marketId = predictionMarket.createMarket(desc);

        assertEq(marketId, 0);

        uint256[] memory markets = predictionMarket.getMarkets();
        assertEq(markets.length, 1);
        assertEq(markets[0], 0);
    }

    function testCreateMultipleMarkets() public {
        // First market
        PredictionMarketV3_4.CreateMarketDescription memory desc1 = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: IERC20(address(tokenERC20)),
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ in 30 days?",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        // Second market
        PredictionMarketV3_4.CreateMarketDescription memory desc2 = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: IERC20(address(tokenERC20)),
            distribution: new uint256[](0),
            question: "Will ETH price close above 10k$ in 30 days?",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 marketId1 = predictionMarket.createMarket(desc1);
        uint256 marketId2 = predictionMarket.createMarket(desc2);

        assertEq(marketId1, 0);
        assertEq(marketId2, 1);

        uint256[] memory markets = predictionMarket.getMarkets();
        assertEq(markets.length, 2);
    }

    function testGetMarketData() public {
        uint256 marketId = _createTestMarket();

        (
            PredictionMarketV3_4.MarketState state,
            uint256 closesAt,
            uint256 liquidity,
            uint256 balance,
            uint256 sharesAvailable,
            int256 resolvedOutcomeId
        ) = predictionMarket.getMarketData(marketId);

        assertEq(uint256(state), uint256(PredictionMarketV3_4.MarketState.open));
        assertGt(closesAt, block.timestamp);
        assertEq(liquidity, VALUE);
        assertGt(balance, 0);
        assertGt(sharesAvailable, 0);
        assertEq(resolvedOutcomeId, -1);
    }

    function testGetMarketPrices() public {
        uint256 marketId = _createTestMarket();

        (uint256 liquidityPrice, uint256[] memory outcomes) = predictionMarket.getMarketPrices(marketId);

        assertGt(liquidityPrice, 0);
        assertEq(outcomes.length, 2);

        // In a balanced market, each outcome should have 0.5 price
        assertEq(outcomes[0], 0.5 ether);
        assertEq(outcomes[1], 0.5 ether);

        // Prices should sum to 1
        assertEq(outcomes[0] + outcomes[1], 1 ether);
    }

    function testGetMarketShares() public {
        uint256 marketId = _createTestMarket();

        (uint256 liquidityShares, uint256[] memory outcomeShares) = predictionMarket.getMarketShares(marketId);

        assertGt(liquidityShares, 0);
        assertEq(outcomeShares.length, 2);

        // Each outcome should have equal shares in balanced market
        assertEq(outcomeShares[0], VALUE);
        assertEq(outcomeShares[1], VALUE);

        // Outcome shares should sum to value * 2
        assertEq(outcomeShares[0] + outcomeShares[1], VALUE * 2);
    }

    function testAddLiquidityBalancedMarket() public {
        uint256 marketId = _createTestMarket();

        // Get initial state
        (uint256 initialLiquidityShares,) = predictionMarket.getUserMarketShares(marketId, user);
        (,, uint256 initialLiquidity,,,) = predictionMarket.getMarketData(marketId);
        (uint256 initialLiquidityPrice, uint256[] memory initialPrices) = predictionMarket.getMarketPrices(marketId);

        // Add liquidity
        predictionMarket.addLiquidity(marketId, VALUE);

        // Check new state
        (uint256 newLiquidityShares,) = predictionMarket.getUserMarketShares(marketId, user);
        (,, uint256 newLiquidity,,,) = predictionMarket.getMarketData(marketId);
        (uint256 newLiquidityPrice, uint256[] memory newPrices) = predictionMarket.getMarketPrices(marketId);

        assertEq(newLiquidity, initialLiquidity + VALUE);
        assertEq(newLiquidityShares, initialLiquidityShares + VALUE);

        // Prices should remain the same in balanced market
        assertEq(newLiquidityPrice, initialLiquidityPrice);
        assertEq(newPrices[0], initialPrices[0]);
        assertEq(newPrices[1], initialPrices[1]);
    }

    function testRemoveLiquidityBalancedMarket() public {
        uint256 marketId = _createTestMarket();

        // Add some liquidity first
        predictionMarket.addLiquidity(marketId, VALUE);

        // Get state after adding liquidity
        (uint256 liquidityShares,) = predictionMarket.getUserMarketShares(marketId, user);
        (,, uint256 liquidity,,,) = predictionMarket.getMarketData(marketId);
        (uint256 liquidityPrice, uint256[] memory prices) = predictionMarket.getMarketPrices(marketId);
        uint256 initialBalance = tokenERC20.balanceOf(user);

        // Remove liquidity
        predictionMarket.removeLiquidity(marketId, VALUE);

        // Check new state
        (uint256 newLiquidityShares,) = predictionMarket.getUserMarketShares(marketId, user);
        (,, uint256 newLiquidity,,,) = predictionMarket.getMarketData(marketId);
        (uint256 newLiquidityPrice, uint256[] memory newPrices) = predictionMarket.getMarketPrices(marketId);
        uint256 newBalance = tokenERC20.balanceOf(user);

        assertEq(newLiquidity, liquidity - VALUE);
        assertEq(newLiquidityShares, liquidityShares - VALUE);
        assertGt(newBalance, initialBalance); // User should receive tokens back

        // Prices should remain the same in balanced market
        assertEq(newLiquidityPrice, liquidityPrice);
        assertEq(newPrices[0], prices[0]);
        assertEq(newPrices[1], prices[1]);
    }

    function testBuyOutcomeShares() public {
        uint256 marketId = _createTestMarket();
        uint256 outcomeId = 0;
        uint256 minShares = 0.015 ether;

        // Get initial state
        (uint256 initialPrice0, uint256 initialPrice1) = _getOutcomePrices(marketId);
        (,uint256[] memory initialShares) = predictionMarket.getMarketShares(marketId);
        (,uint256[] memory userInitialShares) = predictionMarket.getUserMarketShares(marketId, user);
        uint256 initialBalance = tokenERC20.balanceOf(address(predictionMarket));

        // Buy outcome shares
        predictionMarket.buy(marketId, outcomeId, minShares, VALUE);

        // Check new state
        (uint256 newPrice0, uint256 newPrice1) = _getOutcomePrices(marketId);
        (,uint256[] memory newShares) = predictionMarket.getMarketShares(marketId);
        (,uint256[] memory userNewShares) = predictionMarket.getUserMarketShares(marketId, user);
        uint256 newBalance = tokenERC20.balanceOf(address(predictionMarket));

        // Outcome 0 price should increase
        assertGt(newPrice0, initialPrice0);
        // Outcome 1 price should decrease
        assertLt(newPrice1, initialPrice1);
        // Prices should still sum to 1
        assertEq(newPrice0 + newPrice1, 1 ether);
        // Outcome 0 shares should decrease
        assertLt(newShares[outcomeId], initialShares[outcomeId]);
        // Outcome 1 shares should increase
        assertGt(newShares[1 - outcomeId], initialShares[1 - outcomeId]);

        // User should have outcome shares
        assertGt(userNewShares[outcomeId], userInitialShares[outcomeId]);

        // Contract balance should increase
        assertGt(newBalance, initialBalance);
    }

    function testSellOutcomeShares() public {
        uint256 marketId = _createTestMarket();
        uint256 outcomeId = 0;
        uint256 minShares = 0.015 ether;
        uint256 maxShares = 0.015 ether;

        // First buy some shares
        predictionMarket.buy(marketId, outcomeId, minShares, VALUE);

        // Get state after buying
        (uint256 priceAfterBuy0, uint256 priceAfterBuy1) = _getOutcomePrices(marketId);
        uint256 balanceAfterBuy = tokenERC20.balanceOf(address(predictionMarket));

        // Sell outcome shares
        predictionMarket.sell(marketId, outcomeId, VALUE, maxShares);

        // Check new state
        (uint256 priceAfterSell0, uint256 priceAfterSell1) = _getOutcomePrices(marketId);
        uint256 balanceAfterSell = tokenERC20.balanceOf(address(predictionMarket));

        // Outcome 0 price should decrease compared to after buy
        assertLt(priceAfterSell0, priceAfterBuy0);
        // Outcome 1 price should increase compared to after buy
        assertGt(priceAfterSell1, priceAfterBuy1);
        // Prices should still sum to 1
        assertEq(priceAfterSell0 + priceAfterSell1, 1 ether);

        // Contract balance should decrease
        assertLt(balanceAfterSell, balanceAfterBuy);
    }

    function testCreateMarketWithThreeOutcomes() public {
        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 3,
            token: IERC20(address(tokenERC20)),
            distribution: new uint256[](0),
            question: "Market with 3 outcomes",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 marketId = predictionMarket.createMarket(desc);

        uint256[] memory outcomeIds = predictionMarket.getMarketOutcomeIds(marketId);
        assertEq(outcomeIds.length, 3);
        assertEq(outcomeIds[0], 0);
        assertEq(outcomeIds[1], 1);
        assertEq(outcomeIds[2], 2);

        // Check that prices sum to 1
        (,uint256[] memory prices) = predictionMarket.getMarketPrices(marketId);
        assertEq(prices.length, 3);
        assert(1 ether - (prices[0] + prices[1] + prices[2]) <= 0.000000000000000001 ether);
    }

    function testCreateMarketWith32Outcomes() public {
        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 32,
            token: IERC20(address(tokenERC20)),
            distribution: new uint256[](0),
            question: "Market with 32 outcomes",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 marketId = predictionMarket.createMarket(desc);

        uint256[] memory outcomeIds = predictionMarket.getMarketOutcomeIds(marketId);
        assertEq(outcomeIds.length, 32);

        // Check that prices sum to 1
        (,uint256[] memory prices) = predictionMarket.getMarketPrices(marketId);
        assertEq(prices.length, 32);

        uint256 totalPrice = 0;
        for (uint256 i = 0; i < prices.length; i++) {
            totalPrice += prices[i];
        }
        assertEq(totalPrice, 1 ether);
    }

    function testCannotCreateMarketWithMoreThan32Outcomes() public {
        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 33,
            token: IERC20(address(tokenERC20)),
            distribution: new uint256[](0),
            question: "Market with 33 outcomes",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        vm.expectRevert(bytes("!oc"));
        predictionMarket.createMarket(desc);
    }

    function testCreateMarketWithFees() public {
        uint256 buyFee = 0.01 ether; // 1%
        uint256 treasuryFee = 0.02 ether; // 2%
        uint256 distributorFee = 0.03 ether; // 3%

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: IERC20(address(tokenERC20)),
            distribution: new uint256[](0),
            question: "Market with 1%/2%/3% Fees",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({
                fee: buyFee,
                treasuryFee: treasuryFee,
                distributorFee: distributorFee
            }),
            sellFees: PredictionMarketV3_4.Fees({
                fee: buyFee,
                treasuryFee: treasuryFee,
                distributorFee: distributorFee
            }),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 marketId = predictionMarket.createMarket(desc);

        predictionMarket.buy(marketId, 0, 0, 0.1 ether);

        uint256 treasuryNewBalance = tokenERC20.balanceOf(treasury);
        uint256 distributorNewBalance = tokenERC20.balanceOf(distributor);
        uint256 feesBalance = predictionMarket.getUserClaimableFees(marketId, user);

        // Treasury should receive treasury fee
        assertEq(treasuryNewBalance, 0.002 ether);
        // Distributor should receive distributor fee
        assertEq(distributorNewBalance, 0.003 ether);
        // Fees should be claimable
        assertEq(feesBalance, 0.001 ether);

        // claim fees
        uint256 tokenBalance = tokenERC20.balanceOf(user);
        predictionMarket.claimFees(marketId);

        // check fees balance
        uint256 newTokenBalance = tokenERC20.balanceOf(user);
        uint256 newFeesBalance = predictionMarket.getUserClaimableFees(marketId, user);
        assertEq(newTokenBalance, tokenBalance + 0.001 ether);
        assertEq(newFeesBalance, 0);
    }

    function testMarketWithDistributedProbabilities() public {
        // Test market with 40% / 60% odds
        uint256[] memory distribution = new uint256[](2);
        distribution[0] = 0.6 ether * VALUE; // 60% of liquidity to outcome 0
        distribution[1] = 0.4 ether * VALUE; // 40% of liquidity to outcome 1

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: IERC20(address(tokenERC20)),
            distribution: distribution,
            question: "Market with 40%/60% odds",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 marketId = predictionMarket.createMarket(desc);

        (,uint256[] memory prices) = predictionMarket.getMarketPrices(marketId);

        // Prices should reflect the distribution
        // The outcome with more liquidity should have lower price
        assertLt(prices[0], prices[1]); // outcome 0 has more liquidity, so lower price
        assertEq(prices[0] + prices[1], 1 ether); // should still sum to 1
    }

    // Helper functions
    function _createTestMarket() internal returns (uint256) {
        uint256 marketIndex = predictionMarket.marketIndex();

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: IERC20(address(tokenERC20)),
            distribution: new uint256[](0),
            question: string(abi.encodePacked("Test Market ", marketIndex)), // add marketIndex to avoid conflicts
            image: "test-image",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 marketId = predictionMarket.createMarket(desc);

        return marketId;
    }

    function _getOutcomePrices(uint256 marketId) internal view returns (uint256, uint256) {
        (,uint256[] memory prices) = predictionMarket.getMarketPrices(marketId);
        return (prices[0], prices[1]);
    }

    function testClaimWinningsAndLiquidity() public {
        uint256 marketId = _createTestMarket();
        predictionMarket.buy(marketId, 0, 0.0001 ether, VALUE);

        // resolving market as admin
        predictionMarket.adminResolveMarketOutcome(marketId, 0);
        uint256 tokenBalance = tokenERC20.balanceOf(user);

        // claiming winnings
        predictionMarket.claimWinnings(marketId);
        uint256 tokenBalanceAfterWinnings = tokenERC20.balanceOf(user);
        assertEq(tokenBalanceAfterWinnings, tokenBalance + 0.015 ether);

        // claiming liquidity
        predictionMarket.claimLiquidity(marketId);
        uint256 tokenBalanceAfterLiquidity = tokenERC20.balanceOf(user);
        assertEq(tokenBalanceAfterLiquidity, tokenBalanceAfterWinnings + 0.005 ether);
    }

    function testFullFlow() public {
        uint256 marketId = _createTestMarket();
        uint256 balance;
        uint256 balanceAfterAction;
        // 20 users buying positions of outcomes 0 and 1, market resolving and then admin claiming liquidity + users claiming winnings
        for (uint256 i = 0; i < 20; i++) {
            (uint256 price0, uint256 price1) = _getOutcomePrices(marketId);
            address trader = makeAddr(string(abi.encodePacked("user", i)));
            tokenERC20.transfer(trader, 1 ether);
            vm.startPrank(trader);
            tokenERC20.approve(address(predictionMarket), 1 ether);
            // random outcome id
            uint256 outcomeId = uint256(keccak256(abi.encodePacked(trader))) % 2;
            // random amount between 0.0001 ether and 0.001 ether
            uint256 amount = uint256(keccak256(abi.encodePacked(trader))) % 0.0009 ether + 0.0001 ether;
            predictionMarket.buy(marketId, outcomeId, 0, amount);
            (uint256 newPrice0, uint256 newPrice1) = _getOutcomePrices(marketId);
            if (outcomeId == 0) {
                assertGt(newPrice0, price0);
                assertLt(newPrice1, price1);
            } else {
                assertGt(newPrice1, price1);
                assertLt(newPrice0, price0);
            }
            (,uint256[] memory outcomeShares) = predictionMarket.getUserMarketShares(marketId, trader);
            assertGt(outcomeShares[outcomeId], amount);
            assertEq(outcomeShares[1 - outcomeId], 0);
            vm.stopPrank();
        }

        (,,,balance,,) = predictionMarket.getMarketData(marketId);
        // resolving market as admin
        predictionMarket.adminResolveMarketOutcome(marketId, 0);
        predictionMarket.claimLiquidity(marketId);
        (,,,balanceAfterAction,,) = predictionMarket.getMarketData(marketId);
        assertLt(balanceAfterAction, balance);
        balance = balanceAfterAction;

        for (uint256 i = 0; i < 20; i++) {
            address trader = makeAddr(string(abi.encodePacked("user", i)));
            uint256 outcomeId = uint256(keccak256(abi.encodePacked(trader))) % 2;
            if (outcomeId == 0) {
                vm.startPrank(trader);
                predictionMarket.claimWinnings(marketId);
                (,,,balanceAfterAction,,) = predictionMarket.getMarketData(marketId);
                assertLt(balanceAfterAction, balance);
                vm.stopPrank();
            }
        }

        // market balance should be back to 0 after all claims are made
        assertEq(balanceAfterAction, 0);
    }

    function testWETHMarket() public {
        // creating weth land
        manager.createLand(IERC20(address(weth)), IERC20(address(managerTokenERC20)));

        weth.deposit{value: 1 ether}();
        weth.approve(address(predictionMarket), 1 ether);

        // creating test market and weth market
        uint256 marketId = _createTestMarket();

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: IERC20(address(weth)),
            distribution: new uint256[](0),
            question: "WETH market",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 wethMarketId = predictionMarket.createMarket(desc);
        uint256 ethBalance = address(user).balance;
        uint256 wethBalance = weth.balanceOf(user);
        uint256 wethPmBalance = weth.balanceOf(address(predictionMarket));

        // buying and selling weth markets should be successful
        predictionMarket.buyWithETH{value: VALUE}(wethMarketId, 0, 0.0001 ether);
        uint256 ethBalanceAfterBuy = address(user).balance;
        uint256 wethBalanceAfterBuy = weth.balanceOf(address(user));
        uint256 wethPmBalanceAfterBuy = weth.balanceOf(address(predictionMarket));
        // user should have spent ETH, not WETH
        assertEq(ethBalanceAfterBuy, ethBalance - VALUE);
        assertEq(wethBalanceAfterBuy, wethBalance);
        assertEq(wethPmBalanceAfterBuy, wethPmBalance + VALUE);

        predictionMarket.sellToETH(wethMarketId, 0, VALUE / 10, 0.1 ether);
        uint256 ethBalanceAfterSell = address(user).balance;
        uint256 wethBalanceAfterSell = weth.balanceOf(user);
        uint256 wethPmBalanceAfterSell = weth.balanceOf(address(predictionMarket));
        assertEq(ethBalanceAfterSell, ethBalanceAfterBuy + VALUE / 10);
        assertEq(wethBalanceAfterSell, wethBalanceAfterBuy);
        assertEq(wethPmBalanceAfterSell, wethPmBalanceAfterBuy - VALUE / 10);

        // should revert if using buyWithETH on non-weth market
        vm.expectRevert(bytes("!w"));
        predictionMarket.buyWithETH{value: VALUE}(marketId, 0, 0.0001 ether);

        // should revert if using sellToETH on non-weth market
        vm.expectRevert(bytes("!w"));
        predictionMarket.sellToETH(marketId, 0, VALUE / 10, 1 ether);
    }

    function testContractUpgradeability() public {
        // Creating market on old implementation
        uint256 marketId = _createTestMarket();
        predictionMarket.buy(marketId, 0, 0.0001 ether, VALUE);

        // Deploy new implementation
        address newImplementation = address(new PredictionMarketV3_4());

        // Upgrade proxy to new implementation
        predictionMarket.upgradeTo(newImplementation);

        // Ensuring data persists on new implementation
        uint256 tokenBalance = tokenERC20.balanceOf(address(predictionMarket));
        assertEq(tokenBalance, VALUE * 2);
        assertEq(predictionMarket.getMarkets().length, 1);
        assertEq(predictionMarket.getMarketOutcomeIds(marketId).length, 2);
        (,uint256[] memory outcomeShares) = predictionMarket.getUserMarketShares(marketId, user);
        assertEq(outcomeShares[0], 0.015 ether);

        // Ensuring markets are created on new implementation
        uint256 newMarketId = _createTestMarket();
        uint256 newTokenBalance = tokenERC20.balanceOf(address(predictionMarket));
        assertEq(newMarketId, 1);
        assertEq(predictionMarket.getMarkets().length, 2);
        assertEq(newTokenBalance, VALUE * 3);
    }
}
