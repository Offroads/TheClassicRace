-- load test base
local TheClassicRace = require("testbase")

-- aliases
local Events = TheClassicRace.Config.Events

function merge(...)
    local config = {}
    for _, c in pairs({...}) do
        for k, v in pairs(c) do
            config[k] = v
        end
    end

    return config
end

describe("Leaderboard", function()
    ---@type TheClassicRaceConfig
    local config
    local db
    local dbboard
    ---@type TheClassicRaceLeaderboard
    local leaderboard
    local time = 1000000000

    local base = {dingedAt = time, classIndex = 11}

    before_each(function()
        config = merge(TheClassicRace.Config, {MaxLeaderboardSize = 5})
        db = LibStub("AceDB-3.0"):New("TheClassicRace_DB", TheClassicRace.DefaultDB, true)
        db:ResetDB()
        dbboard = db.factionrealm.leaderboard[0]
        leaderboard = TheClassicRace.Leaderboard(config, dbboard)
    end)

    describe("ComputeHash", function()
        it("returns same hash for same data", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub2", level = 4, dingedAt = time, classIndex = 11})
            local h1 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            local h2 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            assert.equals(h1, h2)
        end)

        it("returns different hash when a player is added", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            local h1 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            leaderboard:ProcessPlayerInfo({name = "Nub2", level = 4, dingedAt = time, classIndex = 11})
            local h2 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            assert.not_equals(h1, h2)
        end)

        it("returns different hash when a player levels up", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            local h1 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 6, dingedAt = time, classIndex = 11})
            local h2 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            assert.not_equals(h1, h2)
        end)

        it("returns different hash when dingedAt changes", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time + 10, classIndex = 11})
            local h1 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            local h2 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            assert.not_equals(h1, h2)
        end)

        it("returns consistent hash for empty leaderboard", function()
            local h1 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            local h2 = TheClassicRace.Leaderboard.ComputeHash(dbboard)
            assert.equals(h1, h2)
        end)
    end)

    describe("leaderboard", function()
        it("adds players", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub3", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub4", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub5", level = 5, classIndex = 6}, base), false)

            assert.equals(5, #dbboard.players)
            assert.same({
                merge({name = "Nub1", level = 5, classIndex = 11}, base),
                merge({name = "Nub2", level = 5, classIndex = 11}, base),
                merge({name = "Nub3", level = 5, classIndex = 11}, base),
                merge({name = "Nub4", level = 5, classIndex = 11}, base),
                merge({name = "Nub5", level = 5, classIndex = 6}, base),
            }, dbboard.players)
        end)

        it("doesn't add duplicates", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)

            assert.equals(1, #dbboard.players)
        end)

        it("doesn't add beyond max", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub3", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub4", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub5", level = 5}, base), false)
            -- max
            leaderboard:ProcessPlayerInfo(merge({name = "Nub6", level = 5}, base), false)
            assert.equals(5, #dbboard.players)
            assert.same({
                merge({name = "Nub1", level = 5, classIndex = 11}, base),
                merge({name = "Nub2", level = 5, classIndex = 11}, base),
                merge({name = "Nub3", level = 5, classIndex = 11}, base),
                merge({name = "Nub4", level = 5, classIndex = 11}, base),
                merge({name = "Nub5", level = 5, classIndex = 11}, base),
            }, dbboard.players)
        end)

        it("bumps on ding", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 6}, base), false)

            assert.equals(1, #dbboard.players)
            assert.equals(6, dbboard.players[1].level)
        end)

        it("reorders on ding", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub3", level = 5}, base), false)

            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 6}, base), false)
            assert.equals(3, #dbboard.players)
            assert.same({
                merge({name = "Nub2", level = 6, classIndex = 11}, base),
                merge({name = "Nub1", level = 5, classIndex = 11}, base),
                merge({name = "Nub3", level = 5, classIndex = 11}, base),
            }, dbboard.players)
        end)

        it("inserts new player with earlier dingedAt before same-level players", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time + 10, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub2", level = 5, dingedAt = time + 20, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub3", level = 5, dingedAt = time, classIndex = 11})

            assert.equals(3, #dbboard.players)
            assert.equals("Nub3", dbboard.players[1].name)
            assert.equals("Nub1", dbboard.players[2].name)
            assert.equals("Nub2", dbboard.players[3].name)
        end)

        it("updates dingedAt for existing player and reorders", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time + 20, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub2", level = 5, dingedAt = time + 10, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})

            assert.equals(2, #dbboard.players)
            assert.equals("Nub1", dbboard.players[1].name)
            assert.equals(time, dbboard.players[1].dingedAt)
            assert.equals("Nub2", dbboard.players[2].name)
        end)

        it("ignores later dingedAt for existing player", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            local rank, changed = leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time + 10, classIndex = 11})

            assert.equals(1, #dbboard.players)
            assert.equals(time, dbboard.players[1].dingedAt)
            assert.is_nil(changed)
        end)

        it("truncates on ding", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub3", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub4", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub5", level = 5}, base), false)

            leaderboard:ProcessPlayerInfo(merge({name = "Nub6", level = 6}, base), false)
            assert.equals(5, #dbboard.players)

            assert.same({
                merge({name = "Nub6", level = 6, classIndex = 11}, base),
                merge({name = "Nub1", level = 5, classIndex = 11}, base),
                merge({name = "Nub2", level = 5, classIndex = 11}, base),
                merge({name = "Nub3", level = 5, classIndex = 11}, base),
                merge({name = "Nub4", level = 5, classIndex = 11}, base),
            }, dbboard.players)
        end)
    end)
end)
