pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "./RealitioERC20.sol";

// openzeppelin imports
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

library CeilDiv {
  // calculates ceil(x/y)
  function ceildiv(uint256 x, uint256 y) internal pure returns (uint256) {
    if (x > 0) return ((x - 1) / y) + 1;
    return x / y;
  }
}

/// @title Market Contract Factory
contract PredictionMarket is Initializable, OwnableUpgradeable {
  using SafeMath for uint256;
  using CeilDiv for uint256;

  // ------ Events ------

  event MarketCreated(
    address indexed participant,
    uint256 indexed marketId,
    uint256 outcomes,
    string question,
    string image
  );

  event ParticipantAction(
    address indexed participant,
    MarketAction indexed action,
    uint256 indexed marketId,
    uint256 outcomeId,
    uint256 shares,
    uint256 value,
    uint256 timestamp
  );

  event MarketOutcomePrice(uint256 indexed marketId, uint256 indexed outcomeId, uint256 value, uint256 timestamp);

  event MarketLiquidity(
    uint256 indexed marketId,
    uint256 value, // total liquidity (ETH)
    uint256 price, // value of 1 liquidity share; max: 1 ETH (50-50 situation)
    uint256 timestamp
  );

  event MarketResolved(address indexed oracle, uint256 indexed marketId, uint256 outcomeId, uint256 timestamp);

  // ------ Events End ------

  uint256 public constant MAX_UINT_256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

  uint256 public constant ONE = 10**18;

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
    claimFees
  }

  struct Market {
    // market details
    string name; // TODO remove: deprecated;
    uint256 closedDateTime;
    uint256 balance; // total stake (ETH)
    uint256 liquidity; // stake held (ETH)
    uint256 sharesAvailable; // shares held (all outcomes)
    mapping(address => uint256) liquidityShares;
    mapping(address => bool) liquidityClaims; // wether participant has claimed liquidity winnings
    MarketState state; // resolution variables
    MarketResolution resolution; // fees
    MarketFees fees;
    // market outcomes
    uint256[] outcomeIds;
    mapping(uint256 => MarketOutcome) outcomes;
  }

  struct MarketFees {
    uint256 value; // fee % taken from every transaction
    uint256 poolWeight; // internal var used to ensure pro-rate fee distribution
    mapping(address => uint256) claimed;
  }

  struct MarketResolution {
    address oracle; // TODO remove: deprecated;
    bool resolved;
    uint256 outcomeId;
    bytes32 questionId; // realitio questionId
  }

  struct MarketOutcome {
    uint256 marketId;
    uint256 id;
    string name; // TODO remove: deprecated;
    Shares shares;
  }

  struct Shares {
    uint256 total; // number of shares
    uint256 available; // available shares
    mapping(address => uint256) holders;
    mapping(address => bool) claims; // wether participant has claimed winnings
  }

  uint256[] marketIds;
  mapping(uint256 => Market) markets;
  uint256 public marketIndex;

  // governance
  uint256 public fee; // fee % taken from every transaction, can be updated by contract owner
  // realitio configs
  address public realitioAddress;
  uint256 public realitioTimeout;
  // market creation
  IERC20 public token; // token used for rewards / market creation
  uint256 public requiredBalance; // required balance for market creation

  // ------ Modifiers ------

  modifier isMarket(uint256 marketId) {
    require(marketId < marketIndex);
    _;
  }

  modifier timeTransitions(uint256 marketId) {
    if (now > markets[marketId].closedDateTime && markets[marketId].state == MarketState.open) {
      nextState(marketId);
    }
    _;
  }

  modifier atState(uint256 marketId, MarketState state) {
    require(markets[marketId].state == state);
    _;
  }

  modifier notAtState(uint256 marketId, MarketState state) {
    require(markets[marketId].state != state);
    _;
  }

  modifier transitionNext(uint256 marketId) {
    _;
    nextState(marketId);
  }

  modifier mustHoldRequiredBalance() {
    require(token.balanceOf(msg.sender) >= requiredBalance, "msg.sender must hold minimum erc20 balance");
    _;
  }

  // ------ Modifiers End ------

  // Initializer function (replaces constructor)
  function initialize() public initializer {
    __Ownable_init();
  }

  // ------ Core Functions ------

  /// Create a new Market contract
  /// @dev The new Market contract is then saved in the array of this contract for future reference.
  /// @param question - Market details: https://reality.eth.link/app/docs/html/contracts.html#how-questions-are-structured
  /// @param image - image ipfs hash
  /// @param closesAt - Timestamp of market expiration
  /// @param oracle - Artbitrator address
  /// @param outcomes - Number of outcomes
  function createMarket(
    string memory question,
    string memory image,
    uint256 closesAt,
    address oracle,
    uint256 outcomes
  ) public payable mustHoldRequiredBalance() returns (uint256) {
    uint256 marketId = marketIndex;
    marketIds.push(marketId);

    Market storage market = markets[marketId];

    require(msg.value > 0, "The stake has to be greater than 0.");
    require(closesAt >= now, "Market has to close after the current date");
    require(oracle == address(oracle), "Invalid oracle address");
    // starting with secondary markets
    require(outcomes == 2, "Number market outcome has to be 2");

    market.closedDateTime = closesAt;
    market.state = MarketState.open;
    market.resolution.oracle = oracle;
    market.fees.value = fee;
    // setting intial value to an integer that does not map to any outcomeId
    market.resolution.outcomeId = MAX_UINT_256;

    // creating question in realitio
    RealitioERC20 realitio = RealitioERC20(realitioAddress);

    market.resolution.questionId = realitio.askQuestionERC20(
      2,
      question,
      oracle,
      uint32(realitioTimeout),
      uint32(closesAt),
      0,
      0
    );

    market.liquidity = msg.value;
    // TODO review: only valid for 50-50 start
    market.liquidityShares[msg.sender] = market.liquidityShares[msg.sender].add(msg.value);

    // creating market outcomes
    for (uint256 i = 0; i < outcomes; i++) {
      market.outcomeIds.push(i);
      MarketOutcome storage outcome = market.outcomes[i];

      outcome.marketId = marketId;
      outcome.id = i;
    }

    // price starts at 0.5 ETH
    // TODO review: only valid for 50-50 start
    addSharesToMarket(marketId, msg.value);

    // emiting initial price events
    emitMarketOutcomePriceEvents(marketId);
    emit ParticipantAction(msg.sender, MarketAction.addLiquidity, marketId, 0, msg.value, msg.value, now);
    emit MarketCreated(msg.sender, marketId, outcomes, question, image);

    // incrementing market array index
    marketIndex = marketIndex + 1;

    return marketId;
  }

  function calcBuyAmount(
    uint256 amount,
    uint256 marketId,
    uint256 outcomeId
  ) public view returns (uint256) {
    Market storage market = markets[marketId];

    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256 amountMinusFees = amount.sub(amount.mul(market.fees.value) / ONE);
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

  function calcSellAmount(
    uint256 amount,
    uint256 marketId,
    uint256 outcomeId
  ) public view returns (uint256 outcomeTokenSellAmount) {
    Market storage market = markets[marketId];

    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256 amountPlusFees = amount.mul(ONE) / ONE.sub(market.fees.value);
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

  /// Buy shares of a market outcome
  function buy(uint256 marketId, uint256 outcomeId)
    external
    payable
    timeTransitions(marketId)
    atState(marketId, MarketState.open)
  {
    Market storage market = markets[marketId];

    uint256 value = msg.value;
    // TODO: verify value vs shares amount
    uint256 shares = calcBuyAmount(value, marketId, outcomeId);
    uint256 valueMinusFees;

    // subtracting fee from transaction value
    uint256 feeAmount = value.mul(market.fees.value) / ONE;
    market.fees.poolWeight = market.fees.poolWeight.add(feeAmount);
    valueMinusFees = value.sub(feeAmount);

    MarketOutcome storage outcome = market.outcomes[outcomeId];

    // Funding market shares with received ETH
    addSharesToMarket(marketId, valueMinusFees);

    require(shares > 0, "Can't be 0");
    require(outcome.shares.available >= shares, "Can't buy more shares than the ones available");

    transferOutcomeSharesfromPool(msg.sender, marketId, outcomeId, shares);

    emit ParticipantAction(msg.sender, MarketAction.buy, marketId, outcomeId, shares, value, now);
    emitMarketOutcomePriceEvents(marketId);
  }

  /// Sell shares of a market outcome
  function sell(
    uint256 marketId,
    uint256 outcomeId,
    uint256 value
  ) external payable timeTransitions(marketId) atState(marketId, MarketState.open) {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[outcomeId];

    // TODO: verify value vs shares amount
    uint256 shares = calcSellAmount(value, marketId, outcomeId);

    // Invariant check: make sure the stake is <= than user's stake
    require(outcome.shares.holders[msg.sender] >= shares);

    // Invariant check: make sure the market's stake is smaller than the stake
    require((outcome.shares.total - outcome.shares.available) >= shares);

    transferOutcomeSharesToPool(msg.sender, marketId, outcomeId, shares);

    // adding fee to transaction value
    uint256 feeAmount = value.mul(market.fees.value) / (ONE.sub(fee));
    market.fees.poolWeight = market.fees.poolWeight.add(feeAmount);
    uint256 valuePlusFees = value.add(feeAmount);

    // Invariant check: make sure the contract has enough balance to be withdrawn from.
    require(address(this).balance >= valuePlusFees);
    require(market.balance >= valuePlusFees);

    // Rebalancing market shares
    removeSharesFromMarket(marketId, valuePlusFees);

    // Transferring funds to user
    msg.sender.transfer(value);

    emit ParticipantAction(msg.sender, MarketAction.sell, marketId, outcomeId, shares, value, now);
    emitMarketOutcomePriceEvents(marketId);
  }

  function addLiquidity(uint256 marketId)
    external
    payable
    timeTransitions(marketId)
    atState(marketId, MarketState.open)
  {
    Market storage market = markets[marketId];

    require(msg.value > 0, "The stake has to be greater than 0.");

    uint256 value = msg.value;
    uint256 liquidityAmount;

    uint256[] memory outcomesShares = getMarketOutcomesShares(marketId);
    uint256[] memory sendBackAmounts = new uint256[](outcomesShares.length);
    uint256 poolWeight = 0;

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

    // funding market
    market.liquidity = market.liquidity.add(liquidityAmount);
    market.liquidityShares[msg.sender] = market.liquidityShares[msg.sender].add(liquidityAmount);

    addSharesToMarket(marketId, value);

    // transform sendBackAmounts to array of amounts added
    for (uint256 i = 0; i < sendBackAmounts.length; i++) {
      if (sendBackAmounts[i] > 0) {
        transferOutcomeSharesfromPool(msg.sender, marketId, i, sendBackAmounts[i]);
        // TODO: buy event
      }
    }

    emit ParticipantAction(msg.sender, MarketAction.addLiquidity, marketId, 0, liquidityAmount, value, now);
    emit MarketLiquidity(marketId, market.liquidity, getMarketLiquidityPrice(marketId), now);
  }

  function removeLiquidity(uint256 marketId, uint256 shares)
    external
    payable
    timeTransitions(marketId)
    atState(marketId, MarketState.open)
  {
    Market storage market = markets[marketId];

    // Invariant check: make sure the stake is <= than user's stake
    require(market.liquidityShares[msg.sender] >= shares);
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

      if (sendAmounts[i] > 0) {
        transferOutcomeSharesfromPool(msg.sender, marketId, i, sendAmounts[i]);
        // TODO: buy event
      }
    }

    // removing liquidity from market
    removeSharesFromMarket(marketId, liquidityAmount);
    market.liquidity = market.liquidity.sub(shares);
    // removing liquidity tokens from market creator
    market.liquidityShares[msg.sender] = market.liquidityShares[msg.sender].sub(shares);

    // transferring user ETH from liquidity removed
    msg.sender.transfer(liquidityAmount);

    emit ParticipantAction(msg.sender, MarketAction.removeLiquidity, marketId, 0, shares, liquidityAmount, now);
    emit MarketLiquidity(marketId, market.liquidity, getMarketLiquidityPrice(marketId), now);
  }

  /// Determine the result of the market
  /// @dev Only allowed by oracle
  /// @return Id of the outcome
  function resolveMarketOutcome(uint256 marketId)
    public
    timeTransitions(marketId)
    atState(marketId, MarketState.closed)
    transitionNext(marketId)
    returns (uint256)
  {
    Market storage market = markets[marketId];

    RealitioERC20 realitio = RealitioERC20(realitioAddress);
    // will throw an error if question is not finalized
    uint256 outcomeId = uint256(realitio.resultFor(market.resolution.questionId));

    MarketOutcome storage outcome = market.outcomes[outcomeId];

    // TODO: process outcome

    market.resolution.outcomeId = outcomeId;

    emit MarketResolved(msg.sender, marketId, outcomeId, now);
    // emitting 1 price event for winner outcome
    emit MarketOutcomePrice(marketId, outcomeId, ONE, now);
    // emitting 0 price event for loser outcome
    emit MarketOutcomePrice(marketId, (outcomeId == 0 ? 1 : 0), 0, now);
    // final liquidity price = outcome shares / liquidity shares
    uint256 liquidityPrice = outcome.shares.available.mul(ONE).div(market.liquidity);
    emit MarketLiquidity(marketId, market.liquidity, liquidityPrice, now);

    return market.resolution.outcomeId;
  }

  /// Allowing holders of resolved outcome shares to claim earnings.
  function claimWinnings(uint256 marketId) public atState(marketId, MarketState.resolved) {
    Market storage market = markets[marketId];
    MarketOutcome storage resolvedOutcome = market.outcomes[market.resolution.outcomeId];

    require(resolvedOutcome.shares.holders[msg.sender] > 0, "Participant does not hold resolved outcome shares");
    require(
      resolvedOutcome.shares.claims[msg.sender] == false,
      "Participant already claimed resolved outcome winnings"
    );

    // 1 share = 1 ETH
    uint256 value = resolvedOutcome.shares.holders[msg.sender];

    // assuring market has enough funds
    require(market.balance >= value, "Market does not have enough balance");

    market.balance = market.balance.sub(value);
    resolvedOutcome.shares.claims[msg.sender] = true;

    emit ParticipantAction(
      msg.sender,
      MarketAction.claimWinnings,
      marketId,
      market.resolution.outcomeId,
      resolvedOutcome.shares.holders[msg.sender],
      value,
      now
    );

    msg.sender.transfer(value);
  }

  /// Allowing liquidity providers to claim earnings from liquidity providing.
  function claimLiquidity(uint256 marketId) public atState(marketId, MarketState.resolved) {
    Market storage market = markets[marketId];
    MarketOutcome storage resolvedOutcome = market.outcomes[market.resolution.outcomeId];

    // claiming any pending fees
    claimFees(marketId);

    require(market.liquidityShares[msg.sender] > 0, "Participant does not hold liquidity shares");
    require(market.liquidityClaims[msg.sender] == false, "Participant already claimed liquidity winnings");

    // value = total resolved outcome pool shares * pool share (%)
    uint256 value = resolvedOutcome.shares.available.mul(getUserLiquidityPoolShare(marketId, msg.sender)).div(ONE);

    // assuring market has enough funds
    require(market.balance >= value, "Market does not have enough balance");

    market.balance = market.balance.sub(value);
    market.liquidityClaims[msg.sender] = true;

    emit ParticipantAction(
      msg.sender,
      MarketAction.claimLiquidity,
      marketId,
      0,
      market.liquidityShares[msg.sender],
      value,
      now
    );

    msg.sender.transfer(value);
  }

  function claimFees(uint256 marketId) public payable {
    Market storage market = markets[marketId];

    uint256 claimableFees = getUserClaimableFees(marketId, msg.sender);

    if (claimableFees > 0) {
      market.fees.claimed[msg.sender] = market.fees.claimed[msg.sender].add(claimableFees);
      msg.sender.transfer(claimableFees);
    }

    emit ParticipantAction(
      msg.sender,
      MarketAction.claimFees,
      marketId,
      0,
      market.liquidityShares[msg.sender],
      claimableFees,
      now
    );
  }

  function rebalanceFeesPool(
    uint256 marketId,
    uint256 liquidityShares,
    MarketAction action
  ) private returns (uint256) {
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

  /// Internal function for advancing the market state.
  function nextState(uint256 marketId) private {
    Market storage market = markets[marketId];
    market.state = MarketState(uint256(market.state) + 1);
  }

  function emitMarketOutcomePriceEvents(uint256 marketId) private {
    Market storage market = markets[marketId];

    for (uint256 i = 0; i < market.outcomeIds.length; i++) {
      emit MarketOutcomePrice(marketId, i, getMarketOutcomePrice(marketId, i), now);
    }

    // liquidity shares also change value
    emit MarketLiquidity(marketId, market.liquidity, getMarketLiquidityPrice(marketId), now);
  }

  function addSharesToMarket(uint256 marketId, uint256 shares) private {
    Market storage market = markets[marketId];

    for (uint256 i = 0; i < market.outcomeIds.length; i++) {
      MarketOutcome storage outcome = market.outcomes[i];

      outcome.shares.available = outcome.shares.available.add(shares);
      outcome.shares.total = outcome.shares.total.add(shares);

      // only adding to market total shares, the available remains
      market.sharesAvailable = market.sharesAvailable.add(shares);
    }

    market.balance = market.balance.add(shares);
  }

  function removeSharesFromMarket(uint256 marketId, uint256 shares) private {
    Market storage market = markets[marketId];

    for (uint256 i = 0; i < market.outcomeIds.length; i++) {
      MarketOutcome storage outcome = market.outcomes[i];

      outcome.shares.available = outcome.shares.available.sub(shares);
      outcome.shares.total = outcome.shares.total.sub(shares);

      // only subtracting from market total shares, the available remains
      market.sharesAvailable = market.sharesAvailable.sub(shares);
    }

    market.balance = market.balance.sub(shares);
  }

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

  // ------ Governance Functions Start ------

  function setFee(uint256 _fee) public onlyOwner() {
    fee = _fee;
  }

  function setRealitioERC20(address _address) public onlyOwner() {
    realitioAddress = _address;
  }

  function setRealitioTimeout(uint256 timeout) public onlyOwner() {
    realitioTimeout = timeout;
  }

  function setToken(IERC20 _token) public onlyOwner() {
    token = _token;
  }

  function setRequiredBalance(uint256 _requiredBalance) public onlyOwner() {
    requiredBalance = _requiredBalance;
  }

  // ------ Governance Functions End ------

  // ------ Getters ------

  function getUserMarketShares(uint256 marketId, address participant)
    public
    view
    returns (
      uint256,
      uint256,
      uint256
    )
  {
    Market storage market = markets[marketId];

    return (
      market.liquidityShares[participant],
      market.outcomes[0].shares.holders[participant],
      market.outcomes[1].shares.holders[participant]
    );
  }

  function getUserClaimStatus(uint256 marketId, address participant)
    public
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
      return (false, false, false, false, getUserClaimableFees(marketId, participant));
    }

    MarketOutcome storage outcome = market.outcomes[market.resolution.outcomeId];

    return (
      outcome.shares.holders[participant] > 0,
      outcome.shares.claims[participant],
      market.liquidityShares[participant] > 0,
      market.liquidityClaims[participant],
      getUserClaimableFees(marketId, participant)
    );
  }

  // @return % of liquidity pool stake
  function getUserLiquidityPoolShare(uint256 marketId, address participant) public view returns (uint256) {
    Market storage market = markets[marketId];

    return market.liquidityShares[participant].mul(ONE).div(market.liquidity);
  }

  function getUserClaimableFees(uint256 marketId, address participant) public view returns (uint256) {
    Market storage market = markets[marketId];

    uint256 rawAmount = market.fees.poolWeight.mul(market.liquidityShares[participant]).div(market.liquidity);
    return rawAmount.sub(market.fees.claimed[participant]);
  }

  /// Allow retrieving the the array of created contracts
  /// @return An array of all created Market contracts
  function getMarkets() public view returns (uint256[] memory) {
    return marketIds;
  }

  function getMarketData(uint256 marketId)
    public
    view
    returns (
      string memory,
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
      market.name,
      market.state,
      market.closedDateTime,
      market.liquidity,
      market.balance,
      market.sharesAvailable,
      getMarketResolvedOutcome(marketId)
    );
  }

  function getMarketAltData(uint256 marketId)
    public
    view
    returns (
      uint256,
      bytes32,
      uint256
    )
  {
    Market storage market = markets[marketId];

    return (market.fees.value, market.resolution.questionId, uint256(market.resolution.questionId));
  }

  function getMarketQuestion(uint256 marketId) public view returns (bytes32) {
    Market storage market = markets[marketId];

    return (market.resolution.questionId);
  }

  function getMarketPrices(uint256 marketId)
    public
    view
    returns (
      uint256,
      uint256,
      uint256
    )
  {
    return (getMarketLiquidityPrice(marketId), getMarketOutcomePrice(marketId, 0), getMarketOutcomePrice(marketId, 1));
  }

  function getMarketLiquidityPrice(uint256 marketId) public view returns (uint256) {
    Market storage market = markets[marketId];

    if (market.state == MarketState.resolved) {
      // resolved market, price is either 0 or 1
      // final liquidity price = outcome shares / liquidity shares
      return market.outcomes[market.resolution.outcomeId].shares.available.mul(ONE).div(market.liquidity);
    }

    // liquidity price = # liquidity shares / # outcome shares * # outcomes
    return market.liquidity.mul(ONE * market.outcomeIds.length).div(market.sharesAvailable);
  }

  function getMarketResolvedOutcome(uint256 marketId) public view returns (int256) {
    Market storage market = markets[marketId];

    // returning -1 if market still not resolved
    if (market.state != MarketState.resolved) {
      return -1;
    }

    return int256(market.resolution.outcomeId);
  }

  // ------ Outcome Getters ------

  function getMarketOutcomeIds(uint256 marketId) public view returns (uint256[] memory) {
    Market storage market = markets[marketId];
    return market.outcomeIds;
  }

  function getMarketOutcomePrice(uint256 marketId, uint256 marketOutcomeId) public view returns (uint256) {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[marketOutcomeId];

    if (market.state == MarketState.resolved) {
      // resolved market, price is either 0 or 1
      return marketOutcomeId == market.resolution.outcomeId ? ONE : 0;
    }

    require(
      outcome.shares.total >= outcome.shares.available,
      "Total shares has to be equal or higher than available shares"
    );
    require(
      market.sharesAvailable >= outcome.shares.available,
      "Total # available shares has to be equal or higher than outcome available shares"
    );

    uint256 holders = market.sharesAvailable.sub(outcome.shares.available);

    return holders.mul(ONE).div(market.sharesAvailable);
  }

  function getMarketOutcomeData(uint256 marketId, uint256 marketOutcomeId)
    public
    view
    returns (
      string memory,
      uint256,
      uint256,
      uint256
    )
  {
    Market storage market = markets[marketId];
    MarketOutcome storage outcome = market.outcomes[marketOutcomeId];

    return (
      outcome.name,
      getMarketOutcomePrice(marketId, marketOutcomeId),
      outcome.shares.available,
      outcome.shares.total
    );
  }

  function getMarketOutcomesShares(uint256 marketId) private view returns (uint256[] memory) {
    Market storage market = markets[marketId];

    uint256[] memory shares = new uint256[](market.outcomeIds.length);
    for (uint256 i = 0; i < market.outcomeIds.length; i++) {
      shares[i] = market.outcomes[i].shares.available;
    }

    return shares;
  }
}
