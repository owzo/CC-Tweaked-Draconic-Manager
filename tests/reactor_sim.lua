--==============================================================
-- APPROXIMATE DRACONIC REACTOR SIMULATOR (tests only)
--==============================================================

--[[
README
-------
A tick-level model of the Draconic Evolution reactor, transcribed from
TileReactorCore. It is APPROXIMATE: the energy core/flux network is
idealised (gates always deliver exactly their set rate). It exists to
check that the controller is stable and fail-safe, not to predict exact
numbers.

Two rule sets (opts.version):
  "1.12"  output multiplier 1, fuel multiplier 1; stopping pins
          saturation at max
  "1.20"  1.16+ defaults: reactorOutputMultiplier 10 plus an extra x10
          (generation and drain ~100x), fuel use x25; the stabilizer
          only outputs while running, and a stopping core only cools
          once saturation reaches 99%

  local sim = Sim.new({fuel = 10368, version = "1.20"})
  sim:tick()                       -- advance one game tick (1/20 s)
  sim.reactor / sim.inGate / sim.outGate are peripheral-like tables.
]]

local Sim = {}
Sim.__index = Sim

local MAX_TEMPERATURE = 10000

function Sim.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Sim)
    local fuel = opts.fuel or 10368          -- 8 blocks of awakened draconium (mB)
    self.reactableFuel = fuel
    self.convertedFuel = opts.converted or 0
    self.conversionUnit = 0
    self.temperature = opts.temperature or 20
    self.maxSaturation = math.floor(fuel * 96.45061728395062 * 1000)
    self.maxField = fuel * 96.45061728395062 * 100
    self.saturation = 0
    self.field = 0
    self.state = opts.state or "cold"
    self.generationRate = 0
    self.fieldDrain = 0
    self.exploded = false
    self.ticks = 0
    self.inFlow = 0
    self.outFlow = 0
    self.maxTempSeen = 0
    self.minFieldWhileHot = 1
    self.extractScale = 1                    -- <1 simulates a full energy core
    self.version = opts.version or "1.12"
    if self.version == "1.20" then
        self.outputMult, self.fuelMult = 100, 25
    else
        self.outputMult, self.fuelMult = 1, 1
    end

    if self.state == "running" then
        self.temperature = opts.temperature or 6000
        self.saturation = self.maxSaturation * (opts.sat or 0.3)
        self.field = self.maxField * (opts.field or 0.5)
    end
    self:buildPeripherals()
    return self
end

function Sim:convLevel()
    local total = self.reactableFuel + self.convertedFuel
    return ((self.convertedFuel + self.conversionUnit) / total) * 1.3 - 0.3
end

function Sim:injectEnergy(energy)
    if self.state == "warming_up" then
        if self.field < self.maxField / 2 then
            self.field = self.field + math.min(energy, self.maxField / 2 - self.field + 1)
        elseif self.saturation < self.maxSaturation / 2 then
            self.saturation = self.saturation
                + math.min(energy, self.maxSaturation / 2 - self.saturation + 1)
        elseif self.temperature < 2000 then
            self.temperature = self.temperature + energy / (1000 + self.reactableFuel * 10)
            if self.temperature > 2000 then self.temperature = 2000 end
        end
    elseif self.state == "running" or self.state == "stopping" then
        local add = energy * (1 - self.field / self.maxField)
        self.field = math.min(self.maxField, self.field + add)
    end
end

