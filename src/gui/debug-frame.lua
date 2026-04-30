-- Libs
local LibStub = _G.LibStub

-- Addon global
local TheClassicRace = _G.TheClassicRace

-- deps
local AceGUI = LibStub("AceGUI-3.0")

-- WoW API
local GetServerTime, math = _G.GetServerTime, _G.math

local WHITE = "|cffffffff"
local YELLOW = "|cffffff00"
local GRAY  = "|cff888888"
local DIM   = "|cff555555"

local COL_EVENT = 165
local COL_COUNT = 57

-- Human-readable names for network event codes
local EVENT_NAMES = {
    PINFOB    = "PlayerInfoBatch",
    REQSYNC   = "RequestSync",
    OFFERSYNC = "OfferSync",
    STARTSYNC = "StartSync",
    SYNC      = "SyncPayload",
    DATAAVAIL = "DataAvail",
    DATAREQ   = "DataRequest",
    GUILDSYNC = "GuildSync",
    GUILDOFFR = "GuildOffer",
    BPING     = "BuddyPing",
    BPONG     = "BuddyPong",
    FTLSYNC   = "FTLSync",
}

local function formatAge(timestamp)
    if not timestamp then return "never" end
    local diff = GetServerTime() - timestamp
    if diff < 60 then
        return diff .. "s ago"
    elseif diff < 3600 then
        return math.floor(diff / 60) .. "m ago"
    else
        return math.floor(diff / 3600) .. "h ago"
    end
end

---@class TheClassicRaceDebugFrame
local TheClassicRaceDebugFrame = {}
TheClassicRaceDebugFrame.__index = TheClassicRaceDebugFrame
TheClassicRace.DebugFrame = TheClassicRaceDebugFrame
setmetatable(TheClassicRaceDebugFrame, {
    __call = function(cls, ...) return cls.new(...) end,
})

function TheClassicRaceDebugFrame.new(Config, Core, DB, EventBus)
    local self = setmetatable({}, TheClassicRaceDebugFrame)
    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.frame = nil
    self.scroll = nil

    local _self = self
    EventBus:RegisterCallback(Config.Events.MsgStats, self, function() _self:Render() end)
    EventBus:RegisterCallback(Config.Events.BuddyUpdate, self, function() _self:Render() end)

    return self
end

function TheClassicRaceDebugFrame:Hide()
    if self.frame then
        self.frame:Hide()
        self.frame:Release()
        self.frame = nil
        self.scroll = nil
    end
end

function TheClassicRaceDebugFrame:Show()
    if self.frame then
        self.frame:Hide()
        self.frame:Release()
        self.frame = nil
        self.scroll = nil
    end

    local _self = self

    local frame = AceGUI:Create("Window")
    frame:SetTitle("TCR Debug")
    frame:SetWidth(320)
    frame:SetHeight(480)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget)
        widget:Release()
        _self.frame = nil
        _self.scroll = nil
    end)
    self.frame = frame

    local pingBtn = AceGUI:Create("Button")
    pingBtn:SetText("Ping Buddies")
    pingBtn:SetWidth(150)
    pingBtn:SetCallback("OnClick", function()
        TheClassicRace.Sync:SendBuddyPings()
        _self:Render()
    end)
    frame:AddChild(pingBtn)

    local clearBtn = AceGUI:Create("Button")
    clearBtn:SetText("Clear Buddies")
    clearBtn:SetWidth(150)
    clearBtn:SetCallback("OnClick", function()
        _self.DB.factionrealm.buddies = {}
        _self:Render()
    end)
    frame:AddChild(clearBtn)

    local resetStatsBtn = AceGUI:Create("Button")
    resetStatsBtn:SetText("Reset Stats")
    resetStatsBtn:SetWidth(150)
    resetStatsBtn:SetCallback("OnClick", function()
        TheClassicRace.MsgStats = { send = {}, recv = {} }
        _self:Render()
    end)
    frame:AddChild(resetStatsBtn)

    local scrolltainer = AceGUI:Create("SimpleGroup")
    scrolltainer:SetLayout("Fill")
    scrolltainer:SetFullWidth(true)
    scrolltainer:SetFullHeight(true)
    frame:AddChild(scrolltainer)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("Flow")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scrolltainer:AddChild(scroll)
    self.scroll = scroll

    self:Render()
