-- Main Control Script (Computer)
-- Save as: main_control.lua

-- Draconic Reactor Control Script with Interactive Monitor
-- Version 1.0

--[[
README

Features:
- Uses a dynamically adjusting advanced computer touchscreen monitor to interact with your reactor.
- Automated regulation of the input gate for the targeted field strength of 50%.
- Immediate shutdown and charge upon your field strength going below 20% (adjustable).
- Reactor will activate upon a successful charge.
- Immediate shutdown when your temperature goes above 8000C (adjustable).
- Reactor will activate upon temperature cooling down to 3000C (adjustable).
- Easily tweak your output flux gate via touchscreen buttons:
  - +/-100k, 10k, and 1k increments.

Configuration Changes:
- Edit the values in the `config.lua` file to change default settings.

To save configuration changes, edit the `config.lua` file and then restart the script.
]]

-- Import required libraries and scripts
local reac_utils = require("reac_utils")
local monitor_utils = require("monitor_utils")
local stat_utils = require("stat_utils")
local energy_core_utils = require("energy_core_utils")
local config = require("config")

-- Main loop
local function mainLoop()
    while true do
        reac_utils.checkReactorStatus()

        if reac_utils.isEmergency() then
            reac_utils.failSafeShutdown()
            print("Emergency shutdown initiated.")
        elseif reac_utils.info.status == "cold" or reac_utils.info.status == "offline" or reac_utils.info.status == "cooling" then
            if reac_utils.manualCharge then
                reac_utils.manualCharge = false
                reac_utils.reactor.chargeReactor()
            end
        elseif reac_utils.info.status == "charging" then
            reac_utils.setFluxGateFlowRate(reac_utils.gateIn, config.reactor.chargeInflow)
            reac_utils.setFluxGateFlowRate(reac_utils.gateOut, 0)
        elseif reac_utils.info.status == "warming_up" or reac_utils.info.status == "charged" then
            reac_utils.setFluxGateFlowRate(reac_utils.gateIn, config.reactor.chargeInflow)
            reac_utils.setFluxGateFlowRate(reac_utils.gateOut, 0)
            if reac_utils.manualStart then
                reac_utils.manualStart = false
                reac_utils.reactor.activateReactor()
            end
        elseif reac_utils.info.status == "running" or reac_utils.info.status == "online" then
            if reac_utils.manualStop then
                reac_utils.manualStop = false
                reac_utils.reactor.stopReactor()
            end

            reac_utils.adjustReactorTempAndField()
        elseif reac_utils.info.status == "stopping" then
            reac_utils.handleReactorStopping()
        end

        reac_utils.updateFluxGates()

        if reac_utils.mon then
            monitor_utils.updateMonitor()
        end

        -- Log statistics
        stat_utils.logReactorStats(reac_utils.reactor)

        sleep(0.02)
    end
end

-- Main entry point
local function main()
    reac_utils.setup()
    if reac_utils.mon == nil then
        mainLoop()
    else
        parallel.waitForAll(mainLoop, monitor_utils.clickListener)
        reac_utils.clearMonitor()
        reac_utils.drawText("Program stopped!", 1, 1, colors.white, colors.black)
    end
end

main()
