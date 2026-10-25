--==============================================================
-- APPROXIMATE EXTREME / BIGGER REACTORS SIMULATOR (tests only)
--==============================================================

--[[
README
-------
A deliberately simple plant, qualitatively matched to the mods' source
(ER ReactorLogic/TurbineLogic, BR ModernTurbineSimulation):

Reactor
  heat output follows rod insertion with a first-order lag
  (fuel temperature responds slowly), output = maxOutput * (1 - rods%).
  Passive: output fills an FE battery; a full battery throws energy away
  (as both mods do). Active: output boils water into the hot tank,
  limited by free tank space.
Turbine (ER formulas)
  RPM = rotorEnergy / (blades * rotorMass)
  lift = steam * 10 * bladeEfficiency, blade capacity 25 mB/t per blade
  drag = RPM * 0.00025 * blades + rotorMass * 0.01
  coil torque = RPM * coilDrag when engaged; energy = torque * eta(RPM)
  eta = 0.25 * cos(RPM / (45.5 * pi)) + 0.75, peaks near 898 / 1796

Exposed through two facades matching each mod's CC API:
  sim.erReactor / sim.erTurbines[i]   (Extreme Reactors, Celsius)
  sim.brReactor / sim.brTurbines[i]   (Bigger Reactors, Kelvin, objects)
It is for checking that controllers converge and behave, not for
predicting real output numbers.
]]

local Sim = {}
Sim.__index = Sim

local KELVIN = 273.15

function Sim.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Sim)
    self.active = opts.active or false
    self.activelyCooled = opts.activelyCooled or false
    self.maxOutput = opts.maxOutput or 20000         -- FE/t or mB/t of steam
    self.rods = opts.rods or 100
    self.heat = 0                                     -- 0..1 of maxOutput, lagged
    self.lag = opts.lag or 0.02                       -- per tick
    self.capacity = opts.capacity or 10000000
    self.stored = opts.stored or 0
    self.steamMax = opts.steamMax or 50000
    self.steam = opts.steam or 0
    self.fuel, self.fuelMax, self.waste = opts.fuel or 50000, 64000, 0
    self.load = opts.load or 0                        -- FE/t drawn from reactor battery
    self.produced, self.steamMade = 0, 0
    self.assembled = opts.assembled ~= false
    self.turbines = {}
    for i = 1, (opts.turbines or 0) do
        table.insert(self.turbines, {
            active = opts.turbinesActive or false, energy = 0, blades = 40, mass = 500,
            flowSet = 1000, flowLimit = 2000, flow = 0, coils = opts.coilsEngaged or false,
            stored = 0, capacity = 1000000, produced = 0, load = opts.turbineLoad or 0,
            coilDrag = 2.4, maxRPMSeen = 0
        })
    end
    self:buildFacades()
    return self
end

function Sim:tick()
    -- Reactor heat follows rods with a lag.
    local target = self.active and (1 - self.rods / 100) or 0
    self.heat = self.heat + (target - self.heat) * self.lag
    local out = self.heat * self.maxOutput
    if self.active and self.fuel > 0 then
        self.fuel = self.fuel - out * 1e-5
        self.waste = self.waste + out * 1e-5
    end
    if self.activelyCooled then
        local made = math.min(out, self.steamMax - self.steam)
        self.steam = self.steam + made
        self.steamMade, self.produced = made, 0
    else
        self.stored = math.min(self.capacity, self.stored + out)
        self.produced, self.steamMade = out, 0
        self.stored = math.max(0, self.stored - self.load)
    end

    for _, t in ipairs(self.turbines) do
        local rpm = t.energy / (t.blades * t.mass)
        local steamIn = 0
        if t.active then
            steamIn = math.min(t.flowSet, self.steam, t.flowLimit)
            self.steam = self.steam - steamIn
        end
        local cap = t.blades * 25
        local eff = steamIn <= cap and 1 or (1 - (steamIn - cap) / steamIn)
        local lift = steamIn * 10 * eff
        local drag = rpm * 0.00025 * t.blades + t.mass * 0.01
        local torque = t.coils and rpm * t.coilDrag or 0
        local eta = 0.25 * math.cos(rpm / (45.5 * math.pi)) + 0.75
        if rpm < 500 then eta = math.min(eta, 0.5) end
        local energy = torque * eta
        t.energy = math.max(0, t.energy + lift - drag - torque)
        t.flow = steamIn
        local room = t.capacity - t.stored
        t.produced = math.min(energy, room + t.load)
        t.stored = math.max(0, math.min(t.capacity, t.stored + energy) - t.load)
        t.rpm = t.energy / (t.blades * t.mass)
        t.maxRPMSeen = math.max(t.maxRPMSeen, t.rpm)
    end
end

function Sim:fuelTemp() return 20 + self.heat * 1800 end
function Sim:caseTemp() return 20 + self.heat * 1200 end

