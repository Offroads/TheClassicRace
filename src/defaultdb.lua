local TheClassicRace = _G.TheClassicRace

---@class TheClassicRaceDefaultDB
local TheClassicRaceDefaultDB = {
    profile = {
        options = {
            minimap = {
                hide = false,
            },
            networking = true,
            dontbump = false,
            maxLevelNotify = true,
            classTopN = 3,
            globalTopN = 5,
            debug = false,
        },
        gui = {
            display = true,
            statusFrameStatus = {
                width = 240,
                height = 240,
            },
        },
    },
    factionrealm = {
        dbversion = "0.0.0",
        finished = false,
        buddies = {},
        leaderboard = {
            ['**'] = {
                minLevel = 2,
                highestLevel = 1,
                players = {},
            },
        },
        -- Pioneers: first player to reach each level
        -- realmOpenedAt: GetServerTime() recorded on first-ever DB init for this realm; synced to keep earliest
        realmOpenedAt = nil,
        -- raceStartedAt: earliest dingedAt ever seen; fallback reference when realmOpenedAt is nil
        raceStartedAt = nil,
        -- playerHistory[name] = {classIndex, levels = {[level] = dingedAt}}
        playerHistory = {},
        -- firstToLevel[classFilter][level] = {name, classIndex, dingedAt}
        -- classFilter 0 = overall, 1-11 = per class
        firstToLevel = {},
        pioneersMigrated = false,
    },
}

TheClassicRace.DefaultDB = TheClassicRaceDefaultDB