function Sim:tick()
    self.ticks = self.ticks + 1
    if self.exploded then return end

    -- Energy transfer through the gates.
    self:injectEnergy(self.inFlow)
    local extracting = self.state == "running"
        or (self.state == "stopping" and self.version == "1.12")
    if extracting then
        local taken = math.min(self.saturation, self.outFlow * self.extractScale)
        self.saturation = self.saturation - taken
    end

    if self.state == "running" or self.state == "stopping" then
        local satRatio = self.saturation / self.maxSaturation
        local negCSat = (1 - satRatio) * 99
        local temp50 = math.min((self.temperature / MAX_TEMPERATURE) * 50, 99)
        local conv = self:convLevel()

        local tempRiseExpo = (negCSat ^ 3) / (100 - negCSat) + 444.7
        local tempRiseResist = (temp50 ^ 4) / (100 - temp50)
        local riseAmount = (tempRiseExpo - tempRiseResist * (1 - conv) + conv * 1000) / 10000

        if self.state == "stopping" and conv < 1 and self.temperature <= 2001 then
            self.state = "cooling"
        elseif self.state == "stopping" and conv < 1 and self.version == "1.12" then
            self.saturation = self.maxSaturation
            self.temperature = self.temperature - (1 - conv)
        elseif self.state == "stopping" and conv < 1 and satRatio >= 0.99 then
            self.temperature = self.temperature - (1 - conv)
        else
            self.temperature = self.temperature + riseAmount * 10
        end

        local baseMaxRFt = (self.maxSaturation / 1000) * 1.5 * self.outputMult
        local maxRFt = baseMaxRFt * (1 + conv * 2)
        self.generationRate = (1 - satRatio) * maxRFt
        self.saturation = math.min(self.maxSaturation, self.saturation + self.generationRate)

        local t = self.temperature
        local drainFactor
        if t > 8000 then
            drainFactor = 1 + ((t - 8000) ^ 2) * 0.0000025
        elseif t > 2000 then
            drainFactor = 1
        elseif t > 1000 then
            drainFactor = (t - 1000) / 1000
        else
            drainFactor = 0
        end
        self.fieldDrain = drainFactor * math.max(0.01, 1 - satRatio) * (baseMaxRFt / 10.923556)
        self.field = self.field - math.min(self.fieldDrain, self.field)

        local fuelUse = drainFactor * (1 - satRatio) * 0.001 * self.fuelMult
        self.conversionUnit = self.conversionUnit + fuelUse
        if self.conversionUnit >= 1 then
            self.conversionUnit = self.conversionUnit - 1
            self.reactableFuel = self.reactableFuel - 1
            self.convertedFuel = self.convertedFuel + 1
        end

        -- The only explosion trigger in the source: field gone while hot.
        if self.field <= 0 and self.temperature > 2000 then
            self.exploded = true
            self.state = "beyond_hope"
        end
        self.maxTempSeen = math.max(self.maxTempSeen, self.temperature)
        self.minFieldWhileHot = math.min(self.minFieldWhileHot, self.field / self.maxField)
    elseif self.state == "cooling" then
        self.generationRate, self.fieldDrain = 0, 0
        self.temperature = self.temperature - 2
        if self.temperature <= 100 then
            self.temperature = 20
            self.state = "cold"
            self.field, self.saturation = 0, 0
        end
    else
        self.generationRate, self.fieldDrain = 0, 0
    end
end

function Sim:buildPeripherals()
    local sim = self
    self.reactor = {
        getReactorInfo = function()
            return {
                temperature = sim.temperature,
                fieldStrength = sim.field,
                maxFieldStrength = sim.maxField,
                energySaturation = sim.saturation,
                maxEnergySaturation = sim.maxSaturation,
                fuelConversion = sim.convertedFuel + sim.conversionUnit,
                maxFuelConversion = sim.reactableFuel + sim.convertedFuel,
                generationRate = sim.generationRate,
                fieldDrainRate = sim.fieldDrain,
                fuelConversionRate = 0,
                status = sim.state,
                failSafe = false
            }
        end,
        chargeReactor = function()
            if sim.state == "cold" or sim.state == "cooling" then
                sim.state = "warming_up"
            end
        end,
        activateReactor = function()
            if sim.state == "warming_up" and sim.temperature >= 2000
                    and sim.field >= sim.maxField / 2
                    and sim.saturation >= sim.maxSaturation / 2 then
                sim.state = "running"
            end
        end,
        stopReactor = function()
            if sim.state == "running" or sim.state == "warming_up" then
                sim.state = "stopping"
            end
        end
    }
    local function gate(field)
        -- Like the real gate, the override only applies once enabled.
        local g = {override = false, value = 0}
        g.getFlow = function() return sim[field] end
        g.setOverrideEnabled = function(v)
            g.override = v
            sim[field] = v and g.value or 0
        end
        g.getOverrideEnabled = function() return g.override end
        g.setFlowOverride = function(v)
            assert(type(v) == "number" and v >= 0, "bad flow " .. tostring(v))
            g.value = v
            sim[field] = g.override and v or 0
        end
        g.setSignalLowFlow = function() end
        g.setSignalHighFlow = function() end
        return g
    end
    self.inGate = gate("inFlow")
    self.outGate = gate("outFlow")
end

return Sim
