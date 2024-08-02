-- Statistics Utilities
-- Save as: lib/stat_utils.lua

--[[
README

Functions to log statistics for the Draconic Reactor and Energy Core.
Includes logging reactor statistics and generating reports.
]]

local config = require("config").energyCore

-- Function to log errors
function logError(err)
    local logFile = fs.open(config.logsFile, "a")
    logFile.writeLine(os.date() .. ": " .. err)
    logFile.close()
end

-- Function to log reactor statistics
function logReactorStats(reactor)
    local logFile = fs.open("reactor_stats.log", "a")
    local info = reactor.getReactorInfo()
    logFile.writeLine(os.date() .. ": " .. textutils.serialize(info))
    logFile.close()
end

-- Function to log energy core statistics
function logEnergyCoreStats(energyCore, inputRate, outputRate)
    local logFile = fs.open("energy_core_stats.log", "a")
    local energyStored = energyCore.getEnergyStored()
    local maxEnergyStored = energyCore.getMaxEnergyStored()
    local transferRate = energyCore.getTransferPerTick()
    logFile.writeLine(os.date() .. ": Stored=" .. energyStored .. ", Max=" .. maxEnergyStored .. ", Transfer=" .. transferRate .. ", InputRate=" .. inputRate .. ", OutputRate=" .. outputRate)
    logFile.close()
end
