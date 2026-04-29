# Changelog

## 2.5.0-rc1

Reformat the report to look like Details!'s damage report — Details-style ranked leaderboard front and center, sessions below.

- New `BuildLeaderboard()` function aggregates every non-tank pull across all stored sessions and renders a most-to-least ranked list:
  ```
  EarlyPull Pull Report — 12 non-tank pulls (5 tank pulls hidden)
   1. Stoley-TarrenMill   3   25.0%  (3 early)
   2. Treaderzwl-Kazzak   2   16.7%  (1 early, 1 late)
   3. [Unknown]           2   16.7%  (1 early, 1 untimed)
   4. Zheenevo            1    8.3%  (1 early)
   ...
  ```
- The in-game window leads with the leaderboard, then shows the per-session breakdown below for users who want to dig in.
- The **Report to Raid** / **Report to Party** buttons now post only the leaderboard — concise, ranked, no per-session noise. Drops chat output from ~30 lines per session to ~10 total.
- Names are padded to align the count and percentage columns regardless of name length.

## 2.4.0-rc1

The report window and chat report no longer call out tanks. Tank pulls (resolved via the boss-target signal) are still recorded in storage with `pullerIsTank=true`, but the per-puller leaderboard and per-pull list filter them out. The header notes how many tank pulls were hidden so the data isn't completely invisible.

- `RecordPull(ctx, actor)` now stores `pullerIsTank` on each record.
- `Report.BuildReport` filters tank pulls before building the leaderboard. Session header reads e.g. `"Session 1: Manaforge Omega @ 21:05..23:14 (8 non-tank pulls, 4 tank pulls hidden)"`.
- Top-line summary updated similarly: `"3 sessions, 22 non-tank pulls (11 tank pulls hidden)"`.

Existing pulls in saved history don't have the `pullerIsTank` flag, so they default to false and stay visible. Going forward, only newly recorded pulls get the tank exemption.

## 2.3.0-rc1

Tighter rules for what counts as an "early" pull, so the addon stops shaming people for noise.

- Default `pullOnTimeWindow` raised from `0.005s` to `0.25s`. Anything within a quarter-second of the countdown end is now classified as on-time, not early or late. The slider in the settings panel reflects the new default.
- Tank pulls no longer get the early-flag treatment. If the puller is the unit the boss is currently targeting (i.e. the tank by definition), the message is just `"Boss pulled by <Tank>."` regardless of how early it was — tanks are supposed to pull. Late pulls and on-time pulls keep their normal text for everyone.
- Added `EarlyPull:BuildPullMessage(ctx, actor)` as the single source of truth for the announce string; the boss-target / damage-meter / polling paths all funnel through it.

Note: existing users keep their saved `pullOnTimeWindow` value. To pick up the new 0.25s default, run `/earlypull reset` and `/reload`.

## 2.2.0-rc1

Pulls are now grouped into raid sessions instead of one flat list. A session is a contiguous run of pulls inside the same raid instance with no >30 minute gap; entering a different raid or returning after a long break starts a new one.

- Storage moved from `EarlyPullDB.pulls` to `EarlyPullDB.sessions`. Each session record carries `instanceName`, `instanceID`, `startTs`, `lastPullTs`, and its own `pulls[]` array.
- The pre-2.2 flat history is migrated automatically into a single "Imported (pre-2.2)" session on first load.
- Report window now shows newest session first, with header `=== Session N: <Instance> @ HH:MM..HH:MM (X pulls) ===`, per-session puller leaderboard, and per-session chronological pull list.
- 50-session retention cap (oldest sessions drop off when exceeded).

## 2.1.0-rc1

Adds session-wide pull tracking and a report UI.

- Each pull (boss, timing, puller name and class) is recorded to `EarlyPullDB.pulls` and persists across reloads/relogs. Capped at 500 most recent entries.
- New report window — open with `/earlypull stats` or `/earlypull report`. Shows:
  - Per-puller leaderboard: count of pulls broken down into early / on time / late / untimed.
  - Chronological list of every recorded pull with timestamp.
  - Buttons: **Report to Raid**, **Report to Party**, **Refresh**, **Clear**, **Close**.
  - The text area is selectable so users can copy the report out manually.
- New slash forms: `/earlypull report-raid`, `/earlypull report-party`, `/earlypull stats-print` (prints the report locally without opening the window).
- Posting to chat respects combat lockdown — the addon refuses to post and prints a notice instead. Out-of-combat posting works normally.

## 2.0.0-rc1

Major rewrite for Midnight 12.0+. Replaces the WeakAura's CLEU+threat scoring with the new Blizzard damage-meter API, since `COMBAT_LOG_EVENT_UNFILTERED` is silently disabled inside raid encounters (Midnight's Restricted Addons system).

