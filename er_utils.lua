--==============================================================
-- EXTREME / BIGGER REACTORS UTILITIES
-- Save as: er_utils.lua
--==============================================================

--[[
README
-------
Hardware adapters and control laws for Extreme Reactors (ZeroCore2) and
Bigger Reactors, reactors and turbines. Facts below come from the mods'
1.20.1 source.

Adapters (one API for both mods)
  er_utils.classify(name, dev)   -> "er_reactor" | "er_turbine" |
                                    "br_reactor" | "br_turbine" | nil
  er_utils.wrap(kind, name, dev) -> adapter with read() and setters

  reactor read(): {assembled, active, activelyCooled,
                   stored, capacity, produced        (FE, passive only)
                   steam, steamMax, steamMade        (mB, active only)
                   fuel, fuelMax, waste, burned, reactivity,
                   fuelTemp, caseTemp (Celsius), rods (avg insertion %)}
  turbine read(): {assembled, active, rpm, stored, capacity, produced,
                   flow (mB/t used), flowSet, flowLimit, coils,
                   steam, steamMax}

  Differences hidden here: ER has flat getters and setters that apply a
  tick later and never raise; BR has object accessors (battery(),
  rotor(), fluidTank()), raises when the multiblock is unassembled and
  reports temperatures in Kelvin. BR turbine coils start ENGAGED.

Controllers (pure; no peripheral calls)
  newBufferController(cfg)  rods for a passive (FE buffer) or active
                            (steam tank) reactor
  newTurbineController(cfg) steam flow + coil engagement for a turbine

Neither mod has meltdowns or overspeed damage: the only failure modes
are wasted fuel (buffer full), wasted steam and lost efficiency, so the
controllers optimise efficiency rather than guard against explosions.
]]

local er_utils = {}

local KELVIN = 273.15

local function hasMethod(dev, name)
    return type(dev) == "table" and type(dev[name]) == "function"
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

------------------------------------------------------------
-- CLASSIFICATION
------------------------------------------------------------
local TYPES = {
    ["BigReactors-Reactor"]    = "er_reactor",
    ["BigReactors-Turbine"]    = "er_turbine",
    ["BiggerReactors_Reactor"] = "br_reactor",
    ["BiggerReactors_Turbine"] = "br_turbine",
    ["bigger-reactor"]         = "br_reactor",   -- Bigger Reactors v1 name
    ["bigger-turbine"]         = "br_turbine"
}

function er_utils.classify(name, dev)
    local kind = TYPES[tostring(peripheral.getType(name))]
    if kind then return kind end
    -- Method fallback for renamed types.
    if hasMethod(dev, "getControlRodsLevels") then return "er_reactor" end
    if hasMethod(dev, "getRotorSpeed") then return "er_turbine" end
    if hasMethod(dev, "fuelTank") and hasMethod(dev, "getControlRod") then return "br_reactor" end
    if hasMethod(dev, "rotor") and hasMethod(dev, "fluidTank") then return "br_turbine" end
    return nil
end

------------------------------------------------------------
-- EXTREME REACTORS ADAPTERS
------------------------------------------------------------
local function erAssembled(dev)
    if hasMethod(dev, "mbIsAssembled") then
        local ok, v = pcall(dev.mbIsAssembled)
        return ok and v == true
    end
    return true
end

local function erReactor(name, dev)
    local a = {name = name, dev = dev, mod = "Extreme Reactors", kind = "reactor"}

    function a.read()
        if not erAssembled(dev) then return {assembled = false} end
        local d = {assembled = true}
        d.active = dev.getActive()
        d.activelyCooled = dev.isActivelyCooled()
        local fs = dev.getFuelStats()
        d.fuel, d.fuelMax = fs.fuelAmount, fs.fuelCapacity
        d.waste, d.burned = fs.wasteAmount, fs.fuelConsumedLastTick
        d.reactivity = fs.fuelReactivity
        d.fuelTemp = fs.fuelTemperature or dev.getFuelTemperature()
        d.caseTemp = dev.getCasingTemperature()
        if d.activelyCooled then
            local hs = dev.getHotFluidStats()
            d.steam, d.steamMax = hs.fluidAmount, hs.fluidCapacity
            d.steamMade = hs.fluidProducedLastTick
        else
            local es = dev.getEnergyStats()
            d.stored, d.capacity = es.energyStored, es.energyCapacity
            d.produced = es.energyProducedLastTick
        end
        local levels = dev.getControlRodsLevels()
        local sum, n = 0, 0
        for _, lvl in pairs(levels or {}) do sum = sum + lvl; n = n + 1 end
        d.rods = n > 0 and sum / n or 0
        d.rodCount = n
        return d
    end

    -- ER setters run on the server thread a tick later and never raise
    -- for bad values, so arguments are validated here.
    function a.setActive(on) dev.setActive(on and true or false) end
    function a.setRods(level) dev.setAllControlRodLevels(math.floor(clamp(level, 0, 100) + 0.5)) end
    -- Moves waste to an access port set to output; a no-op without one.
    function a.ejectWaste() dev.doEjectWaste() end
    return a
