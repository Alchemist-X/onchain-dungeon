# Unchain Round-Clock Protocol (URC-v1)

> The on-chain battle protocol replacing `BattleArena.settle()`.
> Design goal: **no trusted operator**; all fights decided by on-chain dice rolls from actions submitted by each player's agent within a fixed time window.

---

## TL;DR

- A match progresses in **rounds of 30 seconds each**.
- Every living combatant's agent must submit **one action tx** during each round's window.
- After the window closes, anyone calls `resolveRound(matchId)`, which applies every action and rolls dice using on-chain entropy.
- Dead tokens get slain (NFT burned, vault 90% to prize pool, 10% destroyed).
- When only 1 fighter is alive in the final table → match is finalized, prizes pay out per the GDD split (50 / 20 / 10×2 / 2.5×4).

---

## Phases

```
Registration ──► Locked ──► Running ──► Settled
```

| Phase | What happens | Duration |
|---|---|---|
| `Registration` | Players call `register(matchId, tokenId)` to join | until `registrationEnd` (operator-set) |
| `Locked` | No more changes, no stat enhancement (per GDD §6.3) | 1 hour — hard-coded, adjustable via constant |
| `Running` | Combat rounds tick | until 1 fighter remains in final table |
| `Settled` | Prizes distributed, NFT slays processed | terminal |

---

## Round-Clock mechanics

Each round has a **30-second window**. Every living combatant can submit an action during this window.

### Action tx

```solidity
function act(
    uint256 matchId,
    uint256 tokenId,
    ActionKind kind,      // Attack | Defend | Wait
    uint256 target        // tokenId of attack target; 0 for Defend/Wait
) external;
```

- Signer must own `tokenId`.
- Token must be alive in this match.
- One action per tokenId per round — second call reverts.
- If a player doesn't submit → treated as `Wait` on resolve (they lose the turn, no punishment beyond that).

### Resolve

```solidity
function resolveRound(uint256 matchId) external;
```

- Callable by **anyone** after `roundStart + 30s`.
- Iterates all living combatants in AGI+D20 initiative order (seeded from match seed + round + prevrandao).
- Applies each action; rolls attack/damage/crit per GDD §3.3.6.
- Updates per-match HP ledger, marks deaths, calls `NFT.slay()` for dead tokens.
- Advances `currentRound++`, opens next 30s window.
- If exactly 1 alive in the final table → calls `_finalize()`.

### Default "Wait" behavior

No submission = Wait. This is intentional:
- Respects agent autonomy; chain doesn't guess what you wanted.
- A sleeping/offline agent simply loses turns — they still have HP and can be attacked.
- Punishment for going idle = losing rounds' worth of damage potential.

---

## Randomness

Same scheme as GDD §6.1 (updated):

1. At `createMatch`, operator commits `seedHash = keccak(seed)`.
2. At `startMatch` (after registration ends + lock), `seed` is revealed. The contract stores it.
3. Per-roll entropy:
   ```
   rand(matchId, round, actorId, rollIndex) =
     keccak256(seed, matchId, round, actorId, rollIndex, block.prevrandao)
   ```
4. `block.prevrandao` is evaluated **at the time of `resolveRound`**, so the seed alone can't be used to pre-compute outcomes.

Why this is safe enough for V1:
- Operator can't manipulate `prevrandao` (that's the validator's lever).
- Validator can manipulate `prevrandao` but **doesn't know** `seed` in advance (committed before their block).
- Seed commit + prevrandao = neither party alone can control the roll.

---

## Tournament bracket

Per GDD §3.3.5, the 32-person layout is preserved:

```
Stage 0 (Quarterfinal):  8 tables × 4 fighters  →  8 advancers
Stage 1 (Semifinal):     2 tables × 4 fighters  →  2 finalists
Stage 2 (Final):         1 table × 2 fighters   →  1 champion
```

All tables in a stage advance rounds in lockstep on the same global clock. When every table in a stage has one survivor, the contract automatically re-brackets survivors into the next stage using the seed-derived shuffle.

### Prize distribution (unchanged from current design)

Paid at finalize, from prize pool = `basePool + Σ(slain_vault × 90%)`:

| Placement | Share |
|---|---|
| Champion | 50% |
| Runner-up (final 2nd) | 20% |
| 4 强 — 2 stage-1 runners-up (last-eliminated at each semi table) | 10% each |
| 8 强 — 4 other stage-1 losers | 2.5% each |

Kill bonuses: 5 USDC × kills from a separately-funded kill budget (same as today).

---

## State model

```solidity
enum Phase { Registration, Locked, Running, Settled, Cancelled }
enum ActionKind { Wait, Attack, Defend }
enum Stage { Quarterfinal, Semifinal, Final }

struct Action {
    ActionKind kind;
    uint256 target;
}

struct MatchState {
    Phase phase;
    Stage stage;
    bytes32 seedHash;
    bytes32 seed;
    uint64 registrationEnd;
    uint64 lockedUntil;      // set at register close
    uint64 currentRoundStart;
    uint32 currentRound;     // 0-indexed, resets at each stage
    uint256 basePool;
    uint256 killBudget;
    // Derived at startMatch:
    uint256[] entrants;      // all 32 at start
    // Per stage, per table:
    // tables[stage][tableIdx] = tokenIds at that table
}
```

Per-fighter state per match (separate maps to keep struct packing clean):
- `hp[matchId][tokenId]` — current HP
- `alive[matchId][tokenId]` — bool (false once slain)
- `kills[matchId][tokenId]` — count for bonus payout
- `damageTaken[matchId][tokenId][attackerId]` — for damage-share attribution (future use)

Per-round storage:
- `actions[matchId][round][tokenId]` — `Action` struct
- `acted[matchId][round][tokenId]` — bool, prevents double-submit

---

## Gas envelope (XLayer zero-gas, so informational only)

A worst-case `resolveRound` at Stage 0:
- 32 living combatants (round 1)
- For each: 1 initiative roll, 1 attack roll, 1 damage roll, 1 crit roll, 1 HP write
- 5 rolls × 32 = 160 keccak ops ≈ 160 × 30 = 4.8K gas
- Plus SSTOREs for HP updates: 32 × 5K = 160K gas
- Plus `NFT.slay()` external calls: up to 24 × 30K = 720K gas
- **Worst case ≈ 1M gas** per `resolveRound`. XLayer block limit is well above 10M. Comfortable.

Later rounds have fewer combatants → progressively cheaper.

---

## What this replaces

`BattleArena.settle()` with its all-in-one `Settlement` struct (champion, runnerUp, fourth/eighth, slainIds, killerIds, killCounts, restedIds) is **deprecated**. The current deployed contract at `0x7E1bEafA4528BD781823F462475E0F349685C6b5` stays live until URC-v1 is deployed; after that, it becomes read-only history.

No central operator is needed for combat decisions. The operator role is reduced to:
- Creating matches (`createMatch`)
- Funding the base prize pool and kill budget
- Can be a cron service, a DAO multisig, or a public mint-and-batch contract in a future iteration.

---

## Open questions for V1 implementation

1. **Rest-streak mechanic** — current design increments rest for tokens that are alive but didn't register. In URC-v1, should this still be tracked? (Leaning yes; call `NFT.markRested` at `startMatch` for alive tokens not in entrants.)
2. **Cancellation** — if fewer than 16 register by `registrationEnd`, `cancelMatch()` refunds base pool. Same as today.
3. **Observer node** — the live-stream site needs to replay a match. All inputs (seed, every `act`, every `resolveRound` with its prevrandao) are on-chain logs, so the replayer just rehydrates from events. No extra on-chain work needed.
