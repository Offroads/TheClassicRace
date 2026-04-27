-- Addon global
local TheClassicRace = _G.TheClassicRace

-- WoW API
local C_Timer, IsInGuild, math = _G.C_Timer, _G.IsInGuild, _G.math

-- djb2 chain over all leaderboards — mirrors Tracker:ComputeFullHash without a cross-component dependency
local function computeFullHash(db, config)
    local hash = 5381
    for classIndex = 0, #config.Classes do
        local lb = db.factionrealm.leaderboard[classIndex]
        if lb then
            hash = ((hash * 33) + TheClassicRace.Leaderboard.ComputeHash(lb)) % 2147483647
        end
    end
    return hash
end

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
    self.guildOffers = nil  -- non-nil only during active guild sync window

    EventBus:RegisterCallback(self.Config.Network.Events.RequestSync, self, self.OnNetRequestSync)
    EventBus:RegisterCallback(self.Config.Network.Events.OfferSync, self, self.OnNetOfferSync)
    EventBus:RegisterCallback(self.Config.Network.Events.StartSync, self, self.OnNetStartSync)
    EventBus:RegisterCallback(self.Config.Network.Events.SyncPayload, self, self.OnNetSyncPayload)
    EventBus:RegisterCallback(self.Config.Network.Events.GuildSync, self, self.OnNetGuildSync)
    EventBus:RegisterCallback(self.Config.Network.Events.GuildOffer, self, self.OnNetGuildOffer)
    EventBus:RegisterCallback(self.Config.Network.Events.BuddyPing, self, self.OnNetBuddyPing)
    EventBus:RegisterCallback(self.Config.Network.Events.BuddyPong, self, self.OnNetBuddyPong)

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

    -- after 5s we attempt to sync with somebody who offered via YELL
    local _self = self
    C_Timer.After(self.Config.RequestSyncWait, function() _self:DoSync() end)

    -- guild sync: announce to GUILD and pick the longest-uptime partner after GuildSyncWait+1s
    self:SendGuildSync()
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
    self:AddBuddy(sender)
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

function TheClassicRaceSync:SetReady()
    if not self.isReady then
        self.isReady = true
        self:SendBuddyPings()
    end
end

function TheClassicRaceSync:DoSync()
    -- no offers
    if #self.offers == 0 then
        TheClassicRace:DebugPrint("no sync partners")

        -- mark ourselves as synced up, otherwise nobody can ever sync
        self:SetReady()
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
        self:SetReady()
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
    self.lastSync = self.Core:Now()

    local requesterClassIndex, requesterGlobalHash, requesterClassHash
    if type(payload) == "table" then
        requesterClassIndex = payload[1]

        if type(payload[2]) == "table" then
            -- guild sync: payload[2] is per-class hashes — send every leaderboard that differs
            local perClassHashes = payload[2]
            for classIndex = 0, #self.Config.Classes do
                local lb = self.DB.factionrealm.leaderboard[classIndex]
                if lb and #lb.players > 0 then
                    local myHash = TheClassicRace.Leaderboard.ComputeHash(lb)
                    if myHash ~= (perClassHashes[classIndex + 1] or 0) then
                        self:Sync(sender, classIndex)
                    end
                end
            end
            return
        end

        -- zone sync: payload[2] is globalHash, payload[3] is classHash
        requesterGlobalHash, requesterClassHash = payload[2], payload[3]
    else
        requesterClassIndex = payload
    end

    -- only send global + own class (zone sync path)
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

    local batch = TheClassicRace.Serializer.DeserializePlayerInfoBatch(payload)

    self.EventBus:PublishEvent(self.Config.Events.SyncResult, batch)

    -- mark ourselves as synced up
    if not self.isReady then
        TheClassicRace:DebugPrint("we're now synced up")
        self:SetReady()
    end
end

-- Periodic guild sync ticker: re-runs the guild sync flow every GuildSyncInterval seconds.
-- Only fires once we're ready (initial zone sync complete).
function TheClassicRaceSync:InitGuildTicker()
    local _self = self
    C_Timer.NewTicker(self.Config.GuildSyncInterval, function()
        if _self.isReady then
            _self:SendGuildSync()
        end
    end)
