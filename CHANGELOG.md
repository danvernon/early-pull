# Changelog

## 1.0.0-rc1

Initial release candidate. Port of the "Early Pull" WeakAura (wago.io/V4JIxqNQ4) to a standalone addon.

- Detect pulls via `ENCOUNTER_START` and classify against `START_PLAYER_COUNTDOWN` / DBM "PT" timer.
- Score combat log, threat table, and boss target events within a narrow window to identify the puller and spell.
- Native Blizzard Settings panel with announce channel, timing window, and sync priority options.
- Native `C_ChatInfo` addon messages for sync coordination (AceComm replaced).
- Midnight (Interface 120001+) compatibility: guards secret-value GUIDs, threat values, and encounter IDs; pcall-wraps `UnitGUID` for compound unit tokens; falls back to name-based candidate keys when source GUIDs are opaque.
- Defaults to Group (RAID/PARTY) chat for announcements since Say is commonly hidden from the sender's own chat tab.
