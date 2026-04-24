-- Addon global
local TheClassicRace = _G.TheClassicRace

-- WoW API
local C_FriendList = _G.C_FriendList
local CreateFrame = _G.CreateFrame
local WorldFrame = _G.WorldFrame
local GetTime = _G.GetTime

--[[
Scanner listens passively to WHO_LIST_UPDATE events and publishes results via EventBus.

SendWho() is a protected function in MoP Classic and cannot be called from timers or
any non-hardware-event context. TriggerScan() is therefore wired to hardware events:
  - WorldFrame OnMouseDown (every in-world click), with a 60s cooldown
  - The minimap icon's OnClick

This mirrors the CensusPlusClassic approach: piggyback on the player's existing
hardware events rather than requiring a dedicated UI button.
]]--
---@class TheClassicRaceScanner
local TheClassicRaceScanner = {}
TheClassicRaceScanner.__index = TheClassicRaceScanner
TheClassicRace.Scanner = TheClassicRaceScanner
setmetatable(TheClassicRaceScanner, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

local SCAN_COOLDOWN = 60  -- seconds between automatic scans

function TheClassicRaceScanner.new(Core, DB, EventBus)
    local self = setmetatable({}, TheClassicRaceScanner)

    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.lastScanTime = 0
    self.nextScanClassIdx = 1  -- cycles through MopClassIndexes

    self.whoFrame = CreateFrame("Frame")
    self.whoFrame:RegisterEvent("WHO_LIST_UPDATE")
    local _self = self
    self.whoFrame:SetScript("OnEvent", function(_, event)
        if event == "WHO_LIST_UPDATE" then
            _self:OnWhoListUpdate()
        end
    end)

    -- Piggyback on every in-world mouse click (hardware event) to drive periodic scans.
    -- TriggerScan enforces a cooldown so clicks don't spam /who.
    if WorldFrame then
        WorldFrame:HookScript("OnMouseDown", function()
            _self:TriggerScan()
        end)
    end

    return self
end

function TheClassicRaceScanner:InitTicker(offset)
end

function TheClassicRaceScanner:OnBumpScan(classIndex)
end

function TheClassicRaceScanner:OnWhoListUpdate()
    -- Restore FriendsFrame so manual /who works normally again
    local ff = _G.FriendsFrame
    if ff then ff:RegisterEvent("WHO_LIST_UPDATE") end

    if self.DB.factionrealm.finished then return end

    local total, numShown = C_FriendList.GetNumWhoResults()
    numShown = numShown or total
    if not numShown or numShown == 0 then return end

    local batch = {}
    for i = 1, numShown do
        local name, level, filename

        local info = C_FriendList.GetWhoInfo(i)
        if type(info) == "table" then
            name     = info.fullName
            level    = tonumber(info.level)
            filename = info.filename
        else
            -- Positional API fallback: charName, guild, charLevel, race, class, zone, filename, gender
            local charName, _, charLevel, _, _, _, charFilename = C_FriendList.GetWhoInfo(i)
            name     = charName
            level    = tonumber(charLevel)
            filename = charFilename
        end

        if name and level and level > 1 then
            local playerName = self.Core:SplitFullPlayer(name)
            table.insert(batch, {
                name  = playerName,
                level = level,
                class = filename and string.upper(filename) or nil,
            })
        end
    end

    if #batch == 0 then return end

    if #batch > 1 then
        table.sort(batch, function(a, b) return a.level > b.level end)
    end

    self.EventBus:PublishEvent(TheClassicRace.Config.Events.SlashWhoResult, batch, self.classIndex)
end

-- TriggerScan sends a /who query for the next class leaderboard that isn't full.
-- Once all class leaderboards reach 50 players it falls back to a global level scan.
-- MUST be called from a hardware event context (mouse click, key press).
-- Safe to call frequently — enforces a 60s cooldown internally.
function TheClassicRaceScanner:TriggerScan()
    if self.DB.factionrealm.finished then return end

    local now = GetTime()
    if now - self.lastScanTime < SCAN_COOLDOWN then return end
    self.lastScanTime = now

    local maxLevel   = TheClassicRace.Config.MaxLevel
    local maxSize    = TheClassicRace.Config.MaxLeaderboardSize
    local validIdx   = TheClassicRace.Config.MopClassIndexes
    local numClasses = #validIdx
    local query      = nil

    -- Cycle through classes, find the next one that still needs filling
    for i = 0, numClasses - 1 do
        local slot       = ((self.nextScanClassIdx - 1 + i) % numClasses) + 1
        local classIndex = validIdx[slot]
        local classLb    = self.DB.factionrealm.leaderboard[classIndex]
        local className  = TheClassicRace.Config.Classes[classIndex]
        local filter     = TheClassicRace.Config.WhoClassFilter[className]

        if filter and classLb and #classLb.players < maxSize then
            self.nextScanClassIdx = (slot % numClasses) + 1

            local numPlayers = #classLb.players
            local scanMin
            if numPlayers > 0 then
                -- scan from lowest known player's level upward
                scanMin = classLb.players[numPlayers].level
                if scanMin >= maxLevel then scanMin = maxLevel - 1 end
            else
                scanMin = maxLevel - 20
            end

            query = tostring(scanMin) .. "-" .. tostring(maxLevel) .. " c-" .. filter
            break
        end
    end

    -- All class leaderboards full: scan by global top range
    if not query then
        local lb      = self.DB.factionrealm.leaderboard[0]
        local scanMin = math.max(lb.minLevel, lb.highestLevel)
        if scanMin <= 1 then scanMin = maxLevel - 10 end
        if scanMin >= maxLevel then scanMin = maxLevel - 1 end
        query = tostring(scanMin) .. "-" .. tostring(maxLevel)
    end

    TheClassicRace:PPrint("Scanning /who " .. query)

    if C_FriendList then
        local ff = _G.FriendsFrame
        if ff then ff:UnregisterEvent("WHO_LIST_UPDATE") end
        if C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(true) end
        if C_FriendList.SendWho then C_FriendList.SendWho(query) end
    end
end