end

-- Announce our presence to the guild and open a window for offers.
-- Used both on login (called from InitSync) and by the periodic ticker.
function TheClassicRaceSync:SendGuildSync()
    if not IsInGuild() then return end
    if not self.DB.profile.options.networking then return end
    if self.DB.factionrealm.finished then return end

    self.guildOffers = {}

    local fullHash = computeFullHash(self.DB, self.Config)
    self.Network:SendObject(self.Config.Network.Events.GuildSync,
            {self.classIndex, fullHash, self.Core:LoginTime()}, "GUILD")

    local _self = self
    C_Timer.After(self.Config.GuildSyncWait + 1, function()
        _self:DoGuildSync()
    end)
end

-- Received when another guild member announces via GuildSync.
-- If our data differs, whisper back an offer after a random delay to spread load.
function TheClassicRaceSync:OnNetGuildSync(payload, sender)
    if not self.DB.profile.options.networking then return end
    if not self.isReady then return end

    local _, requesterFullHash, _ = payload[1], payload[2], payload[3]

    local myFullHash = computeFullHash(self.DB, self.Config)
    if myFullHash == requesterFullHash then return end

    local delay = math.random(0, self.Config.GuildSyncWait)
    local _self = self
    C_Timer.After(delay, function()
        local myGlobalHash = TheClassicRace.Leaderboard.ComputeHash(_self.DB.factionrealm.leaderboard[0])
        local myClassHash = TheClassicRace.Leaderboard.ComputeHash(
                _self.DB.factionrealm.leaderboard[_self.classIndex] or {players = {}})
        _self.Network:SendObject(_self.Config.Network.Events.GuildOffer,
                {_self.classIndex, _self.lastSync, myFullHash, myGlobalHash, myClassHash, _self.Core:LoginTime()},
                "WHISPER", sender)
    end)
end

-- Collect guild offers during the open window.
function TheClassicRaceSync:OnNetGuildOffer(offer, sender)
    if self.guildOffers == nil then return end
    local classIndex, lastSync, fullHash, globalHash, classHash, loginTime =
            offer[1], offer[2], offer[3], offer[4], offer[5], offer[6]
    TheClassicRace:DebugPrint("GuildOffer from " .. sender)
    table.insert(self.guildOffers, {
        name = sender, classIndex = classIndex, lastSync = lastSync,
        fullHash = fullHash, globalHash = globalHash, classHash = classHash, loginTime = loginTime,
    })
end

-- Add or update a buddy entry in the persistent DB list.
function TheClassicRaceSync:AddBuddy(name)
    if name == self.Core:FullRealMe() then return end
    local buddies = self.DB.factionrealm.buddies
    if not buddies[name] then
        buddies[name] = {}
    end
    buddies[name].lastSeen = self.Core:Now()
    TheClassicRace:DebugPrint("Buddy: added/updated " .. name)
end

