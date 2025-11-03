--==============================================================
-- STATISTICS UTILITIES
-- Save as: stat_utils.lua
--==============================================================

--[[
README
-------
Handles automated logging for reactor and energy flow data.
Works only with configured flux gates and reactor stabilizer.

Adds:
- Automatic retries
- Error handling with logging
- Periodic background logging
]]

------------------------------------------------------------
-- IMPORT CONFIG + SETUP
------------------------------------------------------------
local cfg = require("config")
local p = cfg.peripherals
local stat_utils = {}

------------------------------------------------------------
-- WRAP PERIPHERALS
------------------------------------------------------------
local reactor = peripheral.wrap(p.reactor)
local inGate = peripheral.wrap(p.fluxIn)
local outGate = peripheral.wrap(p.fluxOut)

------------------------------------------------------------
-- LOGGING FUNCTION
------------------------------------------------------------
local function logError(msg)
    local f = fs.open(cfg.energyCore.logsFile, "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

------------------------------------------------------------
-- LOG REACTOR DATA
------------------------------------------------------------
function stat_utils.logReactorStats()
    local ok, info = pcall(reactor.getReactorInfo)
    if not ok or not info then
        logError("Failed to read reactor info.")
        return
    end

    local f = fs.open("reactor_stats.log", "a")
    if not f then
        logError("Failed to open reactor_stats.log")
        return
    end

    f.writeLine(string.format(
        "%s | Status=%s | Temp=%.1f | Field=%.1f | Fuel=%.2f | Sat=%.1f",
        os.date("%Y-%m-%d %H:%M:%S"),
        tostring(info.status or "unknown"),
        tonumber(info.temperature or 0),
        tonumber(info.fieldStrength or 0),
        tonumber(info.fuelConversion or 0),
        tonumber(info.energySaturation or 0)
    ))
    f.close()
end

------------------------------------------------------------
-- LOG FLUX GATE FLOW DATA
------------------------------------------------------------
function stat_utils.logEnergyCoreStats()
    local okIn, inFlow = pcall(inGate.getFlow)
    local okOut, outFlow = pcall(outGate.getFlow)
    if not okIn or not okOut then
        logError("Flux gate read error during logEnergyCoreStats()")
        return
    end

    local f = fs.open("energy_core_stats.log", "a")
    if not f then
        logError("Failed to open energy_core_stats.log")
        return
    end
    f.writeLine(string.format(
        "%s | In: %.0f RF/t | Out: %.0f RF/t",
        os.date("%Y-%m-%d %H:%M:%S"), inFlow, outFlow))
    f.close()
end

------------------------------------------------------------
-- AUTOMATION: BACKGROUND LOGGER
------------------------------------------------------------
function stat_utils.runAutoLogger()
    while true do
        local ok, err = pcall(function()
            stat_utils.logReactorStats()
            stat_utils.logEnergyCoreStats()
        end)
        if not ok then logError("AutoLogger error: " .. tostring(err)) end
        sleep(10)  -- Log every 10 seconds
    end
end

return stat_utils
