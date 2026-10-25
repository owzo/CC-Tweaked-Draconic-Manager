--==============================================================
-- DRIVER: EXTREME REACTORS / BIGGER REACTORS
-- Save as: drivers/extreme.lua
--==============================================================

--[[
README
-------
Reactor and turbine units for Extreme Reactors (ZeroCore2) and Bigger
Reactors, through the adapters in er_utils. Works with or without
Draconic Evolution installed; finds nothing when neither mod is present.

Units (same contract as drivers/draconic.lua)
  kind "fission"  reactor: rods keep its buffer in config.extreme's band
                  (FE battery when passive, steam tank when active)
  kind "turbine"  turbine: spin-up, steam flow to hold targetRPM, coils
                  off while its own buffer is full

Steam coupling: actively cooled reactors and turbines in the same steam
group share steam (default: everything is one group, the usual build of
reactors feeding a shared pipe network). Separate systems get separate
groups via config.extreme.units[i].steamGroup. Each active reactor's
feed-forward demand is its group's total commanded turbine flow, split
evenly between the group's active reactors; the reactor's own steam
tank level trims it.
]]

local driver = {id = "extreme", label = "Extreme / Bigger Reactors"}

-- Steam groups, kept across discover() calls so units found later
-- (hot-plugged) join the right group.
local plants = {}

local STATS = {
    fission = {"active", "rods", "buffer", "production", "fuel", "waste", "fuel_temp", "case_temp"},
    turbine = {"active", "mode", "rpm", "flow", "flow_set", "coils", "buffer", "production"}
}

local function pctRange(key, label, min, max)
    return {key = key, label = label, step = 0.05, fmt = "pct", min = min, max = max}
end

-- Settings players can change on the monitor (see persist.lua).
local SETTINGS = {
    fission = {
        pctRange("bufferLow", "Buffer Low", 0, function(c) return c.bufferHigh - 0.1 end),
        pctRange("bufferHigh", "Buffer High", function(c) return c.bufferLow + 0.1 end, 1),
        {key = "rodGain", label = "Rod Gain", step = 0.1, fmt = "num", min = 0.2, max = 3}
    },
    turbine = {
        {key = "targetRPM", label = "Target RPM", step = 50, fmt = "rpm",
         min = 500, max = function(c) return c.maxRPM - 50 end},
        {key = "maxRPM", label = "Cut Steam At", step = 50, fmt = "rpm",
         min = function(c) return c.targetRPM + 50 end, max = 2500},
        pctRange("coilsOffAbove", "Coils Off At", function(c) return c.coilsOnBelow + 0.05 end, 1),
        pctRange("coilsOnBelow", "Coils On At", 0.05, function(c) return c.coilsOffAbove - 0.05 end),
        {key = "flowGain", label = "Flow Gain", step = 0.1, fmt = "num", min = 0.2, max = 3}
    }
}

local function merged(base, overrides)
    local out = {}
    for k, v in pairs(base or {}) do out[k] = v end
    for k, v in pairs(overrides or {}) do out[k] = v end
    return out
end

