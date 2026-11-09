# CRE oracles runbook

Operating notes for the Chainlink CRE oracle contracts (`contracts/oracles/`): how a sports result reaches the chain, what to do when the workflow reports a void, and the workflow-identity settings a resolver redeploy must keep. Written for ENG-3271; the resolver itself lives in `myriad-cre-workflow`.

## Deployments

| | BSC mainnet (56) | BSC testnet (97) |
|---|---|---|
| `SportsCREOracle` | `0xE5d08a4797c0Bd67e1B6B0Acb4730C12BE7A1065` | `0x640Ddd09cD2ce9137d8b17f031CfbC1242Baa60a` |
| `CryptoCREOracle` | `0xD6a00F56955Ac5AA9901B2a98E504a6D6811f2E5` | `0x197948d44B324b1191ca368073E5e373515c4a42` |
| Manager (`PredictionMarketV3ManagerCLOB`) | `0xaB5591E280fF9Bf368DB60c3b775b5C7Ba5ea3dB` | `0x1a36B32262Fd8940F555A7E7f4B4cFc022bFc61E` |
| `AdminRegistry` | `0xcAAdcdf80A88e0024642fe9cBEfF4011B7a4F653` | `0x6558F30c013668ff686842066D710B56d40c0fa8` |
| KeystoneForwarder | `0x76c9cf548b4179F8901cda1f8623568b58215E62` | `0x76c9cf548b4179F8901cda1f8623568b58215E62` |

Both `SportsCREOracle` deployments were checked against `contracts/oracles/SportsCREOracle.sol` on 2026-11-09: the runtime bytecode matches byte for byte once the two immutables (`registry`, `manager`) and the CBOR metadata trailer are masked. Re-check after any source change with `forge build` and `cast code`, the same way.

**`CryptoCREOracle` is different.** The source on `main` is the `fix/cre-oracle-slot-collision` version (10,165 bytes of runtime code); both deployments run 9,622 bytes that match neither it nor the earlier `clob-chainlink-integration` version. The deployed crypto oracle predates the data-source/interval and slot-collision changes, so treat the source here as what a redeploy would ship, not as what is live. Finding the exact deployed commit is a separate task.

## How a sports market resolves

1. **Create.** The CMS creates the market with `oracle = SportsCREOracle` and `oracleData = abi.encode(externalRef)`. The manager calls `initialize(marketId, data)`, which stores the ref as-is. The ref is **opaque to the contract**: it only has to be non-empty and unique per market outcome. Since ENG-3264 it is ref v2:

   ```
   apisports:{sport}.{fixtureId}:{1x2|ml}:{home|away|draw}
   ```

   `1x2` is soccer's 90-minute result; `ml` is the final score including overtime for the other sports. `draw` exists only for soccer and American football (NFL games can end tied). A 3-way game is three markets with three refs on the same fixture.

