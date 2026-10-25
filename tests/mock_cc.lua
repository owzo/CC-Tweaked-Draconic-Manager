--==============================================================
-- MINIMAL CC:TWEAKED ENVIRONMENT MOCK (tests only)
--==============================================================

--[[
README
-------
Installs fake ComputerCraft globals (fs, peripheral, term, window,
colors, os events/timers, sleep, parallel, settings, http, disk) on top
of standard Lua 5.1+, with a virtual clock.

  local cc = require("mock_cc")
  cc.reset()
  cc.addPeripheral("left", "monitor", cc.newScreen(29, 19))
  cc.run(fn, {untilTime = 60, onAdvance = function(dt) ... end})

Only what this project uses is implemented.
]]

local M = {}

------------------------------------------------------------
-- COLORS
------------------------------------------------------------
local colorNames = {"white", "orange", "magenta", "lightBlue", "yellow", "lime",
    "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown", "green",
    "red", "black"}
colors = {}
for i, name in ipairs(colorNames) do colors[name] = 2 ^ (i - 1) end
colours = colors

------------------------------------------------------------
-- SCREENS (terminal / monitor framebuffer)
------------------------------------------------------------
function M.newScreen(baseW, baseH)
    local s = {scale = 1, rows = {}, bgRows = {}, fgRows = {}, x = 1, y = 1,
               fg = colors.white, bg = colors.black}
    local function size()
        return math.floor(baseW / s.scale), math.floor(baseH / s.scale)
    end
    local function blank()
        local w, h = size()
        for y = 1, h do
            s.rows[y] = string.rep(" ", w)
            s.bgRows[y] = {}
            s.fgRows[y] = {}
        end
    end
    blank()
    function s.getSize() return size() end
    function s.setTextScale(v) s.scale = v; blank() end
    function s.getTextScale() return s.scale end
    function s.setCursorPos(x, y) s.x, s.y = math.floor(x), math.floor(y) end
    function s.getCursorPos() return s.x, s.y end
    function s.setTextColor(c) s.fg = c end
    function s.setBackgroundColor(c) s.bg = c end
    s.setTextColour, s.setBackgroundColour = s.setTextColor, s.setBackgroundColor
    function s.getTextColor() return s.fg end
    function s.getBackgroundColor() return s.bg end
    function s.isColor() return true end
    s.isColour = s.isColor
    function s.setCursorBlink() end
    function s.clear() blank() end
    function s.clearLine()
        local w = size()
        s.rows[s.y] = string.rep(" ", w)
    end
    function s.scroll() end
    function s.write(text)
        text = tostring(text)
        local w, h = size()
        local row = s.rows[s.y]
        if row then
            for i = 1, #text do
                local x = s.x + i - 1
                if x >= 1 and x <= w then
                    row = row:sub(1, x - 1) .. text:sub(i, i) .. row:sub(x + 1)
                    s.bgRows[s.y][x] = s.bg
                    s.fgRows[s.y][x] = s.fg
                end
            end
            s.rows[s.y] = row
        end
        s.x = s.x + #text
    end
    function s.getLine(y) return s.rows[y] end
    function s.text() return table.concat(s.rows, "\n") end
    -- Returns x, y of the first occurrence of `needle`.
    function s.find(needle)
        for y, row in ipairs(s.rows) do
            local x = row:find(needle, 1, true)
            if x then return x, y end
        end
    end
    return s
end

window = {
    create = function(parent, x, y, w, h)
        local win = setmetatable({}, {__index = parent})
        win.getSize = function() return w, h end
        win.setVisible = function() end
        win.redraw = function() end
        return win
    end
}

------------------------------------------------------------
-- FILESYSTEM (in memory)
------------------------------------------------------------
local files, dirs

local function norm(path)
    local parts = {}
    for part in tostring(path):gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then table.insert(parts, part) end
    end
    return table.concat(parts, "/")
end

fs = {}
function fs.combine(a, ...)
    local out = a
    for _, b in ipairs({...}) do out = out .. "/" .. b end
    return norm(out)
end
function fs.getDir(p)
    p = norm(p)
    return p:match("^(.*)/[^/]*$") or ""
end
function fs.getName(p) return norm(p):match("([^/]*)$") end
function fs.exists(p)
    p = norm(p)
    return p == "" or files[p] ~= nil or dirs[p] ~= nil
end
function fs.isDir(p) p = norm(p); return p == "" or dirs[p] ~= nil end
function fs.makeDir(p)
    p = norm(p)
    while p ~= "" do dirs[p] = true; p = fs.getDir(p) end
