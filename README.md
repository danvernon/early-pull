# EarlyPull

A small World of Warcraft Midnight (Interface 120001+) addon that calls out who pulled a boss and how early or late it was. Built as a standalone replacement for the [Early Pull WeakAura](https://wago.io/V4JIxqNQ4), since Midnight's Restricted Addons system silently disables `COMBAT_LOG_EVENT_UNFILTERED` inside raid encounters and the WA stopped working as a result.

## What you get

- **Banner at engage**: a center-screen raid-warning-style notification with timing and (when resolvable) the puller's name. Examples:
  - `"Boss pulled by <Tank>."` (tank pulls — no early flag, since tanks are supposed to pull)
  - `"Boss pulled 0.42 seconds early by <Name>."`
  - `"Boss pulled on time by <Name>."`
  - `"Boss pulled 0.65 seconds late by <Name>."`
  - `"Boss pulled by <Name>."` (no countdown was active, or pull was outside the configured timing window)
- **Pull history**: every announced pull is recorded into a session bucket (one per raid night per instance). Open the report window with `/earlypull stats` to see a per-puller leaderboard and chronological list, plus buttons to post the report to RAID or PARTY chat.

## Install

- **CurseForge**: search for "EarlyPull" in the CurseForge app, or download from the [project page](https://www.curseforge.com/wow/addons/early-pull).
- **Manual**: grab the latest release zip from [GitHub Releases](https://github.com/danvernon/early-pull/releases) and unzip into `World of Warcraft\_retail_\Interface\AddOns\` so you end up with `...\AddOns\EarlyPull\`.

Reload your UI / restart WoW. There's no in-world setup; the addon just listens for raid encounters.

## How puller attribution works

Midnight blocks the traditional combat-log path inside raid encounters, so EarlyPull resolves the puller from three layered sources, whichever lands first:

1. **Boss target** (`boss1target` … `boss8target`) — whichever player the boss is currently targeting. Most accurate for tank pulls and used as the *isTank* signal that exempts tanks from the early flag.
2. **`DAMAGE_METER_COMBAT_SESSION_UPDATED`** — fires per damage event server-side; the first fire after `ENCOUNTER_START` snapshots the active damage-meter session.
3. **Polling** — `C_DamageMeter.GetCombatSessionFromType(...)` is queried at `+0.2s, +0.5s, +1.0s, +2.0s, +3.5s, +5.0s, +7.0s` after engage. The actor with the highest damage so far is picked. Damage values are secret-wrapped by Midnight in restricted state, so comparisons are wrapped in `pcall` and the addon falls back to the first actor in the list when comparisons can't be made.

If none of those resolve a puller within seven seconds, the banner fires anyway with `"by [Unknown]"` so the timing info isn't lost.

## Slash commands

- `/earlypull` or `/ep` — open the settings panel
- `/earlypull test` — simulate a banner without needing a raid encounter
- `/earlypull stats` (alias: `report`) — open the pull-history report window
- `/earlypull report-raid` / `report-party` — post the current report to chat (out of combat only)
- `/earlypull stats-print` — print the report to local chat
- `/earlypull details` — print the last pull's diagnostic info
- `/earlypull reset` — wipe SavedVariables (requires `/reload`)

## Settings

Open via `/earlypull` or Game Menu → Options → AddOns → EarlyPull.

- **Early / On-Time / Late / Untimed Pull** — how each timing class is displayed: **Banner** (center-screen, default), **Chat** (local chat line), or **None**.
- **Pull Time Diff Decimals** — how many decimals in the seconds value.
- **On-Time Window (seconds)** — ± this many seconds is considered on-time. Default `0.25s`.
- **Max Pull Time Diff (seconds)** — if the actual pull is further off than this, the pull is classified as *untimed* instead of early/late.
- **Auto-Print Details** — verbose diagnostic output (boss-target scan, damage-meter session contents, selection results). Off by default; useful for troubleshooting.

## Limitations on Midnight

- **Display is local-only.** Midnight blocks addon-initiated chat inside restricted combat, so EarlyPull doesn't broadcast — each user running the addon sees their own banner. Use the report window's *Report to Raid* button between pulls to share session stats.
- **Puller attribution can be approximate.** If `boss1target` isn't populated at engage and the damage-meter session has multiple actors, the highest-damage heuristic biases toward burst-DPS classes (Evokers, Mages, Warlocks). Tank pulls resolved via boss target are reliable.
- **Raid scope.** The detection logic only fires when `IsInInstance()` returns `"raid"`. Dungeons, scenarios, world bosses, and timewalking don't trigger it. `/earlypull test` works anywhere for smoke-testing the banner display.

## Credits

Original "Early Pull" WeakAura — pull-detection concept and timing logic come from there. The Midnight port re-implements blame attribution from scratch on the new `C_DamageMeter` API since the WA's CLEU+threat scoring no longer functions in restricted state.

## License

[MIT](LICENSE).