2. **Report.** Hourly, `myriad-sports-resolver` reads final scores from API-Sports and calls `onReport(metadata, abi.encode(string[] refs, int256[] outcomes))` through the KeystoneForwarder. Outcomes are `0` (that side won), `1` (it didn't) or `-1` (void). Results are keyed by `keccak256(ref)` and are **write-once**: a second report for the same ref is ignored, not reverted.

3. **Resolve.** `PredictionMarketV3ManagerCLOB.resolveMarket(marketId)` is permissionless. It needs the market closed (`closesAt` passed) and the oracle's `getResult` to return `0` or `1`. Run it with `scripts/resolve_clob_market.sh`, mode 1, outcome `-2` ("use oracle"), or any wallet can call it directly.

### No timing guard on `onReport`

`onReport` does not check that the market is closed, so a result can be stored before `closesAt`. That is fine for the markets we create: the CMS sets `closesAt` to kickoff + 24h and the resolver only looks a game up after kickoff + the sport's shortest game length + a grace period, so a stored result always describes a finished game. It matters if someone creates a sports market whose close is far after the game, or points a ref at the wrong fixture: whatever the workflow reports first is final for that ref.

## Void path (cancelled, abandoned, long-postponed games)

The workflow reports `-1` for cancelled or abandoned games and for games still postponed 48 hours after their original kickoff. The oracle stores it, but **`resolveMarket` reverts on a void result** (`invalid outcome`), so a voided game never resolves on its own. An operator finishes it:

1. Confirm the stored result: `cast call <SportsCREOracle> "getResult(uint256)(int256,bool)" <marketId>` returns `(-1, true)`.
2. Wait for the market to close (`adminVoidMarket` requires `block.timestamp >= closesAt`, normally kickoff + 24h). To close it sooner, a `MARKET_ADMIN_ROLE` wallet can call `adminSetClosesAt(marketId, now)` first.
3. Void it with a `RESOLUTION_ADMIN_ROLE` wallet: `scripts/resolve_clob_market.sh`, mode 1, outcome `-1`, which calls `adminVoidMarket(marketId, outcome0Payout, outcome1Payout)`. The payouts are per-token refunds in 1e18 and must sum to 1e18; 50/50 returns each holder the average price. For a 3-way event, void every child market.
4. The CMS shows the same state as "void, needs admin" (ENG-3289) and offers the void modal, which does step 3 from the UI.

If a game was reported `-1` by mistake (for example a postponement that was then played), the ref's result cannot be rewritten. Re-point the market at a fresh ref with `updateMarketOracle(marketId, SportsCREOracle, abi.encode(newRef))` from a `MARKET_ADMIN_ROLE` wallet; `initialize` will reject a market that is already initialised on this oracle, so the new ref has to go through a different oracle instance, or the market is resolved by hand with `adminResolveMarket`. In practice: resolve by hand.

A tied NBA or MLB final, an awarded or walkover soccer game, or a suspended game is **not** reported at all; the workflow logs it and an operator resolves with `adminResolveMarket` (outcome `0` or `1`) or voids as above.

## Workflow identity

`CREReceiverBase` always checks that `onReport` comes from the forwarder. The author and workflow-name checks are opt-in: each is enforced only when its expected value is non-zero.

| | mainnet | testnet |
|---|---|---|
| `getForwarder()` | `0x76c9…5E62` | `0x76c9…5E62` |
| `getExpectedAuthor()` | `0x7C0F97fb24E8712E97285C7Ba7527ed6d0eb6995` | `0x0` (not enforced) |
| `getExpectedWorkflowName()` | `0x61393038613266366430` = `"a908a2f6d0"` | `0x0` (not enforced) |
| `getExpectedWorkflowId()` | `0x0` (stored only, never enforced) | `0x0` |

The workflow name CRE puts in the report metadata is the **first 10 hex characters of `sha256(workflowName)`, as ASCII**. `a908a2f6d0` is `sha256("myriad-sports-resolver-production")[:10]`, so a resolver redeploy on mainnet must keep the workflow name `myriad-sports-resolver-production` and the same owner key, or its reports revert with `UnauthorizedWorkflowName` / `UnauthorizedAuthor`. Staging enforces neither, so `myriad-sports-resolver-staging` can be redeployed freely. To rotate, a `MARKET_ADMIN_ROLE` wallet calls `setExpectedWorkflowName(bytes10)` / `setExpectedAuthor(address)`; to compute the value: `printf '%s' "<name>" | shasum -a 256 | cut -c1-10 | xxd -p`.

## Local checks

```bash
forge test --match-path "test/*CRE*"          # SportsCREOracle, CryptoCREOracle, CREReceiverBase
forge script script/TestDeliverSportsResult.s.sol  # deliver a result by hand (signer must be the forwarder)
```

`test/SportsCREOracle.t.sol` locks the ref v2 format: the longest realistic ref (46 bytes) initialises and resolves, a 3-way event resolves each side on its own, and a report before close is accepted.
