# EarlyPull

Announces who pulled the boss and how early/late relative to the DBM/Blizzard pull timer.

Ported from the "Early Pull" WeakAura (https://wago.io/V4JIxqNQ4) to a standalone addon for Midnight (Interface 120001+).

## Install

1. Unzip `EarlyPull-1.0.0-rc1.zip` into your `World of Warcraft\_retail_\Interface\AddOns\` folder. You should end up with `...\AddOns\EarlyPull\` containing `EarlyPull.toc`, `Core.lua`, `Options.lua`.
2. At the character-select screen, click **AddOns** and make sure **EarlyPull** is enabled.
3. Log in. You'll see no UI; the addon just listens for pulls.

## Usage

When someone in your raid triggers a Blizzard pull countdown (via `/readycheck` or DBM/BigWigs pull timer) and the encounter then starts, EarlyPull classifies the pull and announces the result:

- *"Boss pulled 2.15 seconds early by <Name> <Spell>."*
- *"Boss pulled on time by <Name> <Spell>."*
- *"Boss pulled 0.80 seconds late by <Name>."*
- *"Boss pulled by <Name>."* (no countdown / outside the timing window)

It scores combat-log events, boss threat tables, and boss targeting in a short window around the pull to identify the most likely culprit. Pet pulls attribute to the pet's owner.

### Slash commands

- `/earlypull` or `/ep` — open the settings panel
- `/earlypull details` — print the last pull's blame breakdown
- `/earlypull debug` — toggle verbose debug output
- `/earlypull test` — print current state (group, channel, sync)
- `/earlypull reset` — wipe SavedVariables (requires `/reload`)

### Settings

Open via `/earlypull` or Game Menu → Options → AddOns → EarlyPull.

- **Early / On-Time / Late / Untimed Pull** — announce channel: Say, Group, Print, or None. Default is **Group** (RAID or PARTY chat). Say is often filtered out of chat displays in instances — prefer Group.
- **Pull Time Diff Decimals** — how many decimals in the seconds value.
- **On-Time Window (seconds)** — ± this much from the timer is considered "on time".
- **Max Pull Time Diff (seconds)** — if the actual pull is more than this far from the timer, the pull is treated as untimed.
- **Sync Priority** — when multiple players have EarlyPull, only the highest-priority one announces. Low / Normal / High / Isolated (disables sync).
- **Auto-Print Details** — print blame scores to local chat after every pull.

## Known limitations on Midnight (12.0+)

- Blame attribution falls back to character name when player GUIDs come back as opaque "secret" values. The announcement still identifies the right player but may omit the spell link in edge cases.
- `Say` chat from addons appears to be hidden from the sender's own chat tab in many Midnight instances. Group/RAID chat is recommended.

## Credits

Original "Early Pull" WeakAura by its wago.io author. This is a port, not a new work — all scoring heuristics and pull-detection logic come from the WA.
