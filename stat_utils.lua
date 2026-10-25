--==============================================================
-- STATISTICS AND LOGGING UTILITIES
-- Save as: stat_utils.lua
--==============================================================

--[[
README
-------
Single logging subsystem for the whole program.

- stat_utils.log(level, msg)   Append a timestamped event to
                               <dir>/draconic.log
- stat_utils.recordStats(t)    Append a CSV row to
                               <dir>/reactor_stats.csv, rate limited
                               to one row per statsInterval seconds
- stat_utils.recent            Last few events, shown on the monitor

Files are rotated to "<name>.old" once they exceed maxFileBytes so the
computer's limited disk space (1 MB by default) can never fill up.
]]

local stat_utils = {}

local LEVELS = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, CRIT = 5}
local RECENT_LIMIT = 5

local settings = {
    directory     = "logs",
    maxFileBytes  = 65536,
    statsInterval = 10,
    printLevel    = "WARN"
}
local lastStatsAt = nil

stat_utils.recent = {}

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function timestamp()
    local ok, value = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    if ok and value then
        return value
    end
    return string.format("day%d %.2f", os.day(), os.time())
end

local function now()
    -- os.clock() is CPU time on real Lua but uptime in CC:Tweaked.
    return os.clock()
end

local function path(name)
    return fs.combine(settings.directory, name)
end

local function rotateIfNeeded(file)
    if fs.exists(file) and fs.getSize(file) > settings.maxFileBytes then
        local old = file .. ".old"
        if fs.exists(old) then
            fs.delete(old)
        end
        fs.move(file, old)
    end
end

local function append(file, line)
    local ok = pcall(function()
        rotateIfNeeded(file)
        local handle = fs.open(file, "a")
        if handle then
            handle.writeLine(line)
            handle.close()
        end
    end)
    return ok
end

------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------
function stat_utils.init(loggingConfig)
    for key, value in pairs(loggingConfig or {}) do
        settings[key] = value
    end
    if not fs.exists(settings.directory) then
        fs.makeDir(settings.directory)
    end
    lastStatsAt = nil
    stat_utils.recent = {}
end

function stat_utils.log(level, message)
    level = LEVELS[level] and level or "INFO"
    message = tostring(message)
    append(path("draconic.log"),
           timestamp() .. " [" .. level .. "] " .. message)

    table.insert(stat_utils.recent, 1, {level = level, message = message})
    while #stat_utils.recent > RECENT_LIMIT do
        table.remove(stat_utils.recent)
    end

    local threshold = LEVELS[settings.printLevel] or LEVELS.WARN
    if LEVELS[level] >= threshold then
        print("[" .. level .. "] " .. message)
    end
end

-- snapshot fields: status, temperature, fieldPct, satPct, fuelRemaining,
-- generationRate, inputRate, outputRate, corePct
function stat_utils.recordStats(snapshot, force)
    local t = now()
    if not force and lastStatsAt
            and t - lastStatsAt < settings.statsInterval then
        return false
    end
    lastStatsAt = t

    local file = path("reactor_stats.csv")
    if not fs.exists(file) then
        append(file, "time,status,temperature,field,saturation,fuel,"
                  .. "generation,input,output,core")
    end
    append(file, string.format("%s,%s,%.1f,%.4f,%.4f,%.4f,%.0f,%.0f,%.0f,%s",
        timestamp(),
        tostring(snapshot.status),
        snapshot.temperature or 0,
        snapshot.fieldPct or 0,
        snapshot.satPct or 0,
        snapshot.fuelRemaining or 0,
        snapshot.generationRate or 0,
        snapshot.inputRate or 0,
        snapshot.outputRate or 0,
        snapshot.corePct and string.format("%.4f", snapshot.corePct) or ""))
    return true
end

return stat_utils
