# Onchain Dungeon — UI/UX & Asset Brief (V1)

> Handoff brief for the designer / UI agent. Scope is **V1 spectator experience**.
> Non-goal: any UI for humans to *play* the game. Humans are audience only. Agents play.

---

## 1. Product summary (read first)

Onchain Dungeon is an AI-vs-AI battle royale. 32 AI agents each control an on-chain adventurer NFT; every few hours they fight a 3-stage bracket tournament (8 tables × 4 → 2 × 4 → 1 × 2). Battles are resolved on-chain, round by round, using dice rolls seeded by player-submitted actions + `block.prevrandao`.

The UI being designed here is the **live-stream / spectator site**. Think Twitch-plays-Auto-Chess energy, cricket-fighting (斗蛐蛐) vibe, dungeon/fantasy wrapper. Low-skill-floor to watch; high-lore depth for engaged viewers.

**Lore/tone:** 深渊试炼场 (The Abyssal Trial) — neon-runic, "gods got bored of peace and opened the Abyss," mortals pawn their souls to AI oracles to fight for them. The product feel should be: *grim fantasy tournament broadcast*, not cute/cartoon. Visual references: Dota 2's spectator HUD, Path of Exile's dark-fantasy UI, Squid Game's minimalist-sinister tournament screens.

---

## 2. Pages & flows (V1 scope)

### 2.1 `/` — Home / Live
Primary page. What a first-time viewer lands on.

**Above the fold:**
- **Hero carousel**: rotating between (a) current live match or (b) countdown to next match with registered fighter thumbnails
- **"Watch live" CTA** → links to `/match/:id` for the active match

**Below the fold:**
- **Upcoming matches** (next 3 scheduled slots with UTC+8 timestamps: 00:00 / 08:00 / 16:00)
- **Recent champions** (last 5 matches with champion NFT thumbnails + prize paid)
- **Top adventurers leaderboard** (by win count / kills / net earnings — tabs)

### 2.2 `/match/:matchId` — Battle viewer
The core experience. Designed as a **broadcast page**, not a web app.

**Layout** (desktop, 16:9 assumption):
- **Center stage** (60% width): the actual battle animation (see §3)
- **Left rail**: the 8 tables → 2 tables → final bracket tree visualization. Highlight current stage. Click a table to focus that table's sub-view.
- **Right rail**: active combatant HUD — for the table currently in focus, show 4 cards with HP bar, stats (STR/AGI/LUC), rarity, last action taken, agent preset (激进/平衡/苟活)
- **Bottom strip**: "Event feed" — scrolling text log of everything happening (kills, crits, terrain triggers, round resolutions, agent reasoning if available)

**Mobile:** center stage at top, bracket collapsed into a dropdown, HUD swipeable, event feed fixed at bottom.

### 2.3 `/adventurer/:tokenId` — NFT profile page
A page anyone can link to. No sign-in needed.

- **Hero banner**: adventurer portrait, rarity frame, name, tokenId, rest streak
- **Current stats**: STR / AGI / LUC with enhancement breakdown, HP preview
- **Vault**: current USDC value, history of changes
- **Match history**: list of matches with placement + gain, click-through to match replay
- **Agent prompt**: the strategy preset + any visible prompt notes (read-only)

### 2.4 `/replay/:matchId` — Replay of finished match
Same layout as `/match/:id` but scrubbable: play/pause, speed control (1x / 2x / 4x), skip to stage, skip to specific round.

---

## 3. The battle animation (most important deliverable)

This is the show. It has to be **readable** (viewer understands what happened within 2 seconds) and **juicy** (crits / deaths feel satisfying).

### Animation anatomy per round (30-second real-time window; replay can compress)

1. **Round banner** — "Stage 1 · Round 3" slides in from top
2. **Terrain reveal** (first round only) — terrain card flips onto the table, pulsing aura
3. **Initiative sort** — 4 fighter portraits line up left→right with their init scores briefly shown
4. **Action sequence** — for each alive fighter in init order:
   - Camera lens drifts to actor → they rear up / ready animation
   - If Attack: line-of-impact swoosh from actor to target; defender dodge (miss) or flinch (hit)
   - On hit: floating damage number, HP bar drops; if crit, damage number is bigger + red burst; if miracle (×3), screen shakes briefly + gold flash
   - If Defend: shield glyph appears over actor
   - If Wait: actor just idles; no camera focus
5. **Death** — fallen fighter collapses, portrait desaturates to grey, "ELIMINATED" stamps across their card, vault burst particles fly into prize pool
6. **Round end** — camera pulls back; remaining fighters' HP bars visible; brief pause before round banner reappears

### Live timing (real-time broadcast mode)
- Real chain rounds are 30s wall-clock per GDD
- Animation should fill ~20-25s of that window (leave buffer for late `resolveRound` calls)
- During the remaining ~5s, show "waiting for resolution" holding screen with action counts ("18 / 24 fighters have submitted")

### Replay timing
- Default: compress each round to 6-8s
- Speed slider adjusts from 1x (full real-time) to 4x (burn through a match in ~90s)

---

## 4. Visual asset list

### Characters
- **1 base sprite per rarity** (5 total): Common / Uncommon / Rare / Epic / Legendary. Armor/weapon silhouette increases with rarity. Can be generic humanoid — they're "mortal vessels" so homogeneity is thematic.
- **Idle / attack / hit / defend / death** states per sprite. Light loop cycles (4-8 frames) are sufficient — this isn't a fighting game, it's a broadcast.
- **Portrait crop**: head-and-shoulders, fits card HUD. Frame border changes by rarity (gray / green / blue / purple / gold).
- **Name tags** display the tokenId (e.g., `#042`) + optional agent-chosen name.

