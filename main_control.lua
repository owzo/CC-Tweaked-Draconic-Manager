--==============================================================
-- MAIN CONTROL SCRIPT (COMPUTER)
-- Save as: main_control.lua
--==============================================================

--[[
README
-------
Entry point for the CC:Tweaked Draconic Reactor Manager.

Three cooperative loops run under parallel.waitForAny:
  controlLoop  reads the reactor, runs the controller, drives the gates
  uiLoop       redraws the dashboard and records statistics
  eventLoop    touchscreen / mouse input and peripheral hot-plugging

Shared state lives in the `state` table. ComputerCraft coroutines only
switch at yields (sleep / pullEvent), so no locking is needed.

On exit (Ctrl+T or a crash) the gates are left in the fail-safe
position: output at zero and input at twice the last field demand.
]]

local config            = require("config")
local reac_utils        = require("reac_utils")
local monitor_utils     = require("monitor_utils")
local stat_utils        = require("stat_utils")
local energy_core_utils = require("energy_core_utils")

local VERSION = "3.0"
local LINK_LOST_LIMIT = 10     -- consecutive failed reads before rediscovery

local state = {
    hw         = nil,          -- reac_utils.discover() result
    controller = nil,
    info       = nil,
    core       = nil,          -- energy core handle
    coreInfo   = nil,
    failedReads = 0
}

------------------------------------------------------------
-- CONFIG VALIDATION
------------------------------------------------------------
local function validateConfig(cfg)
    local r = cfg.reactor
    local problems = {}
    local function check(cond, msg)
        if not cond then table.insert(problems, msg) end
    end
    check(type(r) == "table", "config.reactor is missing")
    if type(r) ~= "table" then return problems end
    check(r.targetTemperature < r.maxTemperature, "targetTemperature must be below maxTemperature")
    check(r.maxTemperature <= 9000, "maxTemperature above 9000C is not survivable")
    check(r.safeTemperature < r.targetTemperature, "safeTemperature must be below targetTemperature")
    check(r.minField > 0 and r.minField < r.targetField, "minField must be between 0 and targetField")
    check(r.targetField < 0.95, "targetField must be below 0.95")
    check(r.minFuel >= 0 and r.minFuel < 1, "minFuel must be between 0 and 1")
    check(r.maxInflow >= r.chargeInflow, "maxInflow must be at least chargeInflow")
    check(r.controlInterval >= 0.05 and r.controlInterval <= 1, "controlInterval must be 0.05-1 seconds")
    return problems
end

------------------------------------------------------------
-- TERMINAL HELPERS
------------------------------------------------------------
local function banner()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("CC:Tweaked Draconic Reactor Manager v" .. VERSION)
    print(string.rep("-", 40))
end

