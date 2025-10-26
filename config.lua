--==============================================================
-- CONFIGURATION FILE
-- Save as: config.lua
--==============================================================

--[[
README
-------
Configuration file for CC:Tweaked Draconic Reactor + Energy Core Manager.

This file centralizes all user-editable settings, including safety thresholds,
device names, and modem configuration. It supports both wired and wireless
networks, or any combination of the two.

You can connect devices (Reactor Stabilizer, Flux Gates, Energy Core, Monitors)
through either:
    - Wired modems and cable
    - Wireless modems (paired via right-click)
    - A hybrid of both

The computer only needs a modem that can reach all devices in the same
network or paired group.
]]

--==============================================================
-- CONFIG TABLE
--==============================================================
local config = {}

------------------------------------------------------------
-- DRACONIC REACTOR CONFIGURATION
------------------------------------------------------------
config.reactor = {
    id                = "1",              -- Reactor ID (for multiple reactors)
    outputMultiplier  = 1.0,              -- Output multiplier from modpack
    tempPinpoint      = 0,                -- Temperature adjustment sensitivity

    -- Safety thresholds
    maxOvershoot      = 200.0,            -- Max temperature increase before emergency shutdown
    minFuel           = 0.05,             -- Minimum fuel level before auto-shutdown

    -- Target operation values
    defaultTemp       = 8000.0,           -- Default target temperature (°C)
    defaultField      = 0.50,             -- Default target field strength (50%)
    safeTemperature   = 3000.0,           -- Temperature below which the reactor can safely restart

    -- Flow control
    maxOutflow        = 30000000.0,       -- Max energy outflow (RF/t)
    chargeInflow      = 20000000.0,       -- Max inflow during charging (RF/t)

    -- Field thresholds
    shutDownField     = 0.20,             -- Shutdown if field strength drops below 20%
    restartFix        = 100,              -- Restart delay ticks after field recharge

    -- Options
    safeMode          = true,             -- If true, disables dangerous operations automatically
    maxTempInc        = 400.0             -- Maximum allowed temperature increase per tick
}

------------------------------------------------------------
-- ENERGY CORE CONFIGURATION
------------------------------------------------------------
config.energyCore = {
    logsFile          = "logs.cfg",       -- Log file path for event logging
    monitorScale      = 1,                -- Text scaling for monitor display
}

------------------------------------------------------------
-- PERIPHERAL MAPPINGS
------------------------------------------------------------
-- Update these values if you want to manually specify exact peripheral names.
-- If left blank, automatic detection will attempt to find devices by type.
config.peripherals = {
    reactor     = "",                     -- Reactor stabilizer modem name
    energyCore  = "",                     -- Energy Core I/O Crystal modem name
    fluxIn      = "",                     -- Flux Gate controlling power INTO reactor
    fluxOut     = "",                     -- Flux Gate controlling power OUT to core
    monitors    = {"top"}                 -- One or more monitor sides/names
}

------------------------------------------------------------
-- PERIPHERAL DETECTION AND VALIDATION
------------------------------------------------------------
local function findPeripheralByType(expectedType)
    local names = peripheral.getNames()
    for _, name in ipairs(names) do
        local pType = peripheral.getType(name)
        if pType == expectedType then
            return name
        end
    end
    return nil
end

local function validatePeripherals()
    -- Reactor Stabilizer
    if config.peripherals.reactor == "" then
        config.peripherals.reactor = findPeripheralByType("draconic_reactor")
    end
    if not config.peripherals.reactor or not peripheral.isPresent(config.peripherals.reactor) then
        error("Reactor Stabilizer not found. Attach a modem to one stabilizer.")
    end

    -- Energy Core I/O Crystal
    if config.peripherals.energyCore == "" then
        config.peripherals.energyCore = findPeripheralByType("draconic_rf_storage")
    end
    if not config.peripherals.energyCore or not peripheral.isPresent(config.peripherals.energyCore) then
        error("Energy Core not found. Attach a modem to an I/O crystal.")
    end

    -- Flux Gates
    if config.peripherals.fluxIn == "" then
        config.peripherals.fluxIn = findPeripheralByType("draconic_flux_gate")
    end
    if not config.peripherals.fluxIn or not peripheral.isPresent(config.peripherals.fluxIn) then
        error("Input Flux Gate not found.")
    end

    if config.peripherals.fluxOut == "" then
        config.peripherals.fluxOut = findPeripheralByType("draconic_flux_gate")
    end
    if not config.peripherals.fluxOut or not peripheral.isPresent(config.peripherals.fluxOut) then
        error("Output Flux Gate not found.")
    end

    -- Monitor(s)
    local monitorFound = false
    for _, side in ipairs(config.peripherals.monitors) do
        if peripheral.getType(side) == "monitor" then
            monitorFound = true
        end
    end
    if not monitorFound then
        error("No valid monitor found. Check 'config.peripherals.monitors' or attach a monitor.")
    end
end

------------------------------------------------------------
-- INITIAL VALIDATION (RUNS ON LOAD)
------------------------------------------------------------
validatePeripherals()

return config
