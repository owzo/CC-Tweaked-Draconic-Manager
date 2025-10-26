-- Reactor Utilities
-- Save as: reac_utils.lua

--[[
README

Functions to handle Draconic Reactor control and monitoring.
Includes setup, error handling, and reactor status checks.
]]

local config = require("config").reactor

local reac_utils = {}

-- Peripherals
local reactor
local gateIn
local gateOut
local mon

-- Info
local info
local currentEmergency = false
local currentField
local currentFuel
local stableTicks = 0
local screenPage = 0
local openConfirmDialog = false
local manualStart = false
local manualCharge = false
local manualStop = false

-- Function to log errors
function logError(err)
    local logFile = fs.open("error_log.txt", "a")
    logFile.writeLine(os.date() .. ": " .. err)
    logFile.close()
end

-- Function to validate peripherals (Newly Added)
local function validatePeripherals()
    reactor = peripheral.find("draconic_reactor")
    gateIn = peripheral.find("flux_gate", function(name) return peripheral.getType(name) == "flux_gate" end)
    gateOut = peripheral.find("flux_gate", function(name) return peripheral.getType(name) == "flux_gate" end)
    mon = peripheral.find("monitor")

    if not reactor then error("Reactor not found!") end
    if not gateIn then error("Input flux gate not found!") end
    if not gateOut then error("Output flux gate not found!") end
    if not mon then error("Monitor not found!") end
end

-- Function to setup peripherals
function reac_utils.setupPeripherals()
    validatePeripherals() -- Updated to include validation
    gateIn.setOverrideEnabled(true)
    gateIn.setFlowOverride(0)
    gateOut.setOverrideEnabled(true)
    gateOut.setFlowOverride(0)
    print("Peripherals setup complete!")
end

-- Function to get reactor status
function reac_utils.getReactorStatus()
    local success, status = pcall(function()
        return reactor.getReactorInfo().status
    end)
    if not success then
        logError("Failed to get reactor status: " .. status)
        return "Error"
    end
    return status
end

-- Function to get reactor temperature
function reac_utils.getTemperature()
    local success, temp = pcall(function()
        return reactor.getReactorInfo().temperature
    end)
    if not success then
        logError("Failed to get reactor temperature: " .. temp)
        return "Error"
    end
    return temp
end

-- Function to get reactor field strength
function reac_utils.getFieldStrength()
    local success, fieldStrength = pcall(function()
        return reactor.getReactorInfo().fieldStrength
    end)
    if not success then
        logError("Failed to get reactor field strength: " .. fieldStrength)
        return "Error"
    end
    return fieldStrength
end

-- Function to get reactor energy saturation
function reac_utils.getEnergySaturation()
    local success, energySaturation = pcall(function()
        return reactor.getReactorInfo().energySaturation
    end)
    if not success then
        logError("Failed to get reactor energy saturation: " .. energySaturation)
        return "Error"
    end
    return energySaturation
end

-- Function to set flux gate flow rate
function reac_utils.setFluxGateFlowRate(channel, flowRate)
    local success, result = pcall(function()
        channel.setSignalLowFlow(flowRate)
    end)
    if not success then
        logError("Failed to set flux gate flow rate: " .. result)
    end
end

-- Function to perform fail-safe shutdown
function reac_utils.failSafeShutdown()
    pcall(function()
        reactor.stopReactor()
        setFluxGateFlowRate(gateIn, config.shutDownField * 1.2)
        setFluxGateFlowRate(gateOut, 0)
    end)
end

-- Setup function
function reac_utils.setup()
    term.clear()
    print("Starting program...")
    setupPeripherals()
    print("Started!")
end

-- Function to check reactor status
function reac_utils.checkReactorStatus()
    local success, reactorInfo = pcall(function()
        return reactor.getReactorInfo()
    end)
    if not success then
        logError("Failed to get reactor info: " .. reactorInfo)
        return
    end

    info = reactorInfo
    currentField = info.fieldStrength / info.maxFieldStrength
    currentFuel = 1.0 - (info.fuelConversion / info.maxFuelConversion)
end

-- Function to determine if reactor is in emergency state
function reac_utils.isEmergency()
    currentEmergency = config.safeMode and info.temperature >= 2000.0 and 
        (info.status == "running" or info.status == "online" or info.status == "stopping") and 
        (info.temperature > config.defaultTemp + config.maxOvershoot or currentField < 0.004 or currentFuel < config.minFuel)
    return currentEmergency
end

-- Function to adjust reactor temperature and field
function reac_utils.adjustReactorTempAndField()
    local temp = getTemperature()
    local tempInc = math.sqrt(config.defaultTemp - temp) / 2.0
    local newOutflow = math.min(config.maxOutflow, info.maxEnergySaturation * tempInc / 100)

    if currentField > config.defaultField * 1.05 then
        setFluxGateFlowRate(gateIn, 0)
    elseif currentField > config.defaultField * 0.95 then
        setFluxGateFlowRate(gateIn, calcInflow(config.defaultField, info.fieldDrainRate))
    else
        setFluxGateFlowRate(gateIn, calcInflow(config.defaultField * 1.5, info.fieldDrainRate))
    end

    setFluxGateFlowRate(gateOut, math.floor(newOutflow * config.outputMultiplier))
end

-- Function to handle reactor stopping
function reac_utils.handleReactorStopping()
    if currentField > config.shutDownField then
        setFluxGateFlowRate(gateIn, calcInflow(config.shutDownField, info.fieldDrainRate))
    else
        setFluxGateFlowRate(gateIn, calcInflow(config.shutDownField * 1.2, info.fieldDrainRate))
    end
    setFluxGateFlowRate(gateOut, 0.0)

    if manualStart then
        manualStart = false
        reactor.activateReactor()
    end
end

-- Function to update flux gates
function reac_utils.updateFluxGates()
    local newInflow = 0.0
    local newOutflow = 0.0

    if reactor.status == "running" then
        local temp = getTemperature()
        if temp < config.defaultTemp then
            local tempInc = math.sqrt(config.defaultTemp - temp) / 2.0
            newOutflow = math.min(config.maxOutflow, info.maxEnergySaturation * tempInc / 100)
        else
            newOutflow = 0.0
        end

        if currentField > config.defaultField * 1.05 then
            newInflow = 0.0
        elseif currentField > config.defaultField * 0.95 then
            newInflow = calcInflow(config.defaultField, info.fieldDrainRate)
        else
            newInflow = calcInflow(config.defaultField * 1.5, info.fieldDrainRate)
        end
    elseif reactor.status == "stopping" then
        newInflow = calcInflow(config.shutDownField, info.fieldDrainRate)
        newOutflow = 0.0
    end

    setFluxGateFlowRate(gateIn, math.floor(newInflow))
    setFluxGateFlowRate(gateOut, math.floor(newOutflow * config.outputMultiplier))
end

return reac_utils