end

local function erTurbine(name, dev)
    local a = {name = name, dev = dev, mod = "Extreme Reactors", kind = "turbine"}

    function a.read()
        if not erAssembled(dev) then return {assembled = false} end
        local d = {assembled = true}
        d.active = dev.getActive()
        d.rpm = dev.getRotorSpeed()
        local es = dev.getEnergyStats()
        d.stored, d.capacity, d.produced = es.energyStored, es.energyCapacity, es.energyProducedLastTick
        d.flow = dev.getFluidFlowRate()
        d.flowSet = dev.getFluidFlowRateMax()
        d.flowLimit = dev.getFluidFlowRateMaxMax()
        d.coils = dev.getInductorEngaged()
        d.steam, d.steamMax = dev.getInputAmount(), dev.getFluidAmountMax()
        d.blades = hasMethod(dev, "getNumberOfBlades") and dev.getNumberOfBlades() or nil
        return d
    end

    function a.setActive(on) dev.setActive(on and true or false) end
    function a.setFlow(rate) dev.setFluidFlowRateMax(math.floor(math.max(0, rate) + 0.5)) end
    function a.setCoils(on) dev.setInductorEngaged(on and true or false) end
    return a
end

------------------------------------------------------------
-- BIGGER REACTORS ADAPTERS
------------------------------------------------------------
local function brConnected(dev)
    if hasMethod(dev, "connected") then
        local ok, v = pcall(dev.connected)
        return ok and v == true
    end
    return true
end

local function brReactor(name, dev)
    local a = {name = name, dev = dev, mod = "Bigger Reactors", kind = "reactor"}

    function a.read()
        if not brConnected(dev) then return {assembled = false} end
        local d = {assembled = true}
        d.active = dev.active()
        local bat = dev.battery()
        d.activelyCooled = bat == nil
        local ft = dev.fuelTank()
        d.fuel, d.fuelMax = ft.fuel(), ft.capacity()
        d.waste, d.burned = ft.waste(), ft.burnedLastTick()
        d.reactivity = ft.fuelReactivity()
        d.fuelTemp = dev.fuelTemperature() - KELVIN
        local stack = hasMethod(dev, "stackTemperature") and dev.stackTemperature() or dev.casingTemperature()
        d.caseTemp = stack - KELVIN
        if bat then
            d.stored, d.capacity, d.produced = bat.stored(), bat.capacity(), bat.producedLastTick()
        else
            local ct = dev.coolantTank()
            d.steam, d.steamMax = ct.hotFluidAmount(), ct.capacity()
            d.steamMade = ct.transitionedLastTick()
        end
        local n = dev.controlRodCount()
        local sum = 0
        for i = 0, n - 1 do sum = sum + dev.getControlRod(i).level() end
        d.rods = n > 0 and sum / n or 0
        d.rodCount = n
        return d
    end

    function a.setActive(on) dev.setActive(on and true or false) end
    function a.setRods(level) dev.setAllControlRodLevels(clamp(level, 0, 100)) end
    function a.ejectWaste() dev.fuelTank().ejectWaste() end
    return a
end

local function brTurbine(name, dev)
    local a = {name = name, dev = dev, mod = "Bigger Reactors", kind = "turbine"}

    function a.read()
        if not brConnected(dev) then return {assembled = false} end
        local d = {assembled = true}
        d.active = dev.active()
        d.rpm = dev.rotor().RPM()
        local bat = dev.battery()
        d.stored, d.capacity, d.produced = bat.stored(), bat.capacity(), bat.producedLastTick()
        local tank = dev.fluidTank()
        d.flow, d.flowSet, d.flowLimit = tank.flowLastTick(), tank.nominalFlowRate(), tank.flowRateLimit()
        d.coils = dev.coilEngaged()
        local input = tank.input()
        d.steam, d.steamMax = input.amount(), input.maxAmount()
        return d
    end

    function a.setActive(on) dev.setActive(on and true or false) end
    function a.setFlow(rate) dev.fluidTank().setNominalFlowRate(math.floor(math.max(0, rate) + 0.5)) end
    function a.setCoils(on) dev.setCoilEngaged(on and true or false) end
    return a
