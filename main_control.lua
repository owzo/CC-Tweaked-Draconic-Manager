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
local persist       = import("persist")
local log_shipper   = import("log_shipper")
local alarms        = import("alarms")
local totals        = import("totals")
local updater       = import("updater")

local VERSION = "4.1"
local TOTALS_SAVE_SECONDS = 60
local UPDATE_CONFIRM_SECONDS = 10

-- Every driver is optional: a missing or broken driver file only removes
-- that mod's support. Drivers whose mod is not attached find no units.
local DRIVERS = {"drivers.draconic", "drivers.extreme", "drivers.mekanism", "drivers.energy_core"}

local state = {
    units = {},                -- every discovered unit, in driver order
    byId = {},
    drivers = {},
    rescanAt = nil,            -- pending hot-plug rescan (os.clock time)
    update = {text = "not checked"},
    alarmCount = 0
}

-- How long peripheral events must settle before a hot-plug rescan.
local RESCAN_DELAY = 2

------------------------------------------------------------
-- TASK SCHEDULER
------------------------------------------------------------
-- Like parallel.waitForAny, but tasks can be added while running, so a
-- reactor connected later gets its own control loop without a restart.
local tasks = {}

local function spawn(fn)
    local task = {co = coroutine.create(fn)}
    table.insert(tasks, task)
    local ok, filter = coroutine.resume(task.co)
    if not ok then error(filter, 0) end
    task.filter = filter
end

local function runTasks()
    while true do
        local event = {os.pullEventRaw()}
        -- Tasks spawned while handling this event start with the next one.
        for i = 1, #tasks do
            local task = tasks[i]
            if coroutine.status(task.co) ~= "dead"
                    and (task.filter == nil or task.filter == event[1] or event[1] == "terminate") then
                local ok, filter = coroutine.resume(task.co, (table.unpack or unpack)(event))
                if not ok then error(filter, 0) end
                task.filter = filter
            end
        end
    end
end

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

local function knownUnit(id) return state.byId[id] ~= nil end

local function discoverUnits(drivers)
    local ctx = {config = config, log = stat_utils, import = import,
                 askGates = askGates, askUnits = askUnits,
                 overrides = persist.overrides, persist = persist, known = knownUnit}
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

-- Monitor pins: saved in-game pins win over config.ui.monitorUnits
-- (which may name a unit by id or by its display name).
local function currentPins()
    local pins = {}
    for monitor, ref in pairs(config.ui.monitorUnits or {}) do
        for _, u in ipairs(state.units) do
            if u.id == ref or u.name == ref then pins[monitor] = u.id end
        end
    end
    for monitor, id in pairs(persist.pins()) do pins[monitor] = id end
    return pins
end

-- Every unit's active alarms, for the alarm outputs.
local function activeAlarms()
    local list = {}
    for _, u in ipairs(state.units) do
        local ctl = u.controller
        for _, text in ipairs(ctl and ctl.alarms or {}) do
            table.insert(list, {unit = u.name, text = text})
        end
    end
    return list
end

local function uiLoop()
    local nextSample, lastTick, nextSave = 0, os.clock(), os.clock() + TOTALS_SAVE_SECONDS
    while true do
        -- Long-term totals: integrate each unit's generation.
        local now = os.clock()
        for _, u in ipairs(state.units) do
            if u.kind ~= "storage" then
                local ok, s = pcall(u.summary)
                if ok and s then totals.add(u.id, s.power, now - lastTick) end
            end
        end
        lastTick = now
        if now >= nextSave then
            totals.save()
            nextSave = now + TOTALS_SAVE_SECONDS
        end

        local current = activeAlarms()
        state.alarmCount = #current
        for _, a in ipairs(alarms.update(current, now)) do
            stat_utils.log("WARN", "ALARM " .. a.unit .. ": " .. a.text)
        end

        local storage = firstStorage()
        local core = storage and storage.info
        local models = {}
        for _, u in ipairs(state.units) do
            local m = u.model()
            m.settings = u.settings
            table.insert(models, m)
        end
        if os.clock() >= nextSample then
            monitor_utils.sample(models)
            nextSample = os.clock() + (config.ui.graphInterval or 5)
        end
        local hourly, lifetime = totals.network(24)
        if state.update.confirmUntil and os.clock() > state.update.confirmUntil then
            state.update.confirmUntil = nil
        end
        monitor_utils.render({units = models, core = core, events = stat_utils.recent,
                              pins = currentPins(), formatSetting = persist.format,
                              hourlyFor = function(id) return totals.lastHours(id, 24) end,
                              system = {version = VERSION, hourly = hourly, lifetime = lifetime,
                                        alarms = {count = state.alarmCount, silenced = alarms.isSilenced()},
                                        update = {text = state.update.text, color = state.update.color,
                                                  confirm = state.update.confirmUntil ~= nil}}})
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

