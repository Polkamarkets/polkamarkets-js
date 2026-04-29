// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import "./AdminRegistry.sol";
import "./PredictionMarketV3ManagerCLOB.sol";
import "./IMyriadMarketManager.sol";
import "./ConditionalTokens.sol";
import "./WrappedCollateral.sol";
import "./Outcomes.sol";

/// @title NegRiskAdapter
/// @notice Groups binary CLOB markets into mutually exclusive events.
///         Provides split/merge/convert operations via WrappedCollateral
///         and handles batch resolution (including the "Other wins" case
///         where no named outcome is the winner).
contract NegRiskAdapter is ReentrancyGuardTransient, ERC1155Holder {
  using SafeERC20 for IERC20;

  // ─── Types ───────────────────────────────────────────────────────────

  struct Event {
    uint256 outcomeCount;
    bool resolved;
    int256 winningIndex;   // -1 = no winner ("Other"), 0..N-1 = specific outcome
    uint256[] marketIds;
    string question;       // parent event question (e.g. "Who will win the election?")
  }

  // ─── State ───────────────────────────────────────────────────────────

  AdminRegistry public immutable registry;
  PredictionMarketV3ManagerCLOB public immutable manager;
  ConditionalTokens public immutable conditionalTokens;
  WrappedCollateral public immutable wcol;
  IERC20 public immutable underlying;
  address public treasury;
  address public exchange;

  mapping(bytes32 eventId => Event) internal _events;

  /// @dev Whether redeemNOPositions has already been called for an event.
  mapping(bytes32 eventId => bool) public noPositionsRedeemed;

  /// @dev Total wcol minted (unbacked) by the adapter during convert/mintAll
  ///      operations for each event. Tracked so we know exactly how much
  ///      to burn during resolution cleanup.
  mapping(bytes32 eventId => uint256 wcolMinted) public mintedWcolPerEvent;

  uint256 private _eventNonce;

  // ─── Events ──────────────────────────────────────────────────────────

  event EventCreated(bytes32 indexed eventId, uint256 outcomeCount, uint256[] marketIds);
  event EventResolved(bytes32 indexed eventId, int256 winningIndex);
  event EventVoided(bytes32 indexed eventId, uint256[] yesPayouts);
  event PositionsSplit(bytes32 indexed eventId, uint256 outcomeIndex, address indexed user, uint256 amount);
  event PositionsMerged(bytes32 indexed eventId, uint256 outcomeIndex, address indexed user, uint256 amount);
  event PositionsConverted(bytes32 indexed eventId, uint256 noOutcomeIndex, address indexed user, uint256 amount);
  event AllYesTokensMinted(bytes32 indexed eventId, address indexed recipient, uint256 amount);
  event NOPositionsRedeemed(bytes32 indexed eventId, uint256 wcolRecovered, uint256 wcolBurned, uint256 excessToTreasury);
  event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
  event ExchangeUpdated(address indexed oldExchange, address indexed newExchange);

  // ─── Constructor ─────────────────────────────────────────────────────

  constructor(
    AdminRegistry _registry,
    PredictionMarketV3ManagerCLOB _manager,
    ConditionalTokens _conditionalTokens,
    WrappedCollateral _wcol,
    address _treasury
  ) {
    require(address(_registry) != address(0), "registry 0");
    require(address(_manager) != address(0), "manager 0");
    require(address(_conditionalTokens) != address(0), "ct 0");
    require(address(_wcol) != address(0), "wcol 0");
    require(_treasury != address(0), "treasury 0");

    registry = _registry;
    manager = _manager;
    conditionalTokens = _conditionalTokens;
    wcol = _wcol;
    underlying = _wcol.underlying();
    treasury = _treasury;

    // Pre-approve wcol for ConditionalTokens so splitPosition works
    IERC20(address(_wcol)).forceApprove(address(_conditionalTokens), type(uint256).max);
  }

  // ─── Admin ───────────────────────────────────────────────────────────

  function setTreasury(address newTreasury) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    require(newTreasury != address(0), "treasury 0");
    address old = treasury;
    treasury = newTreasury;
    emit TreasuryUpdated(old, newTreasury);
  }

  function setExchange(address _exchange) external {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    require(_exchange != address(0), "exchange 0");
    address old = exchange;
    exchange = _exchange;
    emit ExchangeUpdated(old, _exchange);
  }

  // ─── Event lifecycle ─────────────────────────────────────────────────

  /// @notice Create a neg risk event with all binary markets in one tx.
  /// @param question The parent event question (e.g. "Who will win the election?").
  /// @param marketParams Array of CreateMarketParams, one per outcome.
  /// @return eventId The keccak256 identifier for this event.
  function createEvent(
    string calldata question,
    PredictionMarketV3ManagerCLOB.CreateMarketParams[] calldata marketParams
  ) external nonReentrant returns (bytes32 eventId) {
    require(registry.hasRole(registry.MARKET_ADMIN_ROLE(), msg.sender), "not market admin");
    require(bytes(question).length > 0, "empty question");
    require(marketParams.length >= 2, "need >= 2 outcomes");
    require(marketParams.length <= 256, "max 256 outcomes");

    uint256 closesAt = marketParams[0].closesAt;
    for (uint256 i = 1; i < marketParams.length; i++) {
      require(marketParams[i].closesAt == closesAt, "closesAt mismatch");
    }

    eventId = keccak256(abi.encodePacked(address(this), _eventNonce));
    _eventNonce++;

    require(_events[eventId].outcomeCount == 0, "event exists");

    Event storage evt = _events[eventId];
    evt.outcomeCount = marketParams.length;
    evt.winningIndex = -2; // unresolved sentinel
    evt.question = question;

    for (uint256 i = 0; i < marketParams.length; i++) {
      uint256 marketId = manager.createNegRiskMarket(
        marketParams[i],
        IERC20(address(wcol)),
        eventId,
        msg.sender
      );
      evt.marketIds.push(marketId);
    }

    emit EventCreated(eventId, marketParams.length, evt.marketIds);
  }

  // ─── Position operations ─────────────────────────────────────────────

  /// @notice Deposit underlying, wrap to wcol, split into YES + NO for one outcome.
  function splitPosition(
    bytes32 eventId,
    uint256 outcomeIndex,
    uint256 amount
  ) external nonReentrant {
    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(!evt.resolved, "event resolved");
    require(outcomeIndex < evt.outcomeCount, "bad index");
    require(amount > 0, "amount 0");

    uint256 marketId = evt.marketIds[outcomeIndex];

    // Take underlying from user, wrap to wcol
    underlying.safeTransferFrom(msg.sender, address(this), amount);
    underlying.forceApprove(address(wcol), amount);
    wcol.wrap(amount);

    // Split: adapter calls CT.splitPosition (wcol is the collateral for this market)
    conditionalTokens.splitPosition(marketId, amount);

    // Transfer YES + NO tokens to user
    uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    uint256 noTokenId = conditionalTokens.getTokenId(marketId, Outcomes.NO);
    conditionalTokens.safeTransferFrom(address(this), msg.sender, yesTokenId, amount, "");
    conditionalTokens.safeTransferFrom(address(this), msg.sender, noTokenId, amount, "");

    emit PositionsSplit(eventId, outcomeIndex, msg.sender, amount);
  }

  /// @notice Merge YES + NO for one outcome back to underlying.
  function mergePositions(
    bytes32 eventId,
    uint256 outcomeIndex,
    uint256 amount
  ) external nonReentrant {
    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(outcomeIndex < evt.outcomeCount, "bad index");
    require(amount > 0, "amount 0");

    uint256 marketId = evt.marketIds[outcomeIndex];
    uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
    uint256 noTokenId = conditionalTokens.getTokenId(marketId, Outcomes.NO);

    // Take YES + NO from user
    conditionalTokens.safeTransferFrom(msg.sender, address(this), yesTokenId, amount, "");
    conditionalTokens.safeTransferFrom(msg.sender, address(this), noTokenId, amount, "");

    // Merge: burns YES + NO, releases wcol to adapter
    conditionalTokens.mergePositions(marketId, amount);

    // Unwrap wcol -> underlying, send to user
    wcol.unwrap(amount);
    underlying.safeTransfer(msg.sender, amount);

    emit PositionsMerged(eventId, outcomeIndex, msg.sender, amount);
  }

  /// @notice Convert NO tokens for one outcome into YES tokens for all other outcomes.
  ///         The adapter mints wcol to facilitate splitting in the complementary markets.
  /// @param eventId The event identifier.
  /// @param noOutcomeIndex The outcome whose NO token the caller is giving up.
  /// @param amount Number of NO tokens to convert.
  function convertPositions(
    bytes32 eventId,
    uint256 noOutcomeIndex,
    uint256 amount
  ) external nonReentrant {
    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(!evt.resolved, "event resolved");
    require(noOutcomeIndex < evt.outcomeCount, "bad index");
    require(amount > 0, "amount 0");

    uint256 n = evt.outcomeCount;
    uint256 noMarketId = evt.marketIds[noOutcomeIndex];
    uint256 noTokenId = conditionalTokens.getTokenId(noMarketId, Outcomes.NO);

    // Take NO(noOutcomeIndex) from caller
    conditionalTokens.safeTransferFrom(msg.sender, address(this), noTokenId, amount, "");

    // Mint wcol for splitting in the other (N-1) markets
    uint256 wcolToMint = (n - 1) * amount;
    wcol.adapterMint(address(this), wcolToMint);
    mintedWcolPerEvent[eventId] += wcolToMint;

    // Split in each other market and send YES to caller, keep NO
    for (uint256 i = 0; i < n; i++) {
      if (i == noOutcomeIndex) continue;

      uint256 marketId = evt.marketIds[i];
      conditionalTokens.splitPosition(marketId, amount);

      // Send YES to caller
      uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
      conditionalTokens.safeTransferFrom(address(this), msg.sender, yesTokenId, amount, "");

      // Adapter retains the NO token (backing for the minted wcol)
    }

    emit PositionsConverted(eventId, noOutcomeIndex, msg.sender, amount);
  }

  /// @notice Mint YES tokens for ALL outcomes in an event. Used by the exchange
  ///         for cross-market matching. Takes wcol from caller, splits in the
  ///         first market, then mints wcol and splits in remaining markets.
  ///         All YES tokens go to `recipient`; adapter keeps all NO tokens.
  /// @param eventId The event identifier.
  /// @param amount Number of shares to create per outcome.
  /// @param recipient Address to receive all YES tokens (typically the exchange).
  function mintAllYesTokens(
    bytes32 eventId,
    uint256 amount,
    address recipient
  ) external nonReentrant {
    require(msg.sender == exchange, "only exchange");
    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(!evt.resolved, "event resolved");
    require(amount > 0, "amount 0");
    require(recipient != address(0), "recipient 0");

    uint256 n = evt.outcomeCount;

    // Take `amount` wcol from caller for the first market's split
    IERC20(address(wcol)).safeTransferFrom(msg.sender, address(this), amount);

    // Split first market using the caller's wcol
    {
      uint256 marketId = evt.marketIds[0];
      conditionalTokens.splitPosition(marketId, amount);
      uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
      conditionalTokens.safeTransferFrom(address(this), recipient, yesTokenId, amount, "");
    }

    // Mint wcol for the remaining (N-1) markets and split each
    if (n > 1) {
      uint256 wcolToMint = (n - 1) * amount;
      wcol.adapterMint(address(this), wcolToMint);
      mintedWcolPerEvent[eventId] += wcolToMint;

      for (uint256 i = 1; i < n; i++) {
        uint256 marketId = evt.marketIds[i];
        conditionalTokens.splitPosition(marketId, amount);
        uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
        conditionalTokens.safeTransferFrom(address(this), recipient, yesTokenId, amount, "");
      }
    }

    emit AllYesTokensMinted(eventId, recipient, amount);
  }

  // ─── Resolution ──────────────────────────────────────────────────────

  /// @notice Permissionless event resolution. Derives `winningIndex` by scanning
  ///         the constituent markets — every market must already be resolved.
  ///         A single YES across the constituents wins; all NO means "Other"
  ///         (winningIndex = -1). Multiple YES is rejected.
  function resolveEvent(bytes32 eventId) external nonReentrant {
    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(!evt.resolved, "already resolved");

    uint256 n = evt.outcomeCount;
    int256 winningIndex = -1;
    uint256 yesCount = 0;

    for (uint256 i = 0; i < n; i++) {
      uint256 mid = evt.marketIds[i];
      require(manager.getMarketState(mid) == IMyriadMarketManager.MarketState.resolved, "market !resolved");
      int256 outcome = manager.getMarketResolvedOutcome(mid);
      if (outcome == int256(Outcomes.YES)) {
        require(yesCount == 0, "multiple YES");
        winningIndex = int256(i);
        yesCount++;
      }
    }

    evt.resolved = true;
    evt.winningIndex = winningIndex;

    emit EventResolved(eventId, winningIndex);
  }

  /// @notice Admin override: caller supplies winningIndex. Resolves any unresolved
  ///         constituent markets via `manager.adminResolveMarket`. For markets
  ///         that are already resolved, asserts the existing outcome matches the
  ///         supplied winningIndex (otherwise reverts).
  function adminResolveEvent(bytes32 eventId, int256 winningIndex) external nonReentrant {
    require(registry.hasRole(registry.RESOLUTION_ADMIN_ROLE(), msg.sender), "not resolution admin");

    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(!evt.resolved, "already resolved");

    uint256 n = evt.outcomeCount;
    require(winningIndex >= -1 && winningIndex < int256(n), "bad winning index");

    evt.resolved = true;
    evt.winningIndex = winningIndex;

    for (uint256 i = 0; i < n; i++) {
      uint256 mid = evt.marketIds[i];
      int256 expected = (winningIndex >= 0 && int256(i) == winningIndex)
        ? int256(Outcomes.YES)
        : int256(Outcomes.NO);

      if (manager.getMarketState(mid) == IMyriadMarketManager.MarketState.resolved) {
        require(manager.getMarketResolvedOutcome(mid) == expected, "winningIndex conflicts with resolved market");
        continue;
      }
      manager.adminResolveMarket(mid, expected);
    }

    emit EventResolved(eventId, winningIndex);
  }

  /// @notice Void the event with per-market YES payouts. Each market is voided
  ///         via adminVoidMarket; NO payout is derived as 1e18 - yesPayout.
  /// @param eventId The event identifier.
  /// @param yesPayouts Array of YES (outcome 0) payouts, one per market, in 1e18.
  function voidEvent(
    bytes32 eventId,
    uint256[] calldata yesPayouts
  ) external nonReentrant {
    require(registry.hasRole(registry.RESOLUTION_ADMIN_ROLE(), msg.sender), "not resolution admin");

    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(!evt.resolved, "already resolved");

    uint256 n = evt.outcomeCount;
    require(yesPayouts.length == n, "length mismatch");

    evt.resolved = true;
    evt.winningIndex = -2;

    for (uint256 i = 0; i < n; i++) {
      manager.adminVoidMarket(evt.marketIds[i], yesPayouts[i], 1e18 - yesPayouts[i]);
    }

    emit EventVoided(eventId, yesPayouts);
  }

  /// @notice After resolution, redeem the adapter's held NO positions, burn
  ///         the wcol that was minted during convert/mintAll operations, and
  ///         send any excess to treasury.
  function redeemNOPositions(bytes32 eventId) external nonReentrant {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    Event storage evt = _events[eventId];
    require(evt.resolved, "not resolved");
    require(!noPositionsRedeemed[eventId], "already redeemed");

    uint256 n = evt.outcomeCount;
    uint256 wcolBefore = IERC20(address(wcol)).balanceOf(address(this));

    // Redeem NO positions from all markets where NO won
    for (uint256 i = 0; i < n; i++) {
      uint256 marketId = evt.marketIds[i];
      int256 outcome = manager.getMarketResolvedOutcome(marketId);

      uint256 noTokenId = conditionalTokens.getTokenId(marketId, Outcomes.NO);
      uint256 balance = conditionalTokens.balanceOf(address(this), noTokenId);

      if (balance == 0) continue;

      if (outcome == Outcomes.VOIDED) {
        conditionalTokens.redeemVoided(marketId);
      } else if (outcome == int256(Outcomes.NO)) {
        conditionalTokens.redeemPosition(marketId);
      }
    }

    uint256 wcolAfter = IERC20(address(wcol)).balanceOf(address(this));
    uint256 wcolRecovered = wcolAfter - wcolBefore;

    // Burn the amount we minted during converts
    uint256 minted = mintedWcolPerEvent[eventId];
    uint256 toBurn = minted < wcolRecovered ? minted : wcolRecovered;
    if (toBurn > 0) {
      wcol.adapterBurn(address(this), toBurn);
    }
    mintedWcolPerEvent[eventId] = 0;
    noPositionsRedeemed[eventId] = true;

    // Any excess is from users' original deposits — send to treasury
    uint256 excess = wcolRecovered > toBurn ? wcolRecovered - toBurn : 0;
    if (excess > 0) {
      wcol.unwrap(excess);
      underlying.safeTransfer(treasury, excess);
    }

    emit NOPositionsRedeemed(eventId, wcolRecovered, toBurn, excess);
  }

  // ─── View functions ──────────────────────────────────────────────────

  function getEvent(bytes32 eventId) external view returns (
    uint256 outcomeCount,
    bool resolved,
    int256 winningIndex,
    uint256[] memory marketIds,
    string memory question
  ) {
    Event storage evt = _events[eventId];
    return (evt.outcomeCount, evt.resolved, evt.winningIndex, evt.marketIds, evt.question);
  }

  function getEventMarkets(bytes32 eventId) external view returns (uint256[] memory) {
    return _events[eventId].marketIds;
  }

  function getEventOutcomeCount(bytes32 eventId) external view returns (uint256) {
    return _events[eventId].outcomeCount;
  }

  function isEventResolved(bytes32 eventId) external view returns (bool) {
    return _events[eventId].resolved;
  }
}
