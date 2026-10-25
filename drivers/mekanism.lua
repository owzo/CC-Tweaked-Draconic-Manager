--==============================================================
-- DRIVER: MEKANISM (fission, fusion, industrial turbine, boiler)
-- Save as: drivers/mekanism.lua
--==============================================================

--[[
README
-------
Units for Mekanism multiblocks through mek_utils. Finds nothing when
Mekanism is not installed. One unit per multiblock: extra ports/valves
of the same structure are recognised by the structure's corner.

  kind "mek_fission"  burn-rate governor + reactor protection (SCRAM)
  kind "mek_fusion"   monitoring + injection rate setting
  kind "mek_turbine"  monitoring + alarms
  kind "mek_boiler"   monitoring + alarms

The fission reactor can melt down. On program exit (Ctrl+T, crash,
update) running fission reactors are SCRAMmed unless
config.mekanism.scramOnExit is false: an unsupervised reactor is the
riskier state.
]]

local driver = {id = "mekanism", label = "Mekanism"}

local function merged(base, overrides)
    local out = {}
    for k, v in pairs(base or {}) do out[k] = v end
    for k, v in pairs(overrides or {}) do out[k] = v end
    return out
end

local function slug(text)
    return (tostring(text):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

local function pct(key, label, min, max)
    return {key = key, label = label, step = 0.05, fmt = "pct", min = min, max = max}
end

local SETTINGS = {
    mek_fission = {
        {key = "targetBurnRate", label = "Burn Target", step = 0.5, fmt = "num", min = 0, max = 10000},
        -- Damage starts at 1200 K: the trip may never be set that high.
        {key = "maxTemperature", label = "Scram Temp K", step = 25, fmt = "int",
         min = function(c) return 400 + c.tempMargin end, max = 1150},
        pct("minCoolant", "Scram Coolant", 0.05, 0.9),
        pct("maxWaste", "Scram Waste", 0.1, 0.95)
    },
    mek_fusion = {
        {key = "fusionInjection", label = "Injection", step = 2, fmt = "int", min = 2, max = 98}
    }
}

local KIND = {fission = "mek_fission", fusion = "mek_fusion", turbine = "mek_turbine", boiler = "mek_boiler"}
local LABEL = {fission = "Fission", fusion = "Fusion", turbine = "Mek Turbine", boiler = "Boiler"}

local STATS = {
    mek_fission = {"active", "temperature", "damage", "burn", "burn_target", "coolant", "heated", "fuel", "waste"},
    mek_fusion = {"plasma", "case", "injection", "production", "dt_fuel"},
    mek_turbine = {"production", "flow", "steam", "energy"},
    mek_boiler = {"boil_rate", "water", "steam", "temperature"}
}

function driver.discover(ctx)
    local mek = ctx.import("mek_utils")
    local base = ctx.config.mekanism or {}
    local perUnit = {}
    for _, spec in ipairs(base.units or {}) do
        if spec.peripheral then perUnit[spec.peripheral] = spec end
    end

    local units, seen, counts = {}, {}, {}
    for _, name in ipairs(peripheral.getNames()) do
        local kind = mek.classify(name)
        if kind then
            local dev = peripheral.wrap(name)
            local key = kind .. "@" .. mek.multiblockKey(name, dev)
            local id = "mekanism:" .. key
            if not seen[key] and not (ctx.known and ctx.known(id)) then
                seen[key] = true
                counts[kind] = (counts[kind] or 0) + 1
                local spec = perUnit[name] or {}
                local unitKind = KIND[kind]
                local defaults = merged(base, spec.settings)
                local cfg = merged(defaults, ctx.overrides and ctx.overrides(id))
                local adapter = mek.wrap(kind, name, dev)
                local unit = {
                    id = id, kind = unitKind, driver = driver.id, mod = "Mekanism",
                    name = spec.name or (LABEL[kind] .. " " .. counts[kind]),
                    adapter = adapter, cfg = cfg, defaults = defaults,
                    settings = SETTINGS[unitKind], data = nil
                }
                if kind == "fission" then
                    unit.controller = mek.newFissionController(cfg)
                elseif kind == "fusion" then
                    unit.controller = mek.newFusionController(cfg)
                else
                    unit.controller = mek.newWatchController(kind)
                end
                local function say(level, msg) ctx.log.log(level, "[" .. unit.name .. "] " .. msg) end
                local failed = 0

                function unit.run()
                    while true do
                        local data, err = mek.read(unit.adapter)
                        if data then failed = 0 else
                            failed = failed + 1
                            if failed == 1 then say("ERROR", "Read failed: " .. tostring(err)) end
                        end
                        unit.data = data
                        local out = unit.controller:step(data, os.clock())
                        for _, e in ipairs(out.events or {}) do say(e.level, e.message) end
                        for _, problem in ipairs(mek.apply(unit.adapter, out)) do say("ERROR", problem) end
                        sleep(cfg.controlInterval or 0.5)
                    end
                end

                function unit.model()
                    return {id = unit.id, name = unit.name, kind = unit.kind, mod = unit.mod,
                            data = unit.data, controller = unit.controller, limits = cfg}
                end

                function unit.summary()
                    local d = unit.data
                    local power = d and (unitKind == "mek_turbine" or unitKind == "mek_fusion") and d.production or 0
                    return {status = d and (d.formed == false and "unformed" or "online") or "no signal",
                            power = power, alarm = unit.controller.alarms[1]}
                end

                function unit.act(action)
                    local ctl = unit.controller
                    local burn = action:match("^burn:(-?[%d%.]+)$")
                    local inj = action:match("^inj:(-?%d+)$")
                    if action == "start" and ctl.requestStart then
                        ctl:requestStart(); say("INFO", "Start requested from screen")
                    elseif action == "stop" and ctl.requestStop then
                        ctl:requestStop(); say("WARN", "SCRAM requested from screen")
                    elseif burn and ctl.adjustTarget then
                        ctl:adjustTarget(tonumber(burn), unit.data and unit.data.maxBurnRate)
                        if ctx.persist then ctx.persist.setOverride(unit.id, "targetBurnRate", cfg.targetBurnRate) end
                        say("INFO", string.format("Burn target %.1f mB/t", cfg.targetBurnRate))
                    elseif inj and unitKind == "mek_fusion" then
                        cfg.fusionInjection = math.max(2, math.min(98, (cfg.fusionInjection or 2) + tonumber(inj)))
                        if ctx.persist then ctx.persist.setOverride(unit.id, "fusionInjection", cfg.fusionInjection) end
                        say("INFO", "Injection rate " .. cfg.fusionInjection)
                    else
                        return false
                    end
                    return true
                end

                function unit.failSafe(reason)
                    if unitKind == "mek_fission" and cfg.scramOnExit ~= false then
                        unit.adapter.scram()
                        say("WARN", "Program exiting (" .. tostring(reason) .. "); reactor SCRAMmed")
                    end
                end

                function unit.record()
                    local d = unit.data
                    if not d or d.formed == false then return end
                    local row
                    if unitKind == "mek_fission" then
                        row = {active = tostring(d.active), temperature = d.temperature, damage = d.damage,
                               burn = d.burnRate, burn_target = cfg.targetBurnRate, coolant = d.coolant,
                               heated = d.heated, fuel = d.fuel, waste = d.waste}
                    elseif unitKind == "mek_fusion" then
                        row = {plasma = d.plasma, case = d.case, injection = d.injection,
                               production = d.production, dt_fuel = d.dtFuel}
                    elseif unitKind == "mek_turbine" then
                        row = {production = d.production, flow = d.flow, steam = d.steam,
                               energy = (d.maxEnergy or 0) > 0 and d.energy / d.maxEnergy or nil}
                    else
                        row = {boil_rate = d.boilRate, water = d.water, steam = d.steam, temperature = d.temperature}
                    end
                    ctx.log.recordRow("mekanism_" .. slug(unit.name), STATS[unitKind], row)
                end

                say("INFO", "Mekanism " .. kind .. " on " .. name)
                table.insert(units, unit)
            end
        end
    end
    return units
end

return driver
