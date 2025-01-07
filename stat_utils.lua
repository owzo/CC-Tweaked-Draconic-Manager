-- Statistics Utilities
-- Save as: stat_utils.lua

--[[
README

Functions to log statistics for the Draconic Reactor and Energy Core.
Includes logging reactor statistics and generating reports.
]]

local config = require("config").energyCore

local stat_utils = {}

-- Peripherals
local energyCore

-- Function to validate peripherals (Newly Added)
local function validatePeripherals()
    energyCore = peripheral.find("draconic_rf_storage")
    if not energyCore then error("Energy Core not found!") end
end

-- Call to validate peripherals (Ensures peripherals are checked before usage)
validatePeripherals()

-- Function to log errors
function stat_utils.logError(err)
    local logFile = fs.open(config.logsFile, "a")
    if logFile then
        logFile.writeLine(os.date() .. ": " .. err)
        logFile.close()
    else
        print("Failed to open log file.")
    end
end

-- Function to log reactor statistics
function stat_utils.logReactorStats(reactor)
    local logFile = fs.open("reactor_stats.log", "a")
    if logFile then
        local info = reactor.getReactorInfo()
        logFile.writeLine(os.date() .. ": " .. textutils.serialize(info))
        logFile.close()
    else
        print("Failed to open reactor statistics log file.")
    end
end

-- Function to log energy core statistics
function stat_utils.logEnergyCoreStats(inputRate, outputRate)
    local logFile = fs.open("energy_core_stats.log", "a")
    if logFile then
        local energyStored = energyCore.getEnergyStored()
        local maxEnergyStored = energyCore.getMaxEnergyStored()
        local transferRate = energyCore.getTransferPerTick()
        logFile.writeLine(os.date() .. ": Stored=" .. energyStored .. ", Max=" .. maxEnergyStored .. ", Transfer=" .. transferRate .. ", InputRate=" .. inputRate .. ", OutputRate=" .. outputRate)
        logFile.close()
    else
        print("Failed to open energy core statistics log file.")
    end
end

return stat_utils
