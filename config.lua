-- Configuration File
-- Save as: config.lua

--[[
README

Configuration file for Draconic Reactor and Energy Core Control Scripts.

This file centralizes all configuration settings. Edit the values below to change the configuration.
]]

local config = {}

-- Draconic Reactor Configurations
config.reactor = {
    outputMultiplier = 1.0,        -- Output multiplier set by modpack (default = 1.0)
    reactornumber = "1",           -- Reactor number for identification
    tempPinpoint = 0,              -- Temperature adjustment pinpoint value

    -- Emergency shutdown parameters
    maxOvershoot = 200.0,          -- Max temperature increase before shutdown
    minFuel = 0.05,                -- Minimum fuel level before shutdown

    -- Default parameters
    defaultTemp = 8000.0,          -- Default target temperature
    defaultField = 0.50,           -- Default field strength percentage
    restartFix = 100,              -- Restart fix delay
    maxTempInc = 400.0,            -- Max temperature increase per tick
    maxOutflow = 30000000.0,       -- Max outflow rate
    chargeInflow = 20000000,       -- Charge inflow rate
    shutDownField = 0.20,          -- Field strength percentage for shutdown
    safeTemperature = 3000.0,      -- Safe temperature to reactivate reactor
    safeMode = true                -- Enable or disable safe mode
}

-- Energy Core Configurations
config.energyCore = {
    logsFile = "logs.cfg",         -- Log file path
    monitorScale = 1               -- Monitor text scale
}

-- Ensure peripherals are found (Added error handling)
local function validatePeripherals()
    local monitor = peripheral.find("monitor")
    local energyCore = peripheral.find("draconic_rf_storage")
    if not monitor then error("Monitor not found!") end
    if not energyCore then error("Energy Core not found!") end
end

validatePeripherals() -- Added call to validation function.

return config
