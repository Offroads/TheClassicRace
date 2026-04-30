local TheClassicRace = _G.TheClassicRace

local function dumpTable(o)
    if type(o) == "table" then
        local s = "{ "
        for k,v in pairs(o) do
            s = s .. "[" .. k .. "] = " .. dumpTable(v) .. ", "
        end
        return s .. "} "
    else
        return tostring(o)
    end
end

function TheClassicRace:Print(message)
    print("|cFFFFFFFF", message)
end

function TheClassicRace:SystemEventPrint(message)
    print(TheClassicRace.Colors.SYSTEM_EVENT_YELLOW, message)
end

function TheClassicRace:PPrint(message)
    print("|cFF7777FFTheClassicRace:|cFFFFFFFF", message)
end

function TheClassicRace:DebugPrint(message)
    local enabled = self.DB and self.DB.profile.options.debug or (not self.DB and self.Config.Debug)
    if enabled then
        print("|cFF7777FFTheClassicRace Debug:|cFFFFFFFF", message)
    end
end

function TheClassicRace:TracePrint(message)
    if (self.Config.Trace == true) then
        print("|cFF7777FFTheClassicRace Trace:|cFFFFFFFF", message)
    end
end

function TheClassicRace:DebugPrintTable(t)
    local enabled = self.DB and self.DB.profile.options.debug or (not self.DB and self.Config.Debug)
    if enabled then
        print("|cFF7777FFTheClassicRace Debug:|cFFFFFFFF table...")
        print(dumpTable(t))
    end
end

function TheClassicRace:TracePrintTable(t)
    if (self.Config.Trace == true) then
        print("|cFF7777FFTheClassicRace Trace:|cFFFFFFFF table...")
        print(dumpTable(t))
    end
end

-- Records a hash mismatch event into HashLog (newest first, capped at 12).
-- direction: ">" we sent data to sender, "<" we received data from sender.
-- classes: list of classIndex values that differed (0=global).
-- ftl: boolean, whether FTL also differed.
function TheClassicRace:AddHashLog(sender, direction, classes, ftl)
    if not self.DB or not self.DB.profile.options.debug then return end
    local GetServerTime = _G.GetServerTime
    table.insert(self.HashLog, 1, {
        time      = GetServerTime(),
        sender    = sender,
        direction = direction,
        classes   = classes or {},
        ftl       = ftl or false,
    })
    while #self.HashLog > 12 do table.remove(self.HashLog) end
    self.EventBus:PublishEvent(self.Config.Events.MsgStats)
end

function TheClassicRace:PlayerChatLink(playerName, linkTitle, className)
    if linkTitle == nil then
        linkTitle = playerName
    end

    local color = TheClassicRace.Colors.SYSTEM_EVENT_YELLOW
    if className ~= nil and TheClassicRace.Colors[className] ~= nil then
        color = TheClassicRace.Colors[className]
    end

    return color .. "|Hplayer:" .. playerName .. "|h[" .. linkTitle .. "]|h|r"
end