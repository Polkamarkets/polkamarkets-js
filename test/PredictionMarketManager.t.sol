// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Contract imports
import "../contracts/PredictionMarketV3_4.sol";
import "../contracts/PredictionMarketV3Manager.sol";
import "../contracts/FantasyERC20.sol";
import "../contracts/ERC20MinterPauser.sol";
import {RealityETH_ERC20_v3_0} from "@reality.eth/contracts/development/contracts/RealityETH_ERC20-3.0.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PredictionMarketManagerTest is Test {
    address public pmv34Implementation;
    PredictionMarketV3_4 public predictionMarket;
    PredictionMarketV3Manager public manager;
    RealityETH_ERC20_v3_0 public realitio;
    ERC20MinterPauser public pmmToken;
    FantasyERC20 public landToken;
    FantasyERC20 public landToken2;

    address public deployer;
    address public user1;
    address public user2;
    address public treasury = address(0x123);
    address public distributor = address(0x456);

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant TOKEN_AMOUNT_TO_CLAIM = 10 ether;
    uint256 public constant LOCK_AMOUNT = 5 ether;
    uint256 public constant NEW_LOCK_AMOUNT = 1 ether;
    uint256 public constant VALUE = 0.01 ether;

    uint256 public landId = 0;
    uint256 public marketId = 0;
    uint256 public outcomeId = 0;

    // Events
    event LandCreated(address indexed user, address indexed token, address indexed tokenToAnswer, uint256 amountLocked);
    event LandDisabled(address indexed user, address indexed token, uint256 amountUnlocked);
    event LandEnabled(address indexed user, address indexed token, uint256 amountLocked);
    event LandOffsetUnlocked(address indexed user, address indexed token, uint256 amountUnlocked);
    event LandAdminAdded(address indexed user, address indexed token, address indexed admin);
    event LandAdminRemoved(address indexed user, address indexed token, address indexed admin);

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
        deployer = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        // Deploy PMM Token for manager
        pmmToken = new ERC20MinterPauser("Polkamarkets", "POLK");

        // Deploy Reality.eth
        realitio = new RealityETH_ERC20_v3_0();

        // Deploy prediction market implementation
        pmv34Implementation = address(new PredictionMarketV3_4());
        bytes memory initData = abi.encodeCall(PredictionMarketV3_4.initialize, IWETH(address(0)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(pmv34Implementation),
            initData
        );
        predictionMarket = PredictionMarketV3_4(payable(address(proxy)));

        // Deploy manager
        manager = new PredictionMarketV3Manager(
            address(predictionMarket),
            IERC20(address(pmmToken)),
            LOCK_AMOUNT,
            address(realitio)
        );

        // Allow manager in prediction market
        predictionMarket.setAllowedManager(address(manager), true);

        // Setup PMM tokens
        pmmToken.mint(deployer, INITIAL_BALANCE);
        pmmToken.mint(user1, INITIAL_BALANCE);
        pmmToken.mint(user2, INITIAL_BALANCE);

        pmmToken.approve(address(manager), type(uint256).max);

        // Setup user1 PMM token approvals
        vm.prank(user1);
        pmmToken.approve(address(manager), type(uint256).max);

        // Setup user2 PMM token approvals
        vm.prank(user2);
        pmmToken.approve(address(manager), type(uint256).max);

        // Fund users with ETH
        vm.deal(deployer, INITIAL_BALANCE);
        vm.deal(user1, INITIAL_BALANCE);
        vm.deal(user2, INITIAL_BALANCE);
    }

    function testContractDeployment() public view {
        assertTrue(address(predictionMarket) != address(0));
        assertTrue(address(manager) != address(0));
        assertTrue(address(realitio) != address(0));
        assertTrue(address(pmmToken) != address(0));

        assertEq(manager.lockAmount(), LOCK_AMOUNT);
        assertEq(address(manager.token()), address(pmmToken));
        assertEq(manager.PMV3(), address(predictionMarket));
        assertEq(manager.landTokensLength(), 0);
    }

    function testCreateLand() public {
        uint256 currentLandIndex = manager.landTokensLength();
        uint256 currentPmmTokenBalance = pmmToken.balanceOf(deployer);

        vm.expectEmit(true, false, true, true);
        emit LandCreated(deployer, address(0), address(pmmToken), LOCK_AMOUNT);

        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        uint256 newLandIndex = manager.landTokensLength();
        uint256 newPmmTokenBalance = pmmToken.balanceOf(deployer);

        assertEq(newLandIndex, currentLandIndex + 1);
        assertEq(newPmmTokenBalance, currentPmmTokenBalance - LOCK_AMOUNT);
        assertTrue(address(createdLandToken) != address(0));
        assertTrue(manager.isLandAdmin(createdLandToken, deployer));

        // Store the first land token for later tests
        landToken = FantasyERC20(address(createdLandToken));
    }

    function testCreateMultipleLands() public {
        // Create first land
        IERC20 firstLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        uint256 currentLandIndex = manager.landTokensLength();
        uint256 currentPmmTokenBalance = pmmToken.balanceOf(deployer);

        // Create second land
        IERC20 secondLandToken = manager.createLand(
            "Token 2",
            "TOKEN2",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        uint256 newLandIndex = manager.landTokensLength();
        uint256 newPmmTokenBalance = pmmToken.balanceOf(deployer);

        assertEq(newLandIndex, currentLandIndex + 1);
        assertEq(newPmmTokenBalance, currentPmmTokenBalance - LOCK_AMOUNT);
        assertTrue(address(secondLandToken) != address(0));
        assertTrue(manager.isLandAdmin(secondLandToken, deployer));

        // Ensure they are different tokens
        assertTrue(address(firstLandToken) != address(secondLandToken));

        // Store tokens for later tests
        landToken = FantasyERC20(address(firstLandToken));
        landToken2 = FantasyERC20(address(secondLandToken));
    }

    function testAddAdminToLand() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        bool currentIsAdmin = manager.isLandAdmin(createdLandToken, user2);

        vm.expectEmit(true, true, true, true);
        emit LandAdminAdded(deployer, address(createdLandToken), user2);

        manager.addAdminToLand(createdLandToken, user2);

        bool newIsAdmin = manager.isLandAdmin(createdLandToken, user2);

        assertFalse(currentIsAdmin);
        assertTrue(newIsAdmin);
    }

    function testRemoveAdminFromLand() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Add admin first
        manager.addAdminToLand(createdLandToken, user2);
        bool currentIsAdmin = manager.isLandAdmin(createdLandToken, user2);

        vm.expectEmit(true, true, true, true);
        emit LandAdminRemoved(deployer, address(createdLandToken), user2);

        manager.removeAdminFromLand(createdLandToken, user2);

        bool newIsAdmin = manager.isLandAdmin(createdLandToken, user2);

        assertTrue(currentIsAdmin);
        assertFalse(newIsAdmin);
    }

    function testFailAddAdminToLandIfNotAdmin() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Try to add admin as non-admin user
        vm.prank(user1);
        manager.addAdminToLand(createdLandToken, user2);
    }

    function testAdminAfterBeingMadeAdmin() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Add user1 as admin
        manager.addAdminToLand(createdLandToken, user1);

        bool currentIsAdmin = manager.isLandAdmin(createdLandToken, user2);

        // user1 should now be able to add user2 as admin
        vm.prank(user1);
        manager.addAdminToLand(createdLandToken, user2);

        bool newIsAdmin = manager.isLandAdmin(createdLandToken, user2);

        assertFalse(currentIsAdmin);
        assertTrue(newIsAdmin);

        // user1 should be able to remove user2 as admin
        vm.prank(user1);
        manager.removeAdminFromLand(createdLandToken, user2);

        bool lastIsAdmin = manager.isLandAdmin(createdLandToken, user2);
        assertFalse(lastIsAdmin);

        // Reset user1 admin status
        manager.removeAdminFromLand(createdLandToken, user1);
    }

    function testFailDisableLandIfNotAdmin() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Try to disable land as non-admin user
        vm.prank(user1);
        manager.disableLand(createdLandToken);
    }

    function testDisableLand() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        uint256 currentPmmTokenBalance = pmmToken.balanceOf(deployer);
        bool currentPaused = FantasyERC20(address(createdLandToken)).paused();

        vm.expectEmit(true, true, true, true);
        emit LandDisabled(deployer, address(createdLandToken), LOCK_AMOUNT);

        manager.disableLand(createdLandToken);

        uint256 newPmmTokenBalance = pmmToken.balanceOf(deployer);
        bool newPaused = FantasyERC20(address(createdLandToken)).paused();

        assertFalse(currentPaused);
        assertTrue(newPaused);
        assertEq(newPmmTokenBalance, currentPmmTokenBalance + LOCK_AMOUNT);
        assertFalse(manager.isIERC20TokenSocial(createdLandToken));
    }

    function testFailDisableLandIfAlreadyDisabled() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Disable land
        manager.disableLand(createdLandToken);

        // Try to disable again
        manager.disableLand(createdLandToken);
    }

    function testEnableLand() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Disable land first
        manager.disableLand(createdLandToken);

        uint256 currentPmmTokenBalance = pmmToken.balanceOf(deployer);
        bool currentPaused = FantasyERC20(address(createdLandToken)).paused();

        vm.expectEmit(true, true, true, true);
        emit LandEnabled(deployer, address(createdLandToken), LOCK_AMOUNT);

        manager.enableLand(createdLandToken);

        uint256 newPmmTokenBalance = pmmToken.balanceOf(deployer);
        bool newPaused = FantasyERC20(address(createdLandToken)).paused();

        assertTrue(currentPaused);
        assertFalse(newPaused);
        assertEq(newPmmTokenBalance, currentPmmTokenBalance - LOCK_AMOUNT);
        assertTrue(manager.isIERC20TokenSocial(createdLandToken));
    }

    function testFailUpdateLockAmountIfNotOwner() public {
        vm.prank(user1);
        manager.updateLockAmount(NEW_LOCK_AMOUNT);
    }

    function testUpdateLockAmount() public {
        uint256 currentLockAmount = manager.lockAmount();
        assertEq(currentLockAmount, LOCK_AMOUNT);

        manager.updateLockAmount(NEW_LOCK_AMOUNT);

        uint256 newLockAmount = manager.lockAmount();
        assertEq(newLockAmount, NEW_LOCK_AMOUNT);
    }

    function testFailUnlockOffsetFromLandIfNotAdmin() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Update lock amount to create offset
        manager.updateLockAmount(NEW_LOCK_AMOUNT);

        // Try to unlock offset as non-admin user
        vm.prank(user1);
        manager.unlockOffsetFromLand(createdLandToken);
    }

    function testUnlockOffsetFromLand() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Update lock amount to create offset
        manager.updateLockAmount(NEW_LOCK_AMOUNT);

        uint256 currentPmmTokenBalance = pmmToken.balanceOf(deployer);

        vm.expectEmit(true, true, true, true);
        emit LandOffsetUnlocked(deployer, address(createdLandToken), LOCK_AMOUNT - NEW_LOCK_AMOUNT);

        manager.unlockOffsetFromLand(createdLandToken);

        uint256 newPmmTokenBalance = pmmToken.balanceOf(deployer);

        assertEq(newPmmTokenBalance, currentPmmTokenBalance + LOCK_AMOUNT - NEW_LOCK_AMOUNT);
    }

    function testFailCreateMarketIfNotAdmin() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Claim tokens for user1
        vm.prank(user1);
        FantasyERC20(address(createdLandToken)).claimAndApproveTokens();

        // Try to create market as non-admin
        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: createdLandToken,
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ on May 1st 2025",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        vm.prank(user1);
        predictionMarket.createMarket(desc);
    }

    function testCreateMarket() public {
        // Create land first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        // Claim tokens for deployer
        FantasyERC20(address(createdLandToken)).claimAndApproveTokens();

        uint256[] memory currentMarketIds = predictionMarket.getMarkets();
        uint256 currentLandTokenBalance = FantasyERC20(address(createdLandToken)).balanceOf(deployer);

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: createdLandToken,
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ on May 1st 2025",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        vm.expectEmit(true, true, false, true);
        emit MarketCreated(deployer, 0, 2, desc.question, desc.image, address(createdLandToken));

        uint256 newMarketId = predictionMarket.createMarket(desc);

        uint256[] memory newMarketIds = predictionMarket.getMarkets();
        uint256 newLandTokenBalance = FantasyERC20(address(createdLandToken)).balanceOf(deployer);

        assertEq(newMarketIds.length, currentMarketIds.length + 1);
        assertEq(newMarketId, 0);
        // Balance should be less than initial since tokens were used to create the market
        assertLt(newLandTokenBalance, currentLandTokenBalance);

        // Store for later tests
        marketId = newMarketId;
        landToken = FantasyERC20(address(createdLandToken));
    }

    function testBuySharesWhenLandEnabled() public {
        // Create land and market first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        FantasyERC20(address(createdLandToken)).claimAndApproveTokens();

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: createdLandToken,
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ on May 1st 2025",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 createdMarketId = predictionMarket.createMarket(desc);

        uint256 minOutcomeSharesToBuy = 0.015 ether;
        uint256 currentLandTokenBalance = FantasyERC20(address(createdLandToken)).balanceOf(deployer);

        predictionMarket.buy(createdMarketId, outcomeId, VALUE, minOutcomeSharesToBuy);

        uint256 newLandTokenBalance = FantasyERC20(address(createdLandToken)).balanceOf(deployer);
        uint256 amountTransferred = currentLandTokenBalance - newLandTokenBalance;

        assertGt(amountTransferred, 0); // Just check that some tokens were transferred
    }

    function testSellShares() public {
        // Create land and market first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        FantasyERC20(address(createdLandToken)).claimAndApproveTokens();

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: createdLandToken,
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ on May 1st 2025",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 createdMarketId = predictionMarket.createMarket(desc);

        // Buy shares first
        uint256 minOutcomeSharesToBuy = 0.015 ether;
        predictionMarket.buy(createdMarketId, outcomeId, VALUE, minOutcomeSharesToBuy);

        uint256 currentLandTokenBalance = FantasyERC20(address(createdLandToken)).balanceOf(deployer);
        uint256 maxOutcomeSharesToSell = 0.015 ether;

        predictionMarket.sell(createdMarketId, outcomeId, VALUE, maxOutcomeSharesToSell);

        uint256 newLandTokenBalance = FantasyERC20(address(createdLandToken)).balanceOf(deployer);
        uint256 amountTransferred = newLandTokenBalance - currentLandTokenBalance;

        assertGt(amountTransferred, 0); // Just check that some tokens were transferred
    }

    function testFailBuySharesWhenLandDisabled() public {
        // Create land and market first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        FantasyERC20(address(createdLandToken)).claimAndApproveTokens();

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: createdLandToken,
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ on May 1st 2025",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 createdMarketId = predictionMarket.createMarket(desc);

        // Disable land
        manager.disableLand(createdLandToken);

        uint256 minOutcomeSharesToBuy = 0.015 ether;

        // This should fail because land is disabled
        predictionMarket.buy(createdMarketId, outcomeId, VALUE, minOutcomeSharesToBuy);
    }

    function testBuySharesAfterLandReenabled() public {
        // Create land and market first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        FantasyERC20(address(createdLandToken)).claimAndApproveTokens();

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: createdLandToken,
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ on May 1st 2025",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 createdMarketId = predictionMarket.createMarket(desc);

        // Disable and re-enable land
        manager.disableLand(createdLandToken);
        manager.enableLand(createdLandToken);

        uint256 minOutcomeSharesToBuy = 0.015 ether;
        uint256 currentLandTokenBalance = FantasyERC20(address(createdLandToken)).balanceOf(deployer);

        predictionMarket.buy(createdMarketId, outcomeId, VALUE, minOutcomeSharesToBuy);

        uint256 newLandTokenBalance = FantasyERC20(address(createdLandToken)).balanceOf(deployer);
        uint256 amountTransferred = currentLandTokenBalance - newLandTokenBalance;

        assertGt(amountTransferred, 0); // Just check that some tokens were transferred
    }

    function testFailResolveMarketIfNotAdmin() public {
        // Create land and market first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        FantasyERC20(address(createdLandToken)).claimAndApproveTokens();

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: createdLandToken,
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ on May 1st 2025",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 createdMarketId = predictionMarket.createMarket(desc);

        // Try to resolve market as non-admin
        vm.prank(user1);
        predictionMarket.adminResolveMarketOutcome(createdMarketId, 1);
    }

    function testResolveMarket() public {
        // Create land and market first
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        FantasyERC20(address(createdLandToken)).claimAndApproveTokens();

        PredictionMarketV3_4.CreateMarketDescription memory desc = PredictionMarketV3_4.CreateMarketDescription({
            value: VALUE,
            closesAt: uint32(block.timestamp + 30 days),
            outcomes: 2,
            token: createdLandToken,
            distribution: new uint256[](0),
            question: "Will BTC price close above 100k$ on May 1st 2025",
            image: "foo-bar",
            arbitrator: address(0x1),
            buyFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            sellFees: PredictionMarketV3_4.Fees({fee: 0, treasuryFee: 0, distributorFee: 0}),
            treasury: treasury,
            distributor: distributor,
            realitioTimeout: 3600,
            manager: IPredictionMarketV3Manager(address(manager))
        });

        uint256 createdMarketId = predictionMarket.createMarket(desc);

        predictionMarket.adminResolveMarketOutcome(createdMarketId, 1);

        // Force mine a block to update state
        vm.roll(block.number + 1);

        (PredictionMarketV3_4.MarketState state, , , , , ) = predictionMarket.getMarketData(createdMarketId);
        assertEq(uint256(state), 2); // Market should be resolved
    }

    function testLandTokensLength() public {
        uint256 initialLength = manager.landTokensLength();
        assertEq(initialLength, 0);

        manager.createLand(
            "Token 1",
            "TOKEN1",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        uint256 afterFirstLand = manager.landTokensLength();
        assertEq(afterFirstLand, 1);

        manager.createLand(
            "Token 2",
            "TOKEN2",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        uint256 afterSecondLand = manager.landTokensLength();
        assertEq(afterSecondLand, 2);
    }

    function testGetERC20RealitioAddress() public {
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        address realitioAddress = manager.getERC20RealitioAddress(createdLandToken);
        assertTrue(realitioAddress != address(0));
    }

    function testIsAllowedToCreateMarket() public {
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        assertTrue(manager.isAllowedToCreateMarket(createdLandToken, deployer));
        assertFalse(manager.isAllowedToCreateMarket(createdLandToken, user1));

        // Add user1 as admin
        manager.addAdminToLand(createdLandToken, user1);
        assertTrue(manager.isAllowedToCreateMarket(createdLandToken, user1));

        // Disable land
        manager.disableLand(createdLandToken);
        assertFalse(manager.isAllowedToCreateMarket(createdLandToken, deployer));
        assertFalse(manager.isAllowedToCreateMarket(createdLandToken, user1));
    }

    function testIsAllowedToResolveMarket() public {
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        assertTrue(manager.isAllowedToResolveMarket(createdLandToken, deployer));
        assertFalse(manager.isAllowedToResolveMarket(createdLandToken, user1));

        // Add user1 as admin
        manager.addAdminToLand(createdLandToken, user1);
        assertTrue(manager.isAllowedToResolveMarket(createdLandToken, user1));

        // Disable land
        manager.disableLand(createdLandToken);
        assertFalse(manager.isAllowedToResolveMarket(createdLandToken, deployer));
        assertFalse(manager.isAllowedToResolveMarket(createdLandToken, user1));
    }

    function testIsAllowedToEditMarket() public {
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        assertTrue(manager.isAllowedToEditMarket(createdLandToken, deployer));
        assertFalse(manager.isAllowedToEditMarket(createdLandToken, user1));

        // Add user1 as admin
        manager.addAdminToLand(createdLandToken, user1);
        assertTrue(manager.isAllowedToEditMarket(createdLandToken, user1));

        // Disable land
        manager.disableLand(createdLandToken);
        assertFalse(manager.isAllowedToEditMarket(createdLandToken, deployer));
        assertFalse(manager.isAllowedToEditMarket(createdLandToken, user1));
    }

    function testClaimTokens() public {
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        FantasyERC20 fantasyToken = FantasyERC20(address(createdLandToken));

        uint256 balanceBefore = fantasyToken.balanceOf(deployer);
        assertEq(balanceBefore, 0);

        bool hasClaimedBefore = fantasyToken.hasUserClaimedTokens(deployer);
        assertFalse(hasClaimedBefore);

        fantasyToken.claimTokens();

        uint256 balanceAfter = fantasyToken.balanceOf(deployer);
        assertEq(balanceAfter, TOKEN_AMOUNT_TO_CLAIM);

        bool hasClaimedAfter = fantasyToken.hasUserClaimedTokens(deployer);
        assertTrue(hasClaimedAfter);
    }

    function testFailClaimTokensTwice() public {
        IERC20 createdLandToken = manager.createLand(
            "Token",
            "TOKEN",
            TOKEN_AMOUNT_TO_CLAIM,
            IERC20(address(pmmToken))
        );

        FantasyERC20 fantasyToken = FantasyERC20(address(createdLandToken));

        fantasyToken.claimTokens();
        // This should fail
        fantasyToken.claimTokens();
    }
}
