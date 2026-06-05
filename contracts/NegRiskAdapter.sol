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
  event EventMarketForcedNo(bytes32 indexed eventId, uint256 outcomeIndex, uint256 marketId);
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

  // ─── Exchange wrap helper ────────────────────────────────────────────

  /// @notice Wrap `amount` of underlying into wcol on behalf of the exchange.
  ///         Exchange-only. The reverse uses WrappedCollateral.unwrap directly.
  function wrapForExchange(uint256 amount) external nonReentrant {
    require(msg.sender == exchange, "only exchange");
    require(amount > 0, "amount 0");
    underlying.safeTransferFrom(msg.sender, address(this), amount);
    underlying.forceApprove(address(wcol), amount);
    wcol.wrap(amount);
    IERC20(address(wcol)).safeTransfer(msg.sender, amount);
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
    require(
      manager.getMarketState(noMarketId) != IMyriadMarketManager.MarketState.resolved,
      "leg resolved"
    );
    uint256 noTokenId = conditionalTokens.getTokenId(noMarketId, Outcomes.NO);

    // Count splittable legs (i != noOutcomeIndex AND not resolved).
    // Resolved legs are treated as if they never existed — their YES would be
    // worth 0, so skipping them costs the user nothing.
    uint256 k;
    for (uint256 i = 0; i < n; i++) {
      if (i == noOutcomeIndex) continue;
      if (manager.getMarketState(evt.marketIds[i]) == IMyriadMarketManager.MarketState.resolved) continue;
      k++;
    }
    require(k > 0, "no unresolved legs");

    // Take NO(noOutcomeIndex) from caller
    conditionalTokens.safeTransferFrom(msg.sender, address(this), noTokenId, amount, "");

    // Mint wcol for splitting in the K unresolved complementary markets
    uint256 wcolToMint = k * amount;
    wcol.adapterMint(address(this), wcolToMint);
    mintedWcolPerEvent[eventId] += wcolToMint;

    // Split in each unresolved other market and send YES to caller, keep NO
    for (uint256 i = 0; i < n; i++) {
      if (i == noOutcomeIndex) continue;
      uint256 marketId = evt.marketIds[i];
      if (manager.getMarketState(marketId) == IMyriadMarketManager.MarketState.resolved) continue;

      conditionalTokens.splitPosition(marketId, amount);

      // Send YES to caller
      uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
      conditionalTokens.safeTransferFrom(address(this), msg.sender, yesTokenId, amount, "");

      // Adapter retains the NO token (backing for the minted wcol)
    }

    emit PositionsConverted(eventId, noOutcomeIndex, msg.sender, amount);
  }

  /// @notice Mint YES tokens for ALL outcomes in an event. Used by the exchange
  ///         for cross-market matching. Takes underlying from caller, wraps
  ///         to wcol internally, splits in the first market, then mints wcol
  ///         and splits in the remaining markets. All YES tokens go to
  ///         `recipient`; adapter keeps all NO tokens.
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

    // Locate the first unresolved leg — it consumes the freshly-wrapped wcol.
    // Resolved legs are skipped: YES on a resolved-NO leg is worth 0, so
    // the recipient losing that share has no economic effect.
    uint256 firstUnresolved = type(uint256).max;
    for (uint256 i = 0; i < n; i++) {
      if (manager.getMarketState(evt.marketIds[i]) != IMyriadMarketManager.MarketState.resolved) {
        firstUnresolved = i;
        break;
      }
    }
    require(firstUnresolved != type(uint256).max, "no unresolved legs");

    // Pull underlying from the exchange and wrap for the first unresolved market's split.
    underlying.safeTransferFrom(msg.sender, address(this), amount);
    underlying.forceApprove(address(wcol), amount);
    wcol.wrap(amount);

    // Split first unresolved market using the freshly-wrapped wcol
    {
      uint256 marketId = evt.marketIds[firstUnresolved];
      conditionalTokens.splitPosition(marketId, amount);
      uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
      conditionalTokens.safeTransferFrom(address(this), recipient, yesTokenId, amount, "");
    }

    // Count remaining unresolved legs after firstUnresolved
    uint256 remaining;
    for (uint256 i = firstUnresolved + 1; i < n; i++) {
      if (manager.getMarketState(evt.marketIds[i]) != IMyriadMarketManager.MarketState.resolved) {
        remaining++;
      }
    }

    // Mint wcol for the remaining unresolved markets and split each
    if (remaining > 0) {
      uint256 wcolToMint = remaining * amount;
      wcol.adapterMint(address(this), wcolToMint);
      mintedWcolPerEvent[eventId] += wcolToMint;

      for (uint256 i = firstUnresolved + 1; i < n; i++) {
        uint256 marketId = evt.marketIds[i];
        if (manager.getMarketState(marketId) == IMyriadMarketManager.MarketState.resolved) continue;
        conditionalTokens.splitPosition(marketId, amount);
        uint256 yesTokenId = conditionalTokens.getTokenId(marketId, Outcomes.YES);
        conditionalTokens.safeTransferFrom(address(this), recipient, yesTokenId, amount, "");
      }
    }

    emit AllYesTokensMinted(eventId, recipient, amount);
  }

  // ─── Resolution ──────────────────────────────────────────────────────

  /// @notice Permissionless per-market resolution for a neg-risk event. Routes
  ///         through `manager.resolveMarket`. When the resolved outcome is YES,
  ///         atomically forces every other constituent market to NO and finalizes
  ///         the event — encoding mutual exclusivity forward so a dual-YES race
  ///         is structurally impossible.
  function resolveEventMarket(bytes32 eventId, uint256 outcomeIndex) external nonReentrant returns (int256) {
    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(!evt.resolved, "already resolved");
    require(outcomeIndex < evt.outcomeCount, "bad index");

    uint256 marketId = evt.marketIds[outcomeIndex];
    int256 outcome = manager.resolveMarket(marketId);
    if (outcome == int256(Outcomes.YES)) {
      _forceOthersNoAndFinalize(evt, eventId, outcomeIndex);
    }
    return outcome;
  }

  /// @notice Admin per-market override for a neg-risk event. Routes through
  ///         `manager.adminResolveMarket`. When the supplied outcome is YES,
  ///         atomically forces every other constituent market to NO and finalizes
  ///         the event (same forward invariant as `resolveEventMarket`).
  function adminResolveEventMarket(
    bytes32 eventId,
    uint256 outcomeIndex,
    int256 outcome
  ) external nonReentrant returns (int256) {
    require(registry.hasRole(registry.RESOLUTION_ADMIN_ROLE(), msg.sender), "not resolution admin");

    Event storage evt = _events[eventId];
    require(evt.outcomeCount > 0, "event !exist");
    require(!evt.resolved, "already resolved");
    require(outcomeIndex < evt.outcomeCount, "bad index");

    uint256 marketId = evt.marketIds[outcomeIndex];
    int256 result = manager.adminResolveMarket(marketId, outcome);
    if (outcome == int256(Outcomes.YES)) {
      _forceOthersNoAndFinalize(evt, eventId, outcomeIndex);
    }
    return result;
  }

  /// @dev Force every constituent market other than `winnerIndex` to NO and
  ///      finalize the event. Already-resolved markets are skipped (with a
  ///      defense-in-depth check that they aren't YES — should be unreachable
  ///      because the forward invariant prevents two YES from co-existing).
  function _forceOthersNoAndFinalize(Event storage evt, bytes32 eventId, uint256 winnerIndex) internal {
    uint256 n = evt.marketIds.length;
    for (uint256 i = 0; i < n; i++) {
      if (i == winnerIndex) continue;
      uint256 mid = evt.marketIds[i];
      if (manager.getMarketState(mid) == IMyriadMarketManager.MarketState.resolved) {
        require(manager.getMarketResolvedOutcome(mid) != int256(Outcomes.YES), "event already has YES winner");
        continue;
      }
      manager.adminResolveMarket(mid, int256(Outcomes.NO));
      emit EventMarketForcedNo(eventId, i, mid);
    }
    evt.resolved = true;
    evt.winningIndex = int256(winnerIndex);
    emit EventResolved(eventId, int256(winnerIndex));
  }

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

  /// @notice Void the event with per-market YES payouts. Each unresolved market is
  ///         voided via adminVoidMarket; NO payout is derived as 1e18 - yesPayout.
  ///         Already-resolved legs (early NO via adminResolveEventMarket) are
  ///         skipped and keep their existing resolution — their yesPayouts entry
  ///         MUST be 0 to acknowledge the leg is not being voided.
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

    uint256 totalYesPayout;
    for (uint256 i = 0; i < n; i++) {
      require(yesPayouts[i] <= 1e18, "yes payout > 1e18");
      if (manager.getMarketState(evt.marketIds[i]) == IMyriadMarketManager.MarketState.resolved) {
        // Already-NO-resolved legs (YES-resolved would have finalized the event
        // via _forceOthersNoAndFinalize, so we cannot be here) keep their NO
        // outcome — caller must pass 0 to acknowledge they are not being voided.
        require(yesPayouts[i] == 0, "resolved leg payout != 0");
      }
      totalYesPayout += yesPayouts[i];
    }

    // Event-level solvency invariant:
    // a full YES basket across named outcomes can never redeem more than 1 unit.
    require(totalYesPayout <= 1e18, "event payouts overallocated");

    evt.resolved = true;
    evt.winningIndex = -2;

    for (uint256 i = 0; i < n; i++) {
      if (manager.getMarketState(evt.marketIds[i]) == IMyriadMarketManager.MarketState.resolved) continue;
      manager.adminVoidMarket(evt.marketIds[i], yesPayouts[i], 1e18 - yesPayouts[i]);
    }

    emit EventVoided(eventId, yesPayouts);
  }

  function redeemNOPositions(bytes32 eventId) external nonReentrant {
    require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), msg.sender), "not admin");
    Event storage evt = _events[eventId];
    require(evt.resolved, "not resolved");
    require(!noPositionsRedeemed[eventId], "already redeemed");

    uint256 n = evt.outcomeCount;
    uint256 wcolBefore = IERC20(address(wcol)).balanceOf(address(this));

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

    uint256 minted = mintedWcolPerEvent[eventId];

    // Never silently socialize bad debt.
    require(wcolRecovered >= minted, "insolvent event payouts");

    if (minted > 0) {
      wcol.adapterBurn(address(this), minted);
    }

    mintedWcolPerEvent[eventId] = 0;
    noPositionsRedeemed[eventId] = true;

    uint256 excess = wcolRecovered - minted;
    if (excess > 0) {
      wcol.unwrap(excess);
      underlying.safeTransfer(treasury, excess);
    }

    emit NOPositionsRedeemed(eventId, wcolRecovered, minted, excess);
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

  /// @notice Number of constituent markets that are NOT yet resolved.
  ///         Early-resolved legs are excluded — multi-leg paths treat them
  ///         as if they never existed.
  function getUnresolvedOutcomeCount(bytes32 eventId) external view returns (uint256) {
    Event storage evt = _events[eventId];
    uint256 n = evt.outcomeCount;
    uint256 count;
    for (uint256 i = 0; i < n; i++) {
      if (manager.getMarketState(evt.marketIds[i]) != IMyriadMarketManager.MarketState.resolved) {
        count++;
      }
    }
    return count;
  }

  function isEventResolved(bytes32 eventId) external view returns (bool) {
    return _events[eventId].resolved;
  }
}