- **Banner at engage** with full message: `"Boss pulled X seconds early by <Name>."` Resolves the puller name through three layered sources, whichever lands first:
  1. **Boss target** (`boss1target`) — the tank with current aggro, most accurate signal for who pulled.
  2. **`DAMAGE_METER_COMBAT_SESSION_UPDATED`** event — fires per damage event server-side; first fire after `ENCOUNTER_START` snapshots the session.
  3. **Polling** at +0.2s, +0.5s, +1.0s, +2.0s, +3.5s, +5.0s, +7.0s. If all polls fail, banner fires with `"by [Unknown]"`.
- Removed: CLEU registration, threat-table scanning, boss-target ring buffer, sync coordination across multiple addon instances, all the legacy WA scoring heuristics.
- Damage values from `C_DamageMeter` are secret-wrapped numbers in restricted state — comparisons via `>` throw silently. The selection wraps each comparison in `pcall` and falls back to `combatSources[1]` when comparisons can't be made.
- `Auto-Print Details` checkbox now exposes verbose diagnostic output (`BT scan:`, `DM poll:`, `DM selection:`) for debugging future Midnight-API quirks. Disabled by default.

Scope unchanged: only fires inside `instanceType == "raid"`. `/earlypull test` still simulates a banner outside any encounter.

## 1.0.0-rc4

Scope detection to raid instances and harden the combat log filter:

- `ENCOUNTER_START` now bails out unless `IsInInstance()` returns `"raid"`. Dungeons, scenarios, timewalking, and world bosses no longer trigger a banner, since they often don't populate boss units or emit events inside the narrow scoring window and produced misleading "unknown cause" blame results.
- Added `issecretvalue` guards on `sourceFlags` and `destFlags` in the combat log handler. If Midnight ever marks flag fields secret for a player-controlled event, the bitwise filter would have errored silently and dropped the entry; now it just skips cleanly.
- `/earlypull test` still works in any context — bypasses the raid gate and renders the banner directly so you can smoke-test the display without being in a raid.

## 1.0.0-rc3

Switched from chat broadcast to local-only notification:

- Pull announcements now display as a **Banner** (center-screen raid-warning style, via `RaidNotice_AddMessage`) or as a local **Chat** line. No more `SAY` / `RAID` / `PARTY` broadcasts — Midnight's addon-chat restrictions and SAY display filtering made those unreliable anyway.
- Each user who runs EarlyPull gets their own banner. Nothing is broadcast to other raid members.
- Removed the sync-coordination scaffolding (Sync Priority setting, `CHAT_MSG_ADDON` for the EarlyPull prefix, multi-attempt `EARLY_PULL_AFTER_PULL` loop). Not needed when display is local.
- Added `/earlypull test` to simulate a pull banner without needing a raid encounter — useful for verifying the addon installed correctly.
- Updated options panel: announce dropdowns now show Banner / Chat / None. Sync Priority slider removed.

## 1.0.0-rc2

Production-ready candidate. Cleaned up diagnostic scaffolding left over from rc1's in-game debugging:

- Removed `self:Debug(...)` helper and all call sites.
- Removed `pcall` wrappers around `C_Timer.After` callbacks and the "ERROR in EARLY_PULL_AFTER_PULL" fallback prints.
- Removed `/earlypull debug` and `/earlypull test` slash commands.
- Simplified `Announce` back to a direct `SendChatMessage` (via `C_ChatInfo.SendChatMessage` when available) without the debug-only pcall.

All Midnight-compatibility fixes from rc1 are preserved:

- Secret-value guards via `issecretvalue` on GUIDs, `threatValue`, `encounterID`, and `spellID`.
- `pcall` around `UnitGUID` (compound unit tokens throw) and `UnitDetailedThreatSituation`.
- Name-based candidate keys (`"name:<SourceName>"`) when source GUIDs are opaque, so blame still attributes.
- Self-logging in `SendSync` so the sync coordination loop sees the local entry even if the addon-message echo from Midnight doesn't arrive.
- Prefers `C_ChatInfo.SendChatMessage` over the legacy global.

## 1.0.0-rc1

Initial release candidate. Port of the "Early Pull" WeakAura (wago.io/V4JIxqNQ4) to a standalone addon.

- Detect pulls via `ENCOUNTER_START` and classify against `START_PLAYER_COUNTDOWN` / DBM "PT" timer.
- Score combat log, threat table, and boss target events within a narrow window to identify the puller and spell.
- Native Blizzard Settings panel with announce channel, timing window, and sync priority options.
- Native `C_ChatInfo` addon messages for sync coordination (AceComm replaced).
- Midnight (Interface 120001+) compatibility: guards secret-value GUIDs, threat values, and encounter IDs; pcall-wraps `UnitGUID` for compound unit tokens; falls back to name-based candidate keys when source GUIDs are opaque.
- Defaults to Group (RAID/PARTY) chat for announcements since Say is commonly hidden from the sender's own chat tab.
