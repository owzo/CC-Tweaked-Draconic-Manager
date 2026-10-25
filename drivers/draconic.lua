--==============================================================
-- DRIVER: DRACONIC EVOLUTION REACTOR
-- Save as: drivers/draconic.lua
--==============================================================

--[[
README
-------
Wraps reac_utils (hardware + controller) as manager units, one per
Draconic reactor. Every driver exposes the same contract:

  driver.id, driver.label
  driver.discover(ctx) -> units, err
      ctx.config     config.lua table
      ctx.log        stat_utils
      ctx.import     module loader
      ctx.askGates   terminal prompt (single reactor, ambiguous gates)
      ctx.askUnits   terminal setup wizard (several reactors)
      Returns an empty list when the mod's blocks are not attached, so a
      player with only one supported mod never sees the others.

  unit.id, unit.name, unit.kind, unit.driver
  unit.run()            control loop; runs as its own coroutine
  unit.model()          table for the UI
  unit.act(action)      player input; returns true if handled
  unit.failSafe(reason) leave hardware safe when the program exits
  unit.record(extra)    append a stats row (rate limited)
  unit.cfg              live settings (controllers read it every cycle)
  unit.settings         editable settings schema (see persist.lua), or nil
  unit.defaults         config.lua values, restored by RESET
  ctx.overrides(id)     saved in-game changes to layer over the defaults

Each reactor gets its own coroutine, so on DE 1.20 (one server tick per
peripheral call) reactors do not slow each other down.
]]

local driver = {id = "draconic", label = "Draconic Evolution"}

local LINK_LOST_LIMIT = 10     -- consecutive failed reads before rediscovery
local SLOW_CYCLE = 0.25        -- seconds; warn when the control loop is slower

-- Settings players can change on the monitor (see persist.lua). Limits
-- are linked so a target can never pass its trip.
local SETTINGS = {
    {key = "targetTemperature", label = "Target Temp", step = 100, fmt = "temp",
     min = function(c) return c.safeTemperature + 500 end,
     max = function(c) return c.maxTemperature - 100 end},
    {key = "maxTemperature", label = "Trip Temp", step = 100, fmt = "temp",
     min = function(c) return c.targetTemperature + 100 end, max = 9000},
    {key = "targetField", label = "Target Field", step = 0.05, fmt = "pct",
     min = function(c) return c.minField + 0.05 end, max = 0.9},
    {key = "minField", label = "Trip Field", step = 0.01, fmt = "pct",
     min = 0.05, max = function(c) return c.targetField - 0.05 end},
    {key = "safeTemperature", label = "Restart At", step = 250, fmt = "temp",
     min = 1000, max = function(c) return c.targetTemperature - 500 end},
    {key = "autoRestart", label = "Auto Restart", fmt = "bool"},
    -- Temperature loop speed; lower if output hunts, higher if it lags.
    {key = "outputAggressiveness", label = "Output Gain", step = 0.1, fmt = "num",
     min = 0.2, max = 3}
}

local STATS_COLUMNS = {"status", "temperature", "field", "saturation", "fuel",
                       "generation", "input", "output", "core", "cycle_s"}

local function merged(base, overrides)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(overrides or {}) do out[k] = v end
    return out
end

