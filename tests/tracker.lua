-- load test base
local TheClassicRace = require("testbase")

-- aliases
local Events = TheClassicRace.Config.Events
local DRUIDIDX, WARRIORIDX, PALADINIDX, PRIESTIDX =
TheClassicRace.Config.ClassIndexes["DRUID"], TheClassicRace.Config.ClassIndexes["WARRIOR"],
TheClassicRace.Config.ClassIndexes["PALADIN"],TheClassicRace.Config.ClassIndexes["PRIEST"]

function merge(...)
    local config = {}
    for _, c in pairs({...}) do
        for k, v in pairs(c) do
            config[k] = v
        end
    end

    return config
end

function leaderboardSpies(tracker, config)
    local spies = {}

    spies[0] = spy.on(tracker.lbGlobal, "ProcessPlayerInfo")

    for classIndex, _ in ipairs(config.Classes) do
        spies[classIndex] = spy.on(tracker.lbPerClass[classIndex], "ProcessPlayerInfo")
    end

    return spies
end

describe("Tracker", function()
    ---@type TheClassicRaceConfig
    local config
    local db
    ---@type TheClassicRaceCore
    local core
    ---@type TheClassicRaceEventBus
    local eventbus
    ---@type TheClassicRaceNetwork
    local network
    ---@type TheClassicRaceTracker
    local tracker
    local time = 1000000000

    function playerInfo(name, level, classIndex, dingedAt)
        if classIndex == nil then
            classIndex = 11
        end
        if dingedAt == nil then
            dingedAt = time
        end

        return {
            name = name,
            level = level,
            classIndex = classIndex,
            dingedAt = dingedAt,
        }
    end



    before_each(function()
        _G.C_Timer.Reset()
        config = merge(TheClassicRace.Config, {MaxLeaderboardSize = 5})
        db = LibStub("AceDB-3.0"):New("TheClassicRace_DB", TheClassicRace.DefaultDB, true)
        db:ResetDB()
        core = TheClassicRace.Core(TheClassicRace.Config, "Nub", "NubVille")
        -- mock core:Now() to return our mocked time
        function core:Now() return time end
        eventbus = TheClassicRace.EventBus()
        network = {SendObject = function() end}
        tracker = TheClassicRace.Tracker(config, core, db, eventbus, network)
    end)

    after_each(function()
        -- reset any mocking of IsInGuild we did
        _G.SetIsInGuild(nil)
    end)

    describe("leaderboard", function()
        it("adds players to global and class board", function()
            local lbSpies = leaderboardSpies(tracker, config)

            local pInfo

            pInfo = playerInfo("Nubone", 5, DRUIDIDX)
            tracker:ProcessPlayerInfoBatch({ pInfo, }, false)
            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), pInfo)
            assert.spy(lbSpies[DRUIDIDX]).was_called_with(match.is_ref(tracker.lbPerClass[DRUIDIDX]), pInfo)

            pInfo = playerInfo("Nub2", 5, WARRIORIDX)
            tracker:ProcessPlayerInfoBatch({ pInfo, }, false)
            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), pInfo)
            assert.spy(lbSpies[WARRIORIDX]).was_called_with(match.is_ref(tracker.lbPerClass[WARRIORIDX]), pInfo)

            pInfo = playerInfo("Nubthree", 5, PALADINIDX)
            tracker:ProcessPlayerInfoBatch({ pInfo, }, false)
            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), pInfo)
            assert.spy(lbSpies[PALADINIDX]).was_called_with(match.is_ref(tracker.lbPerClass[PALADINIDX]), pInfo)

            pInfo = playerInfo("Nubfour", 5, PRIESTIDX)
            tracker:ProcessPlayerInfoBatch({ pInfo, }, false)
            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), pInfo)
            assert.spy(lbSpies[PRIESTIDX]).was_called_with(match.is_ref(tracker.lbPerClass[PRIESTIDX]), pInfo)
        end)

        it("fixes missing dingedAt", function()
            local lbSpies = leaderboardSpies(tracker, config)

            tracker:ProcessPlayerInfo({name = "Nubone", level = 5, classIndex = DRUIDIDX})

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal),
                    playerInfo("Nubone", 5, DRUIDIDX, time))
        end)

        it("fixes class to classIndex", function()
            local lbSpies = leaderboardSpies(tracker, config)

            tracker:ProcessPlayerInfo({name = "Nubone", level = 5, class = "DRUID"})

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal),
                    playerInfo("Nubone", 5, DRUIDIDX, time))
        end)

        it("should broadcast internal event", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            tracker:ProcessPlayerInfoBatch({ playerInfo("Nubone", 5), }, false)
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 1, 1)

            tracker:ProcessPlayerInfoBatch({ playerInfo("Nubone", 6), }, false)
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 1, 1)

            tracker:ProcessPlayerInfoBatch({ playerInfo("Nub2", 7), }, false)
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 1, 1)

            eventBusSpy:clear()
            tracker:ProcessPlayerInfoBatch({ playerInfo("Nubone", 6), }, false)
            assert.spy(eventBusSpy).was_not_called()

            tracker:ProcessPlayerInfoBatch({ playerInfo("Nubone", 7), }, false)
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 2, 2)
        end)

        it("shouldn't broadcast to network OnNetPlayerInfo", function()
            local networkSpy = spy.on(network, "SendObject")

            tracker:OnNetPlayerInfoBatch({
                TheClassicRace.Serializer.SerializePlayerInfoBatch({
                    {name = "Nubone", level = 7, classIndex = 11, dingedAt = 100},
                }),
                false
            })
            assert.spy(networkSpy).was_not_called()
        end)

        it("should publish Ding on OnNetPlayerInfo", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            tracker:OnNetPlayerInfoBatch({
                TheClassicRace.Serializer.SerializePlayerInfoBatch({
                    {name = "Nubone", level = 7, classIndex = DRUIDIDX, dingedAt = 100},
                }), false, DRUIDIDX
            })

            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 1, 1)

            assert.spy(eventBusSpy).called_at_most(1)
        end)

        it("handles unknown classIndex (0) in a batch without error", function()
            tracker:OnNetPlayerInfoBatch({
                TheClassicRace.Serializer.SerializePlayerInfoBatch({
                    {name = "Nubone", level = 7, classIndex = 0, dingedAt = 100},
                }), false, 0
            })

            assert.equals(1, #db.factionrealm.leaderboard[0].players)
            assert.equals(0, db.factionrealm.leaderboard[0].players[1].classIndex)
        end)

        it("should broadcast to network OnSlashWhoResult", function()
            local networkSpy = spy.on(network, "SendObject")

            tracker:OnSlashWhoResult({ playerInfo("Nubone", 5), })
            -- yells immediately for real-time zone updates
            assert.spy(networkSpy).was_called_with(match.is_ref(network), config.Network.Events.PlayerInfoBatch,
                    match.is_table(), "YELL")
            assert.spy(networkSpy).called_at_most(1)

            -- guild push is batched behind DingPushDelay
            _G.C_Timer.Advance(config.DingPushDelay)
            assert.spy(networkSpy).was_called_with(match.is_ref(network), config.Network.Events.PlayerInfoBatch,
                    match.is_table(), "GUILD")
            assert.spy(networkSpy).called_at_most(2)
        end)

        it("should broadcast to network OnSlashWhoResult, not to guild when not in guild", function()
            local networkSpy = spy.on(network, "SendObject")

            _G.SetIsInGuild(false)

            tracker:OnSlashWhoResult({ playerInfo("Nubone", 5), })
            assert.spy(networkSpy).was_called_with(match.is_ref(network), config.Network.Events.PlayerInfoBatch,
                    match.is_table(), "YELL")
            assert.spy(networkSpy).called_at_most(1)

            _G.C_Timer.Advance(config.DingPushDelay)
            assert.spy(networkSpy).called_at_most(1)
        end)
    end)

    describe("Pioneers", function()
        it("UpdatePioneers sets raceStartedAt on first player", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            assert.equals(time, db.factionrealm.raceStartedAt)
        end)

        it("UpdatePioneers updates raceStartedAt to the minimum seen", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            tracker:ProcessPlayerInfo(playerInfo("Bob", 16, WARRIORIDX, time - 100))
            assert.equals(time - 100, db.factionrealm.raceStartedAt)
        end)

        it("UpdatePioneers does not lower raceStartedAt for a later timestamp", function()
            tracker:ProcessPlayerInfo(playerInfo("Bob", 16, WARRIORIDX, time - 100))
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            assert.equals(time - 100, db.factionrealm.raceStartedAt)
        end)

        it("UpdatePioneers records first player to reach each level (overall)", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            local ftl0 = db.factionrealm.firstToLevel[0]
            assert.equals("Alice",   ftl0[15].name)
            assert.equals(DRUIDIDX,  ftl0[15].classIndex)
            assert.equals(time,      ftl0[15].dingedAt)
        end)

        it("UpdatePioneers records first player to reach each level (per class)", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            local ftlDruid = db.factionrealm.firstToLevel[DRUIDIDX]
            assert.equals("Alice", ftlDruid[15].name)
            assert.equals(time,    ftlDruid[15].dingedAt)
        end)

        it("UpdatePioneers keeps earliest record per level (overall)", function()
            tracker:ProcessPlayerInfo(playerInfo("Bob",   15, WARRIORIDX, time))
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX,   time - 100))
            assert.equals("Alice", db.factionrealm.firstToLevel[0][15].name)
        end)

        it("UpdatePioneers does not overwrite an earlier record with a later one", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX,   time - 100))
            tracker:ProcessPlayerInfo(playerInfo("Bob",   15, WARRIORIDX, time))
            assert.equals("Alice", db.factionrealm.firstToLevel[0][15].name)
        end)

        it("UpdatePioneers uses name as tiebreaker when dingedAt is equal", function()
            tracker:ProcessPlayerInfo(playerInfo("Zebra",    15, WARRIORIDX, time))
            tracker:ProcessPlayerInfo(playerInfo("Aardvark", 15, DRUIDIDX,   time))
            assert.equals("Aardvark", db.factionrealm.firstToLevel[0][15].name)
        end)

        it("UpdatePlayerHistory records dingedAt per level", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            local hist = db.factionrealm.playerHistory["Alice"]
            assert.equals(time,     hist.levels[15])
            assert.equals(DRUIDIDX, hist.classIndex)
        end)

        it("UpdatePlayerHistory keeps earliest dingedAt per level", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time - 50))
            assert.equals(time - 50, db.factionrealm.playerHistory["Alice"].levels[15])
        end)

        it("OnFTLSyncResult merges remote firstToLevel into local DB", function()
            local ftldb = {
                [0] = {[10] = {name = "Remote", classIndex = WARRIORIDX, dingedAt = time - 200}},
            }
            tracker:OnFTLSyncResult(ftldb)
            assert.equals("Remote",  db.factionrealm.firstToLevel[0][10].name)
            assert.equals(time - 200, db.factionrealm.raceStartedAt)
        end)

        it("OnFTLSyncResult keeps local record when it is earlier", function()
            tracker:ProcessPlayerInfo(playerInfo("Local", 10, DRUIDIDX, time - 500))
            local ftldb = {
                [0] = {[10] = {name = "Remote", classIndex = WARRIORIDX, dingedAt = time - 200}},
            }
            tracker:OnFTLSyncResult(ftldb)
            assert.equals("Local", db.factionrealm.firstToLevel[0][10].name)
        end)

        it("OnFTLSyncResult overwrites local record when remote is earlier", function()
            tracker:ProcessPlayerInfo(playerInfo("Local", 10, DRUIDIDX, time - 100))
            local ftldb = {
                [0] = {[10] = {name = "Remote", classIndex = WARRIORIDX, dingedAt = time - 500}},
            }
            tracker:OnFTLSyncResult(ftldb)
            assert.equals("Remote", db.factionrealm.firstToLevel[0][10].name)
        end)
    end)

    describe("RaceFinished", function()
        it("produces RaceFinished event once", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            tracker:OnScanFinished(false)
            assert.spy(eventBusSpy).called_at_most(0)

            tracker:OnScanFinished(true)
            tracker:OnScanFinished(true)
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), Events.RaceFinished)
            assert.spy(eventBusSpy).called_at_most(1)
        end)
    end)

    describe("Sync", function()
        it("adds players", function()
            local lbSpies = leaderboardSpies(tracker, config)

            local nub3 = playerInfo("Nubthree", 5)
            local nub4 = playerInfo("Nubfour", 5, PALADINIDX)
            local nub5 = playerInfo("Nubfive", 5, PRIESTIDX, time - 100)
            tracker:OnSyncResult({
                nub3, nub4, nub5,
            }, false)

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), nub3)
            assert.spy(lbSpies[DRUIDIDX]).was_called_with(match.is_ref(tracker.lbPerClass[DRUIDIDX]), nub3)

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), nub4)
            assert.spy(lbSpies[PALADINIDX]).was_called_with(match.is_ref(tracker.lbPerClass[PALADINIDX]), nub4)

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), nub5)
            assert.spy(lbSpies[PRIESTIDX]).was_called_with(match.is_ref(tracker.lbPerClass[PRIESTIDX]), nub5)

            assert.equals(3, #db.factionrealm.leaderboard[0].players)
            -- canonical order: level desc, dingedAt asc, name asc
            assert.same({
                {name = "Nubfive", level = 5, dingedAt = time - 100, classIndex = PRIESTIDX},
                {name = "Nubfour", level = 5, dingedAt = time, classIndex = PALADINIDX},
                {name = "Nubthree", level = 5, dingedAt = time, classIndex = DRUIDIDX},
            }, db.factionrealm.leaderboard[0].players)
        end)
    end)

    describe("Convergence", function()
        it("NormalizeDB re-sorts legacy leaderboard order and floors timestamps", function()
            db.factionrealm.leaderboard[0].players = {
                {name = "Zebra", level = 5, dingedAt = time + 0.7, classIndex = DRUIDIDX},
                {name = "Aardvark", level = 5, dingedAt = time, classIndex = WARRIORIDX},
                {name = "Top", level = 7, dingedAt = time, classIndex = PRIESTIDX},
            }

            -- constructing a tracker normalizes the persisted data
            TheClassicRace.Tracker(config, core, db, TheClassicRace.EventBus(), network)

            assert.same({
                {name = "Top", level = 7, dingedAt = time, classIndex = PRIESTIDX},
                {name = "Aardvark", level = 5, dingedAt = time, classIndex = WARRIORIDX},
                {name = "Zebra", level = 5, dingedAt = time, classIndex = DRUIDIDX},
            }, db.factionrealm.leaderboard[0].players)
        end)

        it("clients converge on identical hashes after one bidirectional sync", function()
            -- regression for issue #16: A knows the player's class at a stale lower
            -- level, B has the newer level but doesn't know the class
            local dbB = LibStub("AceDB-3.0"):New("TheClassicRace_DB_B", TheClassicRace.DefaultDB, true)
            dbB:ResetDB()
            local trackerB = TheClassicRace.Tracker(config, core, dbB, TheClassicRace.EventBus(), network)

            tracker:ProcessPlayerInfo({name = "Racer", level = 20, classIndex = DRUIDIDX, dingedAt = time - 100})
            trackerB:ProcessPlayerInfo({name = "Racer", level = 25, classIndex = 0, dingedAt = time})
            assert.not_equals(tracker:ComputeFullHash(), trackerB:ComputeFullHash())

            -- exchange all leaderboards both ways through the wire format,
            -- snapshotting both sides first like the real sync exchange does
            local wire = function(t)
                local strs = {}
                for _, b in ipairs(t:CollectBatches(nil) or {}) do
                    strs[#strs + 1] = TheClassicRace.Serializer.SerializePlayerInfoBatch(b.players)
                end
                return strs
            end
            local batchesA, batchesB = wire(tracker), wire(trackerB)
            for _, str in ipairs(batchesB) do
                tracker:OnSyncResult(TheClassicRace.Serializer.DeserializePlayerInfoBatch(str))
            end
            for _, str in ipairs(batchesA) do
                trackerB:OnSyncResult(TheClassicRace.Serializer.DeserializePlayerInfoBatch(str))
            end

            assert.equals(tracker:ComputeFullHash(), trackerB:ComputeFullHash())
            -- both ended up with the latest level and the known class
            assert.same({name = "Racer", level = 25, dingedAt = time, classIndex = DRUIDIDX},
                    db.factionrealm.leaderboard[0].players[1])
            assert.same({name = "Racer", level = 25, dingedAt = time, classIndex = DRUIDIDX},
                    dbB.factionrealm.leaderboard[0].players[1])
        end)

        it("UpdatePioneers ignores level 1", function()
            tracker:ProcessPlayerInfo(playerInfo("Fresh", 1, DRUIDIDX, time))
            assert.is_nil(db.factionrealm.firstToLevel[0])
        end)

        it("OnFTLSyncResult fills in a missing classIndex on otherwise identical records", function()
            tracker:ProcessPlayerInfo({name = "Racer", level = 10, classIndex = 0, dingedAt = time})
            assert.equals(0, db.factionrealm.firstToLevel[0][10].classIndex)

            tracker:OnFTLSyncResult({
                [0] = {[10] = {name = "Racer", classIndex = DRUIDIDX, dingedAt = time}},
            })

            assert.equals(DRUIDIDX, db.factionrealm.firstToLevel[0][10].classIndex)
        end)

        it("OnPHSyncResult merges new players into playerHistory", function()
            tracker:OnPHSyncResult({
                Racer = {classIndex = WARRIORIDX, levels = {[10] = time - 100, [11] = time}},
            })

            local hist = db.factionrealm.playerHistory["Racer"]
            assert.equals(WARRIORIDX, hist.classIndex)
            assert.equals(time - 100, hist.levels[10])
            assert.equals(time, hist.levels[11])
        end)

        it("OnPHSyncResult keeps the earliest dingedAt per level", function()
            tracker:ProcessPlayerInfo(playerInfo("Racer", 10, DRUIDIDX, time - 100))

            tracker:OnPHSyncResult({
                Racer = {classIndex = DRUIDIDX, levels = {[10] = time, [11] = time + 50}},
            })

            local hist = db.factionrealm.playerHistory["Racer"]
            -- local level-10 record was earlier, remote level-11 record is new
            assert.equals(time - 100, hist.levels[10])
            assert.equals(time + 50, hist.levels[11])
        end)

        it("OnPHSyncResult fills in a missing classIndex", function()
            tracker:ProcessPlayerInfo({name = "Racer", level = 10, classIndex = 0, dingedAt = time})
            assert.equals(0, db.factionrealm.playerHistory["Racer"].classIndex)

            tracker:OnPHSyncResult({
                Racer = {classIndex = DRUIDIDX, levels = {[10] = time}},
            })

            assert.equals(DRUIDIDX, db.factionrealm.playerHistory["Racer"].classIndex)
        end)

        it("OnPHSyncResult ignores levels that don't fit the wire format", function()
            tracker:OnPHSyncResult({
                Racer = {classIndex = DRUIDIDX, levels = {[1] = time, [100] = time, [10] = time}},
            })

            local hist = db.factionrealm.playerHistory["Racer"]
            assert.is_nil(hist.levels[1])
            assert.is_nil(hist.levels[100])
            assert.equals(time, hist.levels[10])
        end)

        it("PrunePlayerHistory drops players that aren't on any leaderboard", function()
            db.factionrealm.leaderboard[0].players = {
                {name = "OnBoard", level = 30, dingedAt = time, classIndex = DRUIDIDX},
            }
            db.factionrealm.playerHistory = {
                OnBoard = {classIndex = DRUIDIDX, levels = {[30] = time}},
                Rando = {classIndex = WARRIORIDX, levels = {[10] = time}},
                -- ourselves ("Nub"), never pruned even when not on a leaderboard
                Nub = {classIndex = DRUIDIDX, levels = {[5] = time}},
            }

            -- constructing a tracker runs NormalizeDB, which prunes
            TheClassicRace.Tracker(config, core, db, TheClassicRace.EventBus(), network)

            assert.is_table(db.factionrealm.playerHistory["OnBoard"])
            assert.is_table(db.factionrealm.playerHistory["Nub"])
            assert.is_nil(db.factionrealm.playerHistory["Rando"])
        end)

        it("OnFTLSyncResult ignores records that don't fit the wire format", function()
            tracker:OnFTLSyncResult({
                [0] = {
                    [1] = {name = "Fresh", classIndex = DRUIDIDX, dingedAt = time},
                    [100] = {name = "Impossible", classIndex = DRUIDIDX, dingedAt = time},
                    [10] = {name = "Racer", classIndex = DRUIDIDX, dingedAt = time},
                },
            })

            assert.is_nil(db.factionrealm.firstToLevel[0][1])
            assert.is_nil(db.factionrealm.firstToLevel[0][100])
            assert.equals("Racer", db.factionrealm.firstToLevel[0][10].name)
        end)
    end)
end)