local function slug(text)
    return (tostring(text):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

function driver.discover(ctx)
    local er = ctx.import("er_utils")
    local base = ctx.config.extreme or {}
    local perUnit = {}
    for _, spec in ipairs(base.units or {}) do
        if spec.peripheral then perUnit[spec.peripheral] = spec end
    end

    local function plantFor(group)
        local plant = plants[group]
        if plant then return plant end
        plant = {turbines = {}, steamReactors = {}}
        function plant.steamDemandPerReactor()
            local total, active = 0, 0
            for _, t in ipairs(plant.turbines) do
                if t.data and t.data.active then total = total + (t.controller.flow or 0) end
            end
            for _, r in ipairs(plant.steamReactors) do
                if r.data and r.data.active and r.data.activelyCooled then active = active + 1 end
            end
            return active > 0 and total / active or nil
        end
        plants[group] = plant
        return plant
    end

    local units, counts = {}, {reactor = 0, turbine = 0}
    for _, name in ipairs(peripheral.getNames()) do
        local dev = peripheral.wrap(name)
        local kind = er.classify(name, dev)
        local adapter = kind and er.wrap(kind, name, dev)
        if adapter then
            counts[adapter.kind] = counts[adapter.kind] + 1
        end
        local id = "extreme:" .. name
        if adapter and not (ctx.known and ctx.known(id)) then
            local spec = perUnit[name] or {}
            local plant = plantFor(spec.steamGroup or "default")
            local defaults = merged(base, spec.settings)
            local cfg = merged(defaults, ctx.overrides and ctx.overrides(id))
            local isTurbine = adapter.kind == "turbine"
            local unit = {
                id = id,
                settings = SETTINGS[isTurbine and "turbine" or "fission"],
                defaults = defaults,
                name = spec.name or ((isTurbine and "Turbine " or "Fission ") .. counts[adapter.kind]),
                kind = isTurbine and "turbine" or "fission",
                driver = driver.id,
                mod = adapter.mod,
                adapter = adapter,
                cfg = cfg,
                controller = isTurbine and er.newTurbineController(cfg) or er.newBufferController(cfg),
                last = {},
                data = nil
            }
            local function say(level, msg) ctx.log.log(level, "[" .. unit.name .. "] " .. msg) end
            -- Manual rod mode survives reboots.
            local saved = ctx.persist and ctx.persist.state(id) or {}
            if not isTurbine and saved.auto == false then
                unit.controller.auto = false
                unit.controller.manualRods = tonumber(saved.manualRods) or 50
            end
            local function saveMode()
                if ctx.persist and not isTurbine then
                    ctx.persist.setState(id, {auto = unit.controller.auto,
                                              manualRods = unit.controller.manualRods})
                end
            end
            local failed = 0

            function unit.run()
                while true do
                    local data, err = er.read(unit.adapter)
                    if data then
                        failed = 0
                    else
                        failed = failed + 1
                        if failed == 1 then say("ERROR", "Read failed: " .. tostring(err)) end
                    end
                    unit.data = data
                    local hint = nil
                    if not isTurbine and data and data.activelyCooled and #plant.turbines > 0 then
                        hint = plant.steamDemandPerReactor()
                    end
                    local out = unit.controller:step(data, os.clock(), hint)
                    for _, e in ipairs(out.events) do say(e.level, e.message) end
                    for _, problem in ipairs(er.apply(unit.adapter, out, unit.last)) do
                        say("ERROR", problem)
                    end
                    sleep(cfg.controlInterval or 0.25)
                end
            end

            function unit.model()
                return {id = unit.id, name = unit.name, kind = unit.kind, mod = unit.mod,
                        data = unit.data, controller = unit.controller, limits = cfg}
            end

            function unit.summary()
                local d = unit.data
                return {status = d and (d.assembled == false and "unassembled"
                                        or (d.active and "online" or "offline")) or "no signal",
                        power = d and d.produced, alarm = unit.controller.alarms and unit.controller.alarms[1]}
            end

            function unit.act(action)
                local ctl = unit.controller
                local delta = action:match("^rods:(-?%d+)$")
                if action == "start" then
                    ctl:requestStart(); say("INFO", "Start requested from screen")
                elseif action == "stop" then
                    ctl:requestStop(); say("INFO", "Stop requested from screen")
                elseif action == "auto" and ctl.setAuto then
                    ctl:setAuto(not ctl.auto)
                    saveMode()
                    say("INFO", "Rod control: " .. (ctl.auto and "AUTO" or "MANUAL"))
                elseif delta and ctl.adjustRods then
                    ctl:adjustRods(tonumber(delta))
                    saveMode()
                    say("INFO", "Manual rods set to " .. math.floor(ctl.manualRods) .. "%")
                else
                    return false
                end
                return true
            end

            -- Neither mod can melt down or overspeed-break: leaving the
            -- last settings in place is safe, so there is nothing to do.
            function unit.failSafe() end

            function unit.record()
                local d = unit.data
                if not d or d.assembled == false then return end
                local row
                if isTurbine then
                    row = {active = tostring(d.active), mode = unit.controller.mode, rpm = d.rpm,
                           flow = d.flow, flow_set = d.flowSet, coils = tostring(d.coils),
                           buffer = (d.capacity or 0) > 0 and d.stored / d.capacity or nil,
                           production = d.produced}
                else
                    local level, _, production = er.bufferOf(d)
                    row = {active = tostring(d.active), rods = d.rods, buffer = level,
                           production = production,
                           fuel = (d.fuelMax or 0) > 0 and d.fuel / d.fuelMax or nil,
                           waste = d.waste, fuel_temp = d.fuelTemp, case_temp = d.caseTemp}
                end
                ctx.log.recordRow("extreme_" .. slug(unit.name), STATS[unit.kind], row)
            end

            table.insert(units, unit)
            if isTurbine then table.insert(plant.turbines, unit) else table.insert(plant.steamReactors, unit) end
            say("INFO", string.format("%s %s on %s", adapter.mod, adapter.kind, name))
        end
    end
    return units
end

return driver
