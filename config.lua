--==============================================================
-- CONFIGURATION FILE
-- Save as: config.lua
--==============================================================

--[[
README
-------
Central configuration for the CC:Tweaked Draconic Reactor Manager.
Defines all safety parameters, peripheral names, and monitor/logging options.
]]

------------------------------------------------------------
-- CONFIG TABLE
------------------------------------------------------------
local config = {}

------------------------------------------------------------
-- REACTOR CONFIGURATION
------------------------------------------------------------
config.reactor = {
    id                = "1",              -- Reactor ID (for multiple reactors)
    outputMultiplier  = 1.0,              -- Output scaling (from modpack configs)
    tempPinpoint      = 0,                -- Fine adjustment threshold

    -- Safety thresholds
    maxOvershoot      = 200.0,            -- Max °C above target before shutdown
    minFuel           = 0.02,             -- Minimum fuel ratio before "No Fuel" error
    maxSaturation     = 0.98,             -- Stop reactor when saturation ≥ 98% (full)

    -- Operating targets
    defaultTemp       = 8000.0,           -- Target reactor temperature
    defaultField      = 0.50,             -- Target field percentage
    safeTemperature   = 3000.0,           -- Restart when cooled below this

    -- Energy control
    maxOutflow        = 30000000.0,       -- Max RF/t output
    chargeInflow      = 20000000.0,       -- Input rate during charge

    -- Field management
    shutDownField     = 0.20,             -- Shutdown threshold for field %
    restartFix        = 100,              -- Delay ticks before restart

    -- Behavior toggles
    safeMode          = true,             -- Enable automatic emergency actions
    maxTempInc        = 400.0             -- Max temp rise per tick allowed
}

------------------------------------------------------------
-- LOGGING & MONITOR SETTINGS
------------------------------------------------------------
config.energyCore = {
    logsFile     = "logs.cfg",            -- Global system log
    monitorScale = 1                      -- Monitor text size
}

------------------------------------------------------------
-- PERIPHERAL MAPPINGS
------------------------------------------------------------
config.peripherals = {
    reactor  = "draconic_reactor_0",      -- Reactor stabilizer modem
    fluxIn   = "flow_gate_0",             -- Input flux gate
    fluxOut  = "flow_gate_1",             -- Output flux gate
    monitors = {"monitor_1"}              -- Primary monitor
}

------------------------------------------------------------
-- LOGGING FUNCTION
------------------------------------------------------------
local function writeLog(msg)
    local f = fs.open(config.energyCore.logsFile, "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

------------------------------------------------------------
-- VALIDATION
------------------------------------------------------------
local function validatePeripherals()
    if not peripheral.isPresent(config.peripherals.reactor) then
        writeLog("ERROR: Reactor stabilizer not found!")
        error("Reactor stabilizer not found! Attach modem to stabilizer.")
    end
    if not peripheral.isPresent(config.peripherals.fluxIn) then
        writeLog("ERROR: Input flux gate not found!")
        error("Input flux gate not found!")
    end
    if not peripheral.isPresent(config.peripherals.fluxOut) then
        writeLog("ERROR: Output flux gate not found!")
        error("Output flux gate not found!")
    end
    for _, m in ipairs(config.peripherals.monitors) do
        if peripheral.isPresent(m) and peripheral.getType(m) == "monitor" then
            writeLog("Monitor verified: " .. m)
            return
        end
    end
    writeLog("ERROR: No monitor detected!")
    error("No valid monitor found.")
end

pcall(validatePeripherals)
return config
