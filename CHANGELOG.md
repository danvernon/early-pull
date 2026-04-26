# Changelog

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