local function slug(text)
    return (tostring(text):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

------------------------------------------------------------
-- UNIT
------------------------------------------------------------
local function newUnit(ctx, hw, spec, index, total)
    local reac_utils = ctx.import("reac_utils")
    local log = ctx.log
    local id = "draconic:" .. hw.reactorName
    local defaults = merged(ctx.config.reactor, spec and spec.settings)
    -- Values changed on the monitor win over config.lua.
    local cfg = merged(defaults, ctx.overrides and ctx.overrides(id))
    local name = hw.name or (total > 1 and ("Reactor " .. index) or "Reactor")

    local unit = {
        id = id,
        settings = SETTINGS,
        defaults = defaults,
        name = name,
        kind = "draconic",
        driver = driver.id,
        cfg = cfg,
        hw = hw,
        info = nil,
        failedReads = 0,
        cyclePeriod = nil,
        slowWarned = false
    }
    local prefix = total > 1 and ("[" .. name .. "] ") or ""
    local function say(level, msg) log.log(level, prefix .. msg) end

    unit.info = reac_utils.readInfo(hw.reactor)
    unit.controller = reac_utils.newController(cfg, unit.info)
    -- Continue from the gate's real setpoint so a restart does not jolt output.
    local ok, flow = pcall(hw.output.get)
    if ok and type(flow) == "number" then
        unit.controller.outputRate = flow
    end
    -- Manual output mode survives reboots, like drmon's config.txt.
    local saved = ctx.persist and ctx.persist.state(id) or {}
    if saved.autoOutput == false then
        unit.controller.autoOutput = false
        unit.controller.manualOutput = tonumber(saved.manualOutput) or unit.controller.outputRate
    end
    local function saveMode()
        if ctx.persist then
            ctx.persist.setState(id, {autoOutput = unit.controller.autoOutput,
                                      manualOutput = unit.controller.manualOutput})
        end
    end
    say("INFO", string.format("Reactor %s, input gate %s, output gate %s",
        hw.reactorName, hw.input.name, hw.output.name))

    function unit.run()
        while true do
            local cycleStart = os.clock()
            local info, err = reac_utils.readInfo(unit.hw.reactor)
            if info then
                unit.failedReads = 0
            else
                unit.failedReads = unit.failedReads + 1
                if unit.failedReads == 1 then
                    say("ERROR", "Reactor read failed: " .. tostring(err))
                end
            end
            unit.info = info

            local actions = unit.controller:step(info, os.clock())
            for _, e in ipairs(actions.events) do
                say(e.level, e.message)
            end
            if actions.command then
                say("INFO", "Reactor command: " .. actions.command)
            end
            for _, problem in ipairs(reac_utils.apply(unit.hw, actions)) do
                say("ERROR", problem)
            end

            if unit.failedReads >= LINK_LOST_LIMIT then
                -- Same names again: a modem that was re-placed comes back
                -- under its old name once it is right-clicked.
                local fresh = reac_utils.buildHw({name = unit.hw.name,
                    reactor = unit.hw.reactorName,
                    inputGate = unit.hw.input.name, outputGate = unit.hw.output.name})
                if fresh then
                    unit.hw = fresh
                    say("WARN", "Reconnected to reactor " .. fresh.reactorName)
                end
                unit.failedReads = 0
            end

            -- Peripheral calls may already have used the interval (DE 1.20
            -- runs them on the server thread); otherwise wait out the rest.
            local remaining = cfg.controlInterval - (os.clock() - cycleStart)
            if remaining > 0 then
                sleep(remaining)
            end

            local period = os.clock() - cycleStart
            unit.cyclePeriod = unit.cyclePeriod and (unit.cyclePeriod * 0.9 + period * 0.1) or period
            if unit.cyclePeriod > SLOW_CYCLE and not unit.slowWarned then
                unit.slowWarned = true
                say("WARN", string.format(
                    "Control loop runs every %.2fs (server lag?); keep conservative limits",
                    unit.cyclePeriod))
            end
        end
    end

    function unit.model()
        return {
            id = unit.id, name = unit.name, kind = unit.kind,
            info = unit.info, controller = unit.controller, limits = cfg
        }
    end

    -- Summary used by overviews: is it producing, and how much.
    function unit.summary()
        local i = unit.info
        return {
            status = i and i.status or "no signal",
            power = unit.controller.outputRate,
            alarm = unit.controller.alarms[1]
        }
    end

    function unit.act(action)
        local ctl = unit.controller
        local delta = action:match("^out:(-?%d+)$")
        if delta then
            ctl:adjustManualOutput(tonumber(delta))
            saveMode()
            say("INFO", "Manual output set to " .. tostring(math.floor(ctl.manualOutput)))
        elseif action == "start" then
            ctl:requestStart()
            say("INFO", "Start requested from screen")
        elseif action == "stop" then
            ctl:requestStop()
            say("INFO", "Stop requested from screen")
        elseif action == "auto" then
            ctl:setAutoOutput(not ctl.autoOutput)
            saveMode()
            say("INFO", "Output regulation: " .. (ctl.autoOutput and "AUTO" or "MANUAL"))
        else
            return false
        end
        return true
    end

    function unit.failSafe(reason)
        local input = unit.controller:blindInput()
        reac_utils.apply(unit.hw, {input = input, output = 0, events = {}})
        say("WARN", string.format(
            "Program exiting (%s); gates left fail-safe: input %d, output 0",
            tostring(reason), math.floor(input)))
    end

    function unit.record(extra)
        local i, ctl = unit.info, unit.controller
        if not i then return end
        log.recordRow((total > 1) and ("draconic_" .. slug(name)) or "reactor_stats",
            STATS_COLUMNS, {
                status = i.status, temperature = i.temperature,
                field = i.fieldPct, saturation = i.satPct, fuel = i.fuelRemaining,
                generation = i.generationRate, input = ctl.inputRate,
                output = ctl.outputRate, core = extra and extra.corePct,
                cycle_s = unit.cyclePeriod
            })
    end

    return unit
end

------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------
function driver.discover(ctx)
    local reac_utils = ctx.import("reac_utils")
    local pcfg = ctx.config.peripherals or {}

    -- Nothing Draconic attached and nothing configured: stay silent.
    local configured = pcfg.reactor or (type(pcfg.reactors) == "table" and #pcfg.reactors > 0)
    local anyReactor = false
    for _, n in ipairs(peripheral.getNames()) do
        if reac_utils.isReactor(peripheral.wrap(n)) then anyReactor = true; break end
    end
    if not configured and not anyReactor then
        return {}, reac_utils.missingHint and reac_utils.missingHint() or nil
    end

    local list, err = reac_utils.discoverAll(pcfg, ctx.askGates, ctx.askUnits)
    if not list then return {}, err end

    local specs = type(pcfg.reactors) == "table" and pcfg.reactors or {}
    local units = {}
    for i, hw in ipairs(list) do
        -- On a hot-plug rescan, reactors already running are skipped.
        if not (ctx.known and ctx.known("draconic:" .. hw.reactorName)) then
            table.insert(units, newUnit(ctx, hw, specs[i], i, #list))
        end
    end
    return units
end

return driver