function Sim:buildFacades()
    local sim = self
    local function rodsTable()
        local t = {}
        for i = 0, 3 do t[i] = sim.rods end
        return t
    end

    -- Extreme Reactors -------------------------------------------------
    self.erReactor = {
        mbIsAssembled = function() return sim.assembled end,
        mbIsConnected = function() return true end,
        getActive = function() return sim.active end,
        setActive = function(v) sim.active = v end,
        isActivelyCooled = function() return sim.activelyCooled end,
        getEnergyStats = function()
            return {energyStored = sim.stored, energyCapacity = sim.capacity,
                    energyProducedLastTick = sim.produced, energySystem = "FE"}
        end,
        getFuelStats = function()
            return {fuelAmount = sim.fuel, fuelCapacity = sim.fuelMax, fuelTemperature = sim:fuelTemp(),
                    fuelConsumedLastTick = 0.1, fuelReactivity = 100, wasteAmount = sim.waste}
        end,
        getFuelTemperature = function() return sim:fuelTemp() end,
        getCasingTemperature = function() return sim:caseTemp() end,
        getHotFluidStats = function()
            return {fluidType = "steam", fluidAmount = sim.steam, fluidCapacity = sim.steamMax,
                    fluidProducedLastTick = sim.steamMade}
        end,
        getNumberOfControlRods = function() return 4 end,
        getControlRodsLevels = rodsTable,
        -- ER rounds to int and ignores out-of-range values silently.
        setAllControlRodLevels = function(v)
            v = math.floor(v + 0.5)
            if v >= 0 and v <= 100 then sim.rods = v end
        end
    }

    -- Bigger Reactors ---------------------------------------------------
    self.brReactor = {
        apiVersion = function() return "0.0.1" end,
        connected = function() return sim.assembled end,
        active = function() return sim.active end,
        setActive = function(v) sim.active = v end,
        battery = function()
            if sim.activelyCooled then return nil end
            return {stored = function() return sim.stored end,
                    capacity = function() return sim.capacity end,
                    producedLastTick = function() return sim.produced end}
        end,
        coolantTank = function()
            if not sim.activelyCooled then return nil end
            return {hotFluidAmount = function() return sim.steam end,
                    coldFluidAmount = function() return 50000 end,
                    capacity = function() return sim.steamMax end,
                    transitionedLastTick = function() return sim.steamMade end}
        end,
        fuelTank = function()
            return {capacity = function() return sim.fuelMax end, fuel = function() return sim.fuel end,
                    waste = function() return sim.waste end, fuelReactivity = function() return 1.05 end,
                    burnedLastTick = function() return 0.1 end, totalReactant = function() return sim.fuel end}
        end,
        fuelTemperature = function() return sim:fuelTemp() + KELVIN end,
        stackTemperature = function() return sim:caseTemp() + KELVIN end,
        controlRodCount = function() return 4 end,
        getControlRod = function(i)
            assert(i >= 0 and i < 4, "rod index out of range")
            return {level = function() return sim.rods end,
                    setLevel = function(v) sim.rods = math.max(0, math.min(100, v)) end}
        end,
        setAllControlRodLevels = function(v) sim.rods = math.max(0, math.min(100, v)) end
    }

    self.erTurbines, self.brTurbines = {}, {}
    for _, t in ipairs(self.turbines) do
        t.rpm = 0
        table.insert(self.erTurbines, {
            mbIsAssembled = function() return true end,
            getActive = function() return t.active end,
            setActive = function(v) t.active = v end,
            getRotorSpeed = function() return t.rpm end,
            getEnergyStats = function()
                return {energyStored = t.stored, energyCapacity = t.capacity,
                        energyProducedLastTick = t.produced, energySystem = "FE"}
            end,
            getFluidFlowRate = function() return t.flow end,
            getFluidFlowRateMax = function() return t.flowSet end,
            getFluidFlowRateMaxMax = function() return t.flowLimit end,
            setFluidFlowRateMax = function(v) t.flowSet = math.max(0, math.min(t.flowLimit, math.floor(v))) end,
            getInductorEngaged = function() return t.coils end,
            setInductorEngaged = function(v) t.coils = v end,
            getInputAmount = function() return sim.steam end,
            getFluidAmountMax = function() return sim.steamMax end,
            getNumberOfBlades = function() return t.blades end
        })
        table.insert(self.brTurbines, {
            connected = function() return true end,
            active = function() return t.active end,
            setActive = function(v) t.active = v end,
            rotor = function() return {RPM = function() return t.rpm end,
                                       efficiencyLastTick = function() return 1 end} end,
            battery = function()
                return {stored = function() return t.stored end, capacity = function() return t.capacity end,
                        producedLastTick = function() return t.produced end}
            end,
            fluidTank = function()
                return {flowLastTick = function() return t.flow end,
                        nominalFlowRate = function() return t.flowSet end,
                        flowRateLimit = function() return t.flowLimit end,
                        setNominalFlowRate = function(v) t.flowSet = math.max(0, math.min(t.flowLimit, v)) end,
                        input = function() return {amount = function() return sim.steam end,
                                                   maxAmount = function() return sim.steamMax end,
                                                   name = function() return "steam" end} end}
            end,
            coilEngaged = function() return t.coils end,
            setCoilEngaged = function(v) t.coils = v end
        })
    end
end

return Sim
