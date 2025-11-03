--==============================================================
-- REACTOR UTILITIES
-- Save as: reac_utils.lua
--==============================================================

--[[
README
-------
Handles all direct interactions with the Draconic Reactor stabilizer.

Features:
- Detects and reports "No Fuel" conditions.
- Detects near/full energy saturation (chaos output full).
- Performs automatic emergency shutdown when energy has nowhere to go.
- Provides field and temperature regulation logic.
]]

------------------------------------------------------------
-- MODULE IMPORTS & SETUP
------------------------------------------------------------
local cfg = require("config")
local p = cfg.peripherals
local reac_utils = {}

------------------------------------------------------------
-- GLOBAL VARIABLES
------------------------------------------------------------
reac_utils.reactor = peripheral.wrap(p.reactor)
reac_utils.gateIn  = peripheral.wrap(p.fluxIn)
reac_utils.gateOut = peripheral.wrap(p.fluxOut)
reac_utils.mon     = peripheral.wrap(p.monitors[1])
reac_utils.info    = {}
reac_utils.lastCheck = os.clock()

------------------------------------------------------------
-- LOGGING FUNCTION
------------------------------------------------------------
local function log(msg)
    local f = fs.open(cfg.energyCore.logsFile, "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------
function reac_utils.setup()
    reac_utils.reactor = peripheral.wrap(p.reactor)
    reac_utils.gateIn  = peripheral.wrap(p.fluxIn)
    reac_utils.gateOut = peripheral.wrap(p.fluxOut)
    reac_utils.mon     = peripheral.wrap(p.monitors[1])
    reac_utils.gateIn.setOverrideEnabled(true)
    reac_utils.gateOut.setOverrideEnabled(true)
    log("Reactor peripherals initialized successfully.")
end

------------------------------------------------------------
-- STATUS RETRIEVAL
------------------------------------------------------------
function reac_utils.checkReactorStatus()
    local ok, info = pcall(reac_utils.reactor.getReactorInfo)
    if not ok or not info then
        log("Failed to fetch reactor info.")
        return
    end
    reac_utils.info = info
end

------------------------------------------------------------
-- FUEL & CHAOS MONITORING
------------------------------------------------------------
function reac_utils.checkFuelAndChaos()
    local i = reac_utils.info
    if not i or not i.fuelConversion then
        log("Reactor info unavailable during fuel check.")
        return false
    end

    -- Fuel ratio = 1.0 means full, 0.0 means empty
    local fuelRemaining = 1.0 - (i.fuelConversion / i.maxFuelConversion)
    local energySaturation = i.energySaturation / i.maxEnergySaturation

    -- No fuel left -> stop reactor immediately
    if fuelRemaining <= cfg.reactor.minFuel then
        log("ERROR: Reactor out of fuel! Emergency shutdown triggered.")
        reac_utils.failSafeShutdown()
        if reac_utils.mon then
            reac_utils.mon.setTextColor(colors.red)
            reac_utils.mon.setCursorPos(2, 8)
            reac_utils.mon.write("NO FUEL - Reactor Stopped!")
        end
        return false
    end

    -- Chaos output (energy storage) full -> warn or stop
    if energySaturation >= cfg.reactor.maxSaturation then
        log("WARNING: Energy storage full (" ..
            math.floor(energySaturation * 100) .. "%).")
        if reac_utils.mon then
            reac_utils.mon.setTextColor(colors.yellow)
            reac_utils.mon.setCursorPos(2, 9)
            reac_utils.mon.write("⚠ CHAOS STORAGE FULL ⚠")
        end
        -- Auto-stop reactor if completely full
        if energySaturation >= 1.0 then
            log("Energy saturation 100% - reactor shutting down.")
            reac_utils.failSafeShutdown()
            return false
        end
    end

    return true
end

------------------------------------------------------------
-- FAILSAFE SHUTDOWN
------------------------------------------------------------
function reac_utils.failSafeShutdown()
    pcall(function()
        reac_utils.reactor.stopReactor()
        reac_utils.gateIn.setFlowOverride(0)
        reac_utils.gateOut.setFlowOverride(0)
    end)
    log("Failsafe shutdown executed.")
end

------------------------------------------------------------
-- REACTOR CONTROL LOGIC
------------------------------------------------------------
function reac_utils.adjustReactorTempAndField()
    local i = reac_utils.info
    if not i or not i.temperature then return end

    -- Check for dangerous conditions
    reac_utils.checkFuelAndChaos()

    local currentField = i.fieldStrength / i.maxFieldStrength
    local temp = i.temperature

    -- Input control
    if currentField < cfg.reactor.defaultField then
        reac_utils.gateIn.setFlowOverride(cfg.reactor.chargeInflow)
    else
        reac_utils.gateIn.setFlowOverride(0)
    end

    -- Output control (energy drain)
    local tempDelta = math.max(0, temp - cfg.reactor.safeTemperature)
    local outRate = math.min(cfg.reactor.maxOutflow, tempDelta * 2000)
    reac_utils.gateOut.setFlowOverride(outRate)
end

------------------------------------------------------------
-- EMERGENCY DETECTION
------------------------------------------------------------
function reac_utils.isEmergency()
    local i = reac_utils.info
    if not i or not i.temperature then return false end
    if i.temperature >= cfg.reactor.defaultTemp + cfg.reactor.maxOvershoot then
        log("Emergency: Reactor temperature overshoot detected.")
        return true
    end
    if (i.fieldStrength / i.maxFieldStrength) < cfg.reactor.shutDownField then
        log("Emergency: Field collapse detected.")
        return true
    end
    return false
end

return reac_utils
