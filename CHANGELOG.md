# Changelog

## 2.9.1

- Fixed repeated secret-number errors from Blizzard's raid-warning line-limit code during restricted raid combat.
- Banner messages now use an EarlyPull-owned display frame instead of tainting the shared `RaidWarningFrame`.

## 2.9.0

- Added World of Warcraft 12.1 (Interface 120100) compatibility metadata.
- Promoted the tested 2.9.0 release candidate to stable.

Pure cleanup release. Core.lua shrank from ~1400 lines to ~800 (about 600 lines removed) by stripping dead code left over from the pre-v2.0 architecture. No behavior change for users.

Removed:

- **Blame scoring cluster:** `DetermineBlame`, `FinalizeCandidate`, `FindPetOwner`, `GetBlameDesc`, `PrintCandidateDetails`, `IterateLogWindow` + its three iterator helpers + `binarySearchLogTime` + `AdvanceLog`. Replaced by the damage-meter API path in v2.0.
- **Boss/threat scanning:** `ScanThreat`, `addThreatScanUnit`, `ScanBoss`, `ScanAllBosses`, plus the `UNIT_THREAT_LIST_UPDATE`, `UNIT_TARGET`, `INSTANCE_ENCOUNTER_ENGAGE_UNIT`, and `COMBAT_LOG_EVENT_UNFILTERED` orphaned handlers. The event registrations had already been removed in v2.7.2; the handler bodies were dead weight.
- **Sync coordination:** `OnSync`, `SendSync`, `CreateSyncTable`, `SerializeSyncTable`, `DeserializeSyncTable`, `CompareSyncTables`, `CheckSyncTableEncounter`, `IsMySyncTable`, `GetGroupRank`, `InitSync`, plus the EarlyPull-prefix branch in `CHAT_MSG_ADDON`. The multi-user sync was for the original WA's announce-arbitration; v2.x is local-banner-only and doesn't need it.
- **Ring-buffer initialization in `Init`:** `combatLog`, `threatLog`, `targetLog`, `bossLog`, `syncLog`, `summons`, `summons2`, `unitList`, the combatLog event-filter tables — all populated to support the dead scoring path.
- **Defaults:** `syncPriority`, `criticalWindowBegin/End`, `timelinessDecayRate`, `timelinessOffset`, every `combatLog*`, `threatLog*`, `targetLog*` scoring weight, `spellBlameCutoff`, `lowCertaintyCutoff`. Settings panel never exposed these so no user-visible change. The old keys persist harmlessly in existing `EarlyPullDB` until reset.
- **Unused localized imports:** `assert`, `floor`, `max`, `wipe`, `SendChatMessage` global (we use `C_ChatInfo.SendChatMessage`), `UnitDetailedThreatSituation`, `UnitPlayerControlled`, `CombatLogGetCurrentEventInfo`, the `kSourceFlag*` and `kDestFlag*` and `kNegInfinity` constants.

Smoke test: file parses, all live function references resolved, all dead references confirmed gone.

## 2.8.2

