-- Addon global
local TheClassicRace = _G.TheClassicRace

--[[
Leaderboard is responsible for maintaining our leaderboard data based on data provided by other parts of the system
to us through the EventBus.
]]--
---@class TheClassicRaceLeaderboard
---@field Config TheClassicRaceConfig
---@field leaderboard table<string, table>
local TheClassicRaceLeaderboard = {}
TheClassicRaceLeaderboard.__index = TheClassicRaceLeaderboard
TheClassicRace.Leaderboard = TheClassicRaceLeaderboard
setmetatable(TheClassicRaceLeaderboard, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

-- djb2 hash over all player entries in sorted order
function TheClassicRaceLeaderboard.ComputeHash(lbdb)
    local hash = 5381
    for _, player in ipairs(lbdb.players) do
        local entry = player.name .. player.level .. (player.classIndex or 0) .. math.floor(player.dingedAt or 0)
        for i = 1, #entry do
            hash = ((hash * 33) + string.byte(entry, i)) % 2147483647
        end
    end
    return hash
end

function TheClassicRaceLeaderboard.new(Config, leaderboardDB)
    local self = setmetatable({}, TheClassicRaceLeaderboard)

    self.Config = Config
    self.lbdb = leaderboardDB

    return self
end

--[[
ProcessPlayerInfo updates the leaderboard and triggers notifications accordingly
]]--
function TheClassicRaceLeaderboard:ProcessPlayerInfo(playerInfo)
    TheClassicRace:DebugPrint("[LB] ProcessPlayerInfo: " .. playerInfo.name .. " lvl" .. playerInfo.level)

    -- ignore players below our lower bound threshold
    if playerInfo.level < self.lbdb.minLevel then
        TheClassicRace:DebugPrint("Ignored player info < lvl" .. self.lbdb.minLevel)
        return
    end

    -- determine where to insert the player and his previous rank
    -- doing this O(n) isn't very efficient, but considering the small size of the leaderboard this is more than fine
    local insertAtRank = nil
    local previousRank = nil
    for rank, player in ipairs(self.lbdb.players) do
        -- find the place where to insert the new player
        -- sort by level desc, then by dingedAt asc, then by name asc (tiebreaker)
        -- the name tiebreaker ensures deterministic ordering across clients when
        -- multiple players share the same level and second-precision timestamp
        if insertAtRank == nil then
            if playerInfo.level > player.level then
                insertAtRank = rank
            elseif playerInfo.level == player.level
                    and playerInfo.dingedAt ~= nil
                    and player.dingedAt ~= nil then
                if playerInfo.dingedAt < player.dingedAt then
                    insertAtRank = rank
                elseif playerInfo.dingedAt == player.dingedAt
                        and playerInfo.name < player.name then
                    insertAtRank = rank
                end
            end
        end

        -- find a possibly previous entry of this player
        if previousRank == nil and playerInfo.name == player.name then
            previousRank = rank
        end
    end

    local isNew = previousRank == nil
    local isDing = not isNew and playerInfo.level > self.lbdb.players[previousRank].level
    local isDingedAtUpdate = not isNew and not isDing
            and playerInfo.dingedAt ~= nil
            and self.lbdb.players[previousRank].dingedAt ~= nil
            and playerInfo.dingedAt < self.lbdb.players[previousRank].dingedAt

    -- no change
    if not isNew and not isDing and not isDingedAtUpdate then
        return
    end

    -- grow the leaderboard up until the max size
    if insertAtRank == nil and #self.lbdb.players < self.Config.MaxLeaderboardSize then
        insertAtRank = #self.lbdb.players + 1
    end

    -- not high enough for leaderboard
    if insertAtRank == nil then
        return
    end

    -- remove from previous rank
    if previousRank ~= nil then
        table.remove(self.lbdb.players, previousRank)
    end

    -- add at new rank
    table.insert(self.lbdb.players, insertAtRank, {
        name = playerInfo.name,
        level = playerInfo.level,
        dingedAt = playerInfo.dingedAt,
        classIndex = playerInfo.classIndex,
    })

    -- truncate when leaderboard reached max size
    while #self.lbdb.players > self.Config.MaxLeaderboardSize do
        table.remove(self.lbdb.players)
    end

    -- we only care about levels >= our bottom ranked on the leaderboard
    local lowestLevel = self.lbdb.players[#self.lbdb.players].level
    if #self.lbdb.players >= self.Config.MaxLeaderboardSize then
        self.lbdb.minLevel = lowestLevel
    end

    -- update highest level
    self.lbdb.highestLevel = math.max(self.lbdb.highestLevel, playerInfo.level)

    return insertAtRank, isNew or isDing, lowestLevel
end