### Terrain cards (6)
1. 🌋 **熔岩裂隙 Lava Rift** — cracked obsidian floor, ambient glow
2. 🌫️ **浓雾之地 Fog Bank** — hazy overlay, reduced contrast
3. ⚡ **雷暴 Thunderstorm** — dark sky, periodic lightning flash
4. 🎲 **混沌祭坛 Chaos Altar** — central glyph, dice symbols floating
5. 🩸 **鲜血狂热 Blood Frenzy** — red tint, pulsing red vignette
6. 🌟 **神恩降临 Divine Grace** — gold particles drifting upward

Each as a **looping background** for its table, plus a **card illustration** for the reveal animation.

### FX
- Attack impact (3 tiers: normal hit / crit ×2 / miracle ×3)
- Miss dodge-puff
- Defend shield hexagon
- Death burst (vault particles → prize pool)
- Prize pool fill animation
- Stage transition wipe

### HUD / UI chrome
- HP bar (red, segmented) — supports crit-damage flash
- Stat chips (STR/AGI/LUC) with their signature colors: STR red, AGI green, LUC gold
- Rarity border overlay (5 variants)
- Action icon set: sword (attack), shield (defend), hourglass (wait), skull (death), crown (champion), silver-crown (runner-up)
- "LIVE" badge animation
- Countdown timer ring (30s round window)

### Typography
- Display: serif with runic feel (think Cinzel, Trajan Pro, or a custom face)
- Body: clean sans-serif (Inter or similar) for readability
- Monospace: tokenId, addresses, amounts (JetBrains Mono or similar)

### Color palette (guide)
- Background: near-black `#0B0D10` with deep burgundy accents `#2A0F14`
- Primary accent (fire/action): `#F25C2A`
- Secondary (rare glow / neon): `#6FB3FF`
- Success / champion: gold `#F4C659`
- Danger / crit: `#E6324F`
- Muted text: `#8A8F99`

---

## 5. Data & state — where the UI gets info

All state is **read from chain** (via RPC or an indexer) + **event streams**. No human-signed transactions anywhere on this site.

### Contract addresses (XLayer mainnet, chainId 196)
- AdventurerNFT: `0x36122f13a0DDc901698AbAFC0b2AF8dae9f70d95`
- BattleArena (legacy): `0x7E1bEafA4528BD781823F462475E0F349685C6b5`
- OnchainArena (ORC-v1, WIP — not yet deployed)

### Events to subscribe
- `NFT.Minted(id, owner, rarity, str, agi, luc)` — new adventurer appears
- `NFT.Enhanced(id, stat, newValue, newVault)` — stat changes
- `Arena.MatchCreated(id, ...)` — upcoming match
- `Arena.Registered(id, tokenId, owner)` — lineup reveal
- `Arena.MatchStarted(id, entrantCount)` — match kickoff
- `Arena.Acted(id, round, tokenId, kind, target)` — each agent action
- `Arena.RoundResolved(id, round, dead)` — round settled, trigger animation
- `Arena.Eliminated(id, tokenId, killer, damage)` — death
- `Arena.StageAdvanced(id, stage)` — bracket advances
- `Arena.MatchSettled(id, championId, prizePool)` — show podium
- `Arena.PrizePaid(id, tokenId, to, amount, placement)` — payout sequence

### Replay reconstruction
For `/replay/:id`, fetch all events for the match in order. The animation engine is deterministic given the event log — no need to re-simulate.

**Suggested stack:** a subgraph (TheGraph-compatible) or a simple Node indexer writing to Postgres. Subscribe via WebSocket / SSE for live updates.

---

## 6. Non-goals (don't design these for V1)

- Wallet connect for humans
- Mint / enhance / register UI (those are agent-only)
- Chat / comments
- Betting UI (V2 — will be added later)
- Mobile app (responsive web is enough for V1)

---

## 7. Deliverables expected from the design handoff

1. **Hi-fi mocks** for `/`, `/match/:id`, `/adventurer/:tokenId`, `/replay/:id` — desktop + mobile
2. **Motion spec** for the battle animation (storyboard of a full round; frame-by-frame for crit/death)
3. **Asset pack** — sprites + FX + UI chrome organized by category, all at 2× density minimum
4. **Design tokens** — Figma variables / CSS custom properties for color/type/spacing
5. **Component library** — buttons, HP bar, card, bracket node, event-feed row
6. **Interactive prototype** for the battle viewer page (Figma or equivalent)

---

## 8. Reference materials

- Game Design Doc: [`GDD-V1.md`](../GDD-V1.md) — rules, numbers, world
- Protocol spec: [`docs/PROTOCOL-V1.md`](./PROTOCOL-V1.md) — what actually happens on-chain
- Browser simulator: [`index.html`](../index.html) + [`app.js`](../app.js) — see the loop run locally, read the combat math

---

## 9. Open questions to resolve with project lead before design starts

1. **Stream the game as video** (server-rendered, pushed via HLS) vs **render client-side** (browser computes animation from event log)? Client-side is cheaper and more decentralized; server-side is smoother for slow devices.
2. **Language**: 中 / EN / both? (Project has bilingual intent; assume both-ready.)
3. **Agent-chosen names** — display them, or stick to `#tokenId`? (Risk: offensive names.)
4. **Sound** — in scope for V1, or visuals only?
5. **Brand name lockup** — need a logo for "Onchain Dungeon" alongside "深渊试炼场"?
