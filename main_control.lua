--==============================================================
-- MAIN CONTROL SCRIPT (COMPUTER)
-- Save as: main_control.lua
--==============================================================

--[[
README
-------
Entry point for the CC:Tweaked Reactor Manager.

Drivers (drivers/*.lua) discover "units": reactors, turbines, storage.
Each unit runs its own control coroutine; alongside them:
  uiLoop     redraws the dashboards and records statistics
  eventLoop  touchscreen / mouse input and monitor hot-plugging

ComputerCraft coroutines only switch at yields (sleep / pullEvent), so
no locking is needed.

On exit (Ctrl+T or a crash) every unit leaves its hardware fail-safe
(Draconic: output at zero, field input at twice the last demand).
]]

-- `require` only exists for programs started by the shell. When launched
-- another way (os.run, dofile, os.loadAPI, an old startup file) fall back
-- to loading the module file from this program's directory.
local loaded = {}
local function import(name)
    if type(require) == "function" then
        return require(name)
    end
    if loaded[name] ~= nil then return loaded[name] end
    local dir = ""
    if shell and shell.getRunningProgram then
        dir = fs.getDir(shell.getRunningProgram())
    end
    local path = fs.combine(dir, (name:gsub("%.", "/")) .. ".lua")
    if not fs.exists(path) then
        error("Missing " .. path .. " - run the installer again", 0)
    end
    loaded[name] = dofile(path)
    return loaded[name]
end

local config        = import("config")
local monitor_utils = import("monitor_utils")
local stat_utils    = import("stat_utils")

local VERSION = "4.0"

-- Every driver is optional: a missing or broken driver file only removes
-- that mod's support. Drivers whose mod is not attached find no units.
local DRIVERS = {"drivers.draconic", "drivers.extreme", "drivers.energy_core"}

local state = {
    units = {},                -- every discovered unit, in driver order
    byId = {}
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
    print("CC:Tweaked Reactor Manager v" .. VERSION)
    print(string.rep("-", 40))
end

local function askNumber(prompt)
    write(prompt)
    return tonumber(read())
end

-- Asked once when one reactor has two or more gates and config.lua does
-- not name them.
local function askGates(gates)
    print("")
    print("Found " .. #gates .. " flux gates:")
    for i, name in ipairs(gates) do
        print("  " .. i .. ") " .. name)
    end
    print("Which gate feeds the reactor ENERGY INJECTOR?")
    local inIdx = askNumber("Number: ")
    local outIdx
    if #gates == 2 and inIdx then
        outIdx = inIdx == 1 and 2 or 1
    else
        print("Which gate takes power from a STABILIZER?")
        outIdx = askNumber("Number: ")
    end
    if not inIdx or not outIdx or not gates[inIdx] or not gates[outIdx] then
        return nil
    end
    print("Saved. Run 'set draconic.inputGate' to change later.")
    return gates[inIdx], gates[outIdx]
end

-- One-time wizard when several Draconic reactor peripherals are attached.
-- A reactor with modems on two of its blocks shows up twice; the player
-- skips the duplicate by leaving its input gate blank.
local function askUnits(reactors, gates)
    print("")
    print("Several Draconic reactors found. Set up each one.")
    print("Flux gates:")
    for i, name in ipairs(gates) do print("  " .. i .. ") " .. name) end
    local specs, used = {}, {}
    for _, rname in ipairs(reactors) do
        local dev = peripheral.wrap(rname)
        local ok, info = pcall(dev.getReactorInfo)
        local desc = ""
        if ok and type(info) == "table" then
            desc = string.format(" [%s, %.0fC]", tostring(info.status), tonumber(info.temperature) or 0)
        end
        print("")
        print("Reactor peripheral " .. rname .. desc)
        local inIdx = askNumber("  Input gate (feeds injector), blank = skip duplicate: ")
        if inIdx and gates[inIdx] and not used[gates[inIdx]] then
            local outIdx = askNumber("  Output gate (from stabilizer): ")
            if not outIdx or not gates[outIdx] or used[gates[outIdx]] or outIdx == inIdx then
                print("  Invalid output gate; reactor skipped.")
            else
                write("  Name [Reactor " .. (#specs + 1) .. "]: ")
                local nameIn = read()
                local spec = {
                    name = (nameIn and nameIn ~= "") and nameIn or ("Reactor " .. (#specs + 1)),
                    reactor = rname, inputGate = gates[inIdx], outputGate = gates[outIdx]
                }
                used[spec.inputGate], used[spec.outputGate] = true, true
                table.insert(specs, spec)
            end
        end
    end
    print("")
    print("Saved " .. #specs .. " reactor(s). Run 'set draconic.units nil' to redo setup.")
    return specs
end

------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------
local function loadDrivers()
    local drivers = {}
    for _, name in ipairs(DRIVERS) do
        local ok, drv = pcall(import, name)
        if ok and type(drv) == "table" then
            table.insert(drivers, drv)
        else
            stat_utils.log("WARN", "Driver " .. name .. " unavailable: " .. tostring(drv))
        end
    end
    return drivers
end

local function controlsSomething(units)
    for _, u in ipairs(units) do
        if u.kind ~= "storage" then return true end
    end
    return false
end

local function describePeripherals()
    local lines = {}
    for _, name in ipairs(peripheral.getNames()) do
        table.insert(lines, name .. " (" .. tostring(peripheral.getType(name)) .. ")")
    end
    return lines
end

local function discoverUnits(drivers)
    local ctx = {config = config, log = stat_utils, import = import,
                 askGates = askGates, askUnits = askUnits}
    while true do
        local units, problems = {}, {}
        for _, drv in ipairs(drivers) do
            local ok, found, err = pcall(drv.discover, ctx)
            if not ok then
                table.insert(problems, drv.label .. ": " .. tostring(found))
            else
                for _, u in ipairs(found or {}) do table.insert(units, u) end
                if err then table.insert(problems, err) end
            end
        end
        if controlsSomething(units) then
            for _, p in ipairs(problems) do stat_utils.log("WARN", p) end
            return units
        end
        for _, p in ipairs(problems) do stat_utils.log("ERROR", p) end
        if #problems == 0 then
            stat_utils.log("ERROR", "No reactor found. Connect wired modems (right-click them) to your reactor blocks.")
        end
        print("Attached peripherals:")
        local list = describePeripherals()
        if #list == 0 then print("  (none)") end
        for _, line in ipairs(list) do print("  " .. line) end
        print("Retrying in 5 seconds (Ctrl+T to quit)...")
        sleep(5)
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
local function firstStorage()
    for _, u in ipairs(state.units) do
        if u.kind == "storage" then return u end
    end
end

local function uiLoop()
    while true do
        local storage = firstStorage()
        local core = storage and storage.info
        local models = {}
        for _, u in ipairs(state.units) do
            if u.kind ~= "storage" then table.insert(models, u.model()) end
        end
        monitor_utils.render({units = models, core = core, events = stat_utils.recent})
        if monitor_utils.lastError and monitor_utils.lastError ~= state.reportedUiError then
            state.reportedUiError = monitor_utils.lastError
            stat_utils.log("ERROR", "Display: " .. monitor_utils.lastError)
        end
        for _, u in ipairs(state.units) do
            u.record({corePct = core and core.pct})
        end
        sleep(config.ui.refreshInterval)
    end
end

local function dispatch(action, unitId)
    if not action or action == "redraw" then return end
    local unit = state.byId[unitId]
    if unit then unit.act(action) end
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
        end
    end
end

------------------------------------------------------------
-- SHUTDOWN
------------------------------------------------------------
local function failSafe(reason)
    for _, u in ipairs(state.units) do
        local ok, err = pcall(u.failSafe, reason)
        if not ok then
            stat_utils.log("ERROR", u.name .. ": fail-safe failed: " .. tostring(err))
        end
    end
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
    state.units = discoverUnits(loadDrivers())
    for _, u in ipairs(state.units) do state.byId[u.id] = u end

    setupDisplays()
    print(string.format("Running %d unit(s). Hold Ctrl+T to stop.", #state.units))
    local loops = {uiLoop, eventLoop}
    for _, u in ipairs(state.units) do table.insert(loops, u.run) end
    parallel.waitForAny((table.unpack or unpack)(loops))
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
