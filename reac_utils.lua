--==============================================================
-- REACTOR UTILITIES
-- Save as: reac_utils.lua
--==============================================================

--[[
README
-------
Hardware access and the control law for a Draconic Evolution reactor.

Hardware layer
  reac_utils.discover(cfg, chooseGates)  Find reactor + both flux gates
  reac_utils.readInfo(reactor)            Normalised reactor snapshot
  reac_utils.wrapGate(name, peripheral)   Version-independent gate API

Control layer (pure; no peripheral calls, so it can be unit tested)
  local ctl = reac_utils.newController(reactorCfg, info)
  local actions = ctl:step(info)
      actions.input    RF/t for the input (field) gate
      actions.output   RF/t for the output gate
      actions.command  nil | "charge" | "activate" | "stop"
      actions.events   list of {level, message} to log

Regulation strategy
  Field : input = fieldDrainRate / (1 - targetField). At equilibrium the
          injector adds exactly what the field loses, and the formula is
          self-correcting: a weaker field absorbs a larger share of input.
  Heat  : cascade. Core temperature is a steep, lagging function of
          energy saturation (below ~10% saturation a DE 1.16+ core gains
          hundreds of degrees per tick), so temperature is not driven
          directly:
            outer  temperature error -> saturation setpoint (PI, slow)
            inner  output = generation + (sat - setpoint) * capacity / tau
          Draining exactly the generation rate holds saturation constant;
          the inner term walks it to the setpoint within ~1 second.
          The setpoint never goes below SAT_FLOOR, the integrator freezes
          while saturation cannot follow (energy core full), output
          increases are rate limited and cuts are immediate.

Safety model (fail-safe = field input HIGH, output ZERO)
  - A stopping reactor still needs its containment field until it is
    cold, so the field gate is NEVER zeroed while the reactor is hot.
  - Temperature > maxTemperature, field < minField or fuel < minFuel
    trips the reactor into a controlled stop.
]]

local reac_utils = {}

------------------------------------------------------------
-- PERIPHERAL CLASSIFICATION
------------------------------------------------------------
local function hasMethod(dev, name)
    return type(dev) == "table" and type(dev[name]) == "function"
end

function reac_utils.isReactor(dev)
    return hasMethod(dev, "getReactorInfo")
end

function reac_utils.isGate(dev)
    return hasMethod(dev, "getFlow")
        and (hasMethod(dev, "setFlowOverride")
             or hasMethod(dev, "setSignalLowFlow"))
end

-- Lists "name (type)" for every attached peripheral; used to explain
-- detection failures to the player.
function reac_utils.describePeripherals()
    local lines = {}
    for _, name in ipairs(peripheral.getNames()) do
        table.insert(lines, name .. " (" .. tostring(peripheral.getType(name)) .. ")")
    end
    return lines
end

