--==============================================================
-- Main Control Script (Computer)
-- Save as: main_control.lua
--==============================================================

--[[
README
-------
Central controller for the Draconic Reactor + Energy Core automation system.

Features:
- Compatible with wired, wireless, or mixed modem networks.
- Automated regulation of reactor temperature, field strength, and flux gates.
- Automatic reactor start/stop, charge, and cooling management.
- Emergency failsafe shutdown on unsafe temperature or field conditions.
- Touchscreen control and real-time status display on advanced monitors.
- Logs operational statistics for performance tracking.

Configuration:
Edit "config.lua" to adjust reactor parameters, thresholds, and device mappings.
]]

------------------------------------------------------------
-- IMPORT REQUIRED MODULES
------------------------------------------------------------
local config = require("config")
local reac_utils = require("reac_utils")
local monitor_utils = require("monitor_utils")
local stat_utils = require("stat_utils")
local energy_core_utils = require("energy_core_utils")

------------------------------------------------------------
-- LOGGING AND ERROR HANDLING
------------------------------------------------------------
local function logEvent(message)
    local logFile = fs.open("draconic_manager.log", "a")
    if logFile then
        logFile.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. message)
        logFile.close()
    end
end

local function safeRun(func, name)
    local ok, err = pcall(func)
    if not ok then
        logEvent("Error in " .. name .. ": " .. tostring(err))
        print("Error in " .. name .. ": " .. tostring(err))
    end
end

------------------------------------------------------------
-- MAIN CONTROL LOOP
------------------------------------------------------------
local function mainLoop()
    logEvent("Main control loop started.")

    while true do
        -- Validate reactor object before proceeding
        if not reac_utils.reactor then
            logEvent("Reactor peripheral lost. Attempting to reinitialize...")
            safeRun(reac_utils.setup, "reac_utils.setup")
            sleep(5)
        end

        safeRun(reac_utils.checkReactorStatus, "checkReactorStatus")

        local status = reac_utils.info.status or "unknown"

        if reac_utils.isEmergency() then
            safeRun(reac_utils.failSafeShutdown, "failSafeShutdown")
            logEvent("Emergency shutdown initiated due to unsafe conditions.")
            print("Emergency shutdown triggered.")
        elseif status == "cold" or status == "offline" or status == "cooling" then
            if reac_utils.manualCharge then
                reac_utils.manualCharge = false
                safeRun(reac_utils.reactor.chargeReactor, "chargeReactor")
                logEvent("Manual charge initiated.")
            end
        elseif status == "charging" then
            reac_utils.setFluxGateFlowRate(reac_utils.gateIn, config.reactor.chargeInflow)
            reac_utils.setFluxGateFlowRate(reac_utils.gateOut, 0)
        elseif status == "warming_up" or status == "charged" then
            reac_utils.setFluxGateFlowRate(reac_utils.gateIn, config.reactor.chargeInflow)
            reac_utils.setFluxGateFlowRate(reac_utils.gateOut, 0)
            if reac_utils.manualStart then
                reac_utils.manualStart = false
                safeRun(reac_utils.reactor.activateReactor, "activateReactor")
                logEvent("Manual reactor start initiated.")
            end
        elseif status == "running" or status == "online" then
            if reac_utils.manualStop then
                reac_utils.manualStop = false
                safeRun(reac_utils.reactor.stopReactor, "stopReactor")
                logEvent("Manual reactor stop initiated.")
            end
            safeRun(reac_utils.adjustReactorTempAndField, "adjustReactorTempAndField")
        elseif status == "stopping" then
            safeRun(reac_utils.handleReactorStopping, "handleReactorStopping")
        else
            logEvent("Unknown reactor status: " .. tostring(status))
        end

        -- Flux gate updates
        safeRun(reac_utils.updateFluxGates, "updateFluxGates")

        -- Monitor updates
        if reac_utils.mon then
            safeRun(monitor_utils.updateMonitor, "monitor_utils.updateMonitor")
        end

        -- Energy core statistics
        safeRun(energy_core_utils.logEnergyCoreStats, "logEnergyCoreStats")

        -- Reactor performance logging
        safeRun(function() stat_utils.logReactorStats(reac_utils.reactor) end, "stat_utils.logReactorStats")

        sleep(0.05) -- Loop rate (20 ticks/sec)
    end
end

------------------------------------------------------------
-- PROGRAM ENTRY POINT
------------------------------------------------------------
local function main()
    term.clear()
    term.setCursorPos(1,1)
    print("=============================================")
    print("  CC-Tweaked Draconic Reactor Manager v2.0   ")
    print("=============================================")
    print("Initializing peripherals and configuration...")

    safeRun(reac_utils.setup, "reac_utils.setup")
    logEvent("Initialization complete. Starting main control loop.")

    if reac_utils.mon == nil then
        safeRun(mainLoop, "mainLoop")
    else
        parallel.waitForAll(mainLoop, monitor_utils.clickListener)
        reac_utils.clearMonitor()
        reac_utils.drawText("Program stopped.", 1, 1, colors.white, colors.black)
        logEvent("Program stopped by user.")
    end
end

------------------------------------------------------------
-- SAFE STARTUP WRAPPER
------------------------------------------------------------
local ok, err = pcall(main)
if not ok then
    logEvent("Fatal error in main(): " .. tostring(err))
    print("Fatal error: " .. tostring(err))
    print("See draconic_manager.log for details.")
end