end

local BUILDERS = {er_reactor = erReactor, er_turbine = erTurbine,
                  br_reactor = brReactor, br_turbine = brTurbine}

function er_utils.wrap(kind, name, dev)
    return BUILDERS[kind] and BUILDERS[kind](name, dev)
end

-- Safe read: nil plus error text when the peripheral is gone or throws.
function er_utils.read(adapter)
    local ok, d = pcall(adapter.read)
    if not ok then return nil, tostring(d) end
    if type(d) ~= "table" then return nil, "no data" end
    return d
end

------------------------------------------------------------
-- BUFFER CONTROLLER (reactor rods)
------------------------------------------------------------
--[[
Keeps a buffer between `low` and `high` (fractions): the reactor's own
FE battery when passively cooled, its hot-fluid (steam) tank when
actively cooled. Each cycle:

  demand   = production - d(buffer)/dt        (what is actually used)
  wanted   = demand + (mid - level) * capacity / RECOVERY_SECONDS
  rods    += -ROD_GAIN * dt * (wanted - production) / max(production, wanted)

The rod step is proportional to the RELATIVE production error, so the
same gain works for a 5 kFE/t starter reactor and a 500 kFE/t one, and
it is integral in nature (rods hold position at zero error), which
copes with the strongly nonlinear rod-to-output curve. Readings are
smoothed over a short window because both mods irradiate one fuel
column per tick, which makes per-tick production noisy.
]]
local RECOVERY_SECONDS = 20
-- Steam tanks hold seconds, not minutes: trim faster, and never use the
-- band edges as hard rules (they only cause limit cycles there).
local RECOVERY_SECONDS_STEAM = 4
-- Rod % per second at 100% relative error, and the most rods may move
-- per second. Steam tanks need gentle moves (the reactor's heat lags the
-- tank); FE batteries are large, so passive reactors can move faster and
-- catch sudden load changes before the buffer leaves its band.
local ROD_GAIN, ROD_RATE_MAX = 6, 6
local ROD_GAIN_PASSIVE, ROD_RATE_MAX_PASSIVE = 20, 25
local SMOOTHING = 0.3          -- EMA weight of the newest sample
local WASTE_EJECT_COOLDOWN = 30 -- seconds between eject attempts

local Buffer = {}
Buffer.__index = Buffer

function er_utils.newBufferController(cfg)
    local self = setmetatable({}, Buffer)
    self.cfg = cfg
    self.auto = true
    self.rods = nil            -- last commanded insertion
    self.manualRods = 50
    self.alarms = {}
    self.desired = cfg.autoStartOnBoot and "run" or nil   -- nil = keep current state
    return self
end

-- Normalises a reactor reading into {level, capacity, production}.
function er_utils.bufferOf(d)
    if d.activelyCooled then
        return (d.steamMax or 0) > 0 and d.steam / d.steamMax or 0, d.steamMax or 0, d.steamMade or 0
    end
    return (d.capacity or 0) > 0 and d.stored / d.capacity or 0, d.capacity or 0, d.produced or 0
end

function Buffer:requestStart() self.desired = "run" end
function Buffer:requestStop() self.desired = "stop" end
function Buffer:setAuto(on)
    self.auto = on
    if not on then self.manualRods = self.rods or self.manualRods end
end
function Buffer:adjustRods(delta)
    if self.auto then self:setAuto(false) end
    self.manualRods = clamp(self.manualRods + delta, 0, 100)
end

