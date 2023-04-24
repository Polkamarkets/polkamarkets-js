pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

// openzeppelin imports
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library CeilDiv {
  // calculates ceil(x/y)
  function ceildiv(uint256 x, uint256 y) internal pure returns (uint256) {
    if (x > 0) return ((x - 1) / y) + 1;
    return x / y;
  }
}

interface IRealityETH_ERC20 {
  function askQuestionERC20 (uint256 template_id, string calldata question, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce, uint256 tokens) external returns (bytes32);
  function claimMultipleAndWithdrawBalance (bytes32[] calldata question_ids, uint256[] calldata lengths, bytes32[] calldata hist_hashes, address[] calldata addrs, uint256[] calldata bonds, bytes32[] calldata answers) external;
  function claimWinnings (bytes32 question_id, bytes32[] calldata history_hashes, address[] calldata addrs, uint256[] calldata bonds, bytes32[] calldata answers) external;
  function notifyOfArbitrationRequest (bytes32 question_id, address requester, uint256 max_previous) external;
  function submitAnswerERC20 (bytes32 question_id, bytes32 answer, uint256 max_previous, uint256 tokens) external;
  function questions (bytes32) external view returns (bytes32 content_hash, address arbitrator, uint32 opening_ts, uint32 timeout, uint32 finalize_ts, bool is_pending_arbitration, uint256 bounty, bytes32 best_answer, bytes32 history_hash, uint256 bond, uint256 min_bond);
  function resultFor (bytes32 question_id) external view returns (bytes32);
}

interface IWETH {
  function deposit() external payable;

  function transfer(address to, uint256 value) external returns (bool);

  function withdraw(uint256) external;

  function approve(address guy, uint256 wad) external returns (bool);
}

