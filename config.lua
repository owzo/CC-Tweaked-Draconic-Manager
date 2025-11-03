--==============================================================
-- CONFIGURATION FILE
-- Save as: config.lua
--==============================================================

--[[
README
-------
Configuration file for CC:Tweaked Draconic Reactor + Flux-Gate Manager.

This system no longer connects directly to a Draconic Energy Core or I/O Crystal.
Instead, it uses Flux Gates to read and control energy flow.

Supports:
- Wired modems
- Wireless modems (paired)
- Hybrid of both
]]

------------------------------------------------------------
-- CONFIG TABLE
------------------------------------------------------------
local config = {}

------------------------------------------------------------
-- DRACONIC REACTOR CONFIGURATION
------------------------------------------------------------
config.reactor = {
    id                = "1",              -- Reactor ID (for multi-reactor setups)
    outputMultiplier  = 1.0,              -- Output multiplier set by modpack
    tempPinpoint      = 0,                -- Temperature adjustment sensitivity

    -- Safety thresholds
    maxOvershoot      = 200.0,            -- Max °C above target before shutdown
    minFuel           = 0.05,             -- Minimum fuel ratio before shutdown

    -- Target operation values
    defaultTemp       = 8000.0,           -- Target temperature (°C)
    defaultField      = 0.50,             -- Target field strength (50 %)
    safeTemperature   = 3000.0,           -- Safe restart temperature (°C)

    -- Flow control
    maxOutflow        = 30000000.0,       -- Max output (RF/t)
    chargeInflow      = 20000000.0,       -- Input rate while charging (RF/t)

    -- Field thresholds
    shutDownField     = 0.20,             -- Auto-shutdown below 20 % field
    restartFix        = 100,              -- Restart delay (ticks)

    -- Options
    safeMode          = true,             -- Auto-shutdown on dangerous states
    maxTempInc        = 400.0             -- Max allowed temperature change per tick
}

------------------------------------------------------------
-- ENERGY / MONITOR CONFIGURATION
------------------------------------------------------------
config.energyCore = {
    logsFile     = "logs.cfg",            -- General log file
    monitorScale = 1                      -- Text scale for monitors
}

------------------------------------------------------------
-- PERIPHERAL MAPPINGS
------------------------------------------------------------
-- Leave blank to let the system auto-detect by type.
-- Specify exact names (e.g., "flow_gate_0") if you want to hard-code them.
config.peripherals = {
    reactor  = "",                        -- Reactor stabilizer modem name
    fluxIn   = "",                        -- Flux Gate feeding INTO reactor
    fluxOut  = "",                        -- Flux Gate pulling OUT to storage/core
    monitors = {"top"}                    -- One or more monitor sides/names
}

------------------------------------------------------------
-- PERIPHERAL DETECTION UTILITIES
------------------------------------------------------------
local function findPeripheralByType(expectedType)
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == expectedType then
            return name
        end
    end
    return nil
end

------------------------------------------------------------
-- VALIDATION (LIGHTWEIGHT)
------------------------------------------------------------
local function validatePeripherals()
    -- Reactor Stabilizer
    if config.peripherals.reactor == "" then
        config.peripherals.reactor = findPeripheralByType("draconic_reactor")
    end
    if not config.peripherals.reactor or not peripheral.isPresent(config.peripherals.reactor) then
        error("Reactor Stabilizer not found. Attach a modem to one stabilizer.")
    end

    -- Flux Gates (Energy Core handled via these)
    if config.peripherals.fluxIn == "" or config.peripherals.fluxOut == "" then
        local found = {}
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name):find("flux_gate") then
                table.insert(found, name)
            end
        end
        if #found < 2 then
            error("At least two flux gates are required (input + output).")
        end
        if config.peripherals.fluxIn == "" then config.peripherals.fluxIn = found[1] end
        if config.peripherals.fluxOut == "" then config.peripherals.fluxOut = found[2] end
    end

    -- Monitor(s)
    local monitorFound = false
    for _, side in ipairs(config.peripherals.monitors) do
        if peripheral.getType(side) == "monitor" then
            monitorFound = true
        end
    end
    if not monitorFound then
        error("No valid monitor found. Check config.peripherals.monitors or attach one.")
    end
end

------------------------------------------------------------
-- INITIAL VALIDATION (RUNS ON LOAD)
------------------------------------------------------------
validatePeripherals()

return config
