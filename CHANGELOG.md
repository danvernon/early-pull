# Changelog

## 1.0.0

First stable release. Cleaned up diagnostic scaffolding left over from rc1's in-game debugging:

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
