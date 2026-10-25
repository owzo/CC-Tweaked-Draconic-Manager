--==============================================================
-- APPROXIMATE MEKANISM SIMULATOR (tests only)
--==============================================================

--[[
README
-------
Qualitative Mekanism fission/turbine/fusion plant behind the mod's CC
API (method names and quirks from Mekanism 10.4 source):

Fission
  temperature relaxes toward 300 + burn * heatPerBurn (K) while coolant
  lasts; with no coolant it heads to 300 + burn * 500 (runaway). Coolant
  is consumed in proportion to burn and refilled at coolantSupply;
  heated coolant fills likewise and is drained at heatedDrain.
  Damage accrues above 1200 K at min(T,1800)/12000 points per tick (the
  mod's formula); 100% = meltdown (`sim.meltdown`).
  scram() raises when inactive; activate() raises when active; the
  FilledPercentage getters return 0-1; damage is rounded 0-100.
Turbine: generation follows heated-coolant draw. Energy in Joules.
Fusion: production proportional to injection rate (no explosions).
]]

local Sim = {}
Sim.__index = Sim

function Sim.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Sim)
    self.active = opts.active or false
    self.burn = opts.burn or 0
    self.maxBurn = opts.maxBurn or 50
    self.temperature = opts.temperature or 300
    self.heatPerBurn = opts.heatPerBurn or 30
    self.coolant, self.heated = 1, 0
    self.coolantSupply = opts.coolantSupply or 0.05
    self.heatedDrain = opts.heatedDrain or 0.05
    self.fuel, self.waste = opts.fuel or 0.8, 0
    self.damage = 0
    self.meltdown = false
    self.maxTemperatureSeen = self.temperature
    self.injection = opts.injection or 10
    self.pos = opts.pos or {x = 10, y = 64, z = 20}
    self:buildFacades()
    return self
end

function Sim:tick()
    local burn = self.active and self.burn or 0
    local use = burn * 0.002
    local cooled = self.coolant > 0
    local target = 300 + burn * (cooled and self.heatPerBurn or 500)
    self.temperature = self.temperature + (target - self.temperature) / 100
    self.coolant = math.max(0, math.min(1, self.coolant - use + self.coolantSupply))
    if cooled then self.heated = math.min(1, self.heated + use) end
    self.heatedDrain = self.heatedDrain or 0
    self.drawn = math.min(self.heated, self.heatedDrain)
    self.heated = self.heated - self.drawn
    self.fuel = math.max(0, self.fuel - burn * 1e-6)
    self.waste = math.min(1, self.waste + burn * 1e-6)
    if self.temperature > 1200 then
        self.damage = self.damage + math.min(self.temperature, 1800) / 12000
        if self.damage >= 100 then self.meltdown = true end
    elseif self.damage > 0 then
        self.damage = math.max(0, self.damage - (1200 - self.temperature) / 120000)
    end
    self.maxTemperatureSeen = math.max(self.maxTemperatureSeen, self.temperature)
end

function Sim:buildFacades()
    local sim = self
    self.fission = {
        isFormed = function() return true end,
        getMinPos = function() return {x = sim.pos.x, y = sim.pos.y, z = sim.pos.z} end,
        getStatus = function() return sim.active end,
        isForceDisabled = function() return false end,
        activate = function()
            if sim.active then error("Reactor is already active.") end
            sim.active = true
        end,
        scram = function()
            if not sim.active then error("Scram requires the reactor to be active.") end
            sim.active = false
            sim.scrams = (sim.scrams or 0) + 1
        end,
        getTemperature = function() return sim.temperature end,
        getDamagePercent = function() return math.floor(sim.damage + 0.5) end,
        getBurnRate = function() return sim.burn end,
        getActualBurnRate = function() return sim.active and sim.burn or 0 end,
        getMaxBurnRate = function() return sim.maxBurn end,
        setBurnRate = function(r)
            assert(type(r) == "number", "bad burn rate")
            if r < 0 or r > sim.maxBurn then error("Burn rate out of range") end
            sim.burn = math.floor(r * 100 + 0.5) / 100
        end,
        getCoolantFilledPercentage = function() return sim.coolant end,
        getHeatedCoolantFilledPercentage = function() return sim.heated end,
        getFuelFilledPercentage = function() return sim.fuel end,
        getWasteFilledPercentage = function() return sim.waste end,
        getHeatingRate = function() return sim.active and sim.burn * 100 or 0 end
    }
    self.turbine = {
        isFormed = function() return true end,
        getMinPos = function() return {x = sim.pos.x + 20, y = sim.pos.y, z = sim.pos.z} end,
        getEnergy = function() return 1e9 end,
        getMaxEnergy = function() return 4e9 end,
        getProductionRate = function() return (sim.drawn or 0) * 1e6 end,      -- Joules/t
        getMaxProduction = function() return 1e6 end,
        getFlowRate = function() return (sim.drawn or 0) * 1e4 end,
        getMaxFlowRate = function() return 1e4 end,
        getSteamFilledPercentage = function() return sim.heated end,
        getDumpingMode = function() return "IDLE" end,
        setDumpingMode = function() end
    }
    self.fusion = {
        isFormed = function() return true end,
        getMinPos = function() return {x = sim.pos.x - 20, y = sim.pos.y, z = sim.pos.z} end,
        getPlasmaTemperature = function() return 5e8 end,
        getCaseTemperature = function() return 1e8 end,
        getInjectionRate = function() return sim.injection end,
        setInjectionRate = function(r)
            if r % 2 ~= 0 or r < 0 or r > 98 then error("Injection rate must be even, 0-98") end
            sim.injection = r
        end,
        getProductionRate = function() return sim.injection * 2.5e5 end,  -- Joules/t
        getDTFuelFilledPercentage = function() return 0.6 end,
        getDeuteriumFilledPercentage = function() return 0.6 end,
        getTritiumFilledPercentage = function() return 0.6 end,
        getWaterFilledPercentage = function() return 0.9 end,
        getSteamFilledPercentage = function() return 0.1 end
    }
end

return Sim
