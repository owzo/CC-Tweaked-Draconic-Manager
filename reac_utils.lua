-- Reactor Utilities
-- Save as: lib/reac_utils.lua

--[[
README

Functions to handle Draconic Reactor control and monitoring.
Includes setup, error handling, and reactor status checks.
]]

local config = require("config").reactor

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

-- Peripheral identification function
function periphSearch(type)
    local names = peripheral.getNames()
    for _, name in pairs(names) do
        if peripheral.getType(name) == type then
            return peripheral.wrap(name)
        end
    end
    return nil
end

-- Function to setup peripherals
function setupPeripherals()
    local peripherals = peripheral.getNames()
    
    for _, name in ipairs(peripherals) do
        local type = peripheral.getType(name)
        
        if type == "monitor" and mon == nil then
            mon = peripheral.wrap(name)
            monX, monY = mon.getSize()
            mon = { monitor = mon, X = monX, Y = monY }
        elseif type == "draconic_reactor" and reactor == nil then
            reactor = peripheral.wrap(name)
        elseif type == "flux_gate" then
            if gateIn == nil then
                gateIn = peripheral.wrap(name)
            elseif gateOut == nil then
                gateOut = peripheral.wrap(name)
            end
        end
    end

    if reactor == nil then
        error("No valid reactor was found!")
    end
    if gateIn == nil then
        error("No valid input flux gate was found!")
    end
    if gateOut == nil then
        error("No valid output flux gate was found!")
    end

    gateIn.setOverrideEnabled(true)
    gateIn.setFlowOverride(0)
    gateOut.setOverrideEnabled(true)
    gateOut.setFlowOverride(0)

    print("Peripherals setup complete!")
end

-- Function to get reactor status
function getReactorStatus()
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
function getTemperature()
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
function getFieldStrength()
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
function getEnergySaturation()
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
function setFluxGateFlowRate(channel, flowRate)
    local success, result = pcall(function()
        channel.setSignalLowFlow(flowRate)
    end)
    if not success then
        logError("Failed to set flux gate flow rate: " .. result)
    end
end

-- Function to perform fail-safe shutdown
function failSafeShutdown()
    pcall(function()
        reactor.stopReactor()
        setFluxGateFlowRate(gateIn, config.shutDownField * 1.2)
        setFluxGateFlowRate(gateOut, 0)
    end)
end

-- Setup function
function setup()
    term.clear()
    print("Starting program...")
    setupPeripherals()
    print("Started!")
end

-- Function to check reactor status
function checkReactorStatus()
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
function isEmergency()
    currentEmergency = config.safeMode and info.temperature >= 2000.0 and 
        (info.status == "running" or info.status == "online" or info.status == "stopping") and 
        (info.temperature > config.defaultTemp + config.maxOvershoot or currentField < 0.004 or currentFuel < config.minFuel)
    return currentEmergency
end

-- Function to adjust reactor temperature and field
function adjustReactorTempAndField()
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
function handleReactorStopping()
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
function updateFluxGates()
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
