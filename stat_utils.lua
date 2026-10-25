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
- stat_utils.recordRow(key, columns, row)
                               Append a CSV row to <dir>/<key>.csv
                               (one file per reactor), rate limited to
                               one row per statsInterval seconds
- stat_utils.recent            Last few events, shown on the monitor

Files are rotated to "<name>.old" once they exceed maxFileBytes so the
computer's limited disk space (1 MB by default) can never fill up.

- stat_utils.addSink(fn)       Also hand every written line to
                               fn(fileName, line, csvHeader) (used by
                               log_shipper). fileName is relative, e.g.
                               "draconic.log"; csvHeader is the CSV header
                               line for .csv files. Returns a remover.
                               Sinks must not yield; errors are ignored.
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
local lastStatsAt = {}      -- csv key -> last write time
local sinks = {}
-- Lines written before the first sink is added (remote logging only),
-- replayed to it so startup messages are shipped too.
local early, EARLY_LIMIT = nil, 200

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

local function notify(file, line, header)
    local name = fs.getName(file)
    if early then
        table.insert(early, {name, line, header})
        if #early > EARLY_LIMIT then table.remove(early, 1) end
    end
    for _, sink in ipairs(sinks) do
        pcall(sink, name, line, header)
    end
end

local function append(file, line, header)
    notify(file, line, header)
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
    lastStatsAt = {}
    stat_utils.recent = {}
    local remote = settings.remote
    early = (type(remote) == "table" and remote.enabled == true and #sinks == 0) and {} or nil
end

function stat_utils.addSink(fn)
    table.insert(sinks, fn)
    local backlog = early
    early = nil
    for _, e in ipairs(backlog or {}) do
        pcall(fn, e[1], e[2], e[3])
    end
    return function()
        for i, f in ipairs(sinks) do
            if f == fn then table.remove(sinks, i); return end
        end
    end
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

-- Appends one CSV row to <dir>/<key>.csv, at most once per statsInterval
-- per key. `columns` is the ordered header; `row` maps column -> value
-- (numbers are written with up to 4 decimals, nil as empty).
function stat_utils.recordRow(key, columns, row, force)
    local t = now()
    local last = lastStatsAt[key]
    if not force and last and t - last < settings.statsInterval then
        return false
    end
    lastStatsAt[key] = t

    local file = path(key .. ".csv")
    local header = "time," .. table.concat(columns, ",")
    if not fs.exists(file) then
        append(file, header, header)
    end
    local cells = {timestamp()}
    for _, col in ipairs(columns) do
        local v = row[col]
        if type(v) == "number" then
            v = (v == math.floor(v)) and string.format("%.0f", v) or string.format("%.4f", v)
        end
        table.insert(cells, v == nil and "" or tostring(v))
    end
    append(file, table.concat(cells, ","), header)
    return true
end

return stat_utils