-- Returns {rods = %, active = bool|nil, events = {}} for one cycle.
-- `demandHint` (optional) is the consumption the caller already knows:
-- for an actively cooled reactor, the steam its turbines are set to
-- draw. A steam tank holds only seconds of mismatch, too little to
-- infer demand from its level, so the hint becomes the feed-forward and
-- the tank level only trims it.
function Buffer:step(d, now, demandHint)
    local c = self.cfg
    local out = {events = {}}
    self.alarms = {}
    if not d then
        table.insert(self.alarms, "LINK LOST")
        return out
    end
    if not d.assembled then
        table.insert(self.alarms, "NOT ASSEMBLED")
        return out
    end

    if self.desired == "run" and not d.active then out.active = true end
    if self.desired == "stop" and d.active then out.active = false end
    if self.rods == nil then self.rods = d.rods end

    local level, capacity, production = er_utils.bufferOf(d)
    local fuelPct = (d.fuelMax or 0) > 0 and d.fuel / d.fuelMax or 0
    if fuelPct < (c.lowFuel or 0.1) then
        table.insert(self.alarms, string.format("LOW FUEL %.0f%%", fuelPct * 100))
    end
    -- Waste shares the fuel tank and displaces fuel: eject it once it
    -- passes wasteEjectAt (needs an access port set to output). If it
    -- keeps piling up anyway, ejection isn't reaching anything: alarm.
    local wastePct = (d.fuelMax or 0) > 0 and (d.waste or 0) / d.fuelMax or 0
    if c.wasteEjectAt and wastePct >= c.wasteEjectAt
            and (not self.lastEject or now - self.lastEject >= WASTE_EJECT_COOLDOWN) then
        self.lastEject = now
        out.ejectWaste = true
        table.insert(out.events, {level = "INFO",
            message = string.format("Ejecting waste (%.0f%% of fuel tank)", wastePct * 100)})
    end
    if wastePct >= (c.wasteAlarmAt or 0.5) then
        table.insert(self.alarms, string.format("WASTE %.0f%% - CHECK ACCESS PORT", wastePct * 100))
    end

    -- Smoothed level and production; demand from the change in level.
    local dt = (self.lastAt and now > self.lastAt) and (now - self.lastAt) or nil
    self.level = self.level and (self.level + SMOOTHING * (level - self.level)) or level
    self.production = self.production and (self.production + SMOOTHING * (production - self.production)) or production
    local demand = self.production
    if dt and self.lastLevel then
        -- 20 ticks per second; buffer change per tick.
        local change = (self.level - self.lastLevel) * capacity / (dt * 20)
        demand = self.production - change
    end
    self.demand = self.demand and (self.demand + SMOOTHING * (demand - self.demand)) or demand
    if demandHint then self.demand = demandHint end
    self.lastLevel, self.lastAt = self.level, now

    local cycle = dt or 0
    if not self.auto then
        self.rods = self.manualRods
    elseif not d.active then
        -- Idle reactors keep their last rods; nothing to regulate.
    else
        local gain = (d.activelyCooled and ROD_GAIN or ROD_GAIN_PASSIVE) * (c.rodGain or 1)
        local maxStep = (d.activelyCooled and ROD_RATE_MAX or ROD_RATE_MAX_PASSIVE) * cycle
        local mid = (c.bufferLow + c.bufferHigh) / 2
        local step
        if d.activelyCooled then
            local wanted = math.max(0, self.demand
                + (mid - self.level) * capacity / (RECOVERY_SECONDS_STEAM * 20))
            local scale = math.max(self.production, wanted, 1)
            step = clamp(-gain * cycle * (wanted - self.production) / scale, -maxStep, maxStep)
        elseif self.level >= c.bufferHigh then
            -- Battery full: every FE more is thrown away, so stop burning
            -- fuel at once. Large FE buffers make this safe to do abruptly.
            step = 100
        elseif self.level <= c.bufferLow then
            step = -2 * maxStep    -- empty side of the band: open up fast
        else
            local wanted = math.max(0, self.demand + (mid - self.level) * capacity / (RECOVERY_SECONDS * 20))
            local scale = math.max(self.production, wanted, 1)
            step = clamp(-gain * cycle * (wanted - self.production) / scale, -maxStep, maxStep)
        end
        self.rods = clamp(self.rods + step, 0, 100)
    end
    out.rods = self.rods
    return out
end

------------------------------------------------------------
-- TURBINE CONTROLLER
------------------------------------------------------------
--[[
States
  spin-up  RPM below SPINUP_FRACTION of target: coils off (engaged coils
           brake the rotor), full steam flow.
  run      coils on, steam flow regulated to hold targetRPM.
  idle     turbine's own buffer above coilsOffAbove: coils off and flow
           regulated to keep the rotor at speed, ready to resume once
           the buffer falls below coilsOnBelow.
Overspeed above maxRPM cuts steam to zero. Efficiency peaks at ~1800
RPM in both mods (ER: cos curve, peaks ~898/1796; BR: peak 1800, zero
at ~2457), so 1800 is the default target.
]]
local SPINUP_FRACTION = 0.95
-- PI gains for a turbine with a 2000 mB/t flow limit, scaled by the
-- actual limit (a rough proxy for rotor size). Rotor inertia is large
-- (tens of seconds to change speed), so the integral is slow.
local FLOW_KP = 5              -- mB/t per RPM of error
local FLOW_KI = 0.1            -- mB/t per RPM-second of error
local REFERENCE_LIMIT = 2000

