--==============================================================
-- Statistics Utilities
-- Save as: stat_utils.lua
--==============================================================

--[[
README
-------
Handles logging of Draconic Reactor and Energy Core statistics.

Features:
- Compatible with wired, wireless, or mixed modem networks
- Automatically validates and reconnects to peripherals
- Logs structured timestamped data for both reactor and core
- Creates CSV-style logs for easy analysis
- Safe, fault-tolerant file operations
]]

------------------------------------------------------------
-- DEPENDENCIES AND CONFIG
------------------------------------------------------------
local cfg = require("config")
local energyCfg = cfg.energyCore
local peripherals = cfg.peripherals

local stat_utils = {}

------------------------------------------------------------
-- LOCAL PERIPHERALS
------------------------------------------------------------
local energyCore

------------------------------------------------------------
-- LOGGING HELPERS
------------------------------------------------------------
local function safeWriteLog(path, line)
    local ok, err = pcall(function()
        local f = fs.open(path, "a")
        if not f then
            print("Unable to open log file: " .. path)
            return
        end
        f.writeLine(line)
        f.close()
    end)
    if not ok then
        print("Logging error: " .. tostring(err))
    end
end

local function logError(message)
    safeWriteLog(energyCfg.logsFile or "logs.cfg",
        string.format("%s | ERROR: %s", os.date("%Y-%m-%d %H:%M:%S"), message))
end

------------------------------------------------------------
-- PERIPHERAL VALIDATION AND RECOVERY
------------------------------------------------------------
local function findEnergyCore()
    if peripherals.energyCore and peripherals.energyCore ~= "" then
        if peripheral.isPresent(peripherals.energyCore) then
            return peripheral.wrap(peripherals.energyCore)
        end
    end
    return peripheral.find("draconic_rf_storage")
end

local function validatePeripherals()
    energyCore = findEnergyCore()
    if not energyCore then
        logError("Energy Core peripheral not found.")
        error("Energy Core not found. Attach a modem to an I/O crystal.")
    end
end

------------------------------------------------------------
-- INITIALIZE ON LOAD
------------------------------------------------------------
validatePeripherals()

------------------------------------------------------------
-- LOG REACTOR STATISTICS
------------------------------------------------------------
function stat_utils.logReactorStats(reactor)
    if not reactor or not reactor.getReactorInfo then
        logError("Invalid reactor reference in logReactorStats()")
        return
    end

    local ok, info = pcall(reactor.getReactorInfo)
    if not ok or not info then
        logError("Failed to fetch reactor information for statistics.")
        return
    end

    -- Flatten data for log output
    local line = string.format(
        "%s | Status=%s | Temp=%.2f | Field=%.2f | Fuel=%.2f | Sat=%.2f | Gen=%.2f",
        os.date("%Y-%m-%d %H:%M:%S"),
        tostring(info.status or "unknown"),
        tonumber(info.temperature or 0),
        tonumber(info.fieldStrength or 0),
        tonumber(info.fuelConversion or 0),
        tonumber(info.energySaturation or 0),
        tonumber(info.generationRate or 0)
    )

    safeWriteLog("reactor_stats.log", line)
end

------------------------------------------------------------
-- LOG ENERGY CORE STATISTICS
------------------------------------------------------------
function stat_utils.logEnergyCoreStats(inputRate, outputRate)
    if not energyCore then
        validatePeripherals()
    end

    local ok, data = pcall(function()
        return {
            stored = energyCore.getEnergyStored(),
            max = energyCore.getMaxEnergyStored(),
            transfer = energyCore.getTransferPerTick()
        }
    end)

    if not ok or not data then
        logError("Failed to read energy core statistics.")
        return
    end

    local line = string.format(
        "%s | Stored=%d | Max=%d | Transfer=%d | In=%d | Out=%d",
        os.date("%Y-%m-%d %H:%M:%S"),
        data.stored or 0,
        data.max or 0,
        data.transfer or 0,
        inputRate or 0,
        outputRate or 0
    )

    safeWriteLog("energy_core_stats.log", line)
end

------------------------------------------------------------
-- CSV-STYLE EXPORT (OPTIONAL)
------------------------------------------------------------
function stat_utils.exportCSV()
    local ok, data = pcall(function()
        local s = energyCore.getEnergyStored()
        local m = energyCore.getMaxEnergyStored()
        local t = energyCore.getTransferPerTick()
        return string.format("%s,%d,%d,%d", os.date("%Y-%m-%d %H:%M:%S"), s, m, t)
    end)
    if ok and data then
        safeWriteLog("energy_core_summary.csv", data)
    else
        logError("Failed to write CSV energy summary.")
    end
end

------------------------------------------------------------
-- EXPORTED ERROR LOGGER (for external modules)
------------------------------------------------------------
function stat_utils.logError(err)
    logError(err)
end

return stat_utils