end

-- Adds a 3-column table row to the scroll container.
function TheClassicRaceDebugFrame:AddRow(col1, col2, col3, col1Color, col2Color, col3Color)
    local nameLabel = AceGUI:Create("Label")
    nameLabel:SetWidth(COL_EVENT)
    nameLabel:SetText((col1Color or WHITE) .. col1 .. "|r")
    self.scroll:AddChild(nameLabel)

    local sentLabel = AceGUI:Create("Label")
    sentLabel:SetWidth(COL_COUNT)
    sentLabel:SetText((col2Color or WHITE) .. col2 .. "|r")
    sentLabel:SetJustifyH("RIGHT")
    self.scroll:AddChild(sentLabel)

    local recvLabel = AceGUI:Create("Label")
    recvLabel:SetWidth(COL_COUNT)
    recvLabel:SetText((col3Color or WHITE) .. col3 .. "|r")
    recvLabel:SetJustifyH("RIGHT")
    self.scroll:AddChild(recvLabel)
end

function TheClassicRaceDebugFrame:AddSeparator()
    local sep = AceGUI:Create("Label")
    sep:SetFullWidth(true)
    sep:SetText(DIM .. string.rep("\xe2\x94\x80", 36) .. "|r")
    self.scroll:AddChild(sep)
end

function TheClassicRaceDebugFrame:AddSpacer()
    local spacer = AceGUI:Create("Label")
    spacer:SetFullWidth(true)
    spacer:SetText(" ")
    self.scroll:AddChild(spacer)
end

function TheClassicRaceDebugFrame:Render()
    if not self.scroll then return end
    self.scroll:ReleaseChildren()
    self:RenderMsgStats()
    self:RenderBuddies()
    self.scroll:DoLayout()
end

function TheClassicRaceDebugFrame:RenderMsgStats()
    local stats = TheClassicRace.MsgStats
    if not stats then return end

    -- collect union of all event types seen
    local allEvents = {}
    local seen = {}
    for event in pairs(stats.send) do
        if not seen[event] then seen[event] = true; allEvents[#allEvents + 1] = event end
    end
    for event in pairs(stats.recv) do
        if not seen[event] then seen[event] = true; allEvents[#allEvents + 1] = event end
    end
    table.sort(allEvents)

    -- header row
    self:AddRow("Message Type", "Sent", "Recv", YELLOW, YELLOW, YELLOW)
    self:AddSeparator()

    if #allEvents == 0 then
        local none = AceGUI:Create("Label")
        none:SetFullWidth(true)
        none:SetText(GRAY .. "no messages yet|r")
        self.scroll:AddChild(none)
    else
        local totalSend, totalRecv = 0, 0
        for _, event in ipairs(allEvents) do
            local s = stats.send[event] or 0
            local r = stats.recv[event] or 0
            totalSend = totalSend + s
            totalRecv = totalRecv + r
            local name = EVENT_NAMES[event] or event
            local sColor = s > 0 and WHITE or GRAY
            local rColor = r > 0 and WHITE or GRAY
            self:AddRow(name, tostring(s), tostring(r), WHITE, sColor, rColor)
        end

        self:AddSeparator()
        self:AddRow("Total", tostring(totalSend), tostring(totalRecv), YELLOW, YELLOW, YELLOW)
    end

    self:AddSpacer()
end

function TheClassicRaceDebugFrame:RenderBuddies()
    local buddies = self.DB.factionrealm.buddies

    local list = {}
    for name, info in pairs(buddies) do
        list[#list + 1] = { name = name, lastSeen = info.lastSeen }
    end
    table.sort(list, function(a, b)
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)

    local buddyHeader = AceGUI:Create("Label")
    buddyHeader:SetFullWidth(true)
    buddyHeader:SetText(YELLOW .. "Buddies: " .. #list .. "|r")
    self.scroll:AddChild(buddyHeader)

    self:AddSeparator()

    for _, buddy in ipairs(list) do
        local label = AceGUI:Create("Label")
        label:SetFullWidth(true)
        label:SetText(WHITE .. buddy.name .. "  " .. GRAY .. formatAge(buddy.lastSeen) .. "|r")
        self.scroll:AddChild(label)
    end
end
