// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// openzeppelin imports
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// local imports
import "./IFantasyERC20.sol";
import "./IRealityETH_ERC20.sol";
import "./IPredictionMarketV3Manager.sol";

library CeilDiv {
  // calculates ceil(x/y)
  function ceildiv(uint256 x, uint256 y) internal pure returns (uint256) {
    if (x > 0) return ((x - 1) / y) + 1;
    return x / y;
  }
}

interface IWETH {
  function deposit() external payable;

  function transfer(address to, uint256 value) external returns (bool);

  function withdraw(uint256) external;

  function approve(address guy, uint256 wad) external returns (bool);
}

/// @title Market Contract Factory
contract PredictionMarketV3_2 is ReentrancyGuard {
  using SafeERC20 for IERC20;
  using CeilDiv for uint256;

  // ------ Events ------

  event MarketCreated(
    address indexed user,
    uint256 indexed marketId,
    uint256 outcomes,
    string question,
    string image,
    IERC20 token
  );

  event MarketActionTx(
    address indexed user,
    MarketAction indexed action,
    uint256 indexed marketId,
    uint256 outcomeId,
    uint256 shares,
    uint256 value,
    uint256 timestamp
  );

  event Referral(
    address indexed user,
    uint256 indexed marketId,
    string indexed code,
    MarketAction action,
    uint256 outcomeId,
    uint256 value,
    uint256 timestamp
  );

  event MarketOutcomeShares(uint256 indexed marketId, uint256 timestamp, uint256[] outcomeShares, uint256 liquidity);

  event MarketOutcomePrice(uint256 indexed marketId, uint256 indexed outcomeId, uint256 value, uint256 timestamp);

  event MarketLiquidity(
    uint256 indexed marketId,
    uint256 value, // total liquidity
    uint256 price, // value of one liquidity share; max: 1 (even odds situation)
    uint256 timestamp
  );

  event MarketResolved(
    address indexed user,
    uint256 indexed marketId,
    uint256 outcomeId,
    uint256 timestamp,
    bool admin
  );

  event MarketPaused(address indexed user, uint256 indexed marketId, bool paused, uint256 timestamp);

  // ------ Events End ------

  uint256 public constant MAX_UINT_256 = type(uint256).max;

  uint256 public constant ONE = 10**18;

  uint256 public constant MAX_OUTCOMES = 2**5;

  uint256 public constant MAX_FEE = 5 * 10**16; // 5%

  enum MarketState {
    open,
    closed,
    resolved
  }
  enum MarketAction {
    buy,
    sell,
    addLiquidity,
    removeLiquidity,
    claimWinnings,
    claimLiquidity,
    claimFees,
    claimVoided
  }

  struct Market {
    // market details
    uint256 closesAtTimestamp;
    uint256 balance; // total stake
    uint256 liquidity; // stake held
    uint256 sharesAvailable; // shares held (all outcomes)
    mapping(address => uint256) liquidityShares;
    mapping(address => bool) liquidityClaims; // wether user has claimed liquidity earnings
    MarketState state; // resolution variables
    MarketResolution resolution; // fees
    MarketFees fees;
    // market outcomes
    uint256 outcomeCount;
    mapping(uint256 => MarketOutcome) outcomes;
    IERC20 token; // ERC20 token market will use for trading
    IPredictionMarketV3Manager manager; // manager contract
    address creator; // market creator
    bool paused; // market paused, no trading allowed
  }

  struct Fees {
    uint256 fee; // fee % taken from every transaction
    uint256 treasuryFee; // fee % taken from every transaction to a treasury address
    uint256 distributorFee; // fee % taken from every transaction to a distributor address
  }

  struct MarketFees {
    uint256 poolWeight; // internal var used to ensure pro-rate fee distribution
    mapping(address => uint256) claimed;
    address treasury; // address to send treasury fees to
    address distributor; // fee % taken from every transaction to a treasury address
    Fees buyFees; // fees for buy transactions
    Fees sellFees; // fees for sell transactions
  }

  struct MarketResolution {
    bool resolved;
    uint256 outcomeId;
    bytes32 questionId; // realitio questionId
    // realitio
    IRealityETH_ERC20 realitio;
    uint256 realitioTimeout;
  }

  struct MarketOutcome {
    uint256 marketId;
    uint256 id;
    Shares shares;
  }

  struct Shares {
    uint256 total; // number of shares
    uint256 available; // available shares
    mapping(address => uint256) holders;
    mapping(address => bool) claims; // wether user has claimed winnings
    mapping(address => bool) voidedClaims; // wether user has claimed voided market shares
  }

  struct CreateMarketDescription {
    uint256 value;
    uint256 closesAt;
    uint256 outcomes;
    IERC20 token;
    uint256[] distribution;
    string question;
    string image;
    address arbitrator;
    Fees buyFees;
    Fees sellFees;
    address treasury;
    address distributor;
    IRealityETH_ERC20 realitio;
    uint256 realitioTimeout;
    IPredictionMarketV3Manager manager;
  }

  uint256[] marketIds;
  mapping(uint256 => Market) markets;
  uint256 public marketIndex;

  // weth configs
  IWETH public immutable WETH;

  // ------ Modifiers ------

  modifier isMarket(uint256 marketId) {
    require(marketId < marketIndex, "Market not found");
    _;
  }

  modifier timeTransitions(uint256 marketId) {
    if (block.timestamp > markets[marketId].closesAtTimestamp && markets[marketId].state == MarketState.open) {
      nextState(marketId);
    }
    _;
  }

  modifier atState(uint256 marketId, MarketState state) {
    require(markets[marketId].state == state, "Market in incorrect state");
    _;
  }

  modifier notAtState(uint256 marketId, MarketState state) {
    require(markets[marketId].state != state, "Market in incorrect state");
    _;
  }

  modifier notPaused(uint256 marketId) {
    require(!markets[marketId].paused, "Market is paused");
    _;
  }

  modifier paused(uint256 marketId) {
    require(markets[marketId].paused, "Market is not paused");
    _;
  }

  modifier transitionNext(uint256 marketId) {
    _;
    nextState(marketId);
  }

  modifier transitionLast(uint256 marketId) {
    _;
    lastState(marketId);
  }

  modifier isWETHMarket(uint256 marketId) {
    require(address(WETH) != address(0), "WETH address is address 0");
    require(address(markets[marketId].token) == address(WETH), "Market token is not WETH");
    _;
  }

  // ------ Modifiers End ------

  /// @dev protocol is immutable and has no ownership
  constructor(IWETH _WETH) {
    WETH = _WETH;
  }

  receive() external payable {
    assert(msg.sender == address(WETH)); // only accept ETH via fallback from the WETH contract
  }

  // ------ Core Functions ------

  /// @dev for internal use only, validates the market fees and throws if they are not valid
  function _validateFees(Fees memory fees) private pure {
    require(fees.fee <= MAX_FEE, "fee must be <= 5%");
    require(fees.treasuryFee <= MAX_FEE, "treasury fee must be <= 5%");
    require(fees.distributorFee <= MAX_FEE, "distributor fee must be <= 5%");
  }

  /// @dev Creates a market, initializes the outcome shares pool and submits a question in Realitio
  function _createMarket(CreateMarketDescription memory desc) private returns (uint256) {
    uint256 marketId = marketIndex;
    marketIds.push(marketId);

    Market storage market = markets[marketId];

    require(desc.value > 0, "stake needs to be > 0");
    require(desc.closesAt > block.timestamp, "resolution before current date");
    require(desc.arbitrator != address(0), "invalid arbitrator address");
    require(desc.outcomes > 0 && desc.outcomes <= MAX_OUTCOMES, "outcome count not between 1-32");
    require(address(desc.realitio) != address(0), "_realitioAddress is address 0");
    require(desc.realitioTimeout > 0, "timeout must be positive");
    require(desc.manager.isAllowedToCreateMarket(desc.token, msg.sender), "not allowed to create market");

    market.token = desc.token;
    market.closesAtTimestamp = desc.closesAt;
    market.state = MarketState.open;

    // setting up fees
    _validateFees(desc.buyFees);
    market.fees.buyFees = desc.buyFees;
    _validateFees(desc.sellFees);
    market.fees.sellFees = desc.sellFees;

    market.fees.treasury = desc.treasury;
    market.fees.distributor = desc.distributor;
    // setting intial value to an integer that does not map to any outcomeId
    market.resolution.outcomeId = MAX_UINT_256;
    market.outcomeCount = desc.outcomes;

    // creating question in realitio
    market.resolution.questionId = desc.realitio.askQuestionERC20(
      2,
      desc.question,
      desc.arbitrator,
      uint32(desc.realitioTimeout),
      uint32(desc.closesAt),
      0,
      0
    );
    market.resolution.realitio = desc.realitio;
    market.resolution.realitioTimeout = desc.realitioTimeout;
    market.manager = desc.manager;
    market.creator = msg.sender;

    _addLiquidity(marketId, desc.value, desc.distribution);

    // emiting initial price events
    emitMarketActionEvents(marketId);
    emit MarketCreated(msg.sender, marketId, desc.outcomes, desc.question, desc.image, desc.token);

    // incrementing market array index
    marketIndex = marketIndex + 1;

    return marketId;
  }

  function createMarket(CreateMarketDescription calldata desc) external nonReentrant returns (uint256) {
    uint256 marketId = _createMarket(
      CreateMarketDescription({
        value: desc.value,
        closesAt: desc.closesAt,
        outcomes: desc.outcomes,
        token: desc.token,
        distribution: desc.distribution,
        question: desc.question,
        image: desc.image,
        arbitrator: desc.arbitrator,
        buyFees: desc.buyFees,
        sellFees: desc.sellFees,
        treasury: desc.treasury,
        distributor: desc.distributor,
        realitio: desc.realitio,
        realitioTimeout: desc.realitioTimeout,
        manager: desc.manager
      })
    );
    // transferring funds
    desc.token.safeTransferFrom(msg.sender, address(this), desc.value);

    return marketId;
  }

  function createMarketWithETH(CreateMarketDescription calldata desc) external nonReentrant payable returns (uint256) {
    require(address(desc.token) == address(WETH), "Market token is not WETH");
    require(msg.value == desc.value, "value does not match arguments");
    uint256 marketId = _createMarket(
      CreateMarketDescription({
        value: desc.value,
        closesAt: desc.closesAt,
        outcomes: desc.outcomes,
        token: desc.token,
        distribution: desc.distribution,
        question: desc.question,
        image: desc.image,
        arbitrator: desc.arbitrator,
        buyFees: desc.buyFees,
        sellFees: desc.sellFees,
        treasury: desc.treasury,
        distributor: desc.distributor,
        realitio: desc.realitio,
        realitioTimeout: desc.realitioTimeout,
        manager: desc.manager
      })
    );
    // transferring funds
    IWETH(WETH).deposit{value: msg.value}();

    return marketId;
  }

  function mintAndCreateMarket(CreateMarketDescription calldata desc) external nonReentrant returns (uint256) {
    // mint the amount of tokens to the user
    IFantasyERC20(address(desc.token)).mint(msg.sender, desc.value);

    uint256 marketId = _createMarket(desc);
    // transferring funds
    desc.token.safeTransferFrom(msg.sender, address(this), desc.value);

    return marketId;
  }

  /// @dev Calculates the number of shares bought with "amount" balance
  function calcBuyAmount(
    uint256 amount,
    uint256 marketId,
    uint256 outcomeId
  ) public view returns (uint256) {
    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256 fee = getMarketFee(marketId);
    uint256 amountMinusFees = amount - ((amount * fee) / ONE);
    uint256 buyTokenPoolBalance = outcomesShares[outcomeId];
    uint256 endingOutcomeBalance = buyTokenPoolBalance * ONE;
    for (uint256 i = 0; i < outcomesShares.length; ++i) {
      if (i != outcomeId) {
        uint256 outcomeShares = outcomesShares[i];
        endingOutcomeBalance = (endingOutcomeBalance * outcomeShares).ceildiv(outcomeShares + amountMinusFees);
      }
    }
    require(endingOutcomeBalance > 0, "must have non-zero balances");

    return buyTokenPoolBalance + amountMinusFees - (endingOutcomeBalance.ceildiv(ONE));
  }

  /// @dev Calculates the number of shares needed to be sold in order to receive "amount" in balance
  function calcSellAmount(
    uint256 amount,
    uint256 marketId,
    uint256 outcomeId
  ) public view returns (uint256 outcomeTokenSellAmount) {
    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256 fee = getMarketSellFee(marketId);
    uint256 amountPlusFees = (amount * ONE) / (ONE - fee);
    uint256 sellTokenPoolBalance = outcomesShares[outcomeId];
    uint256 endingOutcomeBalance = sellTokenPoolBalance * ONE;
    for (uint256 i = 0; i < outcomesShares.length; ++i) {
      if (i != outcomeId) {
        uint256 outcomeShares = outcomesShares[i];
        endingOutcomeBalance = (endingOutcomeBalance * outcomeShares).ceildiv(outcomeShares - amountPlusFees);
      }
    }
    require(endingOutcomeBalance > 0, "must have non-zero balances");

    return amountPlusFees + endingOutcomeBalance.ceildiv(ONE) - sellTokenPoolBalance;
  }

  /// @dev Buy shares of a market outcome - returns gross amount of transaction (amount + fee)
  function _buy(
    uint256 marketId,
    uint256 outcomeId,
    uint256 minOutcomeSharesToBuy,
    uint256 value
  ) private timeTransitions(marketId) atState(marketId, MarketState.open) notPaused(marketId) returns (uint256) {
    Market storage market = markets[marketId];

    uint256 shares = calcBuyAmount(value, marketId, outcomeId);
    require(shares >= minOutcomeSharesToBuy, "minimum buy amount not reached");
    require(shares > 0, "shares amount is 0");

    // subtracting fee from transaction value
    uint256 feeAmount = (value * market.fees.buyFees.fee) / ONE;
    market.fees.poolWeight = market.fees.poolWeight + feeAmount;
    uint256 valueMinusFees = value - feeAmount;

    uint256 treasuryFeeAmount = (value * market.fees.buyFees.treasuryFee) / ONE;
    uint256 distributorFeeAmount = (value * market.fees.buyFees.distributorFee) / ONE;
    valueMinusFees = valueMinusFees - treasuryFeeAmount - distributorFeeAmount;

    MarketOutcome storage outcome = market.outcomes[outcomeId];

    // Funding market shares with received funds
    addSharesToMarket(marketId, valueMinusFees);

    require(outcome.shares.available >= shares, "shares pool balance is too low");

    transferOutcomeSharesfromPool(msg.sender, marketId, outcomeId, shares);

    // value emmited in event includes fee (gross amount)
    emit MarketActionTx(msg.sender, MarketAction.buy, marketId, outcomeId, shares, value, block.timestamp);
    emitMarketActionEvents(marketId);

    // transfering treasury/distributor fees
    if (treasuryFeeAmount > 0) {
      market.token.safeTransfer(market.fees.treasury, treasuryFeeAmount);
    }
    if (distributorFeeAmount > 0) {
      market.token.safeTransfer(market.fees.distributor, distributorFeeAmount);
    }

    return value;
  }

  /// @dev Buy shares of a market outcome
  function buy(
    uint256 marketId,
    uint256 outcomeId,
    uint256 minOutcomeSharesToBuy,
    uint256 value
  ) external nonReentrant {
    Market storage market = markets[marketId];
    market.token.safeTransferFrom(msg.sender, address(this), value);
    _buy(marketId, outcomeId, minOutcomeSharesToBuy, value);
  }

  function buyWithETH(
    uint256 marketId,
    uint256 outcomeId,
    uint256 minOutcomeSharesToBuy
  ) external payable isWETHMarket(marketId) nonReentrant {
    uint256 value = msg.value;
    // wrapping and depositing funds
    IWETH(WETH).deposit{value: value}();
    _buy(marketId, outcomeId, minOutcomeSharesToBuy, value);
  }

  function referralBuy(
    uint256 marketId,
    uint256 outcomeId,
    uint256 minOutcomeSharesToBuy,
    uint256 value,
    string memory code
  ) public nonReentrant {
    Market storage market = markets[marketId];
    market.token.safeTransferFrom(msg.sender, address(this), value);
    _buy(marketId, outcomeId, minOutcomeSharesToBuy, value);

    emit Referral(msg.sender, marketId, code, MarketAction.buy, outcomeId, value, block.timestamp);
  }

  function referralBuyWithETH(
    uint256 marketId,
    uint256 outcomeId,
    uint256 minOutcomeSharesToBuy,
    string memory code
  ) public payable nonReentrant {
    uint256 value = msg.value;
    // wrapping and depositing funds
    IWETH(WETH).deposit{value: value}();
    _buy(marketId, outcomeId, minOutcomeSharesToBuy, value);

    emit Referral(msg.sender, marketId, code, MarketAction.buy, outcomeId, msg.value, block.timestamp);
  }

  /// @dev Sell shares of a market outcome - returns gross amount of transaction (amount + fee)
  function _sell(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value,
    uint256 maxOutcomeSharesToSell
  ) private timeTransitions(marketId) atState(marketId, MarketState.open) notPaused(marketId) returns (uint256) {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[outcomeId];

    uint256 shares = calcSellAmount(value, marketId, outcomeId);

    require(shares <= maxOutcomeSharesToSell, "maximum sell amount exceeded");
    require(shares > 0, "shares amount is 0");
    require(outcome.shares.holders[msg.sender] >= shares, "insufficient shares balance");

    transferOutcomeSharesToPool(msg.sender, marketId, outcomeId, shares);

    // adding fees to transaction value
    uint256 fee = getMarketSellFee(marketId);
    {
      uint256 feeAmount = (value * market.fees.sellFees.fee) / (ONE - fee);
      market.fees.poolWeight = market.fees.poolWeight + feeAmount;
    }
    uint256 valuePlusFees = value + (value * fee) / (ONE - fee);

    require(market.balance >= valuePlusFees, "insufficient market balance");

    // Rebalancing market shares
    removeSharesFromMarket(marketId, valuePlusFees);

    // value emmited in event includes fee (gross amount)
    emit MarketActionTx(msg.sender, MarketAction.sell, marketId, outcomeId, shares, valuePlusFees, block.timestamp);
    emitMarketActionEvents(marketId);

    {
      uint256 treasuryFeeAmount = (value * market.fees.sellFees.treasuryFee) / (ONE - fee);
      uint256 distributorFeeAmount = (value * market.fees.sellFees.distributorFee) / (ONE - fee);
      // transfering treasury/distributor fees
      if (treasuryFeeAmount > 0) {
        market.token.safeTransfer(market.fees.treasury, treasuryFeeAmount);
      }
      if (distributorFeeAmount > 0) {
        market.token.safeTransfer(market.fees.distributor, distributorFeeAmount);
      }
    }

    return valuePlusFees;
  }

  function sell(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value,
    uint256 maxOutcomeSharesToSell
  ) external nonReentrant {
    _sell(marketId, outcomeId, value, maxOutcomeSharesToSell);
    // Transferring funds to user
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function sellToETH(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value,
    uint256 maxOutcomeSharesToSell
  ) external isWETHMarket(marketId) nonReentrant {
    Market storage market = markets[marketId];
    require(address(market.token) == address(WETH), "market token is not WETH");

    _sell(marketId, outcomeId, value, maxOutcomeSharesToSell);

    IWETH(WETH).withdraw(value);
    (bool sent, ) = payable(msg.sender).call{value: value}("");
    require(sent, "Failed to send Ether");
  }

  function referralSell(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value,
    uint256 maxOutcomeSharesToSell,
    string memory code
  ) external nonReentrant {
    uint256 valuePlusFees = _sell(marketId, outcomeId, value, maxOutcomeSharesToSell);
    // Transferring funds to user
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);

    emit Referral(msg.sender, marketId, code, MarketAction.sell, outcomeId, valuePlusFees, block.timestamp);
  }

  function referralSellToETH(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value,
    uint256 maxOutcomeSharesToSell,
    string memory code
  ) external isWETHMarket(marketId) nonReentrant {
    Market storage market = markets[marketId];
    require(address(market.token) == address(WETH), "market token is not WETH");

    uint256 valuePlusFees = _sell(marketId, outcomeId, value, maxOutcomeSharesToSell);

    IWETH(WETH).withdraw(value);
    (bool sent, ) = payable(msg.sender).call{value: value}("");
    require(sent, "Failed to send Ether");

    emit Referral(msg.sender, marketId, code, MarketAction.sell, outcomeId, valuePlusFees, block.timestamp);
  }

  /// @dev Adds liquidity to a market - external
  function _addLiquidity(
    uint256 marketId,
    uint256 value,
    uint256[] memory distribution
  ) private timeTransitions(marketId) atState(marketId, MarketState.open) notPaused(marketId) {
    Market storage market = markets[marketId];

    require(value > 0, "stake has to be greater than 0.");

    uint256 liquidityAmount;

    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256[] memory sendBackAmounts = new uint256[](outcomesShares.length);
    uint256 poolWeight = 0;

    if (market.liquidity > 0) {
      require(distribution.length == 0, "market already funded");

      // part of the liquidity is exchanged for outcome shares if market is not balanced
      for (uint256 i = 0; i < outcomesShares.length; ++i) {
        uint256 outcomeShares = outcomesShares[i];
        if (poolWeight < outcomeShares) poolWeight = outcomeShares;
      }

      for (uint256 i = 0; i < outcomesShares.length; ++i) {
        uint256 remaining = (value * outcomesShares[i]) / poolWeight;
        sendBackAmounts[i] = value - remaining;
      }

      liquidityAmount = (value * market.liquidity) / poolWeight;

      // re-balancing fees pool
      rebalanceFeesPool(marketId, liquidityAmount, MarketAction.addLiquidity);
    } else {
      // funding market with no liquidity
      if (distribution.length > 0) {
        require(distribution.length == outcomesShares.length, "distribution length not matching");

        uint256 maxHint = 0;
        for (uint256 i = 0; i < distribution.length; ++i) {
          uint256 hint = distribution[i];
          if (maxHint < hint) maxHint = hint;
        }

        for (uint256 i = 0; i < distribution.length; ++i) {
          uint256 remaining = (value * distribution[i]) / maxHint;
          require(remaining > 0, "must hint a valid distribution");
          sendBackAmounts[i] = value - remaining;
        }
      }

      // funding market with total liquidity amount
      liquidityAmount = value;
    }

    // funding market
    market.liquidity = market.liquidity + liquidityAmount;
    market.liquidityShares[msg.sender] = market.liquidityShares[msg.sender] + liquidityAmount;

    addSharesToMarket(marketId, value);

    {
      // transform sendBackAmounts to array of amounts added
      for (uint256 i = 0; i < sendBackAmounts.length; ++i) {
        if (sendBackAmounts[i] > 0) {
          transferOutcomeSharesfromPool(msg.sender, marketId, i, sendBackAmounts[i]);
        }
      }

      // emitting events, using outcome 0 for price reference
      uint256 referencePrice = getMarketOutcomePrice(marketId, 0);

      for (uint256 i = 0; i < sendBackAmounts.length; ++i) {
        if (sendBackAmounts[i] > 0) {
          // outcome price = outcome shares / reference outcome shares * reference outcome price
          uint256 outcomePrice = (referencePrice * market.outcomes[0].shares.available) /
            market.outcomes[i].shares.available;

          emit MarketActionTx(
            msg.sender,
            MarketAction.buy,
            marketId,
            i,
            sendBackAmounts[i],
            (sendBackAmounts[i] * outcomePrice) / ONE, // price * shares
            block.timestamp
          );
        }
      }
    }

    uint256 liquidityPrice = getMarketLiquidityPrice(marketId);
    uint256 liquidityValue = (liquidityPrice * liquidityAmount) / ONE;

    emit MarketActionTx(
      msg.sender,
      MarketAction.addLiquidity,
      marketId,
      0,
      liquidityAmount,
      liquidityValue,
      block.timestamp
    );
    emit MarketLiquidity(marketId, market.liquidity, liquidityPrice, block.timestamp);
  }

  function addLiquidity(uint256 marketId, uint256 value) external nonReentrant {
    uint256[] memory distribution = new uint256[](0);
    _addLiquidity(marketId, value, distribution);

    Market storage market = markets[marketId];
    market.token.safeTransferFrom(msg.sender, address(this), value);
  }

  function addLiquidityWithETH(uint256 marketId) external nonReentrant payable isWETHMarket(marketId) {
    uint256 value = msg.value;
    uint256[] memory distribution = new uint256[](0);
    _addLiquidity(marketId, value, distribution);
    // wrapping and depositing funds
    IWETH(WETH).deposit{value: value}();
  }

  /// @dev Removes liquidity to a market - external
  function _removeLiquidity(uint256 marketId, uint256 shares)
    private
    timeTransitions(marketId)
    atState(marketId, MarketState.open)
    notPaused(marketId)
    returns (uint256)
  {
    Market storage market = markets[marketId];

    require(market.liquidityShares[msg.sender] >= shares, "insufficient shares balance");
    // claiming any pending fees
    claimFees(marketId);

    // re-balancing fees pool
    rebalanceFeesPool(marketId, shares, MarketAction.removeLiquidity);

    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256[] memory sendAmounts = new uint256[](outcomesShares.length);
    uint256 poolWeight = MAX_UINT_256;

    // part of the liquidity is exchanged for outcome shares if market is not balanced
    for (uint256 i = 0; i < outcomesShares.length; ++i) {
      uint256 outcomeShares = outcomesShares[i];
      if (poolWeight > outcomeShares) poolWeight = outcomeShares;
    }

    uint256 liquidityAmount = (shares * poolWeight) / market.liquidity;

    for (uint256 i = 0; i < outcomesShares.length; ++i) {
      sendAmounts[i] = (outcomesShares[i] * shares) / market.liquidity;
      sendAmounts[i] = sendAmounts[i] - liquidityAmount;
    }

    // removing liquidity from market
    removeSharesFromMarket(marketId, liquidityAmount);
    market.liquidity = market.liquidity - shares;
    // removing liquidity tokens from market creator
    market.liquidityShares[msg.sender] = market.liquidityShares[msg.sender] - shares;

    for (uint256 i = 0; i < outcomesShares.length; ++i) {
      if (sendAmounts[i] > 0) {
        transferOutcomeSharesfromPool(msg.sender, marketId, i, sendAmounts[i]);
      }
    }

    // emitting events, using outcome 0 for price reference
    uint256 referencePrice = getMarketOutcomePrice(marketId, 0);

    for (uint256 i = 0; i < outcomesShares.length; ++i) {
      if (sendAmounts[i] > 0) {
        // outcome price = outcome shares / reference outcome shares * reference outcome price
        uint256 outcomePrice = (referencePrice * market.outcomes[0].shares.available) /
          market.outcomes[i].shares.available;

        emit MarketActionTx(
          msg.sender,
          MarketAction.buy,
          marketId,
          i,
          sendAmounts[i],
          (sendAmounts[i] * outcomePrice) / ONE, // price * shares
          block.timestamp
        );
      }
    }

    emit MarketActionTx(
      msg.sender,
      MarketAction.removeLiquidity,
      marketId,
      0,
      shares,
      liquidityAmount,
      block.timestamp
    );
    emit MarketLiquidity(marketId, market.liquidity, getMarketLiquidityPrice(marketId), block.timestamp);

    return liquidityAmount;
  }

  function removeLiquidity(uint256 marketId, uint256 shares) external nonReentrant {
    uint256 value = _removeLiquidity(marketId, shares);
    // transferring user funds from liquidity removed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function removeLiquidityToETH(uint256 marketId, uint256 shares) external nonReentrant isWETHMarket(marketId) {
    uint256 value = _removeLiquidity(marketId, shares);
    // unwrapping and transferring user funds from liquidity removed
    IWETH(WETH).withdraw(value);
    (bool sent, ) = payable(msg.sender).call{value: value}("");
    require(sent, "Failed to send Ether");
  }

  /// @dev Fetches winning outcome from Realitio and resolves the market
  function resolveMarketOutcome(uint256 marketId)
    external
    timeTransitions(marketId)
    atState(marketId, MarketState.closed)
    transitionNext(marketId)
    returns (uint256)
  {
    Market storage market = markets[marketId];

    // will fail if question is not finalized
    uint256 outcomeId = uint256(market.resolution.realitio.resultFor(market.resolution.questionId));

    market.resolution.outcomeId = outcomeId;

    emit MarketResolved(msg.sender, marketId, outcomeId, block.timestamp, false);
    emitMarketActionEvents(marketId);

    return market.resolution.outcomeId;
  }

  /// @dev overrides market resolution, instead of using realitio
  function adminResolveMarketOutcome(uint256 marketId, uint256 outcomeId)
    external
    notAtState(marketId, MarketState.resolved)
    transitionLast(marketId)
    returns (uint256)
  {
    Market storage market = markets[marketId];

    require(market.manager.isAllowedToEditMarket(market.token, msg.sender), "not allowed to resolve market");

    market.resolution.outcomeId = outcomeId;

    emit MarketResolved(msg.sender, marketId, outcomeId, block.timestamp, true);
    emitMarketActionEvents(marketId);

    return market.resolution.outcomeId;
  }

  /// @dev pauses a market, no trading allowed
  function adminPauseMarket(uint256 marketId) external isMarket(marketId) notPaused(marketId) nonReentrant {
    Market storage market = markets[marketId];
    require(market.manager.isAllowedToEditMarket(market.token, msg.sender), "not allowed to pause market");

    market.paused = true;
    emit MarketPaused(msg.sender, marketId, market.paused, block.timestamp);
  }

  /// @dev unpauses a market, trading allowed
  function adminUnpauseMarket(uint256 marketId) external isMarket(marketId) paused(marketId) nonReentrant {
    Market storage market = markets[marketId];
    require(market.manager.isAllowedToEditMarket(market.token, msg.sender), "not allowed to unpause market");

    market.paused = false;
    emit MarketPaused(msg.sender, marketId, market.paused, block.timestamp);
  }

  /// @dev overrides market close date
  function adminSetMarketCloseDate(uint256 marketId, uint256 closesAt)
    external
    isMarket(marketId)
    notAtState(marketId, MarketState.resolved)
  {
    Market storage market = markets[marketId];
    require(market.manager.isAllowedToEditMarket(market.token, msg.sender), "not allowed to set close date");

    require(closesAt > block.timestamp, "resolution before current date");
    market.closesAtTimestamp = closesAt;
  }

  /// @dev Allows holders of resolved outcome shares to claim earnings.
  function _claimWinnings(uint256 marketId) private atState(marketId, MarketState.resolved) returns (uint256) {
    Market storage market = markets[marketId];
    MarketOutcome storage resolvedOutcome = market.outcomes[market.resolution.outcomeId];

    require(resolvedOutcome.shares.holders[msg.sender] > 0, "user doesn't hold outcome shares");
    require(resolvedOutcome.shares.claims[msg.sender] == false, "user already claimed winnings");

    // 1 share => price = 1
    uint256 value = resolvedOutcome.shares.holders[msg.sender];

    // assuring market has enough funds
    require(market.balance >= value, "insufficient market balance");

    market.balance = market.balance - value;
    resolvedOutcome.shares.claims[msg.sender] = true;

    emit MarketActionTx(
      msg.sender,
      MarketAction.claimWinnings,
      marketId,
      market.resolution.outcomeId,
      resolvedOutcome.shares.holders[msg.sender],
      value,
      block.timestamp
    );

    uint256 treasuryFeeAmount = (value * market.fees.buyFees.treasuryFee) / ONE;
    uint256 distributorFeeAmount = (value * market.fees.buyFees.distributorFee) / ONE;
    uint256 valueMinusFees = value - treasuryFeeAmount - distributorFeeAmount;

    return valueMinusFees;
  }

  function claimWinnings(uint256 marketId) external nonReentrant {
    uint256 value = _claimWinnings(marketId);
    // transferring user funds from winnings claimed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function claimWinningsToETH(uint256 marketId) external nonReentrant isWETHMarket(marketId) {
    uint256 value = _claimWinnings(marketId);
    // unwrapping and transferring user funds from winnings claimed
    IWETH(WETH).withdraw(value);
    (bool sent, ) = payable(msg.sender).call{value: value}("");
    require(sent, "Failed to send Ether");
  }

  /// @dev Allows holders of voided outcome shares to claim balance back.
  function _claimVoidedOutcomeShares(uint256 marketId, uint256 outcomeId)
    private
    atState(marketId, MarketState.resolved)
    returns (uint256)
  {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[outcomeId];

    require(isMarketVoided(marketId), "market is not voided");
    require(outcome.shares.holders[msg.sender] > 0, "user doesn't hold outcome shares");
    require(outcome.shares.voidedClaims[msg.sender] == false, "user already claimed shares");

    // voided market - shares are valued at last market price
    uint256 price = getMarketOutcomePrice(marketId, outcomeId);
    uint256 value = (price * outcome.shares.holders[msg.sender]) / ONE;

    // assuring market has enough funds
    require(market.balance >= value, "insufficient market balance");

    market.balance = market.balance - value;
    outcome.shares.voidedClaims[msg.sender] = true;

    emit MarketActionTx(
      msg.sender,
      MarketAction.claimVoided,
      marketId,
      outcomeId,
      outcome.shares.holders[msg.sender],
      value,
      block.timestamp
    );

    return value;
  }

  function claimVoidedOutcomeShares(uint256 marketId, uint256 outcomeId) external nonReentrant {
    uint256 value = _claimVoidedOutcomeShares(marketId, outcomeId);
    // transferring user funds from voided outcome shares claimed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function claimVoidedOutcomeSharesToETH(uint256 marketId, uint256 outcomeId) external nonReentrant isWETHMarket(marketId) {
    uint256 value = _claimVoidedOutcomeShares(marketId, outcomeId);
    // unwrapping and transferring user funds from voided outcome shares claimed
    IWETH(WETH).withdraw(value);
    (bool sent, ) = payable(msg.sender).call{value: value}("");
    require(sent, "Failed to send Ether");
  }

  /// @dev Allows liquidity providers to claim earnings from liquidity providing.
  function _claimLiquidity(uint256 marketId) private atState(marketId, MarketState.resolved) returns (uint256) {
    Market storage market = markets[marketId];

    // claiming any pending fees
    claimFees(marketId);

    require(market.liquidityShares[msg.sender] > 0, "user doesn't hold shares");
    require(market.liquidityClaims[msg.sender] == false, "user already claimed shares");

    // value = total resolved outcome pool shares * pool share (%)
    uint256 liquidityPrice = getMarketLiquidityPrice(marketId);
    uint256 value = (liquidityPrice * market.liquidityShares[msg.sender]) / ONE;

    // assuring market has enough funds
    require(market.balance >= value, "insufficient market balance");

    market.balance = market.balance - value;
    market.liquidityClaims[msg.sender] = true;

    emit MarketActionTx(
      msg.sender,
      MarketAction.claimLiquidity,
      marketId,
      0,
      market.liquidityShares[msg.sender],
      value,
      block.timestamp
    );

    return value;
  }

  function claimLiquidity(uint256 marketId) external nonReentrant {
    uint256 value = _claimLiquidity(marketId);
    // transferring user funds from liquidity claimed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function claimLiquidityToETH(uint256 marketId) external nonReentrant isWETHMarket(marketId) {
    uint256 value = _claimLiquidity(marketId);
    // unwrapping and transferring user funds from liquidity claimed
    IWETH(WETH).withdraw(value);
    (bool sent, ) = payable(msg.sender).call{value: value}("");
    require(sent, "Failed to send Ether");
  }

  /// @dev Allows liquidity providers to claim their fees share from fees pool
  function _claimFees(uint256 marketId) private returns (uint256) {
    Market storage market = markets[marketId];

    uint256 claimableFees = getUserClaimableFees(marketId, msg.sender);

    if (claimableFees > 0) {
      market.fees.claimed[msg.sender] = market.fees.claimed[msg.sender] + claimableFees;
    }

    emit MarketActionTx(
      msg.sender,
      MarketAction.claimFees,
      marketId,
      0,
      market.liquidityShares[msg.sender],
      claimableFees,
      block.timestamp
    );

    return claimableFees;
  }

  function claimFees(uint256 marketId) public nonReentrant {
    uint256 value = _claimFees(marketId);
    // transferring user funds from fees claimed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function claimFeesToETH(uint256 marketId) public isWETHMarket(marketId) nonReentrant {
    uint256 value = _claimFees(marketId);
    // unwrapping and transferring user funds from fees claimed
    IWETH(WETH).withdraw(value);
    (bool sent, ) = payable(msg.sender).call{value: value}("");
    require(sent, "Failed to send Ether");
  }

  /// @dev Rebalances the fees pool. Needed in every AddLiquidity / RemoveLiquidity call
  function rebalanceFeesPool(
    uint256 marketId,
    uint256 liquidityShares,
    MarketAction action
  ) private {
    Market storage market = markets[marketId];

    uint256 poolWeight = (liquidityShares * market.fees.poolWeight) / market.liquidity;

    if (action == MarketAction.addLiquidity) {
      market.fees.poolWeight = market.fees.poolWeight + poolWeight;
      market.fees.claimed[msg.sender] = market.fees.claimed[msg.sender] + poolWeight;
    } else {
      market.fees.poolWeight = market.fees.poolWeight - poolWeight;
      market.fees.claimed[msg.sender] = market.fees.claimed[msg.sender] - poolWeight;
    }
  }

  /// @dev Transitions market to next state
  function nextState(uint256 marketId) private {
    Market storage market = markets[marketId];
    market.state = MarketState(uint256(market.state) + 1);
  }

  /// @dev Transitions market to last state
  function lastState(uint256 marketId) private {
    Market storage market = markets[marketId];
    market.state = MarketState.resolved;
  }

  /// @dev Emits a outcome price event for every outcome
  function emitMarketActionEvents(uint256 marketId) private {
    Market storage market = markets[marketId];
    uint256[] memory outcomeShares = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      outcomeShares[i] = market.outcomes[i].shares.available;
    }

    emit MarketOutcomeShares(marketId, block.timestamp, outcomeShares, market.liquidity);
  }

  /// @dev Adds outcome shares to shares pool
  function addSharesToMarket(uint256 marketId, uint256 shares) private {
    Market storage market = markets[marketId];

    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      MarketOutcome storage outcome = market.outcomes[i];

      outcome.shares.available = outcome.shares.available + shares;
      outcome.shares.total = outcome.shares.total + shares;

      // only adding to market total shares, the available remains
      market.sharesAvailable = market.sharesAvailable + shares;
    }

    market.balance = market.balance + shares;
  }

  /// @dev Removes outcome shares from shares pool
  function removeSharesFromMarket(uint256 marketId, uint256 shares) private {
    Market storage market = markets[marketId];

    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      MarketOutcome storage outcome = market.outcomes[i];

      outcome.shares.available = outcome.shares.available - shares;
      outcome.shares.total = outcome.shares.total - shares;

      // only subtracting from market total shares, the available remains
      market.sharesAvailable = market.sharesAvailable - shares;
    }

    market.balance = market.balance - shares;
  }

  /// @dev Transfer outcome shares from pool to user balance
  function transferOutcomeSharesfromPool(
    address user,
    uint256 marketId,
    uint256 outcomeId,
    uint256 shares
  ) private {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[outcomeId];

    // transfering shares from shares pool to user
    outcome.shares.holders[user] = outcome.shares.holders[user] + shares;
    outcome.shares.available = outcome.shares.available - shares;
    market.sharesAvailable = market.sharesAvailable - shares;
  }

  /// @dev Transfer outcome shares from user balance back to pool
  function transferOutcomeSharesToPool(
    address user,
    uint256 marketId,
    uint256 outcomeId,
    uint256 shares
  ) private {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[outcomeId];

    // adding shares back to pool
    outcome.shares.holders[user] = outcome.shares.holders[user] - shares;
    outcome.shares.available = outcome.shares.available + shares;
    market.sharesAvailable = market.sharesAvailable + shares;
  }

  // ------ Core Functions End ------

  // ------ Getters ------

  function getUserMarketShares(uint256 marketId, address user) external view returns (uint256, uint256[] memory) {
    Market storage market = markets[marketId];
    uint256[] memory outcomeShares = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      outcomeShares[i] = market.outcomes[i].shares.holders[user];
    }

    return (market.liquidityShares[user], outcomeShares);
  }

  function getUserClaimStatus(uint256 marketId, address user)
    external
    view
    returns (
      bool,
      bool,
      bool,
      bool,
      uint256
    )
  {
    Market storage market = markets[marketId];

    // market still not resolved
    if (market.state != MarketState.resolved) {
      return (false, false, false, false, getUserClaimableFees(marketId, user));
    }

    MarketOutcome storage outcome = market.outcomes[market.resolution.outcomeId];

    return (
      outcome.shares.holders[user] > 0,
      outcome.shares.claims[user],
      market.liquidityShares[user] > 0,
      market.liquidityClaims[user],
      getUserClaimableFees(marketId, user)
    );
  }

  function getUserLiquidityPoolShare(uint256 marketId, address user) external view returns (uint256) {
    Market storage market = markets[marketId];

    return (market.liquidityShares[user] * ONE) / market.liquidity;
  }

  function getUserClaimableFees(uint256 marketId, address user) public view returns (uint256) {
    Market storage market = markets[marketId];

    uint256 rawAmount = (market.fees.poolWeight * market.liquidityShares[user]) / market.liquidity;

    // No fees left to claim
    if (market.fees.claimed[user] > rawAmount) return 0;

    return rawAmount - market.fees.claimed[user];
  }

  function getMarkets() external view returns (uint256[] memory) {
    return marketIds;
  }

  function getMarketData(uint256 marketId)
    external
    view
    returns (
      MarketState,
      uint256,
      uint256,
      uint256,
      uint256,
      int256
    )
  {
    Market storage market = markets[marketId];

    return (
      market.state,
      market.closesAtTimestamp,
      market.liquidity,
      market.balance,
      market.sharesAvailable,
      getMarketResolvedOutcome(marketId)
    );
  }

  function getMarketAltData(uint256 marketId)
    external
    view
    returns (
      uint256,
      bytes32,
      uint256,
      IERC20,
      uint256,
      address,
      IRealityETH_ERC20,
      uint256,
      IPredictionMarketV3Manager
    )
  {
    Market storage market = markets[marketId];

    return (
      market.fees.buyFees.fee,
      market.resolution.questionId,
      uint256(market.resolution.questionId),
      market.token,
      market.fees.buyFees.treasuryFee,
      market.fees.treasury,
      market.resolution.realitio,
      market.resolution.realitioTimeout,
      market.manager
    );
  }

  function getMarketCreator(uint256 marketId) external view returns (address) {
    Market storage market = markets[marketId];

    return market.creator;
  }

  function getMarketQuestion(uint256 marketId) external view returns (bytes32) {
    Market storage market = markets[marketId];

    return (market.resolution.questionId);
  }

  function getMarketPrices(uint256 marketId) external view returns (uint256, uint256[] memory) {
    Market storage market = markets[marketId];
    uint256[] memory prices = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      prices[i] = getMarketOutcomePrice(marketId, i);
    }

    return (getMarketLiquidityPrice(marketId), prices);
  }

  function getMarketShares(uint256 marketId) external view returns (uint256, uint256[] memory) {
    Market storage market = markets[marketId];
    uint256[] memory outcomeShares = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      outcomeShares[i] = market.outcomes[i].shares.available;
    }

    return (market.liquidity, outcomeShares);
  }

  function getMarketLiquidityPrice(uint256 marketId) public view returns (uint256) {
    Market storage market = markets[marketId];

    if (market.state == MarketState.resolved && !isMarketVoided(marketId)) {
      // resolved market, outcome prices are either 0 or 1
      // final liquidity price = outcome shares / liquidity shares
      return (market.outcomes[market.resolution.outcomeId].shares.available * ONE) / market.liquidity;
    }

    // liquidity price = # outcomes / (liquidity * sum (1 / every outcome shares)
    uint256 marketSharesSum = 0;

    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      MarketOutcome storage outcome = market.outcomes[i];

      marketSharesSum = marketSharesSum + (ONE * ONE) / outcome.shares.available;
    }

    return (market.outcomeCount * ONE * ONE * ONE) / market.liquidity / marketSharesSum;
  }

  function getMarketResolvedOutcome(uint256 marketId) public view returns (int256) {
    Market storage market = markets[marketId];

    // returning -1 if market still not resolved
    if (market.state != MarketState.resolved) {
      return -1;
    }

    return int256(market.resolution.outcomeId);
  }

  function isMarketVoided(uint256 marketId) public view returns (bool) {
    Market storage market = markets[marketId];

    // market still not resolved, still in valid state
    if (market.state != MarketState.resolved) {
      return false;
    }

    // resolved market id does not match any of the market ids
    return market.resolution.outcomeId >= market.outcomeCount;
  }

  function getMarketFee(uint256 marketId) public view returns (uint256) {
    Market storage market = markets[marketId];

    return market.fees.buyFees.fee + market.fees.buyFees.treasuryFee + market.fees.buyFees.distributorFee;
  }

  function getMarketSellFee(uint256 marketId) public view returns (uint256) {
    Market storage market = markets[marketId];

    return market.fees.sellFees.fee + market.fees.sellFees.treasuryFee + market.fees.sellFees.distributorFee;
  }

  function getMarketFees(uint256 marketId)
    external
    view
    returns (
      Fees memory,
      Fees memory,
      address,
      address
    )
  {
    Market storage market = markets[marketId];

    return (market.fees.buyFees, market.fees.sellFees, market.fees.treasury, market.fees.distributor);
  }

  // ------ Outcome Getters ------

  function getMarketOutcomeIds(uint256 marketId) external view returns (uint256[] memory) {
    Market storage market = markets[marketId];
    uint256[] memory outcomeIds = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      outcomeIds[i] = i;
    }

    return outcomeIds;
  }

  function getMarketOutcomePrice(uint256 marketId, uint256 outcomeId) public view returns (uint256) {
    Market storage market = markets[marketId];

    if (market.state == MarketState.resolved && !isMarketVoided(marketId)) {
      // resolved market, price is either 0 or 1
      return outcomeId == market.resolution.outcomeId ? ONE : 0;
    }

    // outcome price = 1 / (1 + sum(outcome shares / every outcome shares))
    uint256 div = ONE;
    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      if (i == outcomeId) continue;

      div = div + (market.outcomes[outcomeId].shares.available * ONE) / market.outcomes[i].shares.available;
    }

    return (ONE * ONE) / div;
  }

  function getMarketOutcomeData(uint256 marketId, uint256 outcomeId)
    external
    view
    returns (
      uint256,
      uint256,
      uint256
    )
  {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[outcomeId];

    return (getMarketOutcomePrice(marketId, outcomeId), outcome.shares.available, outcome.shares.total);
  }

  function getMarketOutcomesShares(uint256 marketId) private view returns (uint256[] memory) {
    Market storage market = markets[marketId];

    uint256[] memory shares = new uint256[](market.outcomeCount);
    for (uint256 i = 0; i < market.outcomeCount; ++i) {
      shares[i] = market.outcomes[i].shares.available;
    }

    return shares;
  }

  function getMarketPaused(uint256 marketId) external view returns (bool) {
    Market storage market = markets[marketId];

    return market.paused;
  }
}
