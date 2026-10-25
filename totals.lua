--==============================================================
-- LONG-TERM ENERGY TOTALS
-- Save as: totals.lua
--==============================================================

--[[
README
-------
Integrates each unit's generation (FE or RF per tick) over time into
lifetime and hourly totals that survive reboots (data/totals.db).

  totals.load() / totals.save()
  totals.add(unitId, ratePerTick, seconds)  integrate one interval
  totals.of(unitId) -> {lifetime, hours = {[hourIndex] = energy}}
  totals.lastHours(unitId, n) -> list of n hourly totals, oldest first
  totals.network(n) -> same, summed over every unit

Hours are real-world (os.epoch("utc")) so totals keep meaning across
server restarts; only the last HOURS_KEPT hours are stored.
]]

local totals = {}

local HOURS_KEPT = 48
local TICKS_PER_SECOND = 20

local path = "data/totals.db"
local data = {}                -- unit id -> {lifetime, hours}
local dirty = false

local function hourNow()
    local ok, ms = pcall(os.epoch, "utc")
    if ok and type(ms) == "number" then
        return math.floor(ms / 3600000)
    end
    return math.floor(os.clock() / 3600)
end

function totals.load(file)
    path = file or path
    data = {}
    if not fs.exists(path) then return end
    local handle = fs.open(path, "r")
    if not handle then return end
    local ok, loaded = pcall(textutils.unserialize, handle.readAll())
    handle.close()
    if ok and type(loaded) == "table" then data = loaded end
end

function totals.save()
    if not dirty then return end
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle = fs.open(path, "w")
    if not handle then return end
    handle.write(textutils.serialize(data))
    handle.close()
    dirty = false
end

function totals.add(unitId, ratePerTick, seconds)
    ratePerTick = tonumber(ratePerTick) or 0
    if ratePerTick <= 0 or not seconds or seconds <= 0 then return end
    local energy = ratePerTick * seconds * TICKS_PER_SECOND
    local entry = data[unitId] or {lifetime = 0, hours = {}}
    data[unitId] = entry
    entry.lifetime = entry.lifetime + energy
    local hour = hourNow()
    entry.hours[hour] = (entry.hours[hour] or 0) + energy
    for h in pairs(entry.hours) do
        if h <= hour - HOURS_KEPT then entry.hours[h] = nil end
    end
    dirty = true
end

function totals.of(unitId)
    return data[unitId] or {lifetime = 0, hours = {}}
end

function totals.lastHours(unitId, n)
    local hour, out = hourNow(), {}
    local hours = totals.of(unitId).hours
    for h = hour - n + 1, hour do table.insert(out, hours[h] or 0) end
    return out
end

function totals.network(n)
    local hour, out, lifetime = hourNow(), {}, 0
    for i = 1, n do out[i] = 0 end
    for _, entry in pairs(data) do
        lifetime = lifetime + (entry.lifetime or 0)
        for i = 1, n do
            out[i] = out[i] + (entry.hours[hour - n + i] or 0)
        end
    end
    return out, lifetime
end

return totals