/// @title Market Contract Factory
contract PredictionMarketV2 is ReentrancyGuard {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;
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

  event MarketOutcomeShares(uint256 indexed marketId, uint256 timestamp, uint256[] outcomeShares, uint256 liquidity);

  event MarketOutcomePrice(uint256 indexed marketId, uint256 indexed outcomeId, uint256 value, uint256 timestamp);

  event MarketLiquidity(
    uint256 indexed marketId,
    uint256 value, // total liquidity
    uint256 price, // value of one liquidity share; max: 1 (even odds situation)
    uint256 timestamp
  );

  event MarketResolved(address indexed user, uint256 indexed marketId, uint256 outcomeId, uint256 timestamp);

  // ------ Events End ------

  uint256 public constant MAX_UINT_256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

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
  }

  struct MarketFees {
    uint256 fee; // fee % taken from every transaction
    uint256 poolWeight; // internal var used to ensure pro-rate fee distribution
    mapping(address => uint256) claimed;
    address treasury; // address to send treasury fees to
    uint256 treasuryFee; // fee % taken from every transaction to a treasury address
  }

  struct MarketResolution {
    bool resolved;
    uint256 outcomeId;
    bytes32 questionId; // realitio questionId
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
    uint256 fee;
    uint256 treasuryFee;
    address treasury;
  }

  uint256[] marketIds;
  mapping(uint256 => Market) markets;
  uint256 public marketIndex;

  // realitio configs
  address public realitioAddress;
  uint256 public realitioTimeout;
  // market creation
  IERC20 public requiredBalanceToken; // token used for rewards / market creation
  uint256 public requiredBalance; // required balance for market creation
  // weth configs
  IWETH public WETH;

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

  modifier transitionNext(uint256 marketId) {
    _;
    nextState(marketId);
  }

  modifier mustHoldRequiredBalance() {
    require(
      requiredBalance == 0 || requiredBalanceToken.balanceOf(msg.sender) >= requiredBalance,
      "msg.sender must hold minimum erc20 balance"
    );
    _;
  }

  modifier isWETHMarket(uint256 marketId) {
    require(address(markets[marketId].token) == address(WETH), "Market token is not WETH");
    _;
  }

  // ------ Modifiers End ------

  /// @dev protocol is immutable and has no ownership
  constructor(
    IERC20 _requiredBalanceToken,
    uint256 _requiredBalance,
    address _realitioAddress,
    uint256 _realitioTimeout,
    IWETH _WETH
  ) {
    require(_realitioAddress != address(0), "_realitioAddress is address 0");
    require(_realitioTimeout > 0, "timeout must be positive");

    requiredBalanceToken = _requiredBalanceToken;
    requiredBalance = _requiredBalance;
    realitioAddress = _realitioAddress;
    realitioTimeout = _realitioTimeout;
    WETH = _WETH;
  }

  receive() external payable {
    assert(msg.sender == address(WETH)); // only accept ETH via fallback from the WETH contract
  }

  // ------ Core Functions ------

  /// @dev Creates a market, initializes the outcome shares pool and submits a question in Realitio
  function _createMarket(CreateMarketDescription memory desc) private mustHoldRequiredBalance returns (uint256) {
    uint256 marketId = marketIndex;
    marketIds.push(marketId);

    Market storage market = markets[marketId];

    require(desc.value > 0, "stake needs to be > 0");
    require(desc.closesAt > block.timestamp, "market must resolve after the current date");
    require(desc.arbitrator != address(0), "invalid arbitrator address");
    require(desc.outcomes > 0 && desc.outcomes <= MAX_OUTCOMES, "number of outcomes has to between 1-32");
    require(desc.fee <= MAX_FEE, "fee must be <= 5%");
    require(desc.treasuryFee <= MAX_FEE, "treasury fee must be <= 5%");

    market.token = desc.token;
    market.closesAtTimestamp = desc.closesAt;
    market.state = MarketState.open;
    market.fees.fee = desc.fee;
    market.fees.treasuryFee = desc.treasuryFee;
    market.fees.treasury = desc.treasury;
    // setting intial value to an integer that does not map to any outcomeId
    market.resolution.outcomeId = MAX_UINT_256;
    market.outcomeCount = desc.outcomes;

    // creating question in realitio
    market.resolution.questionId = IRealityETH_ERC20(realitioAddress).askQuestionERC20(
      2,
      desc.question,
      desc.arbitrator,
      uint32(realitioTimeout),
      uint32(desc.closesAt),
      0,
      0
    );

    _addLiquidity(marketId, desc.value, desc.distribution);

    // emiting initial price events
    emitMarketActionEvents(marketId);
    emit MarketCreated(msg.sender, marketId, desc.outcomes, desc.question, desc.image, desc.token);

    // incrementing market array index
    marketIndex = marketIndex + 1;

    return marketId;
  }

  function createMarket(CreateMarketDescription calldata desc) external returns (uint256) {
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
        fee: desc.fee,
        treasuryFee: desc.treasuryFee,
        treasury: desc.treasury
      })
    );
    // transferring funds
    desc.token.safeTransferFrom(msg.sender, address(this), desc.value);

    return marketId;
  }

  function createMarketWithETH(CreateMarketDescription calldata desc) external payable returns (uint256) {
    require(address(desc.token) == address(WETH), "Market token is not WETH");
    require(msg.value == desc.value, "msg.value must be equal to desc.value");
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
        fee: desc.fee,
        treasuryFee: desc.treasuryFee,
        treasury: desc.treasury
      })
    );
    // transferring funds
    IWETH(WETH).deposit{value: msg.value}();

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
    uint256 amountMinusFees = amount.sub(amount.mul(fee) / ONE);
    uint256 buyTokenPoolBalance = outcomesShares[outcomeId];
    uint256 endingOutcomeBalance = buyTokenPoolBalance.mul(ONE);
    for (uint256 i = 0; i < outcomesShares.length; i++) {
      if (i != outcomeId) {
        uint256 outcomeShares = outcomesShares[i];
        endingOutcomeBalance = endingOutcomeBalance.mul(outcomeShares).ceildiv(outcomeShares.add(amountMinusFees));
      }
    }
    require(endingOutcomeBalance > 0, "must have non-zero balances");

    return buyTokenPoolBalance.add(amountMinusFees).sub(endingOutcomeBalance.ceildiv(ONE));
  }

  /// @dev Calculates the number of shares needed to be sold in order to receive "amount" in balance
  function calcSellAmount(
    uint256 amount,
    uint256 marketId,
    uint256 outcomeId
  ) public view returns (uint256 outcomeTokenSellAmount) {
    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256 fee = getMarketFee(marketId);
    uint256 amountPlusFees = amount.mul(ONE) / ONE.sub(fee);
    uint256 sellTokenPoolBalance = outcomesShares[outcomeId];
    uint256 endingOutcomeBalance = sellTokenPoolBalance.mul(ONE);
    for (uint256 i = 0; i < outcomesShares.length; i++) {
      if (i != outcomeId) {
        uint256 outcomeShares = outcomesShares[i];
        endingOutcomeBalance = endingOutcomeBalance.mul(outcomeShares).ceildiv(outcomeShares.sub(amountPlusFees));
      }
    }
    require(endingOutcomeBalance > 0, "must have non-zero balances");

    return amountPlusFees.add(endingOutcomeBalance.ceildiv(ONE)).sub(sellTokenPoolBalance);
  }

  /// @dev Buy shares of a market outcome
  function _buy(
    uint256 marketId,
    uint256 outcomeId,
    uint256 minOutcomeSharesToBuy,
    uint256 value
  ) private timeTransitions(marketId) atState(marketId, MarketState.open) {
    Market storage market = markets[marketId];

    uint256 shares = calcBuyAmount(value, marketId, outcomeId);
    require(shares >= minOutcomeSharesToBuy, "minimum buy amount not reached");
    require(shares > 0, "shares amount is 0");

    // subtracting fee from transaction value
    uint256 feeAmount = value.mul(market.fees.fee) / ONE;
    market.fees.poolWeight = market.fees.poolWeight.add(feeAmount);
    uint256 valueMinusFees = value.sub(feeAmount);

    uint256 treasuryFeeAmount = value.mul(market.fees.treasuryFee) / ONE;
    valueMinusFees = valueMinusFees.sub(treasuryFeeAmount);

    MarketOutcome storage outcome = market.outcomes[outcomeId];

    // Funding market shares with received funds
    addSharesToMarket(marketId, valueMinusFees);

    require(outcome.shares.available >= shares, "outcome shares pool balance is too low");

    transferOutcomeSharesfromPool(msg.sender, marketId, outcomeId, shares);

    emit MarketActionTx(msg.sender, MarketAction.buy, marketId, outcomeId, shares, value, block.timestamp);
    emitMarketActionEvents(marketId);

    // transfering treasury fee to treasury address
    if (treasuryFeeAmount > 0) {
      market.token.safeTransfer(market.fees.treasury, treasuryFeeAmount);
    }
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

  /// @dev Sell shares of a market outcome
  function _sell(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value,
    uint256 maxOutcomeSharesToSell
  ) private timeTransitions(marketId) atState(marketId, MarketState.open) {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[outcomeId];

    uint256 shares = calcSellAmount(value, marketId, outcomeId);

    require(shares <= maxOutcomeSharesToSell, "maximum sell amount exceeded");
    require(shares > 0, "shares amount is 0");
    require(outcome.shares.holders[msg.sender] >= shares, "user does not have enough balance");

    transferOutcomeSharesToPool(msg.sender, marketId, outcomeId, shares);

    // adding fees to transaction value
    uint256 fee = getMarketFee(marketId);
    {
      uint256 feeAmount = value.mul(market.fees.fee) / (ONE.sub(fee));
      market.fees.poolWeight = market.fees.poolWeight.add(feeAmount);
    }
    uint256 valuePlusFees = value.add(value.mul(fee) / (ONE.sub(fee)));

    require(market.balance >= valuePlusFees, "market does not have enough balance");

    // Rebalancing market shares
    removeSharesFromMarket(marketId, valuePlusFees);

    emit MarketActionTx(msg.sender, MarketAction.sell, marketId, outcomeId, shares, value, block.timestamp);
    emitMarketActionEvents(marketId);

    {
      uint256 treasuryFeeAmount = value.mul(market.fees.treasuryFee) / (ONE.sub(fee));
      // transfering treasury fee to treasury address
      if (treasuryFeeAmount > 0) {
        market.token.safeTransfer(market.fees.treasury, treasuryFeeAmount);
      }
    }
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
    require(address(WETH) != address(0), "WETH address is address 0");

    Market storage market = markets[marketId];
    require(address(market.token) == address(WETH), "market token is not WETH");

    _sell(marketId, outcomeId, value, maxOutcomeSharesToSell);

    IWETH(WETH).withdraw(value);
    payable(msg.sender).call{value: value}("");
  }

  /// @dev Adds liquidity to a market - external
  function _addLiquidity(
    uint256 marketId,
    uint256 value,
    uint256[] memory distribution
  ) private timeTransitions(marketId) atState(marketId, MarketState.open) {
    Market storage market = markets[marketId];

    require(value > 0, "stake has to be greater than 0.");

    uint256 liquidityAmount;

    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256[] memory sendBackAmounts = new uint256[](outcomesShares.length);
    uint256 poolWeight = 0;

    if (market.liquidity > 0) {
      require(distribution.length == 0, "market already has liquidity, can't distribute liquidity");

      // part of the liquidity is exchanged for outcome shares if market is not balanced
      for (uint256 i = 0; i < outcomesShares.length; i++) {
        uint256 outcomeShares = outcomesShares[i];
        if (poolWeight < outcomeShares) poolWeight = outcomeShares;
      }

      for (uint256 i = 0; i < outcomesShares.length; i++) {
        uint256 remaining = value.mul(outcomesShares[i]) / poolWeight;
        sendBackAmounts[i] = value.sub(remaining);
      }

      liquidityAmount = value.mul(market.liquidity) / poolWeight;

      // re-balancing fees pool
      rebalanceFeesPool(marketId, liquidityAmount, MarketAction.addLiquidity);
    } else {
      // funding market with no liquidity
      if (distribution.length > 0) {
        require(distribution.length == outcomesShares.length, "weight distribution length does not match");

        uint256 maxHint = 0;
        for (uint256 i = 0; i < distribution.length; i++) {
          uint256 hint = distribution[i];
          if (maxHint < hint) maxHint = hint;
        }

        for (uint256 i = 0; i < distribution.length; i++) {
          uint256 remaining = value.mul(distribution[i]) / maxHint;
          require(remaining > 0, "must hint a valid distribution");
          sendBackAmounts[i] = value.sub(remaining);
        }
      }

      // funding market with total liquidity amount
      liquidityAmount = value;
    }

    // funding market
    market.liquidity = market.liquidity.add(liquidityAmount);
    market.liquidityShares[msg.sender] = market.liquidityShares[msg.sender].add(liquidityAmount);

    addSharesToMarket(marketId, value);

    {
      // transform sendBackAmounts to array of amounts added
      for (uint256 i = 0; i < sendBackAmounts.length; i++) {
        if (sendBackAmounts[i] > 0) {
          transferOutcomeSharesfromPool(msg.sender, marketId, i, sendBackAmounts[i]);
        }
      }

      // emitting events, using outcome 0 for price reference
      uint256 referencePrice = getMarketOutcomePrice(marketId, 0);

      for (uint256 i = 0; i < sendBackAmounts.length; i++) {
        if (sendBackAmounts[i] > 0) {
          // outcome price = outcome shares / reference outcome shares * reference outcome price
          uint256 outcomePrice = referencePrice.mul(market.outcomes[0].shares.available).div(
            market.outcomes[i].shares.available
          );

          emit MarketActionTx(
            msg.sender,
            MarketAction.buy,
            marketId,
            i,
            sendBackAmounts[i],
            sendBackAmounts[i].mul(outcomePrice).div(ONE), // price * shares
            block.timestamp
          );
        }
      }
    }

    uint256 liquidityPrice = getMarketLiquidityPrice(marketId);
    uint256 liquidityValue = liquidityPrice.mul(liquidityAmount) / ONE;

    emit MarketActionTx(msg.sender, MarketAction.addLiquidity, marketId, 0, liquidityAmount, liquidityValue, block.timestamp);
    emit MarketLiquidity(marketId, market.liquidity, liquidityPrice, block.timestamp);
  }

  function addLiquidity(uint256 marketId, uint256 value) external {
    uint256[] memory distribution = new uint256[](0);
    _addLiquidity(marketId, value, distribution);

    Market storage market = markets[marketId];
    market.token.safeTransferFrom(msg.sender, address(this), value);
  }

  function addLiquidityWithETH(uint256 marketId) external payable isWETHMarket(marketId) {
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
    returns (uint256)
  {
    Market storage market = markets[marketId];

    require(market.liquidityShares[msg.sender] >= shares, "user does not have enough balance");
    // claiming any pending fees
    claimFees(marketId);

    // re-balancing fees pool
    rebalanceFeesPool(marketId, shares, MarketAction.removeLiquidity);

    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256[] memory sendAmounts = new uint256[](outcomesShares.length);
    uint256 poolWeight = MAX_UINT_256;

    // part of the liquidity is exchanged for outcome shares if market is not balanced
    for (uint256 i = 0; i < outcomesShares.length; i++) {
      uint256 outcomeShares = outcomesShares[i];
      if (poolWeight > outcomeShares) poolWeight = outcomeShares;
    }

    uint256 liquidityAmount = shares.mul(poolWeight).div(market.liquidity);

    for (uint256 i = 0; i < outcomesShares.length; i++) {
      sendAmounts[i] = outcomesShares[i].mul(shares) / market.liquidity;
      sendAmounts[i] = sendAmounts[i].sub(liquidityAmount);
    }

    // removing liquidity from market
    removeSharesFromMarket(marketId, liquidityAmount);
    market.liquidity = market.liquidity.sub(shares);
    // removing liquidity tokens from market creator
    market.liquidityShares[msg.sender] = market.liquidityShares[msg.sender].sub(shares);

    for (uint256 i = 0; i < outcomesShares.length; i++) {
      if (sendAmounts[i] > 0) {
        transferOutcomeSharesfromPool(msg.sender, marketId, i, sendAmounts[i]);
      }
    }

    // emitting events, using outcome 0 for price reference
    uint256 referencePrice = getMarketOutcomePrice(marketId, 0);

    for (uint256 i = 0; i < outcomesShares.length; i++) {
      if (sendAmounts[i] > 0) {
        // outcome price = outcome shares / reference outcome shares * reference outcome price
        uint256 outcomePrice = referencePrice.mul(market.outcomes[0].shares.available).div(
          market.outcomes[i].shares.available
        );

        emit MarketActionTx(
          msg.sender,
          MarketAction.buy,
          marketId,
          i,
          sendAmounts[i],
          sendAmounts[i].mul(outcomePrice).div(ONE), // price * shares
          block.timestamp
        );
      }
    }

    emit MarketActionTx(msg.sender, MarketAction.removeLiquidity, marketId, 0, shares, liquidityAmount, block.timestamp);
    emit MarketLiquidity(marketId, market.liquidity, getMarketLiquidityPrice(marketId), block.timestamp);

    return liquidityAmount;
  }

  function removeLiquidity(uint256 marketId, uint256 shares) external {
    uint256 value = _removeLiquidity(marketId, shares);
    // transferring user funds from liquidity removed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function removeLiquidityToETH(uint256 marketId, uint256 shares) external isWETHMarket(marketId) {
    uint256 value = _removeLiquidity(marketId, shares);
    // unwrapping and transferring user funds from liquidity removed
    IWETH(WETH).withdraw(value);
    payable(msg.sender).call{value: value}("");
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
    uint256 outcomeId = uint256(IRealityETH_ERC20(realitioAddress).resultFor(market.resolution.questionId));

    market.resolution.outcomeId = outcomeId;

    emit MarketResolved(msg.sender, marketId, outcomeId, block.timestamp);
    emitMarketActionEvents(marketId);

    return market.resolution.outcomeId;
  }

  /// @dev Allows holders of resolved outcome shares to claim earnings.
  function _claimWinnings(uint256 marketId) private atState(marketId, MarketState.resolved) returns (uint256) {
    Market storage market = markets[marketId];
    MarketOutcome storage resolvedOutcome = market.outcomes[market.resolution.outcomeId];

    require(resolvedOutcome.shares.holders[msg.sender] > 0, "user does not hold resolved outcome shares");
    require(resolvedOutcome.shares.claims[msg.sender] == false, "user already claimed resolved outcome winnings");

    // 1 share => price = 1
    uint256 value = resolvedOutcome.shares.holders[msg.sender];

    // assuring market has enough funds
    require(market.balance >= value, "Market does not have enough balance");

    market.balance = market.balance.sub(value);
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

    return value;
  }

  function claimWinnings(uint256 marketId) external {
    uint256 value = _claimWinnings(marketId);
    // transferring user funds from winnings claimed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function claimWinningsToETH(uint256 marketId) external isWETHMarket(marketId) {
    uint256 value = _claimWinnings(marketId);
    // unwrapping and transferring user funds from winnings claimed
    IWETH(WETH).withdraw(value);
    payable(msg.sender).call{value: value}("");
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
    require(outcome.shares.holders[msg.sender] > 0, "user does not hold outcome shares");
    require(outcome.shares.voidedClaims[msg.sender] == false, "user already claimed outcome shares");

    // voided market - shares are valued at last market price
    uint256 price = getMarketOutcomePrice(marketId, outcomeId);
    uint256 value = price.mul(outcome.shares.holders[msg.sender]).div(ONE);

    // assuring market has enough funds
    require(market.balance >= value, "Market does not have enough balance");

    market.balance = market.balance.sub(value);
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

  function claimVoidedOutcomeShares(uint256 marketId, uint256 outcomeId) external {
    uint256 value = _claimVoidedOutcomeShares(marketId, outcomeId);
    // transferring user funds from voided outcome shares claimed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function claimVoidedOutcomeSharesToETH(uint256 marketId, uint256 outcomeId) external isWETHMarket(marketId) {
    uint256 value = _claimVoidedOutcomeShares(marketId, outcomeId);
    // unwrapping and transferring user funds from voided outcome shares claimed
    IWETH(WETH).withdraw(value);
    payable(msg.sender).call{value: value}("");
  }

  /// @dev Allows liquidity providers to claim earnings from liquidity providing.
  function _claimLiquidity(uint256 marketId) private atState(marketId, MarketState.resolved) returns (uint256) {
    Market storage market = markets[marketId];

    // claiming any pending fees
    claimFees(marketId);

    require(market.liquidityShares[msg.sender] > 0, "user does not hold liquidity shares");
    require(market.liquidityClaims[msg.sender] == false, "user already claimed liquidity winnings");

    // value = total resolved outcome pool shares * pool share (%)
    uint256 liquidityPrice = getMarketLiquidityPrice(marketId);
    uint256 value = liquidityPrice.mul(market.liquidityShares[msg.sender]) / ONE;

    // assuring market has enough funds
    require(market.balance >= value, "Market does not have enough balance");

    market.balance = market.balance.sub(value);
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

  function claimLiquidity(uint256 marketId) external {
    uint256 value = _claimLiquidity(marketId);
    // transferring user funds from liquidity claimed
    Market storage market = markets[marketId];
    market.token.safeTransfer(msg.sender, value);
  }

  function claimLiquidityToETH(uint256 marketId) external isWETHMarket(marketId) {
    uint256 value = _claimLiquidity(marketId);
    // unwrapping and transferring user funds from liquidity claimed
    IWETH(WETH).withdraw(value);
    payable(msg.sender).call{value: value}("");
  }

  /// @dev Allows liquidity providers to claim their fees share from fees pool
  function _claimFees(uint256 marketId) private returns (uint256) {
    Market storage market = markets[marketId];

    uint256 claimableFees = getUserClaimableFees(marketId, msg.sender);

    if (claimableFees > 0) {
      market.fees.claimed[msg.sender] = market.fees.claimed[msg.sender].add(claimableFees);
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
    payable(msg.sender).call{value: value}("");
  }

  /// @dev Rebalances the fees pool. Needed in every AddLiquidity / RemoveLiquidity call
  function rebalanceFeesPool(
    uint256 marketId,
    uint256 liquidityShares,
    MarketAction action
  ) private {
    Market storage market = markets[marketId];

    uint256 poolWeight = liquidityShares.mul(market.fees.poolWeight).div(market.liquidity);

    if (action == MarketAction.addLiquidity) {
      market.fees.poolWeight = market.fees.poolWeight.add(poolWeight);
      market.fees.claimed[msg.sender] = market.fees.claimed[msg.sender].add(poolWeight);
    } else {
      market.fees.poolWeight = market.fees.poolWeight.sub(poolWeight);
      market.fees.claimed[msg.sender] = market.fees.claimed[msg.sender].sub(poolWeight);
    }
  }

  /// @dev Transitions market to next state
  function nextState(uint256 marketId) private {
    Market storage market = markets[marketId];
    market.state = MarketState(uint256(market.state) + 1);
  }

  /// @dev Emits a outcome price event for every outcome
  function emitMarketActionEvents(uint256 marketId) private {
    Market storage market = markets[marketId];
    uint256[] memory outcomeShares = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; i++) {
      outcomeShares[i] = market.outcomes[i].shares.available;
    }

    emit MarketOutcomeShares(marketId, block.timestamp, outcomeShares, market.liquidity);
  }

  /// @dev Adds outcome shares to shares pool
  function addSharesToMarket(uint256 marketId, uint256 shares) private {
    Market storage market = markets[marketId];

    for (uint256 i = 0; i < market.outcomeCount; i++) {
      MarketOutcome storage outcome = market.outcomes[i];

      outcome.shares.available = outcome.shares.available.add(shares);
      outcome.shares.total = outcome.shares.total.add(shares);

      // only adding to market total shares, the available remains
      market.sharesAvailable = market.sharesAvailable.add(shares);
    }

    market.balance = market.balance.add(shares);
  }

  /// @dev Removes outcome shares from shares pool
  function removeSharesFromMarket(uint256 marketId, uint256 shares) private {
    Market storage market = markets[marketId];

    for (uint256 i = 0; i < market.outcomeCount; i++) {
      MarketOutcome storage outcome = market.outcomes[i];

      outcome.shares.available = outcome.shares.available.sub(shares);
      outcome.shares.total = outcome.shares.total.sub(shares);

      // only subtracting from market total shares, the available remains
      market.sharesAvailable = market.sharesAvailable.sub(shares);
    }

    market.balance = market.balance.sub(shares);
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
    outcome.shares.holders[user] = outcome.shares.holders[user].add(shares);
    outcome.shares.available = outcome.shares.available.sub(shares);
    market.sharesAvailable = market.sharesAvailable.sub(shares);
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
    outcome.shares.holders[user] = outcome.shares.holders[user].sub(shares);
    outcome.shares.available = outcome.shares.available.add(shares);
    market.sharesAvailable = market.sharesAvailable.add(shares);
  }

  // ------ Core Functions End ------

  // ------ Getters ------

  function getUserMarketShares(uint256 marketId, address user) external view returns (uint256, uint256[] memory) {
    Market storage market = markets[marketId];
    uint256[] memory outcomeShares = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; i++) {
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

    return market.liquidityShares[user].mul(ONE).div(market.liquidity);
  }

  function getUserClaimableFees(uint256 marketId, address user) public view returns (uint256) {
    Market storage market = markets[marketId];

    uint256 rawAmount = market.fees.poolWeight.mul(market.liquidityShares[user]).div(market.liquidity);

    // No fees left to claim
    if (market.fees.claimed[user] > rawAmount) return 0;

    return rawAmount.sub(market.fees.claimed[user]);
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
      address
    )
  {
    Market storage market = markets[marketId];

    return (
      market.fees.fee,
      market.resolution.questionId,
      uint256(market.resolution.questionId),
      market.token,
      market.fees.treasuryFee,
      market.fees.treasury
    );
  }

  function getMarketQuestion(uint256 marketId) external view returns (bytes32) {
    Market storage market = markets[marketId];

    return (market.resolution.questionId);
  }

  function getMarketPrices(uint256 marketId) external view returns (uint256, uint256[] memory) {
    Market storage market = markets[marketId];
    uint256[] memory prices = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; i++) {
      prices[i] = getMarketOutcomePrice(marketId, i);
    }

    return (getMarketLiquidityPrice(marketId), prices);
  }

  function getMarketShares(uint256 marketId) external view returns (uint256, uint256[] memory) {
    Market storage market = markets[marketId];
    uint256[] memory outcomeShares = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; i++) {
      outcomeShares[i] = market.outcomes[i].shares.available;
    }

    return (market.liquidity, outcomeShares);
  }

  function getMarketLiquidityPrice(uint256 marketId) public view returns (uint256) {
    Market storage market = markets[marketId];

    if (market.state == MarketState.resolved && !isMarketVoided(marketId)) {
      // resolved market, outcome prices are either 0 or 1
      // final liquidity price = outcome shares / liquidity shares
      return market.outcomes[market.resolution.outcomeId].shares.available.mul(ONE).div(market.liquidity);
    }

    // liquidity price = # outcomes / (liquidity * sum (1 / every outcome shares)
    uint256 marketSharesSum = 0;

    for (uint256 i = 0; i < market.outcomeCount; i++) {
      MarketOutcome storage outcome = market.outcomes[i];

      marketSharesSum = marketSharesSum.add(ONE.mul(ONE).div(outcome.shares.available));
    }

    return market.outcomeCount.mul(ONE).mul(ONE).mul(ONE).div(market.liquidity).div(marketSharesSum);
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

    return market.fees.fee.add(market.fees.treasuryFee);
  }

  // ------ Outcome Getters ------

  function getMarketOutcomeIds(uint256 marketId) external view returns (uint256[] memory) {
    Market storage market = markets[marketId];
    uint256[] memory outcomeIds = new uint256[](market.outcomeCount);

    for (uint256 i = 0; i < market.outcomeCount; i++) {
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
    for (uint256 i = 0; i < market.outcomeCount; i++) {
      if (i == outcomeId) continue;

      div = div.add(market.outcomes[outcomeId].shares.available.mul(ONE).div(market.outcomes[i].shares.available));
    }

    return ONE.mul(ONE).div(div);
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
    for (uint256 i = 0; i < market.outcomeCount; i++) {
      shares[i] = market.outcomes[i].shares.available;
    }

    return shares;
  }
}
