--==============================================================
-- Energy Core Utilities
-- Save as: energy_core_utils.lua
--==============================================================

--[[
README
-------
Functions for monitoring and controlling a Draconic Energy Core
through CC:Tweaked. Supports both wired and wireless modem
connections (or a hybrid of both).

Handles:
- Energy Core detection and status retrieval
- Monitor display updates
- Logging of statistics and errors
- Flux gate rate adjustments (if present)
]]

------------------------------------------------------------
-- DEPENDENCIES AND CONFIG
------------------------------------------------------------
local cfg = require("config")
local energyCfg = cfg.energyCore
local peripherals = cfg.peripherals

local energy_core_utils = {}

------------------------------------------------------------
-- PERIPHERAL REFERENCES
------------------------------------------------------------
local monitor
local energyCore
local inputGate
local outputGate

------------------------------------------------------------
-- HELPER: FIND PERIPHERAL BY TYPE
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

------------------------------------------------------------
-- VALIDATE AND INITIALIZE PERIPHERALS
------------------------------------------------------------
local function validatePeripherals()
    -- Monitors
    if peripherals.monitors and #peripherals.monitors > 0 then
        for _, side in ipairs(peripherals.monitors) do
            if peripheral.getType(side) == "monitor" then
                monitor = peripheral.wrap(side)
                break
            end
        end
    end
    if not monitor then
        monitor = peripheral.find("monitor")
    end
    if not monitor then
        error("Monitor not found. Attach or define a valid monitor in config.peripherals.monitors.")
    end

    -- Energy Core
    if peripherals.energyCore and peripherals.energyCore ~= "" then
        if not peripheral.isPresent(peripherals.energyCore) then
            error("Configured Energy Core peripheral not found: " .. peripherals.energyCore)
        end
        energyCore = peripheral.wrap(peripherals.energyCore)
    else
        energyCore = peripheral.find("draconic_rf_storage")
    end
    if not energyCore then
        error("Draconic Energy Core not found. Attach a modem to an I/O Crystal.")
    end

    -- Flux Gates (Input and Output)
    if peripherals.fluxIn and peripherals.fluxIn ~= "" then
        inputGate = peripheral.wrap(peripherals.fluxIn)
    else
        inputGate = peripheral.find("draconic_flux_gate")
    end
    if not inputGate then
        error("Input Flux Gate not found.")
    end

    if peripherals.fluxOut and peripherals.fluxOut ~= "" then
        outputGate = peripheral.wrap(peripherals.fluxOut)
    else
        outputGate = peripheral.find("draconic_flux_gate")
    end
    if not outputGate then
        error("Output Flux Gate not found.")
    end
end

-- Run validation on load
validatePeripherals()

------------------------------------------------------------
-- LOGGING FUNCTIONS
------------------------------------------------------------
function energy_core_utils.logError(err)
    local logFile = fs.open(energyCfg.logsFile or "logs.cfg", "a")
    if logFile then
        logFile.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " ERROR: " .. tostring(err))
        logFile.close()
    end
end

function energy_core_utils.logEnergyCoreStats()
    local logFile = fs.open("energy_core_stats.log", "a")
    if not logFile then return end

    local energyStored = energyCore.getEnergyStored()
    local maxEnergyStored = energyCore.getMaxEnergyStored()
    local transferRate = energyCore.getTransferPerTick()
    logFile.writeLine(
        string.format(
            "%s | Stored=%d | Max=%d | Transfer=%d RF/t",
            os.date("%Y-%m-%d %H:%M:%S"),
            energyStored, maxEnergyStored, transferRate
        )
    )
    logFile.close()
end

------------------------------------------------------------
-- MONITOR OUTPUT
------------------------------------------------------------
local function drawText(x, y, text, textColor, bgColor)
    monitor.setCursorPos(x, y)
    monitor.setTextColor(textColor or colors.white)
    monitor.setBackgroundColor(bgColor or colors.black)
    monitor.write(text)
end

function energy_core_utils.updateMonitor()
    monitor.setTextScale(energyCfg.monitorScale or 1)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    local energyStored = energyCore.getEnergyStored()
    local maxEnergyStored = energyCore.getMaxEnergyStored()
    local transferRate = energyCore.getTransferPerTick()

    drawText(2, 2, "Energy Core Status", colors.white, colors.black)
    drawText(2, 4, string.format("Stored: %d RF", energyStored), colors.white)
    drawText(2, 5, string.format("Capacity: %d RF", maxEnergyStored), colors.white)
    drawText(2, 6, string.format("Transfer: %d RF/t", transferRate), colors.white)
end

------------------------------------------------------------
-- FLUX GATE RATE CONTROL
------------------------------------------------------------
function energy_core_utils.setInputRate(rate)
    if inputGate and inputGate.setFlow then
        inputGate.setFlow(rate)
    elseif inputGate and inputGate.setFlowrate then
        inputGate.setFlowrate(rate)
    else
        energy_core_utils.logError("Input flux gate does not support setFlow/setFlowrate.")
    end
end

function energy_core_utils.setOutputRate(rate)
    if outputGate and outputGate.setFlow then
        outputGate.setFlow(rate)
    elseif outputGate and outputGate.setFlowrate then
        outputGate.setFlowrate(rate)
    else
        energy_core_utils.logError("Output flux gate does not support setFlow/setFlowrate.")
    end
end

------------------------------------------------------------
-- CLICK LISTENER (FOR TOUCH MONITORS)
------------------------------------------------------------
function energy_core_utils.clickListener()
    while true do
        local event, side, xPos, yPos = os.pullEvent("monitor_touch")
        if xPos >= 2 and xPos <= 9 and yPos >= 16 and yPos <= 18 then
            energy_core_utils.setInputRate(10000000)  -- Example static input rate
        elseif xPos >= 11 and xPos <= 18 and yPos >= 16 and yPos <= 18 then
            energy_core_utils.setOutputRate(20000000) -- Example static output rate
        end
    end
end

return energy_core_utils
