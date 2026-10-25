--==============================================================
-- MEKANISM UTILITIES
-- Save as: mek_utils.lua
--==============================================================

--[[
README
-------
Adapters and control for Mekanism 10.4 (MC 1.20.1) multiblocks, from the
mod's source:

  fissionReactorPort / fissionReactorLogicAdapter   fission reactor
  turbineValve                                      industrial turbine
  boilerValve                                       thermoelectric boiler
  fusionReactorPort / fusionReactorLogicAdapter     fusion reactor

Facts that shape this module
  - Every Mekanism computer call runs on the server thread and costs a
    tick, so reads run all getters in parallel (one tick in total).
  - Reactor methods exist only while the multiblock is formed; unformed
    peripherals expose isFormed() and little else.
  - Energy is reported in Joules (1 FE = 2.5 J by default, server
    configurable): converted with mekanismEnergyHelper when present.
  - Temperatures are Kelvin. "FilledPercentage" values are 0-1
    fractions; getDamagePercent() is 0-100, rounded.
  - scram() raises if the reactor is already off; activate() raises if
    it is already on or still damaged.

FISSION SAFETY: damage accrues above 1200 K (about 2-3 %/s), and at 100%
damage a meltdown (explosion) is likely within about a minute; meltdowns
are enabled by default. The controller therefore SCRAMs early and never
restarts on its own.
]]

local mek_utils = {}

