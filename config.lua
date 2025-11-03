--==============================================================
-- CONFIGURATION FILE
-- Save as: config.lua
--==============================================================

--[[
README
-------
Central configuration for the Draconic Reactor + Flux Gate Manager.
All device names below are hard-coded to match your wired modem setup.

Devices:
  - Reactor Stabilizer : draconic_reactor_0
  - Input Flux Gate    : flow_gate_0
  - Output Flux Gate   : flow_gate_1
  - Monitor            : monitor_1
  - Computer           : computer_1
]]

------------------------------------------------------------
-- CONFIG TABLE DEFINITION
------------------------------------------------------------
local config = {}  -- Create a new configuration table

------------------------------------------------------------
-- REACTOR CONFIGURATION
------------------------------------------------------------
config.reactor = {
    id                = "1",              -- Unique reactor ID (for multi-reactor systems)
    outputMultiplier  = 1.0,              -- Energy scaling from modpack (keep at 1 unless modified)
    tempPinpoint      = 0,                -- Temperature control precision (unused in auto mode)

    -- Safety thresholds
    maxOvershoot      = 200.0,            -- Max °C above target before auto-shutdown
    minFuel           = 0.05,             -- Min fuel ratio before reactor auto-stops

    -- Target operation parameters
    defaultTemp       = 8000.0,           -- Target operational temperature
    defaultField      = 0.50,             -- Desired field strength (50%)
    safeTemperature   = 3000.0,           -- Cooldown temperature for safe restart

    -- Flow control
    maxOutflow        = 30000000.0,       -- Max RF/t output limit
    chargeInflow      = 20000000.0,       -- Inflow rate during charging

    -- Field thresholds
    shutDownField     = 0.20,             -- Auto-shutdown below 20% field
    restartFix        = 100,              -- Tick delay before restart

    -- Misc Options
    safeMode          = true,             -- Enables automatic safe shutdowns
    maxTempInc        = 400.0             -- Max allowed temp increase per tick
}

------------------------------------------------------------
-- MONITOR + LOGGING CONFIGURATION
------------------------------------------------------------
config.energyCore = {
    logsFile     = "logs.cfg",            -- General logging file
    monitorScale = 1                      -- Default monitor text scale
}

------------------------------------------------------------
-- PERIPHERAL DEFINITIONS (EXPLICIT)
------------------------------------------------------------
config.peripherals = {
    reactor  = "draconic_reactor_0",      -- Reactor stabilizer modem label
    fluxIn   = "flow_gate_0",             -- Flux gate controlling energy input
    fluxOut  = "flow_gate_1",             -- Flux gate controlling energy output
    monitors = {"monitor_1"}              -- List of connected monitors
}

------------------------------------------------------------
-- INTERNAL LOGGING FUNCTION
------------------------------------------------------------
local function writeLog(msg)
    local f = fs.open(config.energyCore.logsFile, "a")  -- Open the main log file in append mode
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

------------------------------------------------------------
-- PERIPHERAL VALIDATION WITH ERROR HANDLING
------------------------------------------------------------
local function validatePeripherals()
    -- Check that the reactor is attached
    if not peripheral.isPresent(config.peripherals.reactor) then
        writeLog("ERROR: Reactor stabilizer not found (" .. config.peripherals.reactor .. ")")
        error("Reactor stabilizer not found! Attach modem to reactor stabilizer.")
    end

    -- Validate both flux gates exist
    if not peripheral.isPresent(config.peripherals.fluxIn) then
        writeLog("ERROR: Input flux gate missing (" .. config.peripherals.fluxIn .. ")")
        error("Input flux gate not found!")
    end

    if not peripheral.isPresent(config.peripherals.fluxOut) then
        writeLog("ERROR: Output flux gate missing (" .. config.peripherals.fluxOut .. ")")
        error("Output flux gate not found!")
    end

    -- Validate at least one monitor
    local monitorFound = false
    for _, m in ipairs(config.peripherals.monitors) do
        if peripheral.isPresent(m) and peripheral.getType(m) == "monitor" then
            monitorFound = true
        end
    end

    if not monitorFound then
        writeLog("ERROR: No valid monitor detected.")
        error("No valid monitor found. Check config or attach one.")
    end

    -- Log success message
    writeLog("Peripherals validated successfully.")
end

------------------------------------------------------------
-- AUTO-VALIDATE ON LOAD
------------------------------------------------------------
pcall(validatePeripherals)  -- Use pcall so script still runs even if validation fails

return config
