-- Addon global
local TheClassicRace = _G.TheClassicRace

-- WoW API
local IsInGuild, GetNumGroupMembers = _G.IsInGuild, _G.GetNumGroupMembers
local C_Timer = _G.C_Timer

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
    self.lastGuildBroadcastHash = nil

    self:ReinitLeaderboards()

    -- subscribe to network events
    EventBus:RegisterCallback(self.Config.Network.Events.PlayerInfoBatch, self, self.OnNetPlayerInfoBatch)
    EventBus:RegisterCallback(self.Config.Network.Events.DataAvailable, self, self.OnNetDataAvailable)
    EventBus:RegisterCallback(self.Config.Network.Events.DataRequest, self, self.OnNetDataRequest)
    -- subscribe to local events
    EventBus:RegisterCallback(self.Config.Events.SlashWhoResult, self, self.OnSlashWhoResult)
    EventBus:RegisterCallback(self.Config.Events.SyncResult, self, self.OnSyncResult)
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

function TheClassicRaceTracker:OnNetPlayerInfoBatch(payload, _, shouldBroadcast)
    -- ignore data received when we've disabled networking
    if not self.DB.profile.options.networking then
        return
    end

    if shouldBroadcast == nil then
        shouldBroadcast = false
    end

    local batchstr = payload[1]
    local isRebroadcast = payload[2]
    local classIndex = payload[3] or 0

    local batch = TheClassicRace.Serializer.DeserializePlayerInfoBatch(batchstr)

    self:ProcessPlayerInfoBatch(batch, shouldBroadcast, false, classIndex)

    -- if it wasn't a rebroadcast then it was a /who scan, we can delay our own /who scan a bit
    if not isRebroadcast then
        self.EventBus:PublishEvent(self.Config.Events.BumpScan, classIndex)
    end
end

function TheClassicRaceTracker:OnSlashWhoResult(playerInfoBatch, classIndex)
    self:ProcessPlayerInfoBatch(playerInfoBatch, true, false, classIndex)
end

function TheClassicRaceTracker:OnSyncResult(playerInfoBatch, shouldBroadcast)
    self:ProcessPlayerInfoBatch(playerInfoBatch, shouldBroadcast, true)
end

function TheClassicRaceTracker:ProcessPlayerInfoBatch(playerInfoBatch, shouldBroadcast, isRebroadcast, classIndex)
    local batch = {}

    -- the network message can be a list of playerInfo
    local changed
    for _, playerInfo in ipairs(playerInfoBatch) do
        playerInfo, changed = self:ProcessPlayerInfo(playerInfo)

        -- if anything was updated then we add the player to the batch to broadcast
        if changed then
            table.insert(batch, playerInfo)
        end
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
-- Returns nil if the global leaderboard is empty.
function TheClassicRaceTracker:CollectBatches()
    local globalPlayers = self.DB.factionrealm.leaderboard[0].players
    if #globalPlayers == 0 then return nil end

    local inGlobal = {}
    for _, p in ipairs(globalPlayers) do inGlobal[p.name] = true end

    local batches = { { players = globalPlayers, classIndex = 0 } }
    for classIndex, _ in ipairs(self.Config.Classes) do
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
    return batches
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
-- 5-second window for others to request our data. GUILD/GROUP still get a
-- full push when the hash has changed (cross-zone reliability).
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

    -- GUILD/GROUP: push full data only when something actually changed
    if fullHash ~= self.lastGuildBroadcastHash then
        local batches = self:CollectBatches()
        if batches then
            if IsInGuild() then self:SendBatches(batches, "GUILD") end
            if GetNumGroupMembers() > 0 then self:SendBatches(batches, "GROUP") end
            self.lastGuildBroadcastHash = fullHash
        end
    end
end

-- Called after the discovery window closes. Whispers data to a single
-- requester, or yells to the zone if multiple players need it.
function TheClassicRaceTracker:ProcessDiscoveryResponses()
    local requesters = self.pendingRequesters
    self.pendingRequesters = nil

    if not requesters or #requesters == 0 then
        TheClassicRace:DebugPrint("Discovery: no one needs data")
        return
    end

    local batches = self:CollectBatches()
    if not batches then return end

    TheClassicRace:DebugPrint("Discovery: " .. #requesters .. " requester(s)")
    if #requesters == 1 then
        self:SendBatches(batches, "WHISPER", requesters[1])
    else
        self:SendBatches(batches, "YELL")
    end
end

-- Received when another player announces their leaderboard hash.
-- If ours differs, whisper back a data request.
function TheClassicRaceTracker:OnNetDataAvailable(hash, sender)
    local myHash = self:ComputeFullHash()
    if myHash == hash then return end

    TheClassicRace:DebugPrint("DataAvail from " .. sender .. ": hash differs, requesting")
    self.Network:SendObject(self.Config.Network.Events.DataRequest, 0, "WHISPER", sender)
end

-- Received when someone wants our data. Only accepted during the active
-- discovery window opened by SendDiscoveryBeacon.
function TheClassicRaceTracker:OnNetDataRequest(_, sender)
    if self.pendingRequesters == nil then return end
    for _, name in ipairs(self.pendingRequesters) do
        if name == sender then return end
    end
    TheClassicRace:DebugPrint("DataRequest from " .. sender)
    table.insert(self.pendingRequesters, sender)
end

--[[
ProcessPlayerInfo updates the leaderboard and triggers notifications accordingly
]]--
function TheClassicRaceTracker:ProcessPlayerInfo(playerInfo)
    -- don't process more player info when we know the race has finished
    if self.DB.factionrealm.finished then
        return
    end

    TheClassicRace:DebugPrint("[T] ProcessPlayerInfo: [" .. tostring(playerInfo.classIndex) .. "][" .. tostring(playerInfo.class) .. "] "
            .. playerInfo.name .. " lvl" .. playerInfo.level)

    if playerInfo.dingedAt == nil then
        playerInfo.dingedAt = self.Core:Now()
    end

    if playerInfo.classIndex == nil and playerInfo.class ~= nil then
        playerInfo.classIndex = self.Core:ClassIndex(playerInfo.class)
        playerInfo.class = nil
    end

    TheClassicRace:DebugPrint("[T] ProcessPlayerInfo: [" .. tostring(playerInfo.classIndex) .. "][" .. tostring(playerInfo.class) .. "] "
            .. playerInfo.name .. " lvl" .. playerInfo.level)

    local globalRank, globalIsChanged = self.lbGlobal:ProcessPlayerInfo(playerInfo)
    local classRank, classIsChanged, classLowestLevel = nil, nil
    if playerInfo.classIndex ~= nil then
        classRank, classIsChanged, classLowestLevel = self.lbPerClass[playerInfo.classIndex]:ProcessPlayerInfo(playerInfo)
    end

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