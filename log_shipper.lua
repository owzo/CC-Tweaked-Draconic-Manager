--==============================================================
-- REMOTE LOG SHIPPER
-- Save as: log_shipper.lua
--==============================================================

--[[
README
-------
Copies every event-log line and stats CSV row written by stat_utils to a
log collector on a real computer (tools/log_collector.py) over HTTP.

  local loop = log_shipper.loop(config.logging.remote, stat_utils)
  parallel.waitForAny(..., loop)

Design rules:
- Reactor control is never blocked. stat_utils hands each line to a sink
  that only appends to an in-memory queue; this module's own coroutine
  does the HTTP work. http.post waits with os.pullEvent, so every other
  coroutine keeps running while a request is in flight.
- The queue is bounded (maxQueue). When full, the oldest entry is
  dropped and counted; the count is sent with the next batch ("dropped")
  and written to the local log.
- A batch is sent every batchSeconds, or sooner once batchEntries lines
  are waiting. Batches stay under maxBatchBytes of JSON (CC:Tweaked's
  default upload limit per request is 4 MiB).
- On failure the batch is kept and retried with exponential backoff
  (batchSeconds doubling, capped at maxBackoff). Nothing ever throws into
  the caller; a disabled or misconfigured shipper just idles.

Payload (JSON, Authorization: Bearer <token>):
  {computer_id, computer_label, sent_at, dropped,
   entries = [{file = "draconic.log", line = "..."},
              {file = "reactor_stats.csv", line = "time,...", header = true}]}
Before the first row of each CSV file a header entry (header = true) is
sent, so the collector can keep remote CSV files valid after rotations.
]]

local log_shipper = {}

local DEFAULTS = {
    enabled       = false,
    url           = nil,
    token         = nil,
    batchSeconds  = 5,
    batchEntries  = 100,
    maxQueue      = 1000,
    maxBatchBytes = 256 * 1024,
    maxLineBytes  = 4096,
    maxBackoff    = 60,
    timeout       = 10
}
local WAKE = "log_shipper_wake"
local IDLE = "log_shipper_idle"     -- never queued: parks the coroutine

local HTTP_RULES_HINT = "CC:Tweaked blocks localhost and LAN addresses" ..
    " (127.0.0.0/8, 10/8, 172.16/12, 192.168/16, ...) by default. Add an" ..
    " allow rule for the collector host above the \"$private\" deny rule" ..
    " in computercraft-server.toml (see README: Logs on a real computer)."

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function merged(cfg)
    local out = {}
    for k, v in pairs(DEFAULTS) do out[k] = v end
    for k, v in pairs(type(cfg) == "table" and cfg or {}) do out[k] = v end
    return out
end

local function idleForever()
    while true do os.pullEventRaw(IDLE) end
end

local function epochMillis()
    if os.epoch then
        local ok, v = pcall(os.epoch, "utc")
        if ok and type(v) == "number" then return v end
    end
    return math.floor(os.time() * 1000)
end

-- Exact JSON size of one entry inside the entries array (+1 for the comma).
local function entryBytes(entry)
    return #textutils.serializeJSON(entry) + 1
end

------------------------------------------------------------
-- QUEUE
------------------------------------------------------------
-- Entries live at absolute indices first..last so a batch in flight can
-- be acknowledged even if the queue overflowed while it was being sent.
local function newQueue(limit)
    local q = {items = {}, first = 1, last = 0, limit = limit,
               dropped = 0, inFlightFirst = nil, inFlightLast = nil}

    function q.size() return q.last - q.first + 1 end

    function q.push(entry)
        q.last = q.last + 1
        q.items[q.last] = entry
        while q.size() > q.limit do
            local i = q.first
            q.items[i] = nil
            q.first = i + 1
            -- Entries being sent right now are counted only if that send fails.
            if not (q.inFlightFirst and i >= q.inFlightFirst and i <= q.inFlightLast) then
                q.dropped = q.dropped + 1
            end
        end
    end

    function q.clear()
        q.items, q.first, q.last = {}, 1, 0
    end

    return q
