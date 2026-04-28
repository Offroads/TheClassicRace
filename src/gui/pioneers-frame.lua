-- Libs
local LibStub = _G.LibStub

-- Addon global
local TheClassicRace = _G.TheClassicRace

-- deps
local AceGUI = LibStub("AceGUI-3.0")

-- WoW API
local math = _G.math

local GRAY = "|cFF888888"

local function formatTimeSince(elapsed)
    elapsed = math.floor(math.max(0, elapsed))
    local s = elapsed % 60
    local m = math.floor(elapsed / 60) % 60
    local h = math.floor(elapsed / 3600) % 24
    local d = math.floor(elapsed / 86400)
    return string.format("%02d:%02d:%02d:%02d", d, h, m, s)
end

--[[
PioneersView renders the "Pioneers" tab inside the main status frame.
It shows, for each level from MaxLevel down to 2, which player was first detected
at that level (overall or filtered by class), along with how long after the race
start that happened.
]]--
---@class TheClassicRacePioneersView
---@field Config TheClassicRaceConfig
---@field Core TheClassicRaceCore
---@field DB table
local TheClassicRacePioneersView = {}
TheClassicRacePioneersView.__index = TheClassicRacePioneersView
TheClassicRace.PioneersView = TheClassicRacePioneersView
setmetatable(TheClassicRacePioneersView, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function TheClassicRacePioneersView.new(Config, Core, DB)
    local self = setmetatable({}, TheClassicRacePioneersView)
    self.Config = Config
    self.Core = Core
    self.DB = DB
    return self
end

function TheClassicRacePioneersView:Render(container, classIndex)
    container:ReleaseChildren()

    local WHITE = TheClassicRace.Colors.WHITE
    local ftl = self.DB.factionrealm.firstToLevel or {}
    local raceStartedAt = self.DB.factionrealm.raceStartedAt
    local levels = ftl[classIndex]

    local scrolltainer = AceGUI:Create("SimpleGroup")
    scrolltainer:SetLayout("Fill")
    scrolltainer:SetFullWidth(true)
    scrolltainer:SetFullHeight(true)
    container:AddChild(scrolltainer)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("Flow")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scrolltainer:AddChild(scroll)

    -- keep scrollbar clear of resize grip
    scroll.scrollbar:ClearAllPoints()
    scroll.scrollbar:SetPoint("TOPLEFT", scroll.scrollframe, "TOPRIGHT", 4, -16)
    scroll.scrollbar:SetPoint("BOTTOMLEFT", scroll.scrollframe, "BOTTOMRIGHT", 4, 32)

    local hasAnyData = false

    for lvl = self.Config.MaxLevel, 2, -1 do
        local label = AceGUI:Create("Label")
        label:SetFullWidth(true)

        local record = levels and levels[lvl]
        if record then
            hasAnyData = true
            local elapsed = raceStartedAt and (record.dingedAt - raceStartedAt) or 0
            local timeStr = formatTimeSince(elapsed)
            local playerClass = self.Core:ClassByIndex(record.classIndex)
            local color = TheClassicRace.Colors[playerClass] or WHITE
            label:SetText(timeStr .. " Lvl " .. string.format("%2d", lvl) .. ": " .. color .. record.name .. "|r")
        else
            label:SetText(GRAY .. "           Lvl " .. string.format("%2d", lvl) .. ": no data|r")
        end

        scroll:AddChild(label)
    end

    if not hasAnyData then
        -- insert a hint at the very top (already added all rows, prepend a note via first child)
        local hint = AceGUI:Create("Label")
        hint:SetFullWidth(true)
        hint:SetText(GRAY .. "No pioneer data yet — keep scanning!|r")
        scroll:AddChild(hint)
    end

    scroll:DoLayout()
end
