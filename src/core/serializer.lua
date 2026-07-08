-- Addon global
local TheClassicRace = _G.TheClassicRace

--[[
]]--
---@class TheClassicRaceSerializer
---@field Config TheClassicRaceConfig
local TheClassicRaceSerializer = {}
TheClassicRace.Serializer = TheClassicRaceSerializer

function TheClassicRaceSerializer.SerializePlayerInfo(playerInfo, dingedAtOffset)
    local level = playerInfo.level
    local classIndex = playerInfo.classIndex

    -- ensure level is always zero padded to 2 digits
    if level < 10 then
        level = "0" .. level
    end

    return level ..
            classIndex ..
            playerInfo.name ..
            -- apply offset
            playerInfo.dingedAt - (dingedAtOffset or 0)
end

function TheClassicRaceSerializer.DeserializePlayerInfo(str, dingedAtOffset)
    -- split string by regex
    -- name is non numeric and not a minus
    -- dingedAt is number with potentially a minus
    local lvlandClass, name, dingedAt = string.match(str, "(%d+)([^%d-]+)(%-?%d+)")

    -- level is always 2 digits
    local level = tonumber(string.sub(lvlandClass, 1, 2))
    -- class index can be 1 or 2 digits
    local classIndex = tonumber(string.sub(lvlandClass, 3))

    return {
        name = name,
        level = level,
        classIndex = classIndex,
        -- apply offset
        dingedAt = tonumber(dingedAt) + (dingedAtOffset or 0),
    }
end

function TheClassicRaceSerializer.SerializePlayerInfoBatch(playerInfoBatch)
    if #playerInfoBatch == 0 then
        return ""
    end

    -- determine offset by finding lowest dingedAt
    local dingedAtOffset = nil
    for _, playerInfo in ipairs(playerInfoBatch) do
        if dingedAtOffset == nil then
            dingedAtOffset = playerInfo.dingedAt
        else
            dingedAtOffset = math.min(dingedAtOffset, playerInfo.dingedAt)
        end
    end

    dingedAtOffset = math.floor(dingedAtOffset)

    -- build payload
    -- zero pad offset (for tests with low timestamps)
    local res = string.sub("0000000000" .. dingedAtOffset, -10) .. "$"
    for _, playerInfo in ipairs(playerInfoBatch) do
        res = res .. TheClassicRaceSerializer.SerializePlayerInfo(playerInfo, dingedAtOffset) .. "$"
    end

    return res
end

