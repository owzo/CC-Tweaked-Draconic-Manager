--==============================================================
-- STATISTICS UTILITIES
-- Save as: stat_utils.lua
--==============================================================

local stat_utils = {}

local function logError(msg)
    local f = fs.open("stats_error.log", "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

function stat_utils.logReactorStats(reactor)
    if not reactor or not reactor.getReactorInfo then
        logError("Reactor unavailable during stats logging.")
        return
    end

    local ok, info = pcall(reactor.getReactorInfo)
    if not ok or not info then
        logError("Failed to get reactor info: " .. tostring(info))
        return
    end

    local f = fs.open("reactor_stats.log", "a")
    if not f then return end
    f.writeLine(string.format(
        "%s | Temp=%.1f | Field=%.2f | Fuel=%.2f | Sat=%.2f | Status=%s",
        os.date("%Y-%m-%d %H:%M:%S"),
        info.temperature or 0,
        info.fieldStrength or 0,
        info.fuelConversion or 0,
        info.energySaturation or 0,
        info.status or "unknown"
    ))
    f.close()
end

return stat_utils