local TYPES = {
    fissionReactorPort = "fission", fissionReactorLogicAdapter = "fission",
    turbineValve = "turbine", boilerValve = "boiler",
    fusionReactorPort = "fusion", fusionReactorLogicAdapter = "fusion"
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function mek_utils.classify(name)
    return TYPES[tostring(peripheral.getType(name))]
end

-- Joules -> FE, honouring the server's conversion rate when exposed.
function mek_utils.toFE(joules)
    joules = tonumber(joules) or 0
    if type(mekanismEnergyHelper) == "table" and mekanismEnergyHelper.joulesToFE then
        local ok, fe = pcall(mekanismEnergyHelper.joulesToFE, joules)
        if ok and type(fe) == "number" then return fe end
    end
    return joules / 2.5
end

-- Several ports/valves of one multiblock are separate peripherals; the
-- multiblock's corner position identifies it.
function mek_utils.multiblockKey(name, dev)
    if type(dev.getMinPos) == "function" then
        local ok, pos = pcall(dev.getMinPos)
        if ok and type(pos) == "table" and pos.x then
            return string.format("%d,%d,%d", pos.x, pos.y, pos.z)
        end
    end
    return name
end

-- Calls every getter in `spec` (field -> method name) at once: each call
-- waits for a server tick, so this costs one tick instead of #spec.
local function readAll(dev, spec)
    local out, errors = {}, {}
    local fns = {}
    for field, method in pairs(spec) do
        table.insert(fns, function()
            local fn = dev[method]
            if type(fn) ~= "function" then return end
            local ok, v = pcall(fn)
            if ok then out[field] = v else errors[field] = v end
        end)
    end
    if parallel and coroutine.running() then
        parallel.waitForAll((table.unpack or unpack)(fns))
    else
        for _, fn in ipairs(fns) do fn() end
    end
    return out, errors
end

local function formed(dev)
    if type(dev.isFormed) ~= "function" then return true end
    local ok, v = pcall(dev.isFormed)
    return ok and v == true
end

------------------------------------------------------------
-- ADAPTERS
------------------------------------------------------------
local FISSION_READS = {
    active = "getStatus", temperature = "getTemperature", damage = "getDamagePercent",
    burnRate = "getBurnRate", actualBurnRate = "getActualBurnRate", maxBurnRate = "getMaxBurnRate",
    coolant = "getCoolantFilledPercentage", heated = "getHeatedCoolantFilledPercentage",
    fuel = "getFuelFilledPercentage", waste = "getWasteFilledPercentage",
    heatingRate = "getHeatingRate", forceDisabled = "isForceDisabled"
}

local function fission(name, dev)
    local a = {name = name, dev = dev, kind = "fission"}
    function a.read()
        if not formed(dev) then return {formed = false} end
        local d = readAll(dev, FISSION_READS)
        d.formed = true
        return d
    end
    function a.scram() return pcall(dev.scram) end
    function a.activate() return pcall(dev.activate) end
    function a.setBurnRate(rate) return pcall(dev.setBurnRate, rate) end
    return a
end

local TURBINE_READS = {
    energy = "getEnergy", maxEnergy = "getMaxEnergy", production = "getProductionRate",
    maxProduction = "getMaxProduction", flow = "getFlowRate", maxFlow = "getMaxFlowRate",
    steam = "getSteamFilledPercentage", dumping = "getDumpingMode"
}

local function turbine(name, dev)
    local a = {name = name, dev = dev, kind = "turbine"}
    function a.read()
        if not formed(dev) then return {formed = false} end
        local d = readAll(dev, TURBINE_READS)
        d.formed = true
        d.energy, d.maxEnergy = mek_utils.toFE(d.energy), mek_utils.toFE(d.maxEnergy)
        d.production, d.maxProduction = mek_utils.toFE(d.production), mek_utils.toFE(d.maxProduction)
        return d
    end
    function a.setDumping(mode) return pcall(dev.setDumpingMode, mode) end
    return a
end

local BOILER_READS = {
    water = "getWaterFilledPercentage", steam = "getSteamFilledPercentage",
    heated = "getHeatedCoolantFilledPercentage", temperature = "getTemperature",
    boilRate = "getBoilRate", maxBoilRate = "getMaxBoilRate"
}

local function boiler(name, dev)
    local a = {name = name, dev = dev, kind = "boiler"}
    function a.read()
        if not formed(dev) then return {formed = false} end
        local d = readAll(dev, BOILER_READS)
        d.formed = true
        return d
    end
    return a
end

local FUSION_READS = {
    plasma = "getPlasmaTemperature", case = "getCaseTemperature",
    injection = "getInjectionRate", production = "getProductionRate",
    dtFuel = "getDTFuelFilledPercentage", deuterium = "getDeuteriumFilledPercentage",
    tritium = "getTritiumFilledPercentage", water = "getWaterFilledPercentage",
    steam = "getSteamFilledPercentage"
}

local function fusion(name, dev)
    local a = {name = name, dev = dev, kind = "fusion"}
    function a.read()
        if not formed(dev) then return {formed = false} end
        local d = readAll(dev, FUSION_READS)
        d.formed = true
        d.production = mek_utils.toFE(d.production)
        -- 1.20.1 has no isIgnited(): producing power means ignited.
        d.ignited = (d.production or 0) > 0
        return d
    end
    -- Injection rate must be even, 0..98.
    function a.setInjection(rate)
        rate = clamp(math.floor((tonumber(rate) or 0) / 2 + 0.5) * 2, 0, 98)
        return pcall(dev.setInjectionRate, rate)
    end
    return a
end

local BUILDERS = {fission = fission, turbine = turbine, boiler = boiler, fusion = fusion}

function mek_utils.wrap(kind, name, dev)
    return BUILDERS[kind] and BUILDERS[kind](name, dev)
end

function mek_utils.read(adapter)
    local ok, d = pcall(adapter.read)
    if not ok then return nil, tostring(d) end
    return d
end

------------------------------------------------------------
-- FISSION CONTROLLER
------------------------------------------------------------
--[[
Reactor protection (checked every cycle while active; any one SCRAMs):
  temperature >= maxTemperature   (default 1000 K; damage starts at 1200)
  damage      >  maxDamage        (default 0: any damage at all)
  coolant     <  minCoolant       (default 20%)
  heated      >  maxHeatedCoolant (default 95%: turbines not keeping up)
  waste       >  maxWaste         (default 90%)
A trip latches: the reactor stays off until a person presses START.

Burn rate: ramps toward targetBurnRate at most burnRampPerSecond, and is
cut 10% per cycle while temperature is within tempMargin of the limit
or coolant is below twice minCoolant, so most excursions are handled
before the protection has to act.
]]
local COMMAND_COOLDOWN = 5

local Fission = {}
Fission.__index = Fission

function mek_utils.newFissionController(cfg)
    local self = setmetatable({}, Fission)
    self.cfg = cfg
    self.alarms = {}
    self.trip = nil
    self.desired = cfg.autoStartOnBoot and "run" or nil
    self.lastCommand = {}
    return self
end

function Fission:requestStart() self.desired = "run"; self.trip = nil end
function Fission:requestStop() self.desired = "stop" end

function Fission:adjustTarget(delta, max)
    local c = self.cfg
    c.targetBurnRate = clamp((c.targetBurnRate or 0) + delta, 0, max or math.huge)
end

function Fission:ready(name, now)
    local last = self.lastCommand[name]
    if last and now - last < COMMAND_COOLDOWN then return false end
    self.lastCommand[name] = now
    return true
end

function Fission:checkTrips(d)
    local c = self.cfg
    if d.temperature and d.temperature >= c.maxTemperature then
        return string.format("temperature %.0fK >= %.0fK", d.temperature, c.maxTemperature)
    elseif d.damage and d.damage > c.maxDamage then
        return string.format("damage %d%%", d.damage)
    elseif d.coolant and d.coolant < c.minCoolant then
        return string.format("coolant %.0f%% < %.0f%%", d.coolant * 100, c.minCoolant * 100)
    elseif d.heated and d.heated > c.maxHeatedCoolant then
        return string.format("heated coolant %.0f%% full", d.heated * 100)
    elseif d.waste and d.waste > c.maxWaste then
        return string.format("waste %.0f%% full", d.waste * 100)
    end
    return nil
end

-- Returns {scram, activate, burnRate, events}.
function Fission:step(d, now)
    local c = self.cfg
    local out = {events = {}}
    self.alarms = {}
    if not d then
        table.insert(self.alarms, "LINK LOST - CANNOT SCRAM")
        return out
    end
    if not d.formed then
        table.insert(self.alarms, "NOT FORMED")
        return out
    end

    if d.active then
        local reason = self:checkTrips(d)
        if reason then
            out.scram = true
            if not self.trip then
                table.insert(out.events, {level = "CRIT", message = "SCRAM: " .. reason})
            end
            self.trip = {reason = reason}
            self.desired = "stop"
        elseif self.desired == "stop" and self:ready("scram", now) then
            out.scram = true
        end
    end

    if self.trip then
        table.insert(self.alarms, "SCRAM: " .. self.trip.reason)
    end
    if (d.damage or 0) > 0 then
        table.insert(self.alarms, string.format("DAMAGE %d%%", d.damage))
    end
    if d.fuel and d.fuel < (c.lowFuel or 0.05) then
        table.insert(self.alarms, string.format("LOW FUEL %.0f%%", d.fuel * 100))
    end
    if d.forceDisabled then
        table.insert(self.alarms, "FORCE DISABLED BY MEKANISM")
    end

    if not d.active and self.desired == "run" and not self.trip
            and not self:checkTrips(d) and self:ready("activate", now) then
        out.activate = true
        table.insert(out.events, {level = "INFO", message = "Activating reactor"})
    end

    -- Burn rate governor.
    if d.active and not out.scram then
        local max = d.maxBurnRate or c.targetBurnRate or 0
        if c.targetBurnRate == nil then c.targetBurnRate = d.burnRate or 0 end
        local target = clamp(c.targetBurnRate, 0, max)
        local current = d.burnRate or 0
        local hot = d.temperature and d.temperature >= c.maxTemperature - c.tempMargin
        local dry = d.coolant and d.coolant < c.minCoolant * 2
        local dt = (self.lastAt and now > self.lastAt) and (now - self.lastAt) or 0
        local new
        if hot or dry then
            new = math.max(0, current * 0.9)
            table.insert(self.alarms, hot and "HOT - BURN RATE REDUCED" or "LOW COOLANT - BURN RATE REDUCED")
        else
            local step = c.burnRampPerSecond * dt
            new = clamp(target, current - step, current + step)
        end
        new = math.floor(new * 100 + 0.5) / 100
        if math.abs(new - current) >= 0.01 then out.burnRate = new end
    end
    self.lastAt = now
    return out
end

------------------------------------------------------------
-- FUSION CONTROLLER (no explosion risk: injection rate only)
------------------------------------------------------------
local Fusion = {}
Fusion.__index = Fusion

function mek_utils.newFusionController(cfg)
    return setmetatable({cfg = cfg, alarms = {}}, Fusion)
end

function Fusion:step(d)
    local out = {events = {}}
    self.alarms = {}
    if not d then table.insert(self.alarms, "LINK LOST"); return out end
    if not d.formed then table.insert(self.alarms, "NOT FORMED"); return out end
    if d.dtFuel and d.dtFuel < 0.05 and d.deuterium and d.deuterium < 0.05 then
        table.insert(self.alarms, "LOW FUEL")
    end
    if self.cfg.fusionInjection and d.injection ~= self.cfg.fusionInjection then
        out.injection = self.cfg.fusionInjection
    end
    return out
end

------------------------------------------------------------
-- MONITOR-ONLY UNITS (turbine, boiler): alarms
------------------------------------------------------------
local Watch = {}
Watch.__index = Watch

function mek_utils.newWatchController(kind)
    return setmetatable({kind = kind, alarms = {}}, Watch)
end

function Watch:step(d)
    self.alarms = {}
    if not d then table.insert(self.alarms, "LINK LOST"); return {events = {}} end
    if not d.formed then table.insert(self.alarms, "NOT FORMED"); return {events = {}} end
    if self.kind == "turbine" and (d.steam or 0) > 0.95 then
        table.insert(self.alarms, "STEAM BACKING UP")
    elseif self.kind == "boiler" and d.water and d.water < 0.1 then
        table.insert(self.alarms, string.format("WATER LOW %.0f%%", d.water * 100))
    end
    return {events = {}}
end

------------------------------------------------------------
-- APPLY
------------------------------------------------------------
function mek_utils.apply(adapter, out)
    local errors = {}
    if out.scram and adapter.scram then
        local ok, err = adapter.scram()
        -- "requires the reactor to be active" just means it is already off.
        if not ok and not tostring(err):find("active") then
            table.insert(errors, "scram: " .. tostring(err))
        end
    elseif out.activate and adapter.activate then
        local ok, err = adapter.activate()
        if not ok then table.insert(errors, "activate: " .. tostring(err)) end
    end
    if out.burnRate and adapter.setBurnRate and not out.scram then
        local ok, err = adapter.setBurnRate(out.burnRate)
        if not ok then table.insert(errors, "setBurnRate: " .. tostring(err)) end
    end
    if out.injection and adapter.setInjection then
        local ok, err = adapter.setInjection(out.injection)
        if not ok then table.insert(errors, "setInjectionRate: " .. tostring(err)) end
    end
    return errors
end

return mek_utils