function TheClassicRaceSerializer.DeserializePlayerInfoBatch(str)
    if str == "" then
        return {}
    end

    -- grab dingedAt from start, should always be 11 digits
    local dingedAtOffset = tonumber(string.sub(str, 1, 10))
    -- chunk off the dingedAt and $ seperator
    str = string.sub(str, 12)

    -- split the rest on $ and deserialize each record
    local res = {}
    for substr in string.gmatch(str, "([^$]+$)") do
        res[#res + 1] = TheClassicRaceSerializer.DeserializePlayerInfo(substr, dingedAtOffset)
    end

    return res
end

-- Serializes firstToLevel into a compact string.
-- firstToLevel[classFilter][level] = {name, classIndex, dingedAt}
-- Record format per entry: CF(2) LV(2) CI(2) name dingedAtDelta $
function TheClassicRaceSerializer.SerializeFTLBatch(firstToLevel)
    local entries = {}
    for classFilter, levels in pairs(firstToLevel) do
        for level, record in pairs(levels) do
            -- only entries that fit the 2-digit wire format; level 1 is not a ding
            if record.dingedAt ~= nil
                    and level >= 2 and level <= 99
                    and classFilter >= 0 and classFilter <= 99 then
                entries[#entries + 1] = {
                    classFilter = classFilter,
                    level = level,
                    name = record.name,
                    classIndex = record.classIndex or 0,
                    dingedAt = record.dingedAt,
                }
            end
        end
    end

    if #entries == 0 then
        return ""
    end

    local offset = entries[1].dingedAt
    for _, e in ipairs(entries) do
        if e.dingedAt < offset then offset = e.dingedAt end
    end
    offset = math.floor(offset)

    local res = string.sub("0000000000" .. offset, -10) .. "$"
    for _, e in ipairs(entries) do
        res = res
            .. string.format("%02d", e.classFilter)
            .. string.format("%02d", e.level)
            .. string.format("%02d", e.classIndex)
            .. e.name
            .. (math.floor(e.dingedAt) - offset)
            .. "$"
    end

    return res
end

-- Serializes playerHistory for the given player names into chunk strings of at most
-- chunkSize players each. Each chunk is independently parseable (own offset header)
-- so partial delivery of a multi-chunk sync still merges cleanly.
-- Chunk format: offset(10) $ record $ record $ ...
-- Record format: classIndex(2) name (":" level(2) delta)+
-- playerHistory[name] = {classIndex = ci, levels = {[level] = dingedAt}}
function TheClassicRaceSerializer.SerializePlayerHistoryChunks(playerHistory, names, chunkSize)
    -- collect valid records first: players with at least one level that fits the wire format
    local records = {}
    for _, name in ipairs(names) do
        local hist = playerHistory[name]
        if hist ~= nil and hist.levels ~= nil then
            local levels = {}
            for level, dingedAt in pairs(hist.levels) do
                if level >= 2 and level <= 99 and dingedAt ~= nil then
                    levels[#levels + 1] = {level = level, dingedAt = math.floor(dingedAt)}
                end
            end
            if #levels > 0 then
                table.sort(levels, function(a, b) return a.level < b.level end)
                records[#records + 1] = {name = name, classIndex = hist.classIndex or 0, levels = levels}
            end
        end
    end

    local chunks = {}
    for chunkStart = 1, #records, chunkSize do
        local chunkEnd = math.min(chunkStart + chunkSize - 1, #records)

        local offset = nil
        for i = chunkStart, chunkEnd do
            for _, entry in ipairs(records[i].levels) do
                if offset == nil or entry.dingedAt < offset then offset = entry.dingedAt end
            end
        end

        local res = string.sub("0000000000" .. offset, -10) .. "$"
        for i = chunkStart, chunkEnd do
            local record = records[i]
            local str = string.format("%02d", record.classIndex) .. record.name
            for _, entry in ipairs(record.levels) do
                str = str .. ":" .. string.format("%02d", entry.level) .. (entry.dingedAt - offset)
            end
            res = res .. str .. "$"
        end
        chunks[#chunks + 1] = res
    end

    return chunks
end

-- Deserializes a single playerHistory chunk produced by SerializePlayerHistoryChunks.
-- Returns {[name] = {classIndex = ci, levels = {[level] = dingedAt}}}.
function TheClassicRaceSerializer.DeserializePlayerHistoryBatch(str)
    if str == "" then
        return {}
    end

    local offset = tonumber(string.sub(str, 1, 10))
    str = string.sub(str, 12)

    local batch = {}
    for substr in string.gmatch(str, "([^$]+)") do
        -- record: classIndex(2) name, then one or more ":" level(2) delta groups
        local ci, name, levelstr = string.match(substr, "^(%d%d)([^:]+)(:.+)$")
        if ci and name and levelstr then
            local levels = {}
            local count = 0
            for lv, delta in string.gmatch(levelstr, ":(%d%d)(%d+)") do
                local level = tonumber(lv)
                local dingedAt = tonumber(delta) + offset
                -- level 1 is not a ding — ignore malformed remote entries
                if level >= 2 and (levels[level] == nil or dingedAt < levels[level]) then
                    levels[level] = dingedAt
                    count = count + 1
                end
            end
            if count > 0 then
                batch[name] = {classIndex = tonumber(ci), levels = levels}
            end
        end
    end

    return batch
end

-- Deserializes a firstToLevel batch string produced by SerializeFTLBatch.
-- When duplicate (classFilter, level) entries appear, keeps the one with the earlier dingedAt.
function TheClassicRaceSerializer.DeserializeFTLBatch(str)
    if str == "" then
        return {}
    end

    local offset = tonumber(string.sub(str, 1, 10))
    str = string.sub(str, 12)

    local ftldb = {}
    for substr in string.gmatch(str, "([^$]+$)") do
        -- format: CF(2) LV(2) CI(2) name(non-digit-non-dash) dingedAtDelta
        local cf, lv, ci, name, delta = string.match(substr, "(%d%d)(%d%d)(%d%d)([^%d-]+)(%-?%d+)")
        if cf and lv and ci and name and delta then
            local classFilter = tonumber(cf)
            local level = tonumber(lv)
            local classIndex = tonumber(ci)
            local dingedAt = tonumber(delta) + offset

            -- level 1 is not a ding — ignore malformed remote entries
            if level >= 2 then
                if ftldb[classFilter] == nil then ftldb[classFilter] = {} end
                local existing = ftldb[classFilter][level]
                if existing == nil or dingedAt < existing.dingedAt
                        or (dingedAt == existing.dingedAt and name < existing.name) then
                    ftldb[classFilter][level] = {
                        name = name,
                        classIndex = classIndex,
                        dingedAt = dingedAt,
                    }
                end
            end
        end
    end

    return ftldb
end