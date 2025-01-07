-- Energy Core Utilities
-- Save as: energy_core_utils.lua

--[[
README

Functions to handle Draconic Energy Core monitoring and interactions.
Includes setup, error handling, and energy core status checks.
]]

local config = require("config").energyCore

local energy_core_utils = {}

-- Peripherals
local monitor
local energyCore
local inputGate
local outputGate

-- Function to validate peripherals (Newly Added)
local function validatePeripherals()
    monitor = peripheral.find("monitor")
    energyCore = peripheral.find("draconic_rf_storage")
    inputGate = peripheral.wrap("input_flux_gate")
    outputGate = peripheral.wrap("output_flux_gate")

    if not monitor then error("Monitor not found!") end
    if not energyCore then error("Energy Core not found!") end
    if not inputGate then error("Input flux gate not found!") end
    if not outputGate then error("Output flux gate not found!") end
end

-- Call to validate peripherals (Ensures everything is present before proceeding)
validatePeripherals()

-- Function to log errors
function energy_core_utils.logError(err)
    local logFile = fs.open(config.logsFile, "a")
    logFile.writeLine(os.date() .. ": " .. err)
    logFile.close()
end

-- Function to draw text on the monitor
function energy_core_utils.drawText(x, y, text, textColor, bgColor)
    monitor.setCursorPos(x, y)
    monitor.setTextColor(textColor)
    monitor.setBackgroundColor(bgColor)
    monitor.write(text)
end

-- Function to update the monitor with energy core status
function energy_core_utils.updateMonitor()
    monitor.clear()
    local energyStored = energyCore.getEnergyStored()
    local maxEnergyStored = energyCore.getMaxEnergyStored()
    local transferRate = energyCore.getTransferPerTick()

    drawText(2, 2, "Energy Core Status", colors.white, colors.black)
    drawText(2, 3, "Energy Stored: " .. energyStored .. " RF", colors.white, colors.black)
    drawText(2, 4, "Max Energy Stored: " .. maxEnergyStored .. " RF", colors.white, colors.black)
    drawText(2, 5, "Transfer Rate: " .. transferRate .. " RF/t", colors.white, colors.black)
end

-- Function to log energy core statistics
function energy_core_utils.logEnergyCoreStats()
    local logFile = fs.open("energy_core_stats.log", "a")
    local energyStored = energyCore.getEnergyStored()
    local maxEnergyStored = energyCore.getMaxEnergyStored()
    local transferRate = energyCore.getTransferPerTick()
    logFile.writeLine(os.date() .. ": Stored=" .. energyStored .. ", Max=" .. maxEnergyStored .. ", Transfer=" .. transferRate)
    logFile.close()
end

-- Function to handle click events on the monitor
function energy_core_utils.clickListener()
    while true do
        local event, side, xPos, yPos = os.pullEvent("monitor_touch")
        if xPos >= 2 and xPos <= 9 and yPos >= 16 and yPos <= 18 then
            setInputRate()
        elseif xPos >= 11 and xPos <= 18 and yPos >= 16 and yPos <= 18 then
            setOutputRate()
        end
    end
end

return energy_core_utils
