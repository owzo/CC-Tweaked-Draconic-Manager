--==============================================================
-- Reactor Utilities
-- Save as: reac_utils.lua
--==============================================================

--[[
README
-------
Functions to manage Draconic Reactor control and monitoring.

Features:
- Compatible with wired, wireless, or mixed modem setups
- Auto-discovers peripherals if names are not defined in config.lua
- Provides complete reactor data tracking and safety automation
- Handles emergency shutdown and recovery logic
- Safely regulates reactor temperature, field strength, and flow rates
]]

------------------------------------------------------------
-- DEPENDENCIES AND CONFIG
------------------------------------------------------------
local cfg = require("config")
local reactorCfg = cfg.reactor
local peripherals = cfg.peripherals

local reac_utils = {}

------------------------------------------------------------
-- LOCAL STATE
------------------------------------------------------------
local reactor
local gateIn
local gateOut
local mon
local info = {}
local currentEmergency = false
local currentField = 0
local currentFuel = 0
local manualStart = false
local manualCharge = false
local manualStop = false

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------
local function logError(err)
    local f = fs.open("reactor_error.log", "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. tostring(err))
        f.close()
    end
end

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
-- VALIDATION / INITIALIZATION
------------------------------------------------------------
local function validatePeripherals()
    -- Reactor
    if peripherals.reactor and peripherals.reactor ~= "" then
        if not peripheral.isPresent(peripherals.reactor) then
            error("Configured reactor peripheral not found: " .. peripherals.reactor)
        end
        reactor = peripheral.wrap(peripherals.reactor)
    else
        local name = findPeripheralByType("draconic_reactor")
        if not name then error("Reactor not found.") end
        reactor = peripheral.wrap(name)
    end

    -- Input Flux Gate
    if peripherals.fluxIn and peripherals.fluxIn ~= "" then
        gateIn = peripheral.wrap(peripherals.fluxIn)
    else
        gateIn = peripheral.find("draconic_flux_gate")
    end
    if not gateIn then error("Input flux gate not found.") end

    -- Output Flux Gate
    if peripherals.fluxOut and peripherals.fluxOut ~= "" then
        gateOut = peripheral.wrap(peripherals.fluxOut)
    else
        gateOut = peripheral.find("draconic_flux_gate")
    end
    if not gateOut then error("Output flux gate not found.") end

    -- Monitor (optional)
    if peripherals.monitors and #peripherals.monitors > 0 then
        for _, side in ipairs(peripherals.monitors) do
            if peripheral.getType(side) == "monitor" then
                mon = peripheral.wrap(side)
                break
            end
        end
    end
    if not mon then
        mon = peripheral.find("monitor")
    end
end

------------------------------------------------------------
-- SETUP
------------------------------------------------------------
function reac_utils.setup()
    term.clear()
    term.setCursorPos(1,1)
    print("Initializing reactor control...")
    validatePeripherals()

    -- Initialize flux gates safely
    if gateIn.setOverrideEnabled then
        gateIn.setOverrideEnabled(true)
        gateIn.setFlowOverride(0)
    elseif gateIn.setFlow then
        gateIn.setFlow(0)
    end
    if gateOut.setOverrideEnabled then
        gateOut.setOverrideEnabled(true)
        gateOut.setFlowOverride(0)
    elseif gateOut.setFlow then
        gateOut.setFlow(0)
    end
    print("Reactor peripherals initialized successfully.")
end

------------------------------------------------------------
-- PERIPHERAL GETTERS
------------------------------------------------------------
function reac_utils.getReactorInfo()
    local ok, data = pcall(reactor.getReactorInfo)
    if not ok or not data then
        logError("Failed to get reactor info: " .. tostring(data))
        return nil
    end
    info = data
    currentField = info.fieldStrength / info.maxFieldStrength
    currentFuel = 1.0 - (info.fuelConversion / info.maxFuelConversion)
    return info
end

------------------------------------------------------------
-- STATUS / READOUT FUNCTIONS
------------------------------------------------------------
function reac_utils.getStatus()
    local i = reac_utils.getReactorInfo()
    if not i then return "unknown" end
    return i.status
end

function reac_utils.getTemperature()
    local i = reac_utils.getReactorInfo()
    return (i and i.temperature) or 0
end

function reac_utils.getFieldStrength()
    local i = reac_utils.getReactorInfo()
    return (i and i.fieldStrength) or 0
end

------------------------------------------------------------
-- CONTROL: FLUX GATE MANAGEMENT
------------------------------------------------------------
function reac_utils.setFluxGateFlowRate(gate, flowRate)
    if not gate or not flowRate then return end
    local ok, err = pcall(function()
        if gate.setFlowrate then
            gate.setFlowrate(flowRate)
        elseif gate.setSignalLowFlow then
            gate.setSignalLowFlow(flowRate)
        elseif gate.setFlow then
            gate.setFlow(flowRate)
        else
            logError("Unknown flux gate interface.")
        end
    end)
    if not ok then
        logError("Failed to set flux gate flow rate: " .. tostring(err))
    end
end

------------------------------------------------------------
-- CONTROL: FAIL-SAFE SHUTDOWN
------------------------------------------------------------
function reac_utils.failSafeShutdown()
    logError("Initiating emergency shutdown...")
    pcall(function()
        if reactor.stopReactor then reactor.stopReactor() end
        reac_utils.setFluxGateFlowRate(gateIn, reactorCfg.shutDownField * 1.2)
        reac_utils.setFluxGateFlowRate(gateOut, 0)
    end)
end

------------------------------------------------------------
-- CHECK + EMERGENCY STATE
------------------------------------------------------------
function reac_utils.checkReactorStatus()
    local i = reac_utils.getReactorInfo()
    if not i then return end
    info = i
    currentField = info.fieldStrength / info.maxFieldStrength
    currentFuel = 1.0 - (info.fuelConversion / info.maxFuelConversion)
end

function reac_utils.isEmergency()
    if not info or not reactorCfg.safeMode then return false end
    currentEmergency =
        (info.temperature > reactorCfg.defaultTemp + reactorCfg.maxOvershoot)
        or (currentField < 0.004)
        or (currentFuel < reactorCfg.minFuel)
    return currentEmergency
end

------------------------------------------------------------
-- REACTOR CONTROL LOGIC
------------------------------------------------------------
local function calcInflow(targetField, drain)
    return math.max(0, (targetField * drain) * 1.2)
end

function reac_utils.adjustReactorTempAndField()
    local temp = reac_utils.getTemperature()
    if not info then return end

    local tempDelta = math.max(0, reactorCfg.defaultTemp - temp)
    local tempInc = math.sqrt(tempDelta) / 2.0
    local newOutflow = math.min(
        reactorCfg.maxOutflow,
        (info.maxEnergySaturation or 1) * tempInc / 100
    )

    -- Field control
    if currentField > reactorCfg.defaultField * 1.05 then
        reac_utils.setFluxGateFlowRate(gateIn, 0)
    elseif currentField > reactorCfg.defaultField * 0.95 then
        reac_utils.setFluxGateFlowRate(gateIn, calcInflow(reactorCfg.defaultField, info.fieldDrainRate))
    else
        reac_utils.setFluxGateFlowRate(gateIn, calcInflow(reactorCfg.defaultField * 1.5, info.fieldDrainRate))
    end

    reac_utils.setFluxGateFlowRate(gateOut, math.floor(newOutflow * reactorCfg.outputMultiplier))
end

------------------------------------------------------------
-- HANDLE REACTOR STOPPING
------------------------------------------------------------
function reac_utils.handleReactorStopping()
    if not info then return end
    local inflow
    if currentField > reactorCfg.shutDownField then
        inflow = calcInflow(reactorCfg.shutDownField, info.fieldDrainRate)
    else
        inflow = calcInflow(reactorCfg.shutDownField * 1.2, info.fieldDrainRate)
    end
    reac_utils.setFluxGateFlowRate(gateIn, inflow)
    reac_utils.setFluxGateFlowRate(gateOut, 0)

    if manualStart and reactor.activateReactor then
        manualStart = false
        reactor.activateReactor()
    end
end

------------------------------------------------------------
-- UPDATE FLUX GATES (LOOP-TIME)
------------------------------------------------------------
function reac_utils.updateFluxGates()
    if not info then return end

    local newInflow = 0
    local newOutflow = 0

    local status = reac_utils.getStatus()
    if status == "running" or status == "online" then
        local temp = reac_utils.getTemperature()
        if temp < reactorCfg.defaultTemp then
            local tempInc = math.sqrt(reactorCfg.defaultTemp - temp) / 2.0
            newOutflow = math.min(
                reactorCfg.maxOutflow,
                info.maxEnergySaturation * tempInc / 100
            )
        end

        if currentField > reactorCfg.defaultField * 1.05 then
            newInflow = 0
        elseif currentField > reactorCfg.defaultField * 0.95 then
            newInflow = calcInflow(reactorCfg.defaultField, info.fieldDrainRate)
        else
            newInflow = calcInflow(reactorCfg.defaultField * 1.5, info.fieldDrainRate)
        end
    elseif status == "stopping" then
        newInflow = calcInflow(reactorCfg.shutDownField, info.fieldDrainRate)
        newOutflow = 0
    end

    reac_utils.setFluxGateFlowRate(gateIn, math.floor(newInflow))
    reac_utils.setFluxGateFlowRate(gateOut, math.floor(newOutflow * reactorCfg.outputMultiplier))
end

------------------------------------------------------------
-- EXPOSE INTERNAL STATE
------------------------------------------------------------
reac_utils.info = info
reac_utils.reactor = reactor
reac_utils.gateIn = gateIn
reac_utils.gateOut = gateOut
reac_utils.mon = mon
reac_utils.manualStart = manualStart
reac_utils.manualCharge = manualCharge
reac_utils.manualStop = manualStop

return reac_utils
