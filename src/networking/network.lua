-- Addon global
local TheClassicRace = _G.TheClassicRace

-- WoW API
local IsInRaid, GetNumGroupMembers = _G.IsInRaid, _G.GetNumGroupMembers

-- Libs
local LibStub = _G.LibStub
local Serializer = LibStub:GetLibrary("AceSerializer-3.0")
local AceComm = LibStub:GetLibrary("AceComm-3.0")
local LibCompress = LibStub:GetLibrary("LibCompress")
local EncodeTable = LibCompress:GetAddonEncodeTable()

local function debugLogPayload(event, payload)
    if event == TheClassicRace.Config.Network.Events.PlayerInfoBatch then
        local batchstr, isRebroadcast, classIndex = payload[1], payload[2], payload[3]
        local players = TheClassicRace.Serializer.DeserializePlayerInfoBatch(batchstr)
        TheClassicRace:DebugPrint("  rebroadcast=" .. tostring(isRebroadcast) ..
                " class=" .. tostring(classIndex or 0) .. " count=" .. #players)
        for _, p in ipairs(players) do
            TheClassicRace:DebugPrint("  " .. p.name .. " lvl" .. p.level .. " [" .. tostring(p.classIndex) .. "]")
        end
    elseif type(payload) == "table" then
        TheClassicRace:DebugPrintTable(payload)
    else
        TheClassicRace:DebugPrint("  payload: " .. tostring(payload))
    end
end

--[[
TheClassicRaceNetwork uses AceComm to send and receive messages over Addon channels
and broadcast them as events once received fully over our EventBus.
--]]
---@class TheClassicRaceNetwork
---@field Core TheClassicRaceCore
---@field EventBus TheClassicRaceEventBus
local TheClassicRaceNetwork = {}
TheClassicRaceNetwork.__index = TheClassicRaceNetwork
TheClassicRace.Network = TheClassicRaceNetwork

setmetatable(TheClassicRaceNetwork, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

---@param Core TheClassicRaceCore
---@param EventBus TheClassicRaceEventBus
function TheClassicRaceNetwork.new(Core, EventBus)
    local self = setmetatable({}, TheClassicRaceNetwork)

    self.Core = Core
    self.EventBus = EventBus

    AceComm:RegisterComm(TheClassicRace.Config.Network.Prefix, function(...)
        self:HandleAddonMessage(...)
    end)

    return self
end

function TheClassicRaceNetwork:Init()
    self.EventBus:PublishEvent(TheClassicRace.Config.Events.NetworkReady)
end

function TheClassicRaceNetwork:HandleAddonMessage(...)
    local prefix, message, _, sender = ...

    -- check if it's our prefix
    if prefix ~= TheClassicRace.Config.Network.Prefix then
        return
    end

    TheClassicRace:DebugPrint("Recv raw <- " .. tostring(sender))

    local ok, err = pcall(function()
        -- YELL gives "Name", GUILD/WHISPER give "Name-Realm" — split before comparing
        local senderName, senderRealm = self.Core:SplitFullPlayer(sender)

        -- completely ignore anything from other realms
        if not self.Core:IsMyRealm(senderRealm) then
            return
        end

        -- ignore our own messages regardless of whether realm is included in sender
        if senderName == self.Core:RealMe() then
            return
        end

        local decoded = EncodeTable:Decode(message)
        local decompressed, decomprErr = LibCompress:Decompress(decoded)
        if not decompressed then
            TheClassicRace:DebugPrint("Decompress error: " .. tostring(decomprErr))
            return
        end

        local ok2, object = Serializer:Deserialize(decompressed)
        if not ok2 then
            TheClassicRace:DebugPrint("Deserialize error: " .. tostring(object))
            return
        end

        local event, payload = object[1], object[2]

        TheClassicRace:TracePrint("Received Network Event: " .. event .. " From: " .. sender)
        TheClassicRace:DebugPrint("Recv " .. event .. " <- " .. sender)
        debugLogPayload(event, payload)

        self.EventBus:PublishEvent(event, payload, sender)
    end)

    if not ok then
        TheClassicRace:PPrint("Network receive error: " .. tostring(err))
    end
end

function TheClassicRaceNetwork:SendObject(event, object, channel, target, prio)
    if prio == nil then
        prio = "BULK"
    end

    local payload = Serializer:Serialize({event, object})
    local compressed = LibCompress:CompressHuffman(payload)
    local encoded = EncodeTable:Encode(compressed)

    TheClassicRace:TracePrint("Send Network Event: " .. event .. " Channel: " .. channel ..
            " Size: " .. string.len(encoded) .. " / " .. string.len(payload))
    TheClassicRace:DebugPrint("Send " .. event .. " -> " .. channel)
    debugLogPayload(event, object)

    if channel == "GROUP" then
        if IsInRaid() then
            AceComm:SendCommMessage(TheClassicRace.Config.Network.Prefix, encoded, "RAID", nil, prio)
        elseif GetNumGroupMembers() > 0 then
            AceComm:SendCommMessage(TheClassicRace.Config.Network.Prefix, encoded, "PARTY", nil, prio)
        end
        return
    end

    AceComm:SendCommMessage(
            TheClassicRace.Config.Network.Prefix,
            encoded,
            channel,
            target,
            prio)
end
