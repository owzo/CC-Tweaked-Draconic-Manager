--==============================================================
-- MAIN CONTROL SCRIPT (COMPUTER)
-- Save as: main_control.lua
--==============================================================

--[[
README
-------
Central automation controller for your Draconic Reactor + Flux Gate system.

Wiring layout (fixed modem labels):
  draconic_reactor_0 → Reactor Stabilizer
  flow_gate_0        → Input Flux Gate (into reactor)
  flow_gate_1        → Output Flux Gate (to storage/core)
  monitor_1          → Primary monitor
  computer_1         → Controller computer

Key Features:
- Full temperature + field + fuel regulation
- Detects and reacts to "No Fuel" or "Chaos Full" states
- Performs automatic safe shutdowns
- Logs every operational event with timestamps
- Displays real-time warnings and readings on the monitor
]]

------------------------------------------------------------
-- IMPORT MODULES
------------------------------------------------------------
local config            = require("config")              -- Configuration & safety thresholds
local reac_utils        = require("reac_utils")          -- Reactor control logic
local monitor_utils     = require("monitor_utils")       -- Monitor UI rendering
local stat_utils        = require("stat_utils")          -- Logging subsystem
local energy_core_utils = require("energy_core_utils")   -- Flux-gate energy monitoring

------------------------------------------------------------
-- LOGGING UTILITIES
------------------------------------------------------------

-- Writes a timestamped event to the system log
local function logEvent(msg)
    local f = fs.open("draconic_manager.log", "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

-- Wraps a function in error handling, logs any thrown error
local function safeRun(func, label)
    local ok, err = pcall(func)
    if not ok then
        local msg = "Error in " .. label .. ": " .. tostring(err)
        logEvent(msg)
        print(msg)
    end
end

------------------------------------------------------------
-- MAIN CONTROL LOOP
------------------------------------------------------------
local function mainLoop()
    logEvent("Main control loop started.")
    while true do
        ----------------------------------------------------
        -- Check reactor peripheral connection
        ----------------------------------------------------
        if not reac_utils.reactor then
            logEvent("Reactor peripheral lost; reinitializing...")
            safeRun(reac_utils.setup, "reac_utils.setup")
            sleep(5)
        end

        ----------------------------------------------------
        -- Retrieve reactor status information
        ----------------------------------------------------
        safeRun(reac_utils.checkReactorStatus, "checkReactorStatus")
        local status = reac_utils.info.status or "unknown"

        ----------------------------------------------------
        -- SAFETY CHECKS: Fuel & Chaos Storage
        ----------------------------------------------------
        -- These checks are performed before normal control logic
        local fuelChaosOK = reac_utils.checkFuelAndChaos()
        if not fuelChaosOK then
            logEvent("Fuel or chaos condition triggered safety halt.")
            -- Allow time for cooling before retrying
            sleep(5)
        end

        ----------------------------------------------------
        -- EMERGENCY: Temperature or Field Safety Breach
        ----------------------------------------------------
        if reac_utils.isEmergency() then
            safeRun(reac_utils.failSafeShutdown, "failSafeShutdown")
            logEvent("Emergency shutdown: unsafe temperature or field detected.")
            print("[!] Emergency shutdown executed.")
        ----------------------------------------------------
        -- COLD OR OFFLINE STATE (Can charge)
        ----------------------------------------------------
        elseif status == "cold" or status == "offline" or status == "cooling" then
            if reac_utils.manualCharge then
                reac_utils.manualCharge = false
                safeRun(reac_utils.reactor.chargeReactor, "chargeReactor")
                logEvent("Manual charge initiated.")
            end
        ----------------------------------------------------
        -- CHARGING STATE (Reactor absorbing energy)
        ----------------------------------------------------
        elseif status == "charging" then
            reac_utils.setFluxGateFlowRate(reac_utils.gateIn, config.reactor.chargeInflow)
            reac_utils.setFluxGateFlowRate(reac_utils.gateOut, 0)
        ----------------------------------------------------
        -- WARMUP OR CHARGED STATE (Ready to start)
        ----------------------------------------------------
        elseif status == "warming_up" or status == "charged" then
            reac_utils.setFluxGateFlowRate(reac_utils.gateIn, config.reactor.chargeInflow)
            reac_utils.setFluxGateFlowRate(reac_utils.gateOut, 0)
            if reac_utils.manualStart then
                reac_utils.manualStart = false
                safeRun(reac_utils.reactor.activateReactor, "activateReactor")
                logEvent("Manual reactor start requested.")
            end
        ----------------------------------------------------
        -- ACTIVE RUNNING STATE
        ----------------------------------------------------
        elseif status == "running" or status == "online" then
            if reac_utils.manualStop then
                reac_utils.manualStop = false
                safeRun(reac_utils.reactor.stopReactor, "stopReactor")
                logEvent("Manual reactor stop requested.")
            end
            safeRun(reac_utils.adjustReactorTempAndField, "adjustReactorTempAndField")
        ----------------------------------------------------
        -- STOPPING / COOLING DOWN
        ----------------------------------------------------
        elseif status == "stopping" then
            safeRun(reac_utils.handleReactorStopping, "handleReactorStopping")
        else
            logEvent("Unknown reactor status: " .. tostring(status))
        end

        ----------------------------------------------------
        -- MONITOR + FLUX GATE DISPLAY UPDATES
        ----------------------------------------------------
        safeRun(reac_utils.updateFluxGates, "updateFluxGates")
        if reac_utils.mon then
            safeRun(energy_core_utils.updateMonitor, "energy_core_utils.updateMonitor")
        end

        ----------------------------------------------------
        -- PERIODIC LOGGING
        ----------------------------------------------------
        safeRun(energy_core_utils.logEnergyCoreStats, "energy_core_utils.logEnergyCoreStats")
        safeRun(function() stat_utils.logReactorStats(reac_utils.reactor) end,
                "stat_utils.logReactorStats")

        sleep(0.2) -- Main tick rate (5 loops/sec = smoother display)
    end
end

------------------------------------------------------------
-- PROGRAM ENTRY POINT
------------------------------------------------------------
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("===================================================")
    print("   CC:Tweaked Draconic Reactor Manager  v2.1")
    print("===================================================")
    print("Initializing peripherals and safety systems...")

    --------------------------------------------------------
    -- INITIALIZATION: Load all utilities and setup
    --------------------------------------------------------
    safeRun(reac_utils.setup, "reac_utils.setup")
    safeRun(energy_core_utils.setup, "energy_core_utils.setup")
    logEvent("Initialization complete; starting main control loop.")

    --------------------------------------------------------
    -- MULTITHREADED EXECUTION
    --------------------------------------------------------
    if reac_utils.mon == nil then
        -- No monitor attached → just run logic
        safeRun(mainLoop, "mainLoop")
    else
        -- Run logic and monitor input concurrently
        parallel.waitForAll(mainLoop, monitor_utils.clickListener)
        reac_utils.mon.setBackgroundColor(colors.black)
        reac_utils.mon.clear()
        reac_utils.mon.setCursorPos(2, 2)
        reac_utils.mon.setTextColor(colors.white)
        reac_utils.mon.write("Program stopped.")
        logEvent("Program terminated by user.")
    end
end

------------------------------------------------------------
-- FAILSAFE STARTUP WRAPPER
------------------------------------------------------------
local ok, err = pcall(main)
if not ok then
    logEvent("Fatal error: " .. tostring(err))
    print("Fatal error: " .. tostring(err))
    print("See draconic_manager.log for details.")
end
