-- Libs
local LibStub = _G.LibStub

-- Addon global
local TheClassicRace = _G.TheClassicRace

-- deps
local AceGUI = LibStub("AceGUI-3.0")

-- WoW API
local GetServerTime, math = _G.GetServerTime, _G.math

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

function TheClassicRaceDebugFrame.new(Config, Core, DB)
    local self = setmetatable({}, TheClassicRaceDebugFrame)
    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.frame = nil
    self.scroll = nil
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
    frame:SetTitle("TCR Buddies")
    frame:SetWidth(320)
    frame:SetHeight(420)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget)
        widget:Release()
        _self.frame = nil
        _self.scroll = nil
    end)
    self.frame = frame

    local pingBtn = AceGUI:Create("Button")
    pingBtn:SetText("Ping Now")
    pingBtn:SetWidth(150)
    pingBtn:SetCallback("OnClick", function()
        TheClassicRace.Sync:SendBuddyPings()
        _self:Render()
    end)
    frame:AddChild(pingBtn)

    local clearBtn = AceGUI:Create("Button")
    clearBtn:SetText("Clear List")
    clearBtn:SetWidth(150)
    clearBtn:SetCallback("OnClick", function()
        _self.DB.factionrealm.buddies = {}
        _self:Render()
    end)
    frame:AddChild(clearBtn)

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

function TheClassicRaceDebugFrame:Render()
    if not self.scroll then return end
    self.scroll:ReleaseChildren()

    local buddies = self.DB.factionrealm.buddies

    local list = {}
    for name, info in pairs(buddies) do
        list[#list + 1] = { name = name, lastSeen = info.lastSeen }
    end
    table.sort(list, function(a, b)
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)

    local header = AceGUI:Create("Label")
    header:SetFullWidth(true)
    header:SetText("|cffffff00Buddies: " .. #list .. "|r")
    self.scroll:AddChild(header)

    for _, buddy in ipairs(list) do
        local label = AceGUI:Create("Label")
        label:SetFullWidth(true)
        label:SetText(buddy.name .. "  |cff888888" .. formatAge(buddy.lastSeen) .. "|r")
        self.scroll:AddChild(label)
    end

    self.scroll:DoLayout()
end