-- Asked once when two gates exist and config.lua does not name them.
local function askGates(gates)
    print("")
    print("Found " .. #gates .. " flux gates:")
    for i, name in ipairs(gates) do
        print("  " .. i .. ") " .. name)
    end
    print("Which gate feeds the reactor ENERGY INJECTOR?")
    write("Number: ")
    local inIdx = tonumber(read())
    local outIdx
    if #gates == 2 and inIdx then
        outIdx = inIdx == 1 and 2 or 1
    else
        print("Which gate takes power from a STABILIZER?")
        write("Number: ")
        outIdx = tonumber(read())
    end
    if not inIdx or not outIdx or not gates[inIdx] or not gates[outIdx] then
        return nil
    end
    print("Saved. Run 'set draconic.inputGate' to change later.")
    return gates[inIdx], gates[outIdx]
end

local function discoverHardware()
    while true do
        local hw, err = reac_utils.discover(config.peripherals, askGates)
        if hw then
            stat_utils.log("INFO", string.format("Reactor %s, input gate %s, output gate %s",
                hw.reactorName, hw.input.name, hw.output.name))
            return hw
        end
        stat_utils.log("ERROR", err)
        print("Attached peripherals:")
        local list = reac_utils.describePeripherals()
        if #list == 0 then print("  (none)") end
        for _, line in ipairs(list) do print("  " .. line) end
        print("Retrying in 5 seconds (Ctrl+T to quit)...")
        sleep(5)
    end
end

local function setupCore()
    local core, why = energy_core_utils.discover(config.peripherals.energyCore)
    state.core = core
    if core then
        stat_utils.log("INFO", "Energy core: " .. core.name)
    elseif config.peripherals.energyCore then
        stat_utils.log("WARN", "Energy core: " .. why)
    end
end

local function setupDisplays()
    local count = monitor_utils.init(config.peripherals.monitors, config.ui)
    if count == 0 then
        stat_utils.log("INFO", "No monitor found; using the computer screen")
    end
end

------------------------------------------------------------
-- LOOPS
------------------------------------------------------------
local function controlLoop()
    local c = config.reactor
    while true do
        local cycleStart = os.clock()
        local info, err = reac_utils.readInfo(state.hw.reactor)
        if info then
            state.failedReads = 0
        else
            state.failedReads = state.failedReads + 1
            if state.failedReads == 1 then
                stat_utils.log("ERROR", "Reactor read failed: " .. tostring(err))
            end
        end
        state.info = info

        local actions = state.controller:step(info, os.clock())
        for _, e in ipairs(actions.events) do
            stat_utils.log(e.level, e.message)
        end
        if actions.command then
            stat_utils.log("INFO", "Reactor command: " .. actions.command)
        end
        for _, problem in ipairs(reac_utils.apply(state.hw, actions)) do
            stat_utils.log("ERROR", problem)
        end

        if state.failedReads >= LINK_LOST_LIMIT then
            -- Peripheral names change if a modem was replaced; look again.
            local hw = reac_utils.discover(config.peripherals, nil)
            if hw then
                state.hw = hw
                stat_utils.log("WARN", "Reconnected to reactor " .. hw.reactorName)
            end
            state.failedReads = 0
        end

        -- Peripheral calls may already have used the interval (DE 1.20
        -- runs them on the server thread); otherwise wait out the rest.
        local remaining = c.controlInterval - (os.clock() - cycleStart)
        if remaining > 0 then
            sleep(remaining)
        end
    end
end

local function uiLoop()
    while true do
        state.coreInfo = energy_core_utils.read(state.core, os.clock())
        monitor_utils.render({
            info       = state.info,
            controller = state.controller,
            core       = state.coreInfo,
            limits     = config.reactor,
            events     = stat_utils.recent
        })
        if state.info then
            local i, ctl = state.info, state.controller
            stat_utils.recordStats({
                status = i.status, temperature = i.temperature,
                fieldPct = i.fieldPct, satPct = i.satPct,
                fuelRemaining = i.fuelRemaining, generationRate = i.generationRate,
                inputRate = ctl.inputRate, outputRate = ctl.outputRate,
                corePct = state.coreInfo and state.coreInfo.pct
            })
        end
        sleep(config.ui.refreshInterval)
    end
end

local function dispatch(action)
    local ctl = state.controller
    if not action then return end
    local delta = action:match("^out:(-?%d+)$")
    if delta then
        ctl:adjustManualOutput(tonumber(delta))
        stat_utils.log("INFO", "Manual output set to " .. monitor_utils.formatRF(ctl.manualOutput))
    elseif action == "start" then
        ctl:requestStart()
        stat_utils.log("INFO", "Start requested from screen")
    elseif action == "stop" then
        ctl:requestStop()
        stat_utils.log("INFO", "Stop requested from screen")
    elseif action == "auto" then
        ctl:setAutoOutput(not ctl.autoOutput)
        stat_utils.log("INFO", "Output regulation: " .. (ctl.autoOutput and "AUTO" or "MANUAL"))
    end
end

local function eventLoop()
    while true do
        local event, a, b, c = os.pullEvent()
        if event == "monitor_touch" then
            dispatch(monitor_utils.handleTouch(a, b, c))
        elseif event == "mouse_click" and monitor_utils.usesTerminal() then
            dispatch(monitor_utils.handleTouch(monitor_utils.TERMINAL, b, c))
        elseif event == "peripheral" or event == "peripheral_detach"
                or event == "monitor_resize" then
            setupDisplays()
            if not state.core then setupCore() end
        end
    end
end

------------------------------------------------------------
-- SHUTDOWN
------------------------------------------------------------
local function failSafe(reason)
    if not state.hw then return end
    local input = state.controller and state.controller:blindInput()
        or config.reactor.chargeInflow
    local actions = {input = input, output = 0, events = {}}
    reac_utils.apply(state.hw, actions)
    stat_utils.log("WARN", string.format(
        "Program exiting (%s); gates left fail-safe: input %s, output 0",
        tostring(reason), monitor_utils.formatRF(input)))
end

------------------------------------------------------------
-- ENTRY POINT
------------------------------------------------------------
local function main()
    banner()
    stat_utils.init(config.logging)

    local problems = validateConfig(config)
    if #problems > 0 then
        for _, p in ipairs(problems) do printError("config.lua: " .. p) end
        error("Fix config.lua and run again.", 0)
    end

    stat_utils.log("INFO", "Starting v" .. VERSION)
    state.hw = discoverHardware()
    setupCore()

    state.info = reac_utils.readInfo(state.hw.reactor)
    state.controller = reac_utils.newController(config.reactor, state.info)
    -- Continue from the gate's real flow so a restart does not jolt output.
    local ok, flow = pcall(state.hw.output.get)
    if ok and type(flow) == "number" then
        state.controller.outputRate = flow
    end

    setupDisplays()
    print("Running. Hold Ctrl+T to stop.")
    parallel.waitForAny(controlLoop, uiLoop, eventLoop)
end

local ok, err = pcall(main)
if not ok then
    failSafe(err)
    if err ~= "Terminated" then
        printError("Fatal: " .. tostring(err))
        print("See " .. fs.combine(config.logging.directory, "draconic.log"))
        stat_utils.log("CRIT", "Fatal: " .. tostring(err))
    end
end