-- Send BPING to up to BuddyPingBatchSize buddies (random sample if more).
function TheClassicRaceSync:SendBuddyPings()
    if not self.isReady then return end
    if self.DB.factionrealm.finished then return end
    if not self.DB.profile.options.networking then return end

    local names = {}
    for name, _ in pairs(self.DB.factionrealm.buddies) do
        names[#names + 1] = name
    end
    if #names == 0 then return end

    local batchSize = self.Config.BuddyPingBatchSize
    local selected = names
    if #names > batchSize then
        selected = {}
        for i = 1, batchSize do
            local j = math.random(i, #names)
            names[i], names[j] = names[j], names[i]
            selected[i] = names[i]
        end
    end

    local myFullHash = computeFullHash(self.DB, self.Config)
    local myPerClassHashes = {}
    for classIndex = 0, #self.Config.Classes do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        myPerClassHashes[classIndex + 1] = lb and TheClassicRace.Leaderboard.ComputeHash(lb) or 0
    end
    local payload = {myFullHash, myPerClassHashes}

    TheClassicRace:DebugPrint("BuddyPing: pinging " .. #selected .. " of " .. #names .. " buddies")
    for _, name in ipairs(selected) do
        self.Network:SendObject(self.Config.Network.Events.BuddyPing, payload, "WHISPER", name)
    end
end

-- Received BPING from a buddy: update their last-seen, push leaderboards they're missing, ack with BPONG.
-- BPONG includes our own hashes so the sender can also push what we're missing (bidirectional in one round trip).
function TheClassicRaceSync:OnNetBuddyPing(payload, sender)
    if not self.DB.profile.options.networking then return end
    self:AddBuddy(sender)

    local myFullHash = computeFullHash(self.DB, self.Config)
    local myPerClassHashes = {}
    for classIndex = 0, #self.Config.Classes do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        myPerClassHashes[classIndex + 1] = lb and TheClassicRace.Leaderboard.ComputeHash(lb) or 0
    end

    -- always ack with our hashes so the sender knows we're online and can push back
    self.Network:SendObject(self.Config.Network.Events.BuddyPong,
            {myFullHash, myPerClassHashes}, "WHISPER", sender)

    if not self.isReady then return end

    local senderFullHash = payload[1]
    if myFullHash == senderFullHash then return end

    local senderPerClassHashes = payload[2]
    for classIndex = 0, #self.Config.Classes do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        if lb and #lb.players > 0 then
            local myHash = myPerClassHashes[classIndex + 1]
            local theirHash = senderPerClassHashes and senderPerClassHashes[classIndex + 1] or 0
            if myHash ~= theirHash then
                self:Sync(sender, classIndex)
            end
        end
    end
end

-- Received BPONG from a buddy: update their last-seen, push any leaderboards they're missing.
function TheClassicRaceSync:OnNetBuddyPong(payload, sender)
    self:AddBuddy(sender)
    TheClassicRace:DebugPrint("BuddyPong from " .. sender)

    if not self.isReady then return end

    local senderFullHash = payload[1]
    if not senderFullHash then return end

    local myFullHash = computeFullHash(self.DB, self.Config)
    if myFullHash == senderFullHash then return end

    local senderPerClassHashes = payload[2]
    for classIndex = 0, #self.Config.Classes do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        if lb and #lb.players > 0 then
            local myHash = TheClassicRace.Leaderboard.ComputeHash(lb)
            local theirHash = senderPerClassHashes and senderPerClassHashes[classIndex + 1] or 0
            if myHash ~= theirHash then
                self:Sync(sender, classIndex)
            end
        end
    end
end

-- Start the periodic buddy ping ticker.
function TheClassicRaceSync:InitBuddyTicker()
    local _self = self
    C_Timer.NewTicker(self.Config.BuddySyncInterval, function()
        _self:SendBuddyPings()
    end)
end

-- Called after the guild offer window closes.
-- Picks the offer with the lowest loginTime (longest uptime = most authoritative)
-- and requests all missing leaderboards from that partner via STARTSYNC with per-class hashes.
function TheClassicRaceSync:DoGuildSync()
    local offers = self.guildOffers
    self.guildOffers = nil

    if not offers or #offers == 0 then
        TheClassicRace:DebugPrint("Guild sync: no offers")
        return
    end

    -- pick longest-uptime partner (lowest loginTime)
    local best = offers[1]
    for _, offer in ipairs(offers) do
        if offer.loginTime ~= nil and (best.loginTime == nil or offer.loginTime < best.loginTime) then
            best = offer
        end
    end

    TheClassicRace:DebugPrint("DoGuildSync with " .. best.name)

    -- sanity check: if full hashes match now, nothing to do
    if best.fullHash == computeFullHash(self.DB, self.Config) then
        TheClassicRace:DebugPrint("Already in sync with guild partner " .. best.name)
        return
    end

    -- send per-class hashes so the partner knows exactly which leaderboards to send back
    local myPerClassHashes = {}
    for classIndex = 0, #self.Config.Classes do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        myPerClassHashes[classIndex + 1] = lb and TheClassicRace.Leaderboard.ComputeHash(lb) or 0
    end

    self.Network:SendObject(self.Config.Network.Events.StartSync,
            {self.classIndex, myPerClassHashes}, "WHISPER", best.name)
end

