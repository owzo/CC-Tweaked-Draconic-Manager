--==============================================================
-- Statistics Utilities (Flux Gate Based)
-- Save as: stat_utils.lua
--==============================================================

--[[
README
-------
Logs reactor and flux gate statistics. This version no longer
depends on draconic_rf_storage or Energy Core peripherals.

Features:
- Compatible with wired/wireless flux gates
- Logs both reactor and flux gate flow rates
- Timestamped structured logs
]]

------------------------------------------------------------
-- MODULE SETUP
------------------------------------------------------------
local stat_utils = {}

------------------------------------------------------------
-- FLUX GATE DISCOVERY
------------------------------------------------------------
local function findFluxGates()
    local gates = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name):find("flux_gate") then
            table.insert(gates, peripheral.wrap(name))
        end
    end
    if #gates == 0 then
        error("No flux gates detected! Attach modems to your gates.")
    end
    return gates
end

local fluxGates = findFluxGates()

------------------------------------------------------------
-- ERROR LOGGING
------------------------------------------------------------
local function logError(msg)
    local f = fs.open("logs.cfg", "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

------------------------------------------------------------
-- REACTOR STATS LOGGING
------------------------------------------------------------
function stat_utils.logReactorStats(reactor)
    if not reactor or not reactor.getReactorInfo then
        logError("Invalid reactor reference in logReactorStats()")
        return
    end

    local ok, info = pcall(reactor.getReactorInfo)
    if not ok or not info then
        logError("Failed to read reactor data: " .. tostring(info))
        return
    end

    local f = fs.open("reactor_stats.log", "a")
    if not f then return end

    local line = string.format(
        "%s | Status=%s | Temp=%.1f | Field=%.1f | Fuel=%.2f | Saturation=%.1f",
        os.date("%Y-%m-%d %H:%M:%S"),
        tostring(info.status or "unknown"),
        tonumber(info.temperature or 0),
        tonumber(info.fieldStrength or 0),
        tonumber(info.fuelConversion or 0),
        tonumber(info.energySaturation or 0)
    )

    f.writeLine(line)
    f.close()
end

------------------------------------------------------------
-- FLUX GATE FLOW LOGGING
------------------------------------------------------------
function stat_utils.logEnergyCoreStats()
    local f = fs.open("energy_core_stats.log", "a")
    if not f then return end

    local inFlow, outFlow = 0, 0
    for _, gate in ipairs(fluxGates) do
        local ok, flow = pcall(gate.getFlow)
        if ok and type(flow) == "number" then
            if flow < 0 then
                inFlow = inFlow + flow
            else
                outFlow = outFlow + flow
            end
        end
    end

    f.writeLine(string.format(
        "%s | In: %.0f RF/t | Out: %.0f RF/t",
        os.date("%Y-%m-%d %H:%M:%S"),
        inFlow, outFlow
    ))
    f.close()
end

return stat_utils
