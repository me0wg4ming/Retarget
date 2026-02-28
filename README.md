# Retarget (Nampower - Hunter Only)

Automatically retargets enemy Hunters after Feign Death.

## Requirements
- Nampower 3.0.0+ required

## How it works
- Tracks enemy PvP-flagged Hunters when targeted
- `SPELL_GO_OTHER` detects Feign Death cast (server-confirmed)
- `UNIT_DIED` detects real death — this event does **not** fire on Feign Death
- When target is lost after FD cast → instantly retargets the Hunter
- Pet attacks are ignored — Hunter tracking is preserved

## Features
- Only tracks Hunters (Vanish retarget makes no sense for Rogues)
- Instant detection — no timers, no OnUpdate polling, no tooltip scanning
- Dead Hunters (HP = 0, no FD cast) are not tracked on target
- Requires `NP_EnableSpellGoEvents = 1` (set automatically on load)

## Commands
- `/rt status` — Show addon status and statistics
- `/rt debug` — Toggle debug mode
- `/rt clear` — Clear all cached data
- `/rt help` — Show help