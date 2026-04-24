# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A World of Warcraft Classic addon written in Lua that tracks the top 50 players racing to level 60 on each realm. Built on the **Ace3 addon framework** (AceAddon, AceDB, AceComm, AceConfig, AceGUI, AceConsole) with LibWho-2.0 and LibCompress.

## Commands

### Setup
```bash
make setup-dev    # install Lua dev tools: luacheck, busted, luacov
make libs         # download external library dependencies (cached in ./libs)
make fetch-libs   # force-fetch fresh libs via bw-release.sh
```

### Build & Release
```bash
make lint         # run luacheck on ./src
make release      # build and optionally upload release
```

### Testing
```bash
make tests                                 # run all tests with coverage
make tests INCLUDES=scan.lua               # run tests matching filename pattern
make tests INCLUDES="scan|leaderboard"     # multiple file patterns
make tests TESTS='.*binary.*'              # filter by test name (regex)
make reflex-tests                          # watch mode (requires reflex)
make reflex-tests INCLUDES=scan.lua        # watch specific file
```

Coverage report is generated automatically; view with `luacov.report.out`. Files excluded from tests (WoW API dependent): `main.lua`, `options.lua`, `scanner.lua`, `gui/*.lua`.

## Architecture

### Component Structure

All components are attached to the `TheClassicRace` global addon object. No other globals. Dependencies are passed via constructor injection. Components communicate through **EventBus** (pub/sub), which decouples them from each other.

**Data flow:**
1. `Scanner` → wraps LibWho, fires `/who` queries every N seconds
2. `Scanner` → publishes `WHO_RESULT` on EventBus
3. `Scan` → implements binary search + scan-down to find highest levels
4. `Tracker` → listens for `WHO_RESULT`, updates Leaderboard
5. `Leaderboard` → detects new players/level-ups, publishes `DING`
6. `ChatNotifier` → listens for `DING`, sends chat messages
7. `StatusFrame` → listens for `REFRESH_GUI`, redraws UI
8. `Network` → bridges AceComm ↔ EventBus for cross-player sync
9. `Sync` → on login, requests leaderboard sync via Network

### Database Layout (AceDB, factionrealm scope)
```lua
TheClassicRace_DB.factionrealm = {
  leaderboard = {
    [0]    = { minLevel, highestLevel, players[] },  -- global (all classes)
    [1..12] = { ... }                                 -- per-class
  }
}
```

### Object-Oriented Pattern
```lua
local Component = {}
Component.__index = Component
TheClassicRace.Component = Component
setmetatable(Component, { __call = function(cls, ...) return cls.new(...) end })
function Component.new(...)
  local self = setmetatable({}, Component)
  return self
end
```

### Network Serialization
Player batches use a compact custom format: `level(2 chars) + classIndex + playerName + dingedAt` with offset encoding to minimize AceComm traffic. LibCompress is applied before transmission.

### Key Conventions
- Player identity format: `"Name-Realm"` (e.g. `"Nubone-NubVille"`)
- Class indices: 1–12 (0 = unknown/all), mapped in `Config.CLASS_INDEXES`
- Leaderboard capped at 50 players per faction-realm
- Network event names: `PINFOB`, `REQSYNC`, `OFFERSYNC`, `STARTSYNC`, `SYNC`
- Local event names: `WHO_RESULT`, `SCAN_FINISHED`, `RACE_FINISHED`, `DING`, `REFRESH_GUI`
- Debug/trace gates use `@debug@` marker in `.toc`; version uses `@project-version@`
- Keep WoW-API-heavy code in `main.lua`, `options.lua`, `scanner.lua`, and `gui/` to preserve test coverage elsewhere

### Key Files
| File | Purpose |
|------|---------|
| `TheClassicRace.toc` | Addon manifest: version, lib load order |
| `.pkgmeta` | External library deps (SVN/Git externals) |
| `libs.xml` | WoW XML that loads libraries in correct order |
| `src/config.lua` | Global constants, colors, class mappings |
| `src/core/event-bus.lua` | Pub/sub event system |
| `src/core/scan.lua` | Binary search algorithm (well-tested) |
| `src/core/leaderboard.lua` | Leaderboard model |
| `src/core/serializer.lua` | Network encoding/decoding |
| `.luacheckrc` | Luacheck config (ignored codes, excluded files) |
| `.luacov` | Coverage config |