Stable release. Code identical to v2.8.2-rc1 — promoted after verifying the v2.8.2-rc1 build captured all 16 pulls from a real Manaforge Omega raid session today (no re-pull drops, name resolution working where Midnight's API allows). Recommended version going forward.

## 2.8.2-rc1

Quick re-pulls after a wipe were being silently dropped. The v2.7.1 phase-event deduplication compares the new `ENCOUNTER_START` against the last pull's encounter ID and timestamp — if both match within 60 seconds, the new fire is treated as a duplicate. That's correct mid-encounter (Blizzard's phase-bar updates do re-fire `ENCOUNTER_START`) but wrong for a wipe-then-repull cycle. The first re-pull after a sub-60-second wipe never made it past the guard, so it produced no banner and no record. Successive pulls in a wipe-fest would all be skipped, which is exactly the "lots of unknowns then nothing" pattern a user reported.

Fix: listen to `ENCOUNTER_END` and clear `pullContext` on it. Wipes/kills both fire `ENCOUNTER_END` (with `success` set accordingly), so by the time the next `ENCOUNTER_START` arrives there's no stale context to match against — the new pull goes through normal resolution.

## 2.8.1-rc1

Strip dev-only test scaffolding that slipped into the v2.8.0-rc1 zip (same accident as v2.6.2-rc1 → v2.6.3-rc1). `SeedTestReport`, `ClearTestSessions`, and the `/earlypull test-report` / `clear-test` slash forms are local-only by design and shouldn't ship. No user-facing behavior change.

## 2.8.0-rc1

Recover usable information when the damage-meter API gives us a class but no name. Reading the actual SavedVariables of a Manaforge Omega raid showed ~62% of pulls had `pullerClass` set (`WARRIOR`, `MAGE`, `DEMONHUNTER`, ...) but no `pullerName` — Midnight's restricted state passes through class info while suppressing names.

Previously all of those collapsed into a single `[Unknown]` row in the leaderboard with no class information. Now:

- **Banner & chat** render `"[Unknown WARRIOR]"` colored in the warrior class color when the class is known but the name isn't. Still distinguishable as not a real player (the brackets give it away) but the raid at least sees what *kind* of player pulled.
- **Leaderboard** aggregates these by class instead of name. So three unknown warriors and two unknown mages produce two rows: `[Unknown WARRIOR]: 3` and `[Unknown MAGE]: 2`, not one mega-row of `[Unknown]: 5`.
- Pulls with genuinely no name *and* no class still collapse to plain `[Unknown]` uncolored.

## 2.7.4-rc1

The v2.7.3 hot fix had the bug it claimed to fix. A user reported the same crash firing 15859 times — bigger than before because the error pop-up actually slows the client down enough to amplify the loop.

The early-bail in `lookupRoleByName` was written as `if type(...) ~= "string" or playerName == "" or issecretvalue(playerName) then` — Lua `or` short-circuits left-to-right, so the `playerName == ""` equality check ran *before* `issecretvalue(playerName)` and threw on every secret-wrapped name. Same bug in `nameMatches`.

Split each predicate into its own `if` so the order is unambiguous: type → issecretvalue → equality. No more reliance on `or` ordering for safety.

## 2.7.3-rc1

Hot fix for a critical regression introduced in v2.7.0. A user reported `Core.lua:808: attempt to compare local 'playerName' (a secret string value)` firing **2606 times** in a single fight — once per damage event during the encounter, because the comparison threw, prevented `ctx.recorded` from being set, and so the next damage event re-entered the same path and crashed again.

The new `lookupRoleByName` helper was comparing the resolved actor name against unit names with `==` without checking for secret-wrapped strings. Both the input `playerName` and the unit names from `GetUnitName/UnitName` can be secret in restricted Midnight raid combat. Now:

- Bail at the top if `playerName` is missing, non-string, empty, or secret.
- Each unit-name comparison checks `issecretvalue` before the `==`.
- The whole scan is wrapped in `pcall` as a final safety net so any future secret-string surprise inside `UnitGroupRolesAssigned` or similar can't take down the resolver chain.

If you were on v2.7.0–v2.7.2 with a tank in your raid, you almost certainly hit this. v2.7.3 fixes it.

## 2.7.2-rc1

Stop trying to register events the v2.0 rewrite no longer uses. A user reported `ADDON_ACTION_FORBIDDEN` for `EarlyPullEventFrame:RegisterEvent()` firing 141 times — Midnight's Restricted Addons system flagged `COMBAT_LOG_EVENT_UNFILTERED` as protected, and we were still trying to register it on every load even though the damage-meter rewrite had stopped using it.

Removed from registration: `COMBAT_LOG_EVENT_UNFILTERED`, `INSTANCE_ENCOUNTER_ENGAGE_UNIT`, plus the `UNIT_THREAT_LIST_UPDATE` and `UNIT_TARGET` unit-event registrations for boss1..8. None of them feed any active code path post-v2.0. Dead handlers for these events still exist in `Core.lua` but are inert and will be cleaned up in a future pass.

## 2.7.1-rc1

Two fixes for noise and crashes during fights.

- **Crash spam in chat handler.** A user reported `Core.lua:484: attempt to index local 'text' (a secret string value...)` firing 39 times in a single fight. The `onChatMessage` handler was calling `text:match("^Boss pulled")` directly on incoming chat-message text, but in restricted Midnight raid combat that text comes back secret-wrapped and `:match()` throws. Added `type(text) == "string" and not issecretvalue(text)` guards before the string method call.
- **Duplicate banners mid-fight.** Some bosses fire `ENCOUNTER_START` multiple times per pull (phase transitions, encounter-bar updates). Each fire was resetting `pullContext` and re-running the resolution chain — fresh banner, fresh record, fresh diagnostic dumps. Now ignored: if we already have an active context for the same `encounterID` from within the last 60 seconds, the new fire is treated as a duplicate and skipped.

## 2.7.0-rc1

Tag damage-meter-resolved pullers as tanks when they're assigned the tank role, so the report's tank exclusion still works when boss-target fails.

The boss-target resolver tags `isTank=true` on actors it returns (because the boss is targeting them = they have aggro = they're functionally the tank). The damage-meter resolver had no way to know — it gave us a name and class but no role. So when a tank's pull was resolved through the fallback path (which is most pulls in restricted Midnight raid combat), they ended up in the report leaderboard as a non-tank early pull.

New helper `lookupRoleByName(playerName)` scans the raid/party roster for a matching name and returns `UnitGroupRolesAssigned` for them. The damage-meter resolver calls it on every selection — if the resolved player is assigned `TANK`, `bestActor.isTank = true`. The tank-pull message format and the leaderboard exclusion both kick in correctly from there.

Also added `isTank=...` to the `DM selection:` diagnostic output so you can verify the role lookup is working.

## 2.6.3-rc1

Strip developer-only test scaffolding (`SeedTestReport`, `ClearTestSessions`, and the `/earlypull test-report` / `clear-test` slash forms) that accidentally shipped in the v2.6.2-rc1 zip. No behavior change for users — those commands were intended to stay in the local working tree only and were never documented.

## 2.6.2-rc1

Three bug fixes after a user reported every pull resolving to `[Unknown]` and the leaderboard header reading "raid" instead of the actual instance name.

- **Names regression from v2.5.2 reverted.** v2.5.2 added an `issecretvalue` filter at write time in `RecordPull`, intending to prevent secret strings from sneaking into storage. But the WoW SavedVariables serializer normalizes secret-wrapped strings to plain text on disk anyway, so the filter was actually *preventing* names from accumulating cross-session. Reverted: names are now stored as-is. The same secret check moved to read-time in `aggregatePulls` so any in-session secrets are rendered as `[Unknown]` without crashing the leaderboard table.
- **Instance name was always "raid".** `local _, instanceName, _, _, _, _, _, instanceID = GetInstanceInfo()` was destructuring with the leading underscore in the wrong slot, capturing `instanceType` ("raid") as the name. Fixed: now correctly captures the first return as `instanceName`. Header reads e.g. `"Manaforge Omega"` instead of `"raid"`.
- **`[Unknown]` no longer rendered in someone's class color.** When the puller's name was unresolvable but the class was readable, `FormatPullerName` returned `[Unknown]` wrapped in the class color escape — visually misleading because it looked like a real player. Now if the name is missing or secret, returns plain `[Unknown]` without coloring.

Existing saved data (with nil names from v2.5.2-era pulls) won't retroactively get names. Going forward, pulls record names properly again.

## 2.6.1-rc1

Critical fix: each pull was being recorded 2-4 times. A user reported a session of 1-pulled bosses showing as 3-4 pulls each in the report.

The puller-resolution chain (`ENCOUNTER_START` immediate boss-target check → `DAMAGE_METER_COMBAT_SESSION_UPDATED` event → polling at +0.2s/+0.5s/+1.0s/...) had no shared "already done" flag. Each layer that successfully resolved called `RecordPull`, so a pull resolved at `ENCOUNTER_START` would also be re-resolved and re-recorded by the polling tick at +0.2s, and again at +0.5s, etc.

Added `ctx.recorded` as the single source of truth — every resolution path checks it before doing work and sets it after `RecordPull` runs. Pulls now record exactly once.

Pre-existing duplicates in `EarlyPullDB` are still there. To clean up, click **Clear** in the report window or run `/earlypull reset` and `/reload`.

## 2.6.0-rc1

Report restructured to mirror how Details! shows segments — current raid only, broken down by boss.

- **Scope:** the leaderboard now shows only the current session (or the most recent one if you're not in a raid). Previously it aggregated across every saved session — pugs, old raid nights, ex-teammates — which made it noisy.
- **Per-boss segments:** within the current session, the report now contains an *Overall* leaderboard at the top followed by a sub-leaderboard per boss encounter, in the order they were first pulled. Same raid night, separated by fight, like Details' segment list.
- **Header shows the instance:** `"EarlyPull Pull Report — Manaforge Omega — 12 non-tank pulls"`.
- All historical data is still retained in `EarlyPullDB.sessions` — only the *display* is scoped. Nothing is deleted.

If a recently-pulled player is missing from the leaderboard (e.g. someone who appeared in a banner but doesn't show up in the report), they were likely affected by the v2.5.1 secret-string crash that prevented their name from being recorded properly — fixed in v2.5.2 onward.

## 2.5.2-rc1

Critical fix for an in-raid crash spam reported by a user (`Core.lua:807: attempt to compare local 'name' (a secret string value, while execution tainted by 'EarlyPull')`). The error fired ~4000 times per encounter when the boss-target `UnitName()` returned a secret-wrapped string.

- `GetPullerFromBossTarget` reordered its `if` so `issecretvalue(name)` runs *before* the `name ~= UNKNOWN` comparison. Lua short-circuits left-to-right, and comparing a secret string to a regular string throws — the secrecy check has to come first.
- Also fixed a subtle precedence bug in the same function: `local name, realm = (exists and UnitName(unit)) or nil, nil` was always assigning `nil` to `realm` because of operator precedence. Replaced with an explicit `if exists then ... end` block so `realm` actually gets the second return from `UnitName`.
- `RecordPull` now strips secret strings from `actor.name` and `actor.classFilename` before storing, so old records can't blow up later when they're aggregated into the leaderboard.
- `FormatPullerName` does the same secrecy filter on the input name before passing it to `format()`.

## 2.5.1-rc1

Drop the per-session detail block from the report window. The window now shows just the leaderboard — same output as the *Report to Raid* button posts to chat. The session breakdown was noisy and didn't convey anything the leaderboard didn't already.

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