end
function fs.getSize(p) return #(files[norm(p)] or "") end
function fs.delete(p) p = norm(p); files[p] = nil; dirs[p] = nil end
function fs.move(a, b) files[norm(b)] = files[norm(a)]; files[norm(a)] = nil end
function fs.copy(a, b)
    assert(files[norm(a)], "copy: no such file " .. a)
    assert(not files[norm(b)], "copy: destination exists " .. b)
    files[norm(b)] = files[norm(a)]
end
function fs.getDrive(p)
    local top = norm(p):match("^[^/]*")
    return M.mounts[top] or "hdd"
end
function fs.list(p)
    p = norm(p)
    local out, seen = {}, {}
    local function consider(path)
        local dir = fs.getDir(path)
        if dir == p and not seen[path] then
            seen[path] = true
            table.insert(out, fs.getName(path))
        end
    end
    for path in pairs(files) do consider(path) end
    for path in pairs(dirs) do consider(path) end
    table.sort(out)
    return out
end
function fs.open(p, mode)
    p = norm(p)
    if mode == "r" then
        local content = files[p]
        if not content then return nil end
        local pos = 1
        return {
            readAll = function() local r = content:sub(pos); pos = #content + 1; return r end,
            readLine = function()
                if pos > #content then return nil end
                local e = content:find("\n", pos, true) or (#content + 1)
                local line = content:sub(pos, e - 1)
                pos = e + 1
                return line
            end,
            close = function() end
        }
    end
    local dir = fs.getDir(p)
    if dir ~= "" and not dirs[dir] then return nil end
    local buffer = mode == "a" and (files[p] or "") or ""
    files[p] = buffer
    return {
        write = function(s) buffer = buffer .. tostring(s); files[p] = buffer end,
        writeLine = function(s) buffer = buffer .. tostring(s) .. "\n"; files[p] = buffer end,
        flush = function() end,
        close = function() end
    }
end

function M.writeFile(p, content)
    local dir = fs.getDir(p)
    if dir ~= "" then fs.makeDir(dir) end
    files[norm(p)] = content
end
function M.readFile(p) return files[norm(p)] end

------------------------------------------------------------
-- PERIPHERALS
------------------------------------------------------------
local registry

peripheral = {}
function peripheral.getNames()
    local names = {}
    for name in pairs(registry) do table.insert(names, name) end
    table.sort(names)
    return names
end
function peripheral.isPresent(name) return registry[name] ~= nil end
function peripheral.getType(name) return registry[name] and registry[name].kind end
function peripheral.wrap(name) return registry[name] and registry[name].dev end
function peripheral.find(kind)
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if registry[name].kind == kind then table.insert(out, registry[name].dev) end
    end
    return table.unpack and table.unpack(out) or unpack(out)
end

function M.addPeripheral(name, kind, dev) registry[name] = {kind = kind, dev = dev} end
function M.removePeripheral(name) registry[name] = nil end

------------------------------------------------------------
-- EVENTS, TIMERS, CLOCK
------------------------------------------------------------
local queue, timers, nextTimer

function os.clock() return M.time end
-- CC never returns from a reboot; end the program like Ctrl+T would.
function os.reboot() M.rebooted = true; error("Terminated", 0) end
function os.day() return 1 end
function os.startTimer(delay)
    nextTimer = nextTimer + 1
    timers[nextTimer] = M.time + math.max(delay, 0.05)
    return nextTimer
end
function os.cancelTimer(id) timers[id] = nil end
function os.queueEvent(...) table.insert(queue, {...}) end
function os.getComputerID() return M.computerId end
function os.getComputerLabel() return M.computerLabel end
function os.epoch() return math.floor(M.time * 1000) end
function os.pullEventRaw(filter) return coroutine.yield(filter) end
function os.pullEvent(filter)
    local ev = {coroutine.yield(filter)}
    if ev[1] == "terminate" then error("Terminated", 0) end
    return (table.unpack or unpack)(ev)
end
function sleep(seconds)
    local id = os.startTimer(seconds)
    repeat
        local _, tid = os.pullEvent("timer")
    until tid == id
end

-- Same semantics as CC:Tweaked's parallel API.
local function runUntil(fns, limit)
    local routines, filters = {}, {}
    for i, fn in ipairs(fns) do routines[i] = coroutine.create(fn) end
    local unpackFn = table.unpack or unpack
    local event = {}
    local alive = #routines
    while true do
        for i, co in ipairs(routines) do
            if co and (filters[i] == nil or filters[i] == event[1] or event[1] == "terminate") then
                local ok, param = coroutine.resume(co, unpackFn(event))
                if not ok then error(param, 0) end
                filters[i] = param
                if coroutine.status(co) == "dead" then
                    routines[i] = false
                    alive = alive - 1
                    if alive <= limit then return i end
                end
            end
        end
        event = {coroutine.yield()}
    end
end
parallel = {
    waitForAny = function(...) return runUntil({...}, #{...} - 1) end,
    waitForAll = function(...) return runUntil({...}, 0) end
}

------------------------------------------------------------
-- TEXTUTILS (serialise / unserialise round trip, like CC's)
------------------------------------------------------------
local function serialize(v, indent)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    assert(t == "table", "cannot serialize " .. t)
    local parts = {}
    local keys = {}
    for k in pairs(v) do table.insert(keys, k) end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    for _, k in ipairs(keys) do
        table.insert(parts, "[" .. serialize(k) .. "] = " .. serialize(v[k]))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end
textutils = {
    serialize = serialize,
    serialise = serialize,
    unserialize = function(s)
        local fn = (loadstring or load)("return " .. s)
        if not fn then return nil end
        local ok, v = pcall(fn)
        return ok and v or nil
    end
}
textutils.unserialise = textutils.unserialize

-- textutils.serializeJSON, transcribed from CC:Tweaked's rom/apis/textutils.lua
-- (default options: bytes 0x7F-0xFF become \u00XX, control chars escaped).
do
    local map = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
                 ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}
    local function hexify(c) return ("\\u00%02X"):format(c:byte()) end
    for i = 0, 0x1f do
        local c = string.char(i)
        if map[c] == nil then map[c] = hexify(c) end
    end
    local function str(s)
        return '"' .. s:gsub('[\0-\31"\\]', map):gsub("[\127-\255]", hexify) .. '"'
    end
    local function impl(t)
        local ty = type(t)
        if ty == "string" then return str(t) end
        if ty == "number" or ty == "boolean" then return tostring(t) end
        assert(ty == "table", "cannot serialize " .. ty)
        if next(t) == nil then return "{}" end
        local obj, arr, largest = {}, {}, 0
        for k, v in pairs(t) do
            if type(k) == "string" then
                table.insert(obj, str(k) .. ":" .. impl(v))
            elseif type(k) == "number" and k > largest then
                largest = k
            end
        end
        for k = 1, largest do arr[k] = t[k] == nil and "null" or impl(t[k]) end
        if #obj > 0 or largest == 0 then return "{" .. table.concat(obj, ",") .. "}" end
        return "[" .. table.concat(arr, ",") .. "]"
    end
    textutils.serializeJSON = function(t) return impl(t) end
    textutils.serialiseJSON = textutils.serializeJSON
end

------------------------------------------------------------
-- MISC APIS
------------------------------------------------------------
local store
settings = {
    get = function(k, d) if store[k] == nil then return d end return store[k] end,
    set = function(k, v) store[k] = v end,
    unset = function(k) store[k] = nil end,
    save = function() M.settingsSaved = true; return true end
}

disk = {
    hasData = function(name) return M.drives[name] ~= nil end,
    getMountPath = function(name) return M.drives[name] end
}

function M.reset(opts)
    opts = opts or {}
    files, dirs, registry = {}, {}, {}
    queue, timers, nextTimer = {}, {}, 0
    store = {}
    M.time = 0
    M.output = {}
    M.inputs = opts.inputs or {}
    M.mounts, M.drives = {}, {}
    M.scheduled = {}
    M.settingsSaved = false
    M.terminal = M.newScreen(51, 19)
    term = setmetatable({current = function() return M.terminal end},
                        {__index = function(_, k) return M.terminal[k] end})
    http = opts.http
    shell = opts.shell
    M.redstone = {}
    redstone = {setOutput = function(side, on) M.redstone[side] = on end,
                getOutput = function(side) return M.redstone[side] or false end}
    rs = redstone
    M.computerId, M.computerLabel = 7, opts.label
end

--[[
Fake http API with requests answered in virtual time.
  handler(req, n) -> {code = 200, body = "", latency = s}
                  or {fail = "Connection refused", latency = s}
  check(url)      -> ok, err for http.checkURL (default: allowed)
req = {url, body, headers, timeout, method, time}. Every request is kept
in api.requests; api.maxInFlight is the peak of concurrent requests.
http.post/http.get wait for http_success/http_failure like CC's.
]]
function M.newHttp(handler, check)
    local api = {requests = {}, inFlight = 0, maxInFlight = 0}
    local function handle(code, body)
        return {getResponseCode = function() return code end,
                readAll = function() return body or "" end,
                getResponseHeaders = function() return {} end,
                close = function() end}
    end
    local function deliver(at, ...)
        if at <= M.time then os.queueEvent(...) else M.schedule(at, ...) end
    end
    function api.request(url, body, headers)
        local req = type(url) == "table" and url or {url = url, body = body, headers = headers}
        req = {url = req.url, body = req.body, headers = req.headers or {}, timeout = req.timeout,
               method = req.method or (req.body and "POST" or "GET"), time = M.time}
        if api.inFlight >= 16 then return false, "Too many ongoing HTTP requests" end
        table.insert(api.requests, req)
        api.inFlight = api.inFlight + 1
        api.maxInFlight = math.max(api.maxInFlight, api.inFlight)
        local r = handler(req, #api.requests) or {code = 200}
        local latency = r.latency or 0
        local limit = req.timeout or 30
        local at
        if latency > limit then
            at = M.time + limit
            deliver(at, "http_failure", req.url, "Timed out")
        elseif r.fail then
            at = M.time + latency
            deliver(at, "http_failure", req.url, r.fail)
        elseif r.code and (r.code < 200 or r.code >= 300) then
            at = M.time + latency
            deliver(at, "http_failure", req.url, r.reason or ("HTTP " .. r.code), handle(r.code, r.body))
        else
            at = M.time + latency
            deliver(at, "http_success", req.url, handle(r.code or 200, r.body))
        end
        return true
    end
    local function wait(url, ok, err)
        if not ok then return nil, err end
        while true do
            local ev, u, a, b = os.pullEvent()
            if (ev == "http_success" or ev == "http_failure") and u == url then
                api.inFlight = api.inFlight - 1
                if ev == "http_success" then return a end
                return nil, a, b
            end
        end
    end
    function api.post(url, body, headers)
        if type(url) == "table" then return wait(url.url, api.request(url)) end
        return wait(url, api.request(url, body, headers))
    end
    function api.get(url, headers)
        if type(url) == "table" then return wait(url.url, api.request(url)) end
        return wait(url, api.request({url = url, headers = headers}))
    end
    function api.checkURL(url)
        if check then return check(url) end
        return true
    end
    return api
end

function M.capture(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    table.insert(M.output, table.concat(parts, " "))
end
print = M.capture
printError = M.capture
write = M.capture
read = function() return table.remove(M.inputs, 1) end

function M.outputText() return table.concat(M.output, "\n") end

-- Queue an event to fire at virtual time t.
function M.schedule(t, ...)
    table.insert(M.scheduled, {t = t, ev = {...}})
    table.sort(M.scheduled, function(a, b) return a.t < b.t end)
end

--[[
Runs fn as the top-level program until it returns or virtual time
reaches opts.untilTime (a "terminate" event is then delivered).
opts.onAdvance(dt) is called whenever the clock moves forward.
Returns ok, err from the program.
]]
function M.run(fn, opts)
    opts = opts or {}
    local limit = opts.untilTime or math.huge
    local co = coroutine.create(fn)
    local unpackFn = table.unpack or unpack
    local filter
    local event = {}
    local terminated = false
    while true do
        if filter == nil or filter == event[1] or event[1] == "terminate" then
            local ok, f = coroutine.resume(co, unpackFn(event))
            if not ok then return false, f end
            filter = f
        end
        if coroutine.status(co) == "dead" then return true end

        if #queue > 0 then
            event = table.remove(queue, 1)
        else
            -- Advance to the next timer or scheduled event.
            local nextT, nextId = math.huge, nil
            for id, t in pairs(timers) do
                if t < nextT or (t == nextT and id < nextId) then nextT, nextId = t, id end
            end
            local sched = M.scheduled[1]
            local target = math.min(nextT, sched and sched.t or math.huge)
            if target > limit then
                if terminated then return false, "program ignored terminate" end
                terminated = true
                target = limit
                event = {"terminate"}
            elseif sched and sched.t <= nextT then
                table.remove(M.scheduled, 1)
                event = sched.ev
            else
                timers[nextId] = nil
                event = {"timer", nextId}
            end
            if target > M.time then
                if opts.onAdvance then opts.onAdvance(target - M.time) end
                M.time = target
            end
        end
    end
end

return M
