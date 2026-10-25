--==============================================================
-- PERSISTENT STATE AND IN-GAME SETTINGS
-- Save as: persist.lua
--==============================================================

--[[
README
-------
Stores what players change on the monitors so it survives reboots and
chunk reloads, in one file (data/manager.db, textutils-serialised):

  overrides  unit id -> {setting = value}  (layered over config.lua)
  pins       monitor name -> unit id        (monitor shows only that unit)

Settings schema
  Drivers describe their editable settings as a list of
    {key, label, step, min, max, fmt}
  where min/max may be functions of the unit's current cfg, so linked
  limits stay consistent (a target can never be set above its trip).
  fmt is "temp" (C), "pct" (fraction shown as %), "rpm" or "bool".
]]

local persist = {}

local path = "data/manager.db"
local data = {overrides = {}, pins = {}}

------------------------------------------------------------
-- FILE
------------------------------------------------------------
function persist.load(file)
    path = file or path
    data = {overrides = {}, pins = {}}
    if not fs.exists(path) then return end
    local handle = fs.open(path, "r")
    if not handle then return end
    local text = handle.readAll()
    handle.close()
    local ok, loaded = pcall(textutils.unserialize, text)
    if ok and type(loaded) == "table" then
        data.overrides = type(loaded.overrides) == "table" and loaded.overrides or {}
        data.pins = type(loaded.pins) == "table" and loaded.pins or {}
    end
end

function persist.save()
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle = fs.open(path, "w")
    if not handle then return false end
    handle.write(textutils.serialize(data))
    handle.close()
    return true
end

------------------------------------------------------------
-- OVERRIDES AND PINS
------------------------------------------------------------
function persist.overrides(unitId)
    return data.overrides[unitId] or {}
end

function persist.setOverride(unitId, key, value)
    data.overrides[unitId] = data.overrides[unitId] or {}
    data.overrides[unitId][key] = value
    persist.save()
end

function persist.clearOverrides(unitId)
    data.overrides[unitId] = nil
    persist.save()
end

function persist.pins()
    return data.pins
end

-- Pins `monitor` to `unitId`, or unpins it when unitId is nil.
function persist.setPin(monitor, unitId)
    data.pins[monitor] = unitId
    persist.save()
end

------------------------------------------------------------
-- SETTINGS SCHEMA
------------------------------------------------------------
local function bound(v, cfg)
    if type(v) == "function" then return v(cfg) end
    return v
end

-- Moves `key` one step in direction `dir` (-1 / +1) within its limits.
-- Returns the new value, or nil when the key is unknown or unchanged.
function persist.adjust(cfg, schema, key, dir)
    for _, item in ipairs(schema or {}) do
        if item.key == key then
            local old = cfg[key]
            local new
            if item.fmt == "bool" then
                new = not old
            else
                new = (old or 0) + item.step * dir
                local lo, hi = bound(item.min, cfg), bound(item.max, cfg)
                if lo and new < lo then new = lo end
                if hi and new > hi then new = hi end
                -- Round away float drift from repeated fractional steps.
                new = math.floor(new / item.step + 0.5) * item.step
                if lo and new < lo then new = new + item.step end
                if hi and new > hi then new = new - item.step end
            end
            if new == old then return nil end
            cfg[key] = new
            return new
        end
    end
    return nil
end

local function int(v)
    local s = string.format("%.0f", v)
    local sign, digits = s:match("^(-?)(%d+)$")
    if not digits then return s end
    return sign .. (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

function persist.format(item, value)
    if value == nil then return "--" end
    if item.fmt == "bool" then return value and "ON" or "OFF" end
    if item.fmt == "pct" then return string.format("%d%%", math.floor(value * 100 + 0.5)) end
    if item.fmt == "temp" then return int(value) .. "C" end
    return int(value)
end

return persist
