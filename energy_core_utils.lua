--==============================================================
-- ENERGY CORE UTILITIES (FLUX GATE BASED)
-- Save as: energy_core_utils.lua
--==============================================================

--[[
README
-------
This module reads and displays power flow through Flux Gates.
Replaces any dependency on the Draconic Energy Core directly.

Features:
- Uses hardcoded gate names from config.lua
- Provides automatic logging, error handling, and retry logic
- Displays real-time input/output rates on monitor
]]

------------------------------------------------------------
-- IMPORT CONFIG
------------------------------------------------------------
local cfg = require("config")                 -- Load config file
local p = cfg.peripherals                     -- Shortcut to peripheral map
local energy_core_utils = {}                  -- Create a module table

------------------------------------------------------------
-- INITIALIZE WRAPPED PERIPHERALS
------------------------------------------------------------
local inputGate = peripheral.wrap(p.fluxIn)   -- Input Flux Gate
local outputGate = peripheral.wrap(p.fluxOut) -- Output Flux Gate
local monitor = peripheral.wrap(p.monitors[1])-- Main Monitor

------------------------------------------------------------
-- INTERNAL LOGGING FUNCTION
------------------------------------------------------------
local function logError(msg)
    local f = fs.open(cfg.energyCore.logsFile, "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

------------------------------------------------------------
-- MONITOR SETUP AND AUTO-RECOVERY
------------------------------------------------------------
function energy_core_utils.setup()
    if not monitor then
        logError("Monitor not found, running headless mode.")
        return
    end

    monitor.setTextScale(cfg.energyCore.monitorScale) -- Set scale from config
    monitor.setBackgroundColor(colors.black)          -- Set background
    monitor.clear()                                   -- Clear monitor text
    monitor.setCursorPos(1, 1)
    monitor.setTextColor(colors.white)
    monitor.write("Energy Flow Monitor Initialized")
    logError("Monitor setup successful.")
end

------------------------------------------------------------
-- AUTOMATED DISPLAY UPDATE LOOP
------------------------------------------------------------
function energy_core_utils.updateMonitor()
    if not monitor then return end

    local okIn, inFlow = pcall(inputGate.getFlow)     -- Safely read input gate
    local okOut, outFlow = pcall(outputGate.getFlow)  -- Safely read output gate
    if not okIn or not okOut then
        logError("Failed to read from one or more flux gates.")
        return
    end

    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(2, 2)
    monitor.write("Energy Flow Monitor")
    monitor.setCursorPos(2, 4)
    monitor.write(string.format("Input Rate : %.0f RF/t", inFlow))
    monitor.setCursorPos(2, 5)
    monitor.write(string.format("Output Rate: %.0f RF/t", outFlow))
end

------------------------------------------------------------
-- AUTOMATED LOGGING FUNCTION
------------------------------------------------------------
function energy_core_utils.logEnergyCoreStats()
    local okIn, inFlow = pcall(inputGate.getFlow)
    local okOut, outFlow = pcall(outputGate.getFlow)

    if not okIn or not okOut then
        logError("Flux gate data unavailable for logging.")
        return
    end

    local f = fs.open("energy_core_stats.log", "a")
    if not f then
        logError("Failed to open log file.")
        return
    end

    f.writeLine(string.format("%s | In: %.0f RF/t | Out: %.0f RF/t",
        os.date("%Y-%m-%d %H:%M:%S"), inFlow, outFlow))
    f.close()
end

------------------------------------------------------------
-- AUTOMATION: PERIODIC REFRESH THREAD
------------------------------------------------------------
function energy_core_utils.runAutoLoop()
    while true do
        local ok, err = pcall(function()
            energy_core_utils.updateMonitor()
            energy_core_utils.logEnergyCoreStats()
        end)
        if not ok then logError("AutoLoop error: " .. tostring(err)) end
        sleep(5)  -- Refresh every 5 seconds
    end
end

return energy_core_utils
