-- Addon global
local TheClassicRace = _G.TheClassicRace

-- WoW API
local C_Timer, IsInGuild, math = _G.C_Timer, _G.IsInGuild, _G.math

--[[
Tracker is responsible for maintaining our leaderboard data based on data provided by other parts of the system
to us through the EventBus.
]]--
---@class TheClassicRaceTracker
---@field DB table<string, table>
---@field Config TheClassicRaceConfig
---@field Core TheClassicRaceCore
---@field EventBus TheClassicRaceEventBus
---@field Network TheClassicRaceNetwork
---@field lbGlobal TheClassicRaceLeaderboard
---@field lbPerClass table<string, TheClassicRaceLeaderboard>
local TheClassicRaceTracker = {}
TheClassicRaceTracker.__index = TheClassicRaceTracker
TheClassicRace.Tracker = TheClassicRaceTracker
setmetatable(TheClassicRaceTracker, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function TheClassicRaceTracker.new(Config, Core, DB, EventBus, Network)
    local self = setmetatable({}, TheClassicRaceTracker)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.Network = Network

    self.pendingRequesters = nil   -- non-nil only during active discovery window
    self.pendingDings = {}
    self.dingPushPending = false

    self:ReinitLeaderboards()

    -- subscribe to network events
    EventBus:RegisterCallback(self.Config.Network.Events.PlayerInfoBatch, self, self.OnNetPlayerInfoBatch)
    EventBus:RegisterCallback(self.Config.Network.Events.DataAvailable, self, self.OnNetDataAvailable)
    EventBus:RegisterCallback(self.Config.Network.Events.DataRequest, self, self.OnNetDataRequest)
    -- subscribe to local events
    EventBus:RegisterCallback(self.Config.Events.SlashWhoResult, self, self.OnSlashWhoResult)
    EventBus:RegisterCallback(self.Config.Events.SyncResult, self, self.OnSyncResult)
    EventBus:RegisterCallback(self.Config.Events.FTLSyncResult, self, self.OnFTLSyncResult)
    EventBus:RegisterCallback(self.Config.Events.ScanFinished, self, self.OnScanFinished)

    return self
end

function TheClassicRaceTracker:ReinitLeaderboards()
    self.lbGlobal = TheClassicRace.Leaderboard(self.Config, self.DB.factionrealm.leaderboard[0])
    self.lbPerClass = {}
    for classIndex, _ in ipairs(self.Config.Classes) do
        self.lbPerClass[classIndex] = TheClassicRace.Leaderboard(self.Config, self.DB.factionrealm.leaderboard[classIndex])
    end
end

function TheClassicRaceTracker:OnScanFinished(endofrace)
    -- if a scan finished but the result wasn't complete then we have too many max level players
    if endofrace then
        self:RaceFinished()
    end
end

function TheClassicRaceTracker:CheckRaceFinished()
    local raceFinished = true
    for _, lbdb in pairs(self.DB.factionrealm.leaderboard) do
        if lbdb.minLevel < self.Config.MaxLevel then
            raceFinished = false
            break
        end
    end

    if raceFinished then
        self:RaceFinished()
    end
end

function TheClassicRaceTracker:RaceFinished()
    if not self.DB.factionrealm.finished then
        self.DB.factionrealm.finished = true

        self.EventBus:PublishEvent(self.Config.Events.RaceFinished)
    end
end

function TheClassicRaceTracker:OnNetPlayerInfoBatch(payload, _)
    if not self.DB.profile.options.networking then return end

    local batchstr = payload[1]
    local isRebroadcast = payload[2]
    local classIndex = payload[3] or 0

    local batch = TheClassicRace.Serializer.DeserializePlayerInfoBatch(batchstr)
    self:ProcessPlayerInfoBatch(batch, classIndex)

end

function TheClassicRaceTracker:OnSlashWhoResult(playerInfoBatch, classIndex)
    local changed = {}
    for _, playerInfo in ipairs(playerInfoBatch) do
        local normalizedInfo, isChanged = self:ProcessPlayerInfo(playerInfo)
        if isChanged then
            changed[#changed + 1] = normalizedInfo
        end
    end
    if #changed > 0 then
        self:ScheduleDingPush(changed)
    end
end

function TheClassicRaceTracker:OnSyncResult(playerInfoBatch)
    self:ProcessPlayerInfoBatch(playerInfoBatch)
end

function TheClassicRaceTracker:ScheduleDingPush(changedPlayers)
    if not self.DB.profile.options.networking then return end
    if self.DB.factionrealm.finished then return end

    -- YELL immediately so zone players get real-time updates
    local batchstr = TheClassicRace.Serializer.SerializePlayerInfoBatch(changedPlayers)
    self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, {batchstr, false, 0}, "YELL")

    -- accumulate into pending set (keyed by name to deduplicate across rapid scans)
    for _, p in ipairs(changedPlayers) do
        self.pendingDings[p.name] = p
    end

    if not self.dingPushPending then
        self.dingPushPending = true
        local _self = self
        C_Timer.After(self.Config.DingPushDelay, function()
            _self:FlushDingPush()
        end)
    end
end

function TheClassicRaceTracker:FlushDingPush()
    self.dingPushPending = false

    local players = {}
    for _, p in pairs(self.pendingDings) do
        players[#players + 1] = p
    end
    self.pendingDings = {}

    if #players == 0 then return end

    local batchstr = TheClassicRace.Serializer.SerializePlayerInfoBatch(players)
    local payload = {batchstr, false, 0}

    if IsInGuild() then
        self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, payload, "GUILD")
    end

    -- whisper a random sample of buddies (capped at BuddyPingBatchSize)
    local names = {}
    for name, _ in pairs(self.DB.factionrealm.buddies) do
        names[#names + 1] = name
    end
    local batchSize = self.Config.BuddyPingBatchSize
    if #names > batchSize then
        for i = 1, batchSize do
            local j = math.random(i, #names)
            names[i], names[j] = names[j], names[i]
        end
        for i = batchSize + 1, #names do names[i] = nil end
    end
    for _, name in ipairs(names) do
        self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, payload, "WHISPER", name)
    end
end

function TheClassicRaceTracker:ProcessPlayerInfoBatch(playerInfoBatch, classIndex)
    for _, playerInfo in ipairs(playerInfoBatch) do
        self:ProcessPlayerInfo(playerInfo)
    end
end

-- djb2 chain over all leaderboards in fixed order (global=0, class 1-12).
-- Any difference in any leaderboard produces a different hash.
function TheClassicRaceTracker:ComputeFullHash()
    local hash = 5381
    for classIndex = 0, #self.Config.Classes do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        if lb then
            hash = ((hash * 33) + TheClassicRace.Leaderboard.ComputeHash(lb)) % 2147483647
        end
    end
    return hash
end

-- Returns {[classIndex]=true} for each leaderboard where requester's hash differs from ours.
-- Returns nil if requesterClassHashes is not a table (old client: treat as needs everything).
-- classHashes is a 1-based array: index i+1 corresponds to leaderboard[i].
function TheClassicRaceTracker:ComputeNeedSet(requesterClassHashes)
    if type(requesterClassHashes) ~= "table" then
        return nil
    end
    local needSet = {}
    for classIndex = 0, #self.Config.Classes do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        local myHash = lb and TheClassicRace.Leaderboard.ComputeHash(lb) or 0
        local theirHash = requesterClassHashes[classIndex + 1] or 0
        if myHash ~= theirHash then
            needSet[classIndex] = true
        end
    end
    return needSet
end

function TheClassicRaceTracker:InitDiscoveryTicker()
    local jitter = math.random(0, self.Config.BroadcastInterval - 1)
    C_Timer.After(jitter, function()
        self:SendDiscoveryBeacon()
        C_Timer.NewTicker(self.Config.BroadcastInterval, function()
            self:SendDiscoveryBeacon()
        end)
    end)
end

-- Collect global + class-unique players into batches ready for sending.
-- needSet: optional {[classIndex]=true} filter; nil means include all.
-- Returns nil if no batches would be produced.
function TheClassicRaceTracker:CollectBatches(needSet)
    local globalPlayers = self.DB.factionrealm.leaderboard[0].players
    if #globalPlayers == 0 then return nil end

    local inGlobal = {}
    for _, p in ipairs(globalPlayers) do inGlobal[p.name] = true end

    local batches = {}
    if needSet == nil or needSet[0] then
        batches[#batches + 1] = { players = globalPlayers, classIndex = 0 }
    end

    for classIndex, _ in ipairs(self.Config.Classes) do
        if needSet == nil or needSet[classIndex] then
            local lb = self.DB.factionrealm.leaderboard[classIndex]
            if lb and #lb.players > 0 then
                local unique = {}
                for _, p in ipairs(lb.players) do
                    if not inGlobal[p.name] then unique[#unique + 1] = p end
                end
                if #unique > 0 then
                    batches[#batches + 1] = { players = unique, classIndex = classIndex }
                end
            end
        end
    end

    return #batches > 0 and batches or nil
end

-- Send collected batches to a channel.
-- YELL: chunked with delays to stay under single-message size.
-- WHISPER/GUILD/GROUP: full batches in one message each.
function TheClassicRaceTracker:SendBatches(batches, channel, target)
    if channel == "YELL" then
        local chunkSize = self.Config.YellChunkSize
        local delay = 0
        for _, batchInfo in ipairs(batches) do
            local batchPlayers = batchInfo.players
            local classIdx = batchInfo.classIndex
            for i = 0, math.ceil(#batchPlayers / chunkSize) - 1 do
                local chunk = {}
                for j = i * chunkSize + 1, math.min((i + 1) * chunkSize, #batchPlayers) do
                    chunk[#chunk + 1] = batchPlayers[j]
                end
                C_Timer.After(delay, function()
                    local batch = TheClassicRace.Serializer.SerializePlayerInfoBatch(chunk)
                    self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, { batch, false, classIdx }, "YELL")
                end)
                delay = delay + self.Config.YellChunkDelay
            end
        end
    else
        for _, batchInfo in ipairs(batches) do
            local batch = TheClassicRace.Serializer.SerializePlayerInfoBatch(batchInfo.players)
            self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, { batch, false, batchInfo.classIndex }, channel, target)
        end
    end
end

-- Every BroadcastInterval seconds: announce our hash to YELL and open a
-- 5-second window for others to request our data.
-- Guild sync is handled separately by Sync:InitGuildTicker().
function TheClassicRaceTracker:SendDiscoveryBeacon()
    if self.DB.factionrealm.finished then return end
    if not self.DB.profile.options.networking then return end
    if #self.DB.factionrealm.leaderboard[0].players == 0 then return end

    local fullHash = self:ComputeFullHash()

    -- open discovery window then announce hash to YELL
    self.pendingRequesters = {}
    self.Network:SendObject(self.Config.Network.Events.DataAvailable, fullHash, "YELL")

    local _self = self
    C_Timer.After(self.Config.RequestSyncWait, function()
        _self:ProcessDiscoveryResponses()
    end)
end

-- Called after the discovery window closes. Whispers data to a single
-- requester, or yells to the zone if multiple players need it.
-- Only sends leaderboards that each requester's hashes indicate they're missing.
function TheClassicRaceTracker:ProcessDiscoveryResponses()
    local requesters = self.pendingRequesters
    self.pendingRequesters = nil

    if not requesters or #requesters == 0 then
        TheClassicRace:DebugPrint("Discovery: no one needs data")
        return
    end

    TheClassicRace:DebugPrint("Discovery: " .. #requesters .. " requester(s)")

    if #requesters == 1 then
        local needSet = self:ComputeNeedSet(requesters[1].classHashes)
        if needSet then
            local classes = {}
            for ci in pairs(needSet) do classes[#classes + 1] = ci end
            TheClassicRace:AddHashLog(requesters[1].name, ">", classes, false)
        end
        local batches = self:CollectBatches(needSet)
        if batches then
            self:SendBatches(batches, "WHISPER", requesters[1].name)
        end
    else
        -- build the union of what all requesters need; fall back to nil (send all) for old clients
        local unionNeedSet = {}
        for _, req in ipairs(requesters) do
            if type(req.classHashes) ~= "table" then
                unionNeedSet = nil
                break
            end
            local needSet = self:ComputeNeedSet(req.classHashes)
            for classIndex, _ in pairs(needSet) do
                unionNeedSet[classIndex] = true
            end
        end
        if unionNeedSet then
            local classes = {}
            for ci in pairs(unionNeedSet) do classes[#classes + 1] = ci end
            TheClassicRace:AddHashLog("(zone yell)", ">", classes, false)
        end
        local batches = self:CollectBatches(unionNeedSet)
        if batches then
            self:SendBatches(batches, "YELL")
        end
    end
end

-- Received when another player announces their leaderboard hash.
-- If ours differs, whisper back a data request with our per-class hashes
-- so the responder can skip sending leaderboards we already agree on.
function TheClassicRaceTracker:OnNetDataAvailable(hash, sender)
    local myHash = self:ComputeFullHash()
    if myHash == hash then return end

    -- send per-class hashes as 1-based array (index i+1 = leaderboard[i])
    local classHashes = {}
    for classIndex = 0, #self.Config.Classes do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        classHashes[classIndex + 1] = lb and TheClassicRace.Leaderboard.ComputeHash(lb) or 0
    end

    TheClassicRace:DebugPrint("DataAvail from " .. sender .. ": hash differs, requesting")
    self.Network:SendObject(self.Config.Network.Events.DataRequest, classHashes, "WHISPER", sender)
end

-- Received when someone wants our data. Only accepted during the active
-- discovery window opened by SendDiscoveryBeacon.
function TheClassicRaceTracker:OnNetDataRequest(classHashes, sender)
    if self.pendingRequesters == nil then return end
    for _, req in ipairs(self.pendingRequesters) do
        if req.name == sender then return end
    end
    TheClassicRace:DebugPrint("DataRequest from " .. sender)
    table.insert(self.pendingRequesters, { name = sender, classHashes = classHashes })
end

--[[
ProcessPlayerInfo updates the leaderboard and triggers notifications accordingly
]]--
function TheClassicRaceTracker:ProcessPlayerInfo(playerInfo)
    -- don't process more player info when we know the race has finished
    if self.DB.factionrealm.finished then
        return
    end

    if playerInfo.dingedAt == nil then
        playerInfo.dingedAt = self.Core:Now()
    end

    if playerInfo.classIndex == nil and playerInfo.class ~= nil then
        playerInfo.classIndex = self.Core:ClassIndex(playerInfo.class)
        playerInfo.class = nil
    end

    TheClassicRace:DebugPrint("[T] ProcessPlayerInfo: [" .. tostring(playerInfo.classIndex) .. "] "
            .. playerInfo.name .. " lvl" .. playerInfo.level)

    local globalRank, globalIsChanged = self.lbGlobal:ProcessPlayerInfo(playerInfo)
    local classRank, classIsChanged, classLowestLevel = nil, nil
    if playerInfo.classIndex ~= nil then
        classRank, classIsChanged, classLowestLevel = self.lbPerClass[playerInfo.classIndex]:ProcessPlayerInfo(playerInfo)
    end

    -- update pioneer records for every detected player
    self:UpdatePioneers(playerInfo)
    self:UpdatePlayerHistory(playerInfo)

    -- publish internal event
    if globalIsChanged or classIsChanged then
        self.EventBus:PublishEvent(self.Config.Events.Ding, playerInfo, globalRank, classRank)
    end

    -- check if the race is finished if the class leaderboard is finished
    if classLowestLevel == self.Config.MaxLevel then
        self:CheckRaceFinished()
    end

    -- return normalized playerinfo and boolean if anything changed
    return playerInfo, globalIsChanged or classIsChanged
end

-- Records this player's dingedAt in playerHistory for future per-character level breakdown.
function TheClassicRaceTracker:UpdatePlayerHistory(playerInfo)
    local dingedAt = playerInfo.dingedAt
    if dingedAt == nil then return end

    local db = self.DB.factionrealm
    local name = playerInfo.name
    local level = playerInfo.level
    local classIndex = playerInfo.classIndex

    if db.playerHistory[name] == nil then
        db.playerHistory[name] = {classIndex = classIndex, levels = {}}
    end

    local hist = db.playerHistory[name]
    if hist.classIndex == nil and classIndex ~= nil then
        hist.classIndex = classIndex
    end
    -- only keep the earliest detection at each level
    if hist.levels[level] == nil or dingedAt < hist.levels[level] then
        hist.levels[level] = dingedAt
    end
end

-- Updates firstToLevel (overall and per-class) and raceStartedAt for every detected player.
function TheClassicRaceTracker:UpdatePioneers(playerInfo)
    local dingedAt = playerInfo.dingedAt
    if dingedAt == nil then return end

    local db = self.DB.factionrealm
    local name = playerInfo.name
    local level = playerInfo.level
    local classIndex = playerInfo.classIndex

    -- track the earliest detection as race start
    if db.raceStartedAt == nil or dingedAt < db.raceStartedAt then
        db.raceStartedAt = dingedAt
    end

    -- overall (classFilter 0)
    if db.firstToLevel[0] == nil then db.firstToLevel[0] = {} end
    local ftl0 = db.firstToLevel[0]
    if ftl0[level] == nil or dingedAt < ftl0[level].dingedAt
            or (dingedAt == ftl0[level].dingedAt and name < ftl0[level].name) then
        ftl0[level] = {name = name, classIndex = classIndex, dingedAt = dingedAt}
    end

    -- per-class
    if classIndex ~= nil and classIndex ~= 0 then
        if db.firstToLevel[classIndex] == nil then db.firstToLevel[classIndex] = {} end
        local ftlC = db.firstToLevel[classIndex]
        if ftlC[level] == nil or dingedAt < ftlC[level].dingedAt
                or (dingedAt == ftlC[level].dingedAt and name < ftlC[level].name) then
            ftlC[level] = {name = name, classIndex = classIndex, dingedAt = dingedAt}
        end
    end
end

-- Merges received firstToLevel data from a sync partner, keeping the earliest record per slot.
-- Also merges realmOpenedAt, keeping the earliest (closest to actual realm launch).
function TheClassicRaceTracker:OnFTLSyncResult(ftldb, remoteRealmOpenedAt)
    local db = self.DB.factionrealm

    if remoteRealmOpenedAt and (db.realmOpenedAt == nil or remoteRealmOpenedAt < db.realmOpenedAt) then
        db.realmOpenedAt = remoteRealmOpenedAt
    end

    for classFilter, levels in pairs(ftldb) do
        if db.firstToLevel[classFilter] == nil then
            db.firstToLevel[classFilter] = {}
        end
        for level, record in pairs(levels) do
            local existing = db.firstToLevel[classFilter][level]
            if existing == nil or record.dingedAt < existing.dingedAt
                    or (record.dingedAt == existing.dingedAt and record.name < existing.name) then
                db.firstToLevel[classFilter][level] = record
                if db.raceStartedAt == nil or record.dingedAt < db.raceStartedAt then
                    db.raceStartedAt = record.dingedAt
                end
            end
        end
    end

    self.EventBus:PublishEvent(self.Config.Events.RefreshGUI)
end