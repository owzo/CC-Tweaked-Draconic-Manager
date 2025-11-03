--==============================================================
-- MAIN CONTROL SCRIPT (COMPUTER)
-- Save as: main_control.lua
--==============================================================

--[[
README
-------
Central automation and supervision program for your
Draconic Reactor + Flux Gate energy system.

Wiring layout (modem labels):
  draconic_reactor_0 → Reactor Stabilizer
  flow_gate_0        → Input Flux Gate (into reactor)
  flow_gate_1        → Output Flux Gate (to storage)
  monitor_1          → Status monitor
  computer_1         → Controller computer

Functions:
- Automatically manages temperature, field strength, and power flow.
- Performs safe start, charge, and stop cycles.
- Detects unsafe conditions and initiates emergency shutdowns.
- Logs every operational event with timestamps.
- Displays real-time system info on the monitor.
]]

------------------------------------------------------------
-- IMPORT MODULES
------------------------------------------------------------
local config            = require("config")              -- User-editable configuration
local reac_utils        = require("reac_utils")          -- Reactor operations module
local monitor_utils     = require("monitor_utils")       -- On-screen drawing utilities
local stat_utils        = require("stat_utils")          -- Periodic logging subsystem
local energy_core_utils = require("energy_core_utils")   -- Flux-gate energy monitoring

------------------------------------------------------------
-- LOGGING UTILITIES
------------------------------------------------------------

-- Writes a timestamped line to the global log file.
local function logEvent(msg)
    local f = fs.open("draconic_manager.log", "a")       -- Open/create main log
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

-- Safely executes any function and logs if it errors.
local function safeRun(func, label)
    local ok, err = pcall(func)
    if not ok then
        local message = "Error in " .. label .. ": " .. tostring(err)
        logEvent(message)
        print(message)
    end
end

------------------------------------------------------------
-- MAIN CONTROL LOOP
------------------------------------------------------------
local function mainLoop()
    logEvent("Main control loop started.")
    while true do
        ----------------------------------------------------
        -- Verify the reactor peripheral is still present
        ----------------------------------------------------
        if not reac_utils.reactor then
            logEvent("Reactor peripheral lost; reinitializing...")
            safeRun(reac_utils.setup, "reac_utils.setup")
            sleep(5)
        end

        ----------------------------------------------------
        -- Update reactor telemetry and status
        ----------------------------------------------------
        safeRun(reac_utils.checkReactorStatus, "checkReactorStatus")
        local status = reac_utils.info.status or "unknown"

        ----------------------------------------------------
        -- EMERGENCY FAILSAFE
        ----------------------------------------------------
        if reac_utils.isEmergency() then
            safeRun(reac_utils.failSafeShutdown, "failSafeShutdown")
            logEvent("Emergency shutdown: unsafe temperature or field detected.")
            print("⚠️ Emergency shutdown executed.")
        ----------------------------------------------------
        -- IDLE / COLD STATES
        ----------------------------------------------------
        elseif status == "cold" or status == "offline" or status == "cooling" then
            if reac_utils.manualCharge then
                reac_utils.manualCharge = false
                safeRun(reac_utils.reactor.chargeReactor, "chargeReactor")
                logEvent("Manual charge initiated.")
            end
        ----------------------------------------------------
        -- CHARGING STATE
        ----------------------------------------------------
        elseif status == "charging" then
            reac_utils.setFluxGateFlowRate(reac_utils.gateIn, config.reactor.chargeInflow)
            reac_utils.setFluxGateFlowRate(reac_utils.gateOut, 0)
        ----------------------------------------------------
        -- WARMING / CHARGED STATES
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
        -- RUNNING / ONLINE STATES
        ----------------------------------------------------
        elseif status == "running" or status == "online" then
            if reac_utils.manualStop then
                reac_utils.manualStop = false
                safeRun(reac_utils.reactor.stopReactor, "stopReactor")
                logEvent("Manual reactor stop requested.")
            end
            safeRun(reac_utils.adjustReactorTempAndField, "adjustReactorTempAndField")
        ----------------------------------------------------
        -- STOPPING SEQUENCE
        ----------------------------------------------------
        elseif status == "stopping" then
            safeRun(reac_utils.handleReactorStopping, "handleReactorStopping")
        else
            logEvent("Unknown reactor status: " .. tostring(status))
        end

        ----------------------------------------------------
        -- UPDATE FLUX GATE CONTROL + MONITOR OUTPUT
        ----------------------------------------------------
        safeRun(reac_utils.updateFluxGates, "updateFluxGates")
        if reac_utils.mon then
            safeRun(monitor_utils.updateMonitor, "monitor_utils.updateMonitor")
        end

        ----------------------------------------------------
        -- PERIODIC STAT LOGGING
        ----------------------------------------------------
        safeRun(energy_core_utils.logEnergyCoreStats, "energy_core_utils.logEnergyCoreStats")
        safeRun(function() stat_utils.logReactorStats(reac_utils.reactor) end,
                "stat_utils.logReactorStats")

        sleep(0.05)   -- 20 iterations per second (tick speed)
    end
end

------------------------------------------------------------
-- ENTRY POINT (SETUP + THREAD LAUNCH)
------------------------------------------------------------
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("===================================================")
    print("   CC:Tweaked Draconic Reactor Manager  v2.0")
    print("===================================================")
    print("Initializing peripherals and configuration...")

    --------------------------------------------------------
    -- Initialize subsystems (reactor / monitor / logging)
    --------------------------------------------------------
    safeRun(reac_utils.setup, "reac_utils.setup")
    safeRun(energy_core_utils.setup, "energy_core_utils.setup")
    logEvent("Initialization complete; entering main loop.")

    --------------------------------------------------------
    -- Run main loop + interactive monitor in parallel
    --------------------------------------------------------
    if reac_utils.mon == nil then
        -- No monitor found, just run the loop
        safeRun(mainLoop, "mainLoop")
    else
        -- Run both logic and touch handler concurrently
        parallel.waitForAll(mainLoop, monitor_utils.clickListener)
        reac_utils.clearMonitor()
        reac_utils.drawText("Program stopped.", 1, 1, colors.white, colors.black)
        logEvent("Program terminated by user interaction.")
    end
end

------------------------------------------------------------
-- SAFE STARTUP WRAPPER (CRASH-RESILIENT)
------------------------------------------------------------
local ok, err = pcall(main)
if not ok then
    logEvent("Fatal crash in main(): " .. tostring(err))
    print("Fatal error: " .. tostring(err))
    print("See draconic_manager.log for details.")
end
