-- Addon global
local TheClassicRace = _G.TheClassicRace

-- WoW API
local C_Timer, IsInGuild = _G.C_Timer, _G.IsInGuild

--[[
TheClassicRaceSync handles both requesting a sync when we login and responding to others who are request a sync
]]--
---@class TheClassicRaceSync
---@field Config TheClassicRaceConfig
---@field Core TheClassicRaceCore
---@field DB table<string, table>
---@field EventBus TheClassicRaceEventBus
local TheClassicRaceSync = {}
TheClassicRaceSync.__index = TheClassicRaceSync
TheClassicRace.Sync = TheClassicRaceSync
setmetatable(TheClassicRaceSync, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function TheClassicRaceSync.new(Config, Core, DB, EventBus, Network)
    local self = setmetatable({}, TheClassicRaceSync)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.Network = Network

    self.classIndex = self.Core:MyClass()

    self.isReady = false
    self.offers = {}
    self.syncPartner = nil
    self.lastSync = nil

    EventBus:RegisterCallback(self.Config.Network.Events.RequestSync, self, self.OnNetRequestSync)
    EventBus:RegisterCallback(self.Config.Network.Events.OfferSync, self, self.OnNetOfferSync)
    EventBus:RegisterCallback(self.Config.Network.Events.StartSync, self, self.OnNetStartSync)
    EventBus:RegisterCallback(self.Config.Network.Events.SyncPayload, self, self.OnNetSyncPayload)

    return self
end

function TheClassicRaceSync:InitSync()
    -- don't request updates when we know the race has finished
    if self.DB.factionrealm.finished then
        return
    end
    -- don't request updates when we've disabled networking
    if not self.DB.profile.options.networking then
        return
    end

    -- include our leaderboard hashes so partners can skip offering when already in sync
    local globalHash = TheClassicRace.Leaderboard.ComputeHash(self.DB.factionrealm.leaderboard[0])
    local classHash = TheClassicRace.Leaderboard.ComputeHash(
            self.DB.factionrealm.leaderboard[self.classIndex] or {players = {}})
    local payload = {self.classIndex, globalHash, classHash}

    self.Network:SendObject(self.Config.Network.Events.RequestSync, payload, "YELL")
    if IsInGuild() then
        self.Network:SendObject(self.Config.Network.Events.RequestSync, payload, "GUILD")
    end

    -- after 5s we attempt to sync with somebody who offered
    local _self = self
    C_Timer.After(self.Config.RequestSyncWait, function() _self:DoSync() end)
end

function TheClassicRaceSync:OnNetRequestSync(payload, sender)
    -- don't respond to requests when we've disabled networking
    if not self.DB.profile.options.networking then
        return
    end

    TheClassicRace:DebugPrint("OnNetRequestSync(" .. sender .. ") isReady=" .. tostring(self.isReady))
    -- if we're still in the process of syncing up ourselves then we shouldn't offer ourselves to sync with
    if not self.isReady then
        return
    end

    -- extract requester's classIndex and hashes (payload is a table in new clients, plain number in old)
    local requesterClassIndex, requesterGlobalHash, requesterClassHash
    if type(payload) == "table" then
        requesterClassIndex, requesterGlobalHash, requesterClassHash = payload[1], payload[2], payload[3]
    else
        requesterClassIndex = payload
    end

    -- compute our hashes to include in offer and to decide whether to offer at all
    local myGlobalHash = TheClassicRace.Leaderboard.ComputeHash(self.DB.factionrealm.leaderboard[0])
    local myClassHash = TheClassicRace.Leaderboard.ComputeHash(
            self.DB.factionrealm.leaderboard[self.classIndex] or {players = {}})

    -- skip offering if the requester already has identical data to us
    if requesterGlobalHash ~= nil and requesterGlobalHash == myGlobalHash then
        local classSyncNeeded = requesterClassIndex == self.classIndex
                and requesterClassHash ~= nil
                and requesterClassHash ~= myClassHash
        if not classSyncNeeded then
            TheClassicRace:DebugPrint("Skipping offer to " .. sender .. " (already in sync)")
            return
        end
    end

    self.Network:SendObject(self.Config.Network.Events.OfferSync,
            { self.classIndex, self.lastSync, myGlobalHash, myClassHash }, "WHISPER", sender)
end

function TheClassicRaceSync:OnNetOfferSync(offer, sender)
    local classIndex, lastSync, globalHash, classHash = offer[1], offer[2], offer[3], offer[4]
    TheClassicRace:DebugPrint("OnNetOfferSync(" .. sender .. ")")
    -- add anyone who offers to sync with us
    table.insert(self.offers, {name = sender, classIndex = classIndex, lastSync = lastSync,
                               globalHash = globalHash, classHash = classHash})
end

function TheClassicRaceSync:SelectPartner()
    -- we prefer to sync with same class without violating their throttle
    -- otherwise same class, but violate their throttle
    -- otherwise any class without violating their throttle
    -- otherwise any class, but voilate their throttle
    local now = self.Core:Now()
    local classIndex = self.classIndex
    local OfferSyncThrottle = self.Config.OfferSyncThrottle

    local offerModes = {"SAME_CLASS_THROTTLED", "SAME_CLASS", "THROTTLED", "ALL"}
    for _, offerMode in ipairs(offerModes) do
        local offers
        if offerMode == "SAME_CLASS_THROTTLED" then
            offers = TheClassicRace.list.filter(self.offers, function(offer)
                return offer.classIndex == classIndex and
                        (offer.lastSync == nil or offer.lastSync < now - OfferSyncThrottle)
            end)
        elseif offerMode == "SAME_CLASS" then
            offers = TheClassicRace.list.filter(self.offers, function(offer)
                return offer.classIndex == classIndex
            end)
        elseif offerMode == "THROTTLED" then
            offers = TheClassicRace.list.filter(self.offers, function(offer)
                return offer.lastSync == nil or offer.lastSync < now - OfferSyncThrottle
            end)
        else
            offers = self.offers
        end

        if #offers > 0 then
            return self:SelectPartnerFromList(offers)
        end
    end
end

function TheClassicRaceSync:SelectPartnerFromList(offers)
    -- select random offer
    local index = math.random(1, #offers)
    return table.remove(offers, index)
end

function TheClassicRaceSync:DoSync()
    -- no offers
    if #self.offers == 0 then
        TheClassicRace:DebugPrint("no sync partners")

        -- mark ourselves as synced up, otherwise nobody can ever sync
        self.isReady = true
        return
    end

    -- select a partner to sync with
    self.syncPartner = self:SelectPartner()

    -- remove the partner from the list of offers (in case we want to retry with another partner)
    self.offers = TheClassicRace.list.filter(self.offers, function(offer)
        return offer.name ~= self.syncPartner.name
    end)

    TheClassicRace:DebugPrint("DoSync(" .. self.syncPartner.name .. ")")

    -- compute our hashes to send and to decide what actually needs syncing
    local myGlobalHash = TheClassicRace.Leaderboard.ComputeHash(self.DB.factionrealm.leaderboard[0])
    local sameClass = self.syncPartner.classIndex == self.classIndex
    local myClassHash = sameClass and TheClassicRace.Leaderboard.ComputeHash(
            self.DB.factionrealm.leaderboard[self.classIndex] or {players = {}})

    local globalMatch = self.syncPartner.globalHash ~= nil and self.syncPartner.globalHash == myGlobalHash
    local classMatch = not sameClass
            or (self.syncPartner.classHash ~= nil and self.syncPartner.classHash == myClassHash)

    if globalMatch and classMatch then
        TheClassicRace:DebugPrint("Already in sync with " .. self.syncPartner.name)
        self.isReady = true
        return
    end

    -- include our hashes so the partner can also skip sending back leaderboards we already agree on
    self.Network:SendObject(self.Config.Network.Events.StartSync,
            {self.classIndex, myGlobalHash, myClassHash}, "WHISPER", self.syncPartner.name)

    -- check if we need to retry syncing after a short timeout
    local _self = self
    C_Timer.After(self.Config.RetrySyncWait, function()
        if not self.isReady then
            _self:DoSync()
        end
    end)

    -- only send leaderboards that the partner doesn't already have
    if not globalMatch then
        self:Sync(self.syncPartner.name, 0)
    end
    if sameClass and not classMatch then
        self:Sync(self.syncPartner.name, self.classIndex)
    end
end

function TheClassicRaceSync:Sync(syncTo, classIndex)
    local batchstr = TheClassicRace.Serializer.SerializePlayerInfoBatch(self.DB.factionrealm.leaderboard[classIndex].players)

    self.Network:SendObject(self.Config.Network.Events.SyncPayload, batchstr, "WHISPER", syncTo)
end

function TheClassicRaceSync:OnNetStartSync(payload, sender)
    TheClassicRace:DebugPrint("OnNetStartSync(" .. sender .. ")")

    -- extract requester's classIndex and hashes (new format: table, old format: plain classIndex)
    local requesterClassIndex, requesterGlobalHash, requesterClassHash
    if type(payload) == "table" then
        requesterClassIndex, requesterGlobalHash, requesterClassHash = payload[1], payload[2], payload[3]
    else
        requesterClassIndex = payload
    end

    -- mark last sync
    self.lastSync = self.Core:Now()

    -- only send leaderboards that the requester doesn't already have
    local myGlobalHash = TheClassicRace.Leaderboard.ComputeHash(self.DB.factionrealm.leaderboard[0])
    if requesterGlobalHash == nil or requesterGlobalHash ~= myGlobalHash then
        self:Sync(sender, 0)
    end

    if requesterClassIndex == self.classIndex then
        local myClassHash = TheClassicRace.Leaderboard.ComputeHash(
                self.DB.factionrealm.leaderboard[self.classIndex] or {players = {}})
        if requesterClassHash == nil or requesterClassHash ~= myClassHash then
            self:Sync(sender, self.classIndex)
        end
    end
end

function TheClassicRaceSync:OnNetSyncPayload(payload, sender)
    TheClassicRace:DebugPrint("OnNetSyncPayload(" .. sender .. ")")

    -- if we've requested sync data then we shouldn't broadcast what we receive because it should already have been spread
    -- if we're provided sync data then we should broadcast relevant info
    local shouldBroadcast = self.isReady

    local batch = TheClassicRace.Serializer.DeserializePlayerInfoBatch(payload)

    -- push into our eventbus
    self.EventBus:PublishEvent(self.Config.Events.SyncResult, batch, shouldBroadcast)

    -- mark ourselves as synced up
    if not self.isReady then
        TheClassicRace:DebugPrint("we're now synced up")
        self.isReady = true
    end
end