-- CC:Tweaked's generic energy peripheral (getEnergy/getEnergyCapacity).
-- Draconic Evolution 1.20.1 builds before August 2024 (DE PR #1817) had
-- broken CC integration, so their blocks only show up like this.
local function isGenericEnergy(dev)
    return hasMethod(dev, "getEnergy") and hasMethod(dev, "getEnergyCapacity")
end

local OLD_DE_HINT = " Blocks only expose CC's generic energy_storage peripheral:"
    .. " your Draconic Evolution build predates its CC fix (Aug 2024)."
    .. " Update to DE 3.1.2.604 or newer."

-- Explains an empty network: old DE builds only show generic peripherals.
function reac_utils.missingHint()
    for _, name in ipairs(peripheral.getNames()) do
        if isGenericEnergy(peripheral.wrap(name)) then
            return "No Draconic peripherals found." .. OLD_DE_HINT
        end
    end
    return nil
end

local function findAll(predicate)
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        local dev = peripheral.wrap(name)
        if predicate(dev) then
            table.insert(found, name)
        end
    end
    table.sort(found)
    return found
end

------------------------------------------------------------
-- FLUX GATE ADAPTER
------------------------------------------------------------
-- DE 1.12+ gates expose an override; very old versions only have the
-- redstone-signal flow limits, which we drive to the same value.
--
-- On DE 1.20 every peripheral call costs a server tick, so unchanged
-- rates are not re-sent and the override flag is only re-verified every
-- OVERRIDE_RECHECK writes (in case a player toggled it in the GUI).
local OVERRIDE_RECHECK = 100

function reac_utils.wrapGate(name, dev)
    local gate = {name = name, dev = dev, lastSet = nil, writes = 0}

    function gate.set(rate)
        rate = math.max(0, math.floor(rate + 0.5))
        if rate == gate.lastSet and gate.writes % OVERRIDE_RECHECK ~= 0 then
            gate.writes = gate.writes + 1
            return
        end
        if hasMethod(dev, "setFlowOverride") then
            local recheck = gate.writes % OVERRIDE_RECHECK == 0
            if recheck and hasMethod(dev, "getOverrideEnabled") then
                if not dev.getOverrideEnabled() then dev.setOverrideEnabled(true) end
            elseif gate.lastSet == nil and hasMethod(dev, "setOverrideEnabled") then
                dev.setOverrideEnabled(true)
            end
            dev.setFlowOverride(rate)
        else
            dev.setSignalLowFlow(rate)
            if hasMethod(dev, "setSignalHighFlow") then
                dev.setSignalHighFlow(rate)
            end
        end
        gate.lastSet = rate
        gate.writes = gate.writes + 1
    end

    function gate.get()
        return dev.getFlow()
    end

    return gate
end

------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------
local function resolve(configured, predicate, label)
    if configured then
        if not peripheral.isPresent(configured) then
            return nil, label .. " '" .. configured .. "' (from config.lua) is not attached"
        end
        local dev = peripheral.wrap(configured)
        if not predicate(dev) then
            return nil, label .. " '" .. configured .. "' is a "
                .. tostring(peripheral.getType(configured)) .. ", not a " .. label
        end
        return configured
    end
    return nil
end

--[[
Finds the reactor and both flux gates.

chooseGates(gateNames) is called only when two or more gates exist and
neither config.lua nor saved settings say which is which; it must return
inputName, outputName (or nil to abort).

Returns a hardware table {reactor, reactorName, input, output} or
nil plus an error message.
]]
function reac_utils.discover(peripheralsCfg, chooseGates)
    peripheralsCfg = peripheralsCfg or {}

    -- Reactor
    local reactorName, err = resolve(peripheralsCfg.reactor, reac_utils.isReactor, "reactor")
    if err then return nil, err end
    if not reactorName then
        local reactors = findAll(reac_utils.isReactor)
        if #reactors == 0 then
            local hint = #findAll(isGenericEnergy) > 0 and OLD_DE_HINT or ""
            return nil, "No reactor found. Connect a wired modem to a reactor stabilizer"
                .. " or injector." .. hint
        elseif #reactors > 1 then
            return nil, "Several reactors found (" .. table.concat(reactors, ", ")
                .. "). Set config.peripherals.reactor."
        end
        reactorName = reactors[1]
    end

    -- Gates: config.lua > saved settings > single prompt
    local inName, inErr = resolve(peripheralsCfg.inputGate, reac_utils.isGate, "flux gate")
    if inErr then return nil, "Input gate: " .. inErr end
    local outName, outErr = resolve(peripheralsCfg.outputGate, reac_utils.isGate, "flux gate")
    if outErr then return nil, "Output gate: " .. outErr end

    local gates = findAll(reac_utils.isGate)
    if not inName or not outName then
        local savedIn = settings and settings.get("draconic.inputGate")
        local savedOut = settings and settings.get("draconic.outputGate")
        local function present(n)
            return n and peripheral.isPresent(n) and reac_utils.isGate(peripheral.wrap(n))
        end
        if not inName and present(savedIn) and savedIn ~= outName then inName = savedIn end
        if not outName and present(savedOut) and savedOut ~= inName then outName = savedOut end
    end

    if not inName or not outName then
        if #gates < 2 then
            local hint = #findAll(isGenericEnergy) > 0 and OLD_DE_HINT or ""
            return nil, "Need two flux gates, found " .. #gates
                .. ". Connect wired modems to both gates and right-click them (red ring)." .. hint
        end
        if inName and #gates == 2 then
            outName = gates[1] == inName and gates[2] or gates[1]
        elseif outName and #gates == 2 then
            inName = gates[1] == outName and gates[2] or gates[1]
        else
            if not chooseGates then
                return nil, "Cannot tell which flux gate is input. Set inputGate/outputGate in config.lua."
            end
            inName, outName = chooseGates(gates)
            if not inName or not outName or inName == outName then
                return nil, "Flux gate selection cancelled."
            end
        end
        if settings then
            settings.set("draconic.inputGate", inName)
            settings.set("draconic.outputGate", outName)
            settings.save()
        end
    end

    if inName == outName then
        return nil, "Input and output gate are the same peripheral (" .. inName .. ")."
    end

    return {
        reactorName = reactorName,
        reactor     = peripheral.wrap(reactorName),
        input       = reac_utils.wrapGate(inName, peripheral.wrap(inName)),
        output      = reac_utils.wrapGate(outName, peripheral.wrap(outName))
    }
end

------------------------------------------------------------
-- MULTI-REACTOR DISCOVERY
------------------------------------------------------------
-- Builds a hardware table from explicit names, validating each one.
-- spec = {name?, reactor, inputGate, outputGate}
function reac_utils.buildHw(spec)
    local label = spec.name or spec.reactor or "?"
    local reactorName, err = resolve(spec.reactor, reac_utils.isReactor, "reactor")
    if not reactorName then return nil, label .. ": " .. (err or "reactor not set") end
    local inName, inErr = resolve(spec.inputGate, reac_utils.isGate, "flux gate")
    if not inName then return nil, label .. ": input gate " .. (inErr or "not set") end
    local outName, outErr = resolve(spec.outputGate, reac_utils.isGate, "flux gate")
    if not outName then return nil, label .. ": output gate " .. (outErr or "not set") end
    if inName == outName then
        return nil, label .. ": input and output gate are the same (" .. inName .. ")"
    end
    return {
        name        = spec.name,
        reactorName = reactorName,
        reactor     = peripheral.wrap(reactorName),
        input       = reac_utils.wrapGate(inName, peripheral.wrap(inName)),
        output      = reac_utils.wrapGate(outName, peripheral.wrap(outName))
    }
end

local function buildAll(specs)
    local list, used = {}, {}
    for i, spec in ipairs(specs) do
        spec = {name = spec.name or ("Reactor " .. i), reactor = spec.reactor,
                inputGate = spec.inputGate, outputGate = spec.outputGate}
        for _, key in ipairs({"reactor", "inputGate", "outputGate"}) do
            local n = spec[key]
            if n and used[n] then
                return nil, spec.name .. ": " .. n .. " is already used by " .. used[n]
            end
            if n then used[n] = spec.name end
        end
        local hw, err = reac_utils.buildHw(spec)
        if not hw then return nil, err end
        table.insert(list, hw)
    end
    return list
end

--[[
Finds every reactor and its gate pair. Returns a list of hardware tables
or nil plus an error.

  1. config.peripherals.reactors = {{name, reactor, inputGate, outputGate}, ...}
  2. the single-reactor fields (reactor / inputGate / outputGate), or a
     lone reactor on the network: the original auto-detection path
  3. a saved assignment from a previous setup ("draconic.units")
  4. setupWizard(reactorNames, gateNames) -> specs, run once and saved

Several reactor peripherals can belong to ONE reactor (a modem on a
stabilizer and another on an injector); the wizard lets the player skip
those duplicates.
]]
function reac_utils.discoverAll(peripheralsCfg, chooseGates, setupWizard)
    peripheralsCfg = peripheralsCfg or {}
    if type(peripheralsCfg.reactors) == "table" and #peripheralsCfg.reactors > 0 then
        return buildAll(peripheralsCfg.reactors)
    end

    local reactors = findAll(reac_utils.isReactor)
    if peripheralsCfg.reactor or #reactors <= 1 then
        local hw, err = reac_utils.discover(peripheralsCfg, chooseGates)
        if not hw then return nil, err end
        return {hw}
    end

    local saved = settings and settings.get("draconic.units")
    if type(saved) == "table" and #saved > 0 then
        local list = buildAll(saved)
        if list then return list end
    end

    if not setupWizard then
        return nil, "Several reactors found (" .. table.concat(reactors, ", ")
            .. "). List them in config.peripherals.reactors."
    end
    local specs = setupWizard(reactors, findAll(reac_utils.isGate))
    if not specs or #specs == 0 then
        return nil, "Reactor setup cancelled."
    end
    local list, err = buildAll(specs)
    if not list then return nil, err end
    if settings then
        settings.set("draconic.units", specs)
        settings.save()
    end
    return list
end

------------------------------------------------------------
-- REACTOR INFO
------------------------------------------------------------
-- DE 1.12-1.20 report invalid, cold, warming_up, running, stopping,
-- cooling, beyond_hope. The aliases cover pre-1.12 builds and scripts
-- written against them (drmon checks these names).
local STATUS_ALIASES = {
    offline  = "cold",
    charging = "warming_up",
    charged  = "warming_up",
    online   = "running"
}

local function ratio(value, max)
    if type(value) ~= "number" or type(max) ~= "number" or max <= 0 then
        return 0
    end
    return value / max
end

-- Returns a normalised copy of getReactorInfo() with derived ratios,
-- or nil plus an error message.
function reac_utils.readInfo(reactor)
    if not reactor then
        return nil, "reactor not connected"
    end
    local ok, raw = pcall(reactor.getReactorInfo)
    if not ok then
        return nil, tostring(raw)
    end
    if type(raw) ~= "table" then
        return nil, "getReactorInfo returned no data (is the reactor built?)"
    end

    local info = {}
    for k, v in pairs(raw) do info[k] = v end

    local status = string.lower(tostring(raw.status or "unknown"))
    info.rawStatus     = status
    info.status        = STATUS_ALIASES[status] or status
    info.temperature   = tonumber(raw.temperature) or 0
    info.fieldPct      = ratio(raw.fieldStrength, raw.maxFieldStrength)
    info.satPct        = ratio(raw.energySaturation, raw.maxEnergySaturation)
    info.fuelRemaining = 1 - ratio(raw.fuelConversion, raw.maxFuelConversion)
    if (tonumber(raw.maxFuelConversion) or 0) <= 0 then
        info.fuelRemaining = 0
    end
    info.generationRate = tonumber(raw.generationRate) or 0
    info.fieldDrainRate = tonumber(raw.fieldDrainRate) or 0
    info.maxEnergySaturation = tonumber(raw.maxEnergySaturation) or 0
    return info
end

------------------------------------------------------------
-- CONTROLLER
------------------------------------------------------------
-- Saturation setpoint gains, per degree C of temperature error. Near
-- the operating point temperature moves ~-17000C per unit of saturation,
-- giving an outer loop time constant of roughly 10 seconds.
local SAT_KI = 5e-6            -- per degree per second
local SAT_KP = 2e-5            -- per degree
-- Lowest saturation setpoint. Fresh fuel needs ~11% at 8000C; below
-- ~8% the temperature response becomes too steep to regulate.
local SAT_FLOOR = 0.08
local SAT_CEILING = 0.99
-- Integrator only runs while saturation is within this of the setpoint.
local SAT_TRACKING_BAND = 0.03
-- Inner loop: close the saturation error over this many game ticks.
local INNER_TAU_TICKS = 20
-- Max output increase per cycle, as a fraction of generation (+ floor).
-- Manual mode uses the smaller fraction: an abrupt 2x output step on
-- DE 1.16+ heats the core ~400C per tick.
local OUTPUT_SLEW_FRACTION = 0.05
-- Seconds of warm-up without progress before the charging alarm.
local CHARGE_STALL_SECONDS = 30
local MANUAL_SLEW_FRACTION = 0.01
local OUTPUT_SLEW_FLOOR = 20000
-- Manual mode interlock: temperature rise rate (C/s) above target.
local MANUAL_MAX_RISE = 100
-- Warm-up completion thresholds used by Draconic Evolution.
local WARM_TEMPERATURE = 2000
local WARM_FIELD = 0.499
local WARM_SATURATION = 0.499
-- Seconds between repeated charge/activate commands.
local COMMAND_COOLDOWN = 5
-- Auto-restart budget: a reactor that keeps tripping needs a human.
local MAX_AUTO_RESTARTS = 3
local AUTO_RESTART_WINDOW = 3600

local Controller = {}
Controller.__index = Controller

function reac_utils.newController(reactorCfg, info)
    local self = setmetatable({}, Controller)
    self.cfg = reactorCfg
    self.autoOutput = true
    self.manualOutput = 0
    self.outputRate = 0
    self.inputRate = 0
    self.observedInput = 0       -- last input chosen while the reactor was visible
    self.trip = nil              -- {reason = "...", restartable = bool}
    self.alarms = {}
    self.lastCommandAt = {}
    self.satIntegral = nil       -- outer loop state; nil = re-initialise
    self.lastTemp, self.lastStepAt = nil, nil
    self.autoRestarts = {}       -- timestamps of recent auto-restarts

    -- Keep a running reactor running across computer restarts; only
    -- charge a cold reactor on boot when explicitly configured.
    local status = info and info.status
    if status == "running" or status == "warming_up" or reactorCfg.autoStartOnBoot then
        self.desired = "run"
    else
        self.desired = "stop"
    end
    return self
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function emit(actions, level, message)
    table.insert(actions.events, {level = level, message = message})
end

-- Player requests -------------------------------------------------------
function Controller:requestStart()
    self.desired = "run"
    self.trip = nil
    self.autoRestarts = {}
end

function Controller:requestStop()
    self.desired = "stop"
end

function Controller:setAutoOutput(enabled)
    self.autoOutput = enabled
    self.satIntegral = nil
    if not enabled then
        self.manualOutput = self.outputRate
    end
end

function Controller:adjustManualOutput(delta)
    if self.autoOutput then
        self.autoOutput = false
        self.manualOutput = self.outputRate
    end
    self.manualOutput = clamp(self.manualOutput + delta, 0, self.cfg.maxOutflow)
end

-- Regulation laws -------------------------------------------------------
-- Input to hold when the reactor cannot be observed (link lost, program
-- exiting). With output at zero, saturation climbs and field drain falls
-- to ~1%, so twice the last known need is a wide margin. The injector
-- accepts and wastes any excess, so maxInflow would burn stored power.
function Controller:blindInput()
    local c = self.cfg
    return clamp(math.max(self.observedInput * 2, c.chargeInflow), 0, c.maxInflow)
end

function Controller:fieldInput(info)
    local c = self.cfg
    if info.fieldPct < c.minField then
        return c.maxInflow
    end
    local rate = info.fieldDrainRate / (1 - c.targetField)
    return clamp(rate, 0, c.maxInflow)
end

function Controller:regulatedOutput(info, dt)
    local c = self.cfg
    local gain = c.outputAggressiveness or 1
    local hot = info.temperature - c.targetTemperature   -- > 0: too hot

    -- Bumpless start: begin from the saturation the core has now.
    if self.satIntegral == nil then
        self.satIntegral = clamp(info.satPct, SAT_FLOOR, SAT_CEILING)
    end
    local setpoint = clamp(self.satIntegral + SAT_KP * gain * hot, SAT_FLOOR, SAT_CEILING)
    if math.abs(info.satPct - setpoint) < SAT_TRACKING_BAND then
        self.satIntegral = clamp(self.satIntegral + SAT_KI * gain * hot * dt,
                                 SAT_FLOOR, SAT_CEILING)
    end
    self.satSetpoint = setpoint

    local excess = (info.satPct - setpoint) * info.maxEnergySaturation
    local target = info.generationRate + excess / INNER_TAU_TICKS
    return self:limitIncrease(target, info, OUTPUT_SLEW_FRACTION)
end

-- Only increases are rate limited: less output always means more
-- saturation and a cooler core, so cuts take effect at once. On DE 1.16+
-- an abrupt 2x output step heats the core ~400C per tick, faster than
-- any control loop can react, so this limit also applies to manual mode.
function Controller:limitIncrease(target, info, fraction)
    local slew = math.max(OUTPUT_SLEW_FLOOR, info.generationRate * fraction)
    target = math.min(target, self.outputRate + slew)
    return clamp(target, 0, self.cfg.maxOutflow)
end

-- Charging that makes no progress means the input gate is not reaching
-- the energy injector: the wrong gate, a fluid gate (DE reports fluid
-- and flux gates identically), or no power behind it.
function Controller:checkChargeProgress(info, now, actions)
    local progress = info.fieldPct + info.satPct + info.temperature / 10000
    if not self.chargeProgress or progress > self.chargeProgress + 1e-4 then
        self.chargeProgress, self.chargeProgressAt = progress, now
        self.chargeStallWarned = false
        return
    end
    if now - self.chargeProgressAt >= CHARGE_STALL_SECONDS then
        table.insert(self.alarms, "CHARGING STALLED - CHECK INPUT GATE")
        if not self.chargeStallWarned then
            self.chargeStallWarned = true
            emit(actions, "WARN", string.format(
                "Charging made no progress for %ds: the input gate is not feeding the energy "
                .. "injector (wrong gate, a fluid gate, or no power behind it)", CHARGE_STALL_SECONDS))
        end
    end
end

function Controller:commandReady(name, now)
    local last = self.lastCommandAt[name]
    if last and now - last < COMMAND_COOLDOWN then
        return false
    end
    self.lastCommandAt[name] = now
    return true
end

function Controller:restartBudgetLeft(now)
    local recent = {}
    for _, t in ipairs(self.autoRestarts) do
        if now - t < AUTO_RESTART_WINDOW then table.insert(recent, t) end
    end
    self.autoRestarts = recent
    return #recent < MAX_AUTO_RESTARTS
end

function Controller:setTrip(actions, reason, restartable)
    self.trip = {reason = reason, restartable = restartable}
    if not restartable or not self.cfg.autoRestart then
        self.desired = "stop"
    end
    emit(actions, "CRIT", "TRIP: " .. reason .. " - stopping reactor")
end

--[[
One control cycle. `info` comes from reac_utils.readInfo (nil when the
reactor could not be read). `now` is a monotonic time in seconds.
]]
function Controller:step(info, now)
    local c = self.cfg
    local actions = {input = 0, output = 0, command = nil, events = {}}
    self.alarms = {}
    now = now or 0

    if not info then
        -- Blind: keep the field fed and stop extracting power.
        table.insert(self.alarms, "REACTOR LINK LOST")
        actions.input = self:blindInput()
        actions.output = 0
        self.inputRate, self.outputRate = actions.input, actions.output
        return actions
    end

    local status = info.status
    local lowFuel = info.fuelRemaining < c.minFuel

    if info.fuelRemaining < c.minFuel * 2 then
        table.insert(self.alarms, string.format("LOW FUEL %.0f%%", info.fuelRemaining * 100))
    end

    -- Trip detection ------------------------------------------------
    local stopNow = false
    if status == "running" then
        if info.temperature > c.maxTemperature then
            self:setTrip(actions, string.format("temperature %.0fC > %.0fC",
                info.temperature, c.maxTemperature), true)
            stopNow = true
        elseif info.fieldPct < c.minField then
            self:setTrip(actions, string.format("field %.1f%% < %.1f%%",
                info.fieldPct * 100, c.minField * 100), true)
            stopNow = true
        elseif lowFuel then
            self:setTrip(actions, string.format("fuel %.1f%% < %.1f%%",
                info.fuelRemaining * 100, c.minFuel * 100), false)
            stopNow = true
        end
    end

    -- Manual mode interlock: hand control back to the regulator well
    -- before the hard trip limit, or as soon as heat is climbing fast.
    local dt = (self.lastStepAt and now > self.lastStepAt) and math.min(now - self.lastStepAt, 1) or 0
    local rise = (self.lastTemp and dt > 0) and (info.temperature - self.lastTemp) / dt or 0
    self.lastTemp, self.lastStepAt = info.temperature, now
    local guard = c.targetTemperature + (c.maxTemperature - c.targetTemperature) * 0.25
    if not self.autoOutput and status == "running"
            and (info.temperature > guard
                 or (info.temperature > c.targetTemperature and rise > MANUAL_MAX_RISE)) then
        self:setAutoOutput(true)
        emit(actions, "WARN", string.format(
            "Manual output overheating reactor (%.0fC, %+.0fC/s); auto regulation re-enabled",
            info.temperature, rise))
    end
    if status ~= "running" then
        self.satIntegral = nil
    end

    -- State machine -------------------------------------------------
    if status == "running" then
        actions.input = self:fieldInput(info)
        if stopNow or self.desired == "stop" then
            actions.output = 0
            if self:commandReady("stop", now) or stopNow then
                actions.command = "stop"
            end
        elseif self.autoOutput then
            actions.output = self:regulatedOutput(info, dt)
        else
            actions.output = self:limitIncrease(self.manualOutput, info, MANUAL_SLEW_FRACTION)
        end

    elseif status == "stopping" then
        actions.input = self:fieldInput(info)
        actions.output = 0
        -- Draconic Evolution lets a stopping reactor be re-activated while
        -- it is above 2000C, so a trip need not wait for a full cooldown
        -- and recharge: resume once it has cooled to safeTemperature and
        -- the field is back near its target.
        local tripAllows = (self.trip == nil)
            or (self.trip.restartable and c.autoRestart and self:restartBudgetLeft(now))
        if self.desired == "run" and tripAllows and not lowFuel
                and info.temperature >= WARM_TEMPERATURE
                and info.temperature <= c.safeTemperature
                and info.fieldPct >= c.targetField * 0.9 then
            if self:commandReady("activate", now) then
                actions.command = "activate"
                if self.trip then
                    table.insert(self.autoRestarts, now)
                    emit(actions, "WARN", "Resuming without cooldown after trip: " .. self.trip.reason)
                else
                    emit(actions, "INFO", "Resuming reactor")
                end
                self.trip = nil
            end
        end

    elseif status == "warming_up" then
        actions.input = clamp(c.chargeInflow, 0, c.maxInflow)
        actions.output = 0
        self:checkChargeProgress(info, now, actions)
        if self.desired == "stop" then
            if self:commandReady("stop", now) then actions.command = "stop" end
        elseif info.temperature >= WARM_TEMPERATURE
                and info.fieldPct >= WARM_FIELD
                and info.satPct >= WARM_SATURATION then
            if self:commandReady("activate", now) then
                actions.command = "activate"
                emit(actions, "INFO", "Reactor charged; activating")
            end
        end

    elseif status == "cold" or status == "cooling" then
        actions.input = 0
        actions.output = 0
        local tripAllows = (self.trip == nil)
            or (self.trip.restartable and c.autoRestart and self:restartBudgetLeft(now))
        if self.desired == "run" and tripAllows and not lowFuel
                and info.temperature <= c.safeTemperature then
            if self:commandReady("charge", now) then
                actions.command = "charge"
                if self.trip then
                    table.insert(self.autoRestarts, now)
                    emit(actions, "WARN", "Auto-restart after trip: " .. self.trip.reason)
                else
                    emit(actions, "INFO", "Charging reactor")
                end
                self.trip = nil
            end
        elseif self.desired == "run" and self.trip and not tripAllows then
            table.insert(self.alarms, "AUTO-RESTART LIMIT - PRESS START")
        elseif self.desired == "run" and lowFuel then
            table.insert(self.alarms, "REFUEL REACTOR")
        end

    elseif status == "beyond_hope" then
        table.insert(self.alarms, "REACTOR CRITICAL - EVACUATE")
        actions.input = c.maxInflow
        actions.output = 0

    else
        -- "invalid" (structure incomplete) or an unknown future status.
        -- Feed the field whenever the core is still hot.
        table.insert(self.alarms, "STATUS " .. string.upper(tostring(status)))
        if info.temperature > WARM_TEMPERATURE then
            actions.input = self:fieldInput(info)
        end
        actions.output = 0
    end

    if self.trip then
        table.insert(self.alarms, "TRIP: " .. self.trip.reason)
    end

    self.observedInput = actions.input
    self.inputRate, self.outputRate = actions.input, actions.output
    return actions
end

------------------------------------------------------------
-- APPLY ACTIONS TO HARDWARE
------------------------------------------------------------
-- Returns a list of error strings (empty on success).
--
-- On DE 1.20 each peripheral call waits for the next server tick, so the
-- two gate writes run in parallel coroutines and share one tick instead
-- of costing two.
function reac_utils.apply(hw, actions)
    local errors = {}
    local function try(label, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then table.insert(errors, label .. ": " .. tostring(err)) end
    end
    local function setInput() try("input gate " .. hw.input.name, hw.input.set, actions.input) end
    local function setOutput() try("output gate " .. hw.output.name, hw.output.set, actions.output) end
    if parallel and coroutine.running() then
        parallel.waitForAll(setInput, setOutput)
    else
        setInput()
        setOutput()
    end
    if actions.command == "charge" then
        try("chargeReactor", hw.reactor.chargeReactor)
    elseif actions.command == "activate" then
        try("activateReactor", hw.reactor.activateReactor)
    elseif actions.command == "stop" then
        try("stopReactor", hw.reactor.stopReactor)
    end
    return errors
end

return reac_utils
