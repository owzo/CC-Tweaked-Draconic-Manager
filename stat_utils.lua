--==============================================================
-- STATISTICS UTILITIES
-- Save as: stat_utils.lua
--==============================================================

local cfg = require("config")
local p = cfg.peripherals
local stat_utils = {}

local reactor = peripheral.wrap(p.reactor)
local inGate  = peripheral.wrap(p.fluxIn)
local outGate = peripheral.wrap(p.fluxOut)

------------------------------------------------------------
-- GENERIC LOGGING
------------------------------------------------------------
local function log(msg)
    local f = fs.open(cfg.energyCore.logsFile, "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

------------------------------------------------------------
-- LOG REACTOR STATS (INCL. FUEL + CHAOS)
------------------------------------------------------------
function stat_utils.logReactorStats()
    local ok, info = pcall(reactor.getReactorInfo)
    if not ok or not info then
        log("Reactor data unavailable for stat logging.")
        return
    end

    local fuelPct = 100 * (1.0 - info.fuelConversion / info.maxFuelConversion)
    local chaosPct = 100 * (info.energySaturation / info.maxEnergySaturation)

    local f = fs.open("reactor_stats.log", "a")
    if f then
        f.writeLine(string.format(
            "%s | Status=%s | Temp=%.0f°C | Field=%.2f%% | Fuel=%.2f%% | Chaos=%.2f%%",
            os.date("%Y-%m-%d %H:%M:%S"),
            info.status or "unknown",
            info.temperature or 0,
            100 * (info.fieldStrength / info.maxFieldStrength),
            fuelPct,
            chaosPct
        ))
        f.close()
    end
end

return stat_utils