local Turbine = {}
Turbine.__index = Turbine

function er_utils.newTurbineController(cfg)
    local self = setmetatable({}, Turbine)
    self.cfg = cfg
    self.flow = nil
    self.coils = nil
    self.mode = "spin-up"
    self.alarms = {}
    self.desired = cfg.autoStartOnBoot and "run" or nil
    return self
end

function Turbine:requestStart() self.desired = "run" end
function Turbine:requestStop() self.desired = "stop" end

function Turbine:step(d, now)
    local c = self.cfg
    local out = {events = {}}
    self.alarms = {}
    if not d then
        table.insert(self.alarms, "LINK LOST")
        return out
    end
    if not d.assembled then
        table.insert(self.alarms, "NOT ASSEMBLED")
        return out
    end
    if self.desired == "run" and not d.active then out.active = true end
    if self.desired == "stop" and d.active then out.active = false end

    local limit = d.flowLimit or REFERENCE_LIMIT
    if self.flow == nil then self.flow = d.flowSet or limit end
    local dt = (self.lastAt and now and now > self.lastAt) and (now - self.lastAt) or 0
    self.lastAt = now
    local target = c.targetRPM
    local buffer = (d.capacity or 0) > 0 and d.stored / d.capacity or 0

    local previous = self.mode
    if d.rpm > c.maxRPM then
        self.mode = "overspeed"
    elseif d.rpm < target * SPINUP_FRACTION and self.mode ~= "idle" then
        self.mode = "spin-up"
    elseif buffer >= c.coilsOffAbove then
        self.mode = "idle"
    elseif self.mode ~= "idle" or buffer <= c.coilsOnBelow then
        self.mode = "run"
    end
    if self.mode ~= previous then
        table.insert(out.events, {level = "INFO", message = "Turbine " .. self.mode})
    end

    local size = limit / REFERENCE_LIMIT
    local err = target - d.rpm
    if self.mode == "overspeed" then
        self.flow, self.integral = 0, 0
        self.coils = buffer < c.coilsOffAbove     -- coils brake when there is room
        table.insert(self.alarms, string.format("OVERSPEED %.0f RPM", d.rpm))
    elseif self.mode == "spin-up" then
        self.flow = limit
        self.coils = false
        self.integral = nil        -- re-seed from the flow that holds speed
    else
        if self.mode ~= previous or self.integral == nil then
            -- Bumpless entry: start from the steam actually flowing.
            self.integral = clamp(d.flow or self.flow, 0, limit)
        end
        local tune = c.flowGain or 1
        self.integral = clamp(self.integral + FLOW_KI * size * tune * err * dt, 0, limit)
        self.flow = clamp(self.integral + FLOW_KP * size * tune * err, 0, limit)
        self.coils = self.mode == "run"
    end
    if d.active and (d.steam or 0) <= 0 and (d.flowSet or 0) > 0 then
        table.insert(self.alarms, "NO STEAM")
    end
    out.flow, out.coils = self.flow, self.coils
    return out
end

------------------------------------------------------------
-- APPLY
------------------------------------------------------------
-- Writes only what changed (ER setters cost a server-thread round trip).
function er_utils.apply(adapter, out, last)
    local errors = {}
    local function try(label, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then table.insert(errors, label .. ": " .. tostring(err)) end
    end
    if out.active ~= nil then try("setActive", adapter.setActive, out.active) end
    if out.rods and (last.rods == nil or math.abs(out.rods - last.rods) >= 0.5) then
        try("setRods", adapter.setRods, out.rods); last.rods = out.rods
    end
    if out.flow and (last.flow == nil or math.abs(out.flow - last.flow) >= 1) then
        try("setFlow", adapter.setFlow, out.flow); last.flow = out.flow
    end
    if out.coils ~= nil and out.coils ~= last.coils then
        try("setCoils", adapter.setCoils, out.coils); last.coils = out.coils
    end
    if out.ejectWaste and adapter.ejectWaste then try("ejectWaste", adapter.ejectWaste) end
    return errors
end

return er_utils