local failSafe

local function checkUpdate()
    state.update = {text = "checking...", color = colors.yellow}
    local latest, err = updater.check(config.update.repoBase)
    if not latest then
        state.update = {text = "check failed", color = colors.red}
        stat_utils.log("WARN", "Update check failed: " .. tostring(err))
    elseif updater.newer(latest, VERSION) then
        state.update = {text = "v" .. latest .. " available", color = colors.orange, latest = latest}
        stat_utils.log("INFO", "Update available: v" .. latest)
    else
        state.update = {text = "up to date", color = colors.green}
    end
end

local function installUpdate()
    stat_utils.log("WARN", "Installing update from " .. config.update.repoBase)
    state.update = {text = "installing...", color = colors.yellow}
    failSafe("update")
    local ok, err = updater.install(config.update.repoBase)
    if not ok then
        state.update = {text = "update failed", color = colors.red}
        stat_utils.log("ERROR", "Update failed: " .. tostring(err))
        return
    end
    totals.save()
    stat_utils.log("INFO", "Update installed; rebooting")
    os.reboot()
end

local function dispatch(action, unitId, monitor)
    if not action or action == "redraw" then return end
    -- System-wide actions (no unit needed).
    if action == "alarm:silence" then
        alarms.silence()
        stat_utils.log("INFO", "Alarm sound silenced")
        return
    elseif action == "sys:check" then
        spawn(checkUpdate)
        return
    elseif action == "sys:update" then
        if state.update.confirmUntil then
            state.update.confirmUntil = nil
            spawn(installUpdate)
        else
            -- Two taps: the first arms, the second (within 10 s) installs.
            state.update.confirmUntil = os.clock() + UPDATE_CONFIRM_SECONDS
        end
        return
    end
    local unit = state.byId[unitId]
    if not unit then return end

    local key, dir = action:match("^set:([%w_]+):(-?%d+)$")
    if key then
        local value = persist.adjust(unit.cfg, unit.settings, key, tonumber(dir))
        if value ~= nil then
            persist.setOverride(unit.id, key, value)
            stat_utils.log("INFO", string.format("[%s] %s set to %s", unit.name, key, tostring(value)))
        end
    elseif action == "reset" then
        for _, item in ipairs(unit.settings or {}) do
            unit.cfg[item.key] = unit.defaults[item.key]
        end
        persist.clearOverrides(unit.id)
        stat_utils.log("INFO", "[" .. unit.name .. "] settings reset to config.lua")
    elseif action == "pin" then
        local pinned = persist.pins()[monitor] == unit.id
        persist.setPin(monitor, not pinned and unit.id or nil)
        stat_utils.log("INFO", string.format("Monitor %s %s %s", monitor,
            pinned and "unpinned from" or "pinned to", unit.name))
    else
        unit.act(action)
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
            if event == "peripheral" then state.rescanAt = os.clock() + RESCAN_DELAY end
        end
    end
end

local function addUnit(u)
    table.insert(state.units, u)
    state.byId[u.id] = u
end

-- Looks for units attached after start-up. Never prompts: a second
-- Draconic reactor still needs the setup wizard (restart) or config.lua.
local function hotplugLoop()
    while true do
        sleep(1)
        if state.rescanAt and os.clock() >= state.rescanAt then
            state.rescanAt = nil
            local ctx = {config = config, log = stat_utils, import = import,
                         overrides = persist.overrides, persist = persist, known = knownUnit}
            for _, drv in ipairs(state.drivers) do
                local ok, found, err = pcall(drv.discover, ctx)
                if ok then
                    for _, u in ipairs(found or {}) do
                        addUnit(u)
                        spawn(u.run)
                        stat_utils.log("INFO", "New unit connected: " .. u.name)
                    end
                    if err then stat_utils.log("WARN", "Rescan: " .. tostring(err)) end
                else
                    stat_utils.log("WARN", "Rescan " .. drv.label .. ": " .. tostring(found))
                end
            end
        end
    end
end

------------------------------------------------------------
-- SHUTDOWN
------------------------------------------------------------
function failSafe(reason)
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
    persist.load()
    totals.load()
    alarms.init(config.alarms)
    state.drivers = loadDrivers()
    for _, u in ipairs(discoverUnits(state.drivers)) do addUnit(u) end

    setupDisplays()
    print(string.format("Running %d unit(s). Hold Ctrl+T to stop.", #state.units))
    spawn(uiLoop)
    spawn(eventLoop)
    spawn(hotplugLoop)
    spawn(log_shipper.loop(config.logging.remote, stat_utils))
    for _, u in ipairs(state.units) do spawn(u.run) end
    runTasks()
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