end

------------------------------------------------------------
-- SHIPPER
------------------------------------------------------------
--[[
Creates a shipper. `log` is stat_utils (needs log and addSink).
Returns the shipper table; shipper.run() is the coroutine body.
Exposed for tests: shipper.queue, shipper.stats, shipper.enabled.
]]
function log_shipper.new(remoteConfig, log)
    local cfg = merged(remoteConfig)
    local self = {cfg = cfg, enabled = cfg.enabled == true,
                  stats = {sent = 0, batches = 0, failures = 0, dropped = 0}}
    local queue = newQueue(math.max(1, math.floor(tonumber(cfg.maxQueue) or DEFAULTS.maxQueue)))
    self.queue = queue
    local headersSent = {}         -- csv file -> true once its header was queued
    local wakePending = false
    local removeSink

    local function say(level, msg)
        pcall(log.log, level, "Remote log: " .. msg)
    end

    local function enqueue(file, line, header)
        line = tostring(line)
        if #line > cfg.maxLineBytes then
            line = line:sub(1, cfg.maxLineBytes - 3) .. "..."
        end
        if header and not headersSent[file] then
            headersSent[file] = true
            queue.push({file = file, line = header, header = true})
            if line == header then return end
        elseif header and line == header then
            return                  -- header already queued for this file
        end
        queue.push({file = file, line = line})
        if not wakePending and queue.size() >= cfg.batchEntries then
            wakePending = true
            os.queueEvent(WAKE)
        end
    end
    self.enqueue = enqueue

    local function disable(reason)
        self.enabled = false
        if removeSink then removeSink() end
        queue.clear()
        say("WARN", reason .. " Remote logging disabled; logs are still written locally.")
    end

    -- Checks the config and the http API. Yields (http.checkURL waits).
    local function validate()
        if type(http) ~= "table" or type(http.post) ~= "function" then
            return false, "the http API is not available (enable [http] enabled = true" ..
                " in computercraft-server.toml)."
        end
        if type(cfg.url) ~= "string" or not cfg.url:match("^https?://[^/]+") then
            return false, "config.logging.remote.url must be an http:// or https:// URL" ..
                " ending in /ingest."
        end
        if type(cfg.token) ~= "string" or cfg.token == "" then
            return false, "config.logging.remote.token is empty; set it to the collector's --token."
        end
        if http.checkURL then
            local ok, okUrl, err = pcall(http.checkURL, cfg.url)
            if not ok then
                if okUrl == "Terminated" then error(okUrl, 0) end
            elseif not okUrl then
                local hint = ""
                if tostring(err):find("not permitted") then hint = " " .. HTTP_RULES_HINT end
                return false, cfg.url .. " is blocked: " .. tostring(err) .. "." .. hint
            end
        end
        return true
    end

    -- Takes up to batchEntries / maxBatchBytes entries from the head.
    local function takeBatch()
        local entries, bytes = {}, 256
        local i = queue.first
        while i <= queue.last and #entries < cfg.batchEntries do
            local e = queue.items[i]
            local size = e.bytes or entryBytes({file = e.file, line = e.line, header = e.header})
            e.bytes = size
            if #entries > 0 and bytes + size > cfg.maxBatchBytes then break end
            bytes = bytes + size
            table.insert(entries, {file = e.file, line = e.line, header = e.header})
            i = i + 1
        end
        return entries, queue.first, i - 1
    end

    local function payload(entries, dropped)
        local label = os.getComputerLabel and os.getComputerLabel() or nil
        return textutils.serializeJSON({
            computer_id = os.getComputerID and os.getComputerID() or 0,
            computer_label = label or "",
            sent_at = epochMillis(),
            dropped = dropped,
            entries = entries
        })
    end

    -- Returns true on a 2xx answer, else false and a reason.
    local function post(body)
        local request = {
            url = cfg.url,
            body = body,
            headers = {["Content-Type"] = "application/json",
                       ["Authorization"] = "Bearer " .. cfg.token},
            timeout = cfg.timeout
        }
        local response, err, failed = http.post(request)
        local handle = response or failed
        local code = handle and handle.getResponseCode and handle.getResponseCode()
        if handle and handle.close then pcall(handle.close) end
        if response and (code == nil or (code >= 200 and code < 300)) then
            return true
        end
        return false, tostring(err or "no response") .. (code and (" (HTTP " .. code .. ")") or ""), code
    end

    local failing = false
    local function sendOnce()
        local entries, firstIdx, lastIdx = takeBatch()
        if #entries == 0 then return true end
        local dropped = queue.dropped
        queue.inFlightFirst, queue.inFlightLast = firstIdx, lastIdx
        local ok, success, reason, code = pcall(function()
            return post(payload(entries, dropped))
        end)
        queue.inFlightFirst, queue.inFlightLast = nil, nil
        if not ok then
            if success == "Terminated" then error(success, 0) end
            success, reason = false, tostring(success)
        end
        if success then
            -- Entries may have been evicted meanwhile: ack only what remains.
            queue.first = math.max(queue.first, lastIdx + 1)
            for i = firstIdx, lastIdx do queue.items[i] = nil end
            queue.dropped = queue.dropped - dropped
            self.stats.sent = self.stats.sent + #entries
            self.stats.batches = self.stats.batches + 1
            if failing then
                failing = false
                say("INFO", "collector reachable again")
            end
            if dropped > 0 then
                self.stats.dropped = self.stats.dropped + dropped
                say("WARN", dropped .. " entries were dropped (queue full, maxQueue = " .. queue.limit .. ")")
            end
            return true
        end
        -- Entries of this batch evicted during the failed send are lost.
        if queue.first > firstIdx then
            queue.dropped = queue.dropped + math.min(queue.first, lastIdx + 1) - firstIdx
        end
        self.stats.failures = self.stats.failures + 1
        if code == 413 and cfg.maxBatchBytes > 4096 then
            cfg.maxBatchBytes = math.floor(cfg.maxBatchBytes / 2)
            for i = queue.first, queue.last do queue.items[i].bytes = nil end
        end
        if not failing then
            failing = true
            local hint = ""
            if code == 401 or code == 403 then
                hint = " - check config.logging.remote.token matches the collector's --token"
            elseif tostring(reason):find("not permitted") then
                hint = " - " .. HTTP_RULES_HINT
            end
            say("WARN", "collector unreachable: " .. tostring(reason) .. hint ..
                "; retrying with backoff")
        end
        return false
    end
    self.sendOnce = sendOnce

    local function waitFor(seconds)
        local timer = os.startTimer(seconds)
        while true do
            local ev, id = os.pullEvent()
            if ev == "timer" and id == timer then return end
            if ev == WAKE and not failing then
                if os.cancelTimer then os.cancelTimer(timer) end
                return
            end
        end
    end

    function self.run()
        if not self.enabled then return idleForever() end
        local ok, err = validate()
        if not ok then
            disable(err)
            return idleForever()
        end
        say("INFO", "shipping logs to " .. cfg.url)
        local delay = cfg.batchSeconds
        while true do
            waitFor(delay)
            wakePending = false
            local sentAll = true
            while queue.size() > 0 do
                local ok2, res = pcall(sendOnce)
                if not ok2 then
                    if res == "Terminated" then error(res, 0) end
                    res = false
                end
                if not res then sentAll = false; break end
            end
            if sentAll then
                delay = cfg.batchSeconds
            else
                delay = math.min(cfg.maxBackoff, math.max(delay, cfg.batchSeconds) * 2)
            end
            self.delay = delay
        end
    end

    if self.enabled and log and log.addSink then
        removeSink = log.addSink(enqueue)
    end
    return self
end

-- Convenience for main_control: a ready-to-run loop function.
function log_shipper.loop(remoteConfig, log)
    local ok, shipper = pcall(log_shipper.new, remoteConfig, log)
    if not ok then
        pcall(log.log, "WARN", "Remote log: disabled: " .. tostring(shipper))
        return idleForever
    end
    log_shipper.current = shipper
    return shipper.run
end

return log_shipper
