--==============================================================
-- ENERGY STORAGE UTILITIES
-- Save as: storage_utils.lua
--==============================================================

--[[
README
-------
Read-only adapters for energy storage blocks from many mods, flow
tracking and the energy-network aggregate. Pure apart from the
peripheral calls inside adapter.read(); everything is reported in FE
(= RF) and per game tick.

  storage_utils.classify(name, dev, types) -> kind or nil, reason
  storage_utils.wrap(kind, name, dev)      -> adapter
      adapter.read() -> {stored, capacity, input, output, rate,
                         formed, saturated} or nil, err
      adapter.key()  -> identity of the physical store (dedupe) or nil
  storage_utils.newTracker()               -> tracker
      tracker:update(raw, now) -> info {stored, max, pct, input, output,
                                 net, transfer, timeToFull, timeToEmpty,
                                 measured, saturated}
  storage_utils.network(units)             -> energy-network aggregate

Kinds (checked in this order; facts from the mods' 1.20.1 source):
  mek_matrix  Mekanism Induction Port ("inductionPort"): getEnergy,
              getMaxEnergy, getLastInput, getLastOutput, isFormed. JOULES.
  mek_cube    Mekanism energy cube ("<tier>EnergyCube"). JOULES, no rates.
  draconic    Draconic Evolution energy pylon ("draconic_rf_storage"):
              getEnergyStored, getMaxEnergyStored, getInputPerTick,
              getOutputPerTick (DE 1.18+), getTransferPerTick.
  flux        Flux Networks controller through the UnlimitedPeripheralWorks
              addon ("flux_controller"): getEnergy, getEnergyCapacity,
              getStatistic() -> {energyInput, energyOutput, ...}.
  powah       Powah energy/ender cell through Advanced Peripherals
              ("energyCell", "enderCell"): getEnergy, getMaxEnergy (FE).
  meter       Advanced Peripherals Energy Detector ("energyDetector"):
              getTransferRate() FE/t. A flow meter, not a store.
  generic     CC:Tweaked's generic "energy_storage" peripheral (getEnergy,
              getEnergyCapacity, FE, 32-bit capped) for any block with a
              Forge energy capability and no peripheral of its own:
              EnderIO capacitor banks, Powah/Thermal cells, etc.

Mekanism always reports Joules. They are converted with the in-game
mekanismEnergyHelper.joulesToFE() (honours the server's conversion
rate) when available, else with the default 2.5 J per FE.
]]

local storage_utils = {}

local TICKS_PER_SECOND = 20
local INT_MAX = 2147483647              -- CC generic methods return Java ints
local LONG_SATURATED = 9.2e18           -- DE pylon long values at Long.MAX
local DEFAULT_J_PER_FE = 2.5
local FLOW_TAU = 5                      -- seconds; smoothing time constant

local function hasMethod(dev, name)
    return type(dev) == "table" and type(dev[name]) == "function"
end

local function call(dev, name, ...)
    if not hasMethod(dev, name) then return nil end
    local ok, v = pcall(dev[name], ...)
    if ok then return v end
    return nil
end

local function num(v)
    return type(v) == "number" and v or nil
end

------------------------------------------------------------
-- CLASSIFICATION
------------------------------------------------------------
-- Generic energy blocks of these mods are not storage: reactor/turbine
-- power taps (their buffer belongs to a controlled unit) and Flux
-- plugs/points (a small per-device transfer buffer).
storage_utils.SKIP_PREFIXES = {"bigreactors:", "biggerreactors:", "draconicevolution:",
                               "fluxnetworks:"}

local function typeSet(types)
    local set = {}
    for _, t in ipairs(types or {}) do set[tostring(t)] = true end
    return set
end

-- types: every type the peripheral reports (primary first).
function storage_utils.classify(name, dev, types)
    local set = typeSet(types)
    local primary = tostring((types and types[1]) or "")
    if set.energyDetector or (hasMethod(dev, "getTransferRate") and hasMethod(dev, "getTransferRateLimit")) then
        return "meter"
    end
    if set.inductionPort or (hasMethod(dev, "getLastInput") and hasMethod(dev, "getTransferCap")
                             and hasMethod(dev, "getMaxEnergy")) then
        return "mek_matrix"
    end
    for t in pairs(set) do
        if t:find("EnergyCube$") and hasMethod(dev, "getMaxEnergy") then return "mek_cube" end
    end
    if set.draconic_rf_storage or (hasMethod(dev, "getEnergyStored") and hasMethod(dev, "getMaxEnergyStored")
                                   and not hasMethod(dev, "getReactorInfo") and not hasMethod(dev, "getFlow")) then
        return "draconic"
    end
    if set.flux_controller or (hasMethod(dev, "getStatistic") and hasMethod(dev, "getEnergyCapacity")) then
        return "flux"
    end
    if (set.energyCell or set.enderCell) and hasMethod(dev, "getMaxEnergy") then
        return "powah"
    end
    if set.energy_storage or (hasMethod(dev, "getEnergy") and hasMethod(dev, "getEnergyCapacity")) then
        for _, prefix in ipairs(storage_utils.SKIP_PREFIXES) do
            if primary:sub(1, #prefix) == prefix then
                return nil, "transit"
            end
        end
        return "generic"
    end
    return nil
end

------------------------------------------------------------
-- ADAPTERS
------------------------------------------------------------
local MOD_LABELS = {
    mek_matrix = "Mekanism", mek_cube = "Mekanism", draconic = "Draconic Evolution",
    flux = "Flux Networks", powah = "Powah", meter = "Advanced Peripherals",
    generic = "Forge Energy"
}

-- Joules -> FE factor, asked once from Mekanism's global helper API.
local jouleFactor
function storage_utils.joulesToFE(joules)
    if not jouleFactor then
        local helper = rawget(_G, "mekanismEnergyHelper")
        local f = helper and call(helper, "joulesToFE", 1000)
        f = num(f)
        jouleFactor = (f and f > 0) and f / 1000 or 1 / DEFAULT_J_PER_FE
    end
    return joules and joules * jouleFactor
end
function storage_utils.resetConversion() jouleFactor = nil end

local function posKey(p)
    if type(p) ~= "table" then return nil end
    return string.format("%s,%s,%s", tostring(p.x), tostring(p.y), tostring(p.z))
end

local READERS = {}

function READERS.mek_matrix(dev)
    if hasMethod(dev, "isFormed") and call(dev, "isFormed") ~= true then
        return {formed = false}
    end
    local stored, capacity = num(call(dev, "getEnergy")), num(call(dev, "getMaxEnergy"))
    if not stored or not capacity then return nil, "matrix read failed" end
    local j = storage_utils.joulesToFE
    return {stored = j(stored), capacity = j(capacity),
            input = j(num(call(dev, "getLastInput"))), output = j(num(call(dev, "getLastOutput")))}
end

function READERS.mek_cube(dev)
    local stored, capacity = num(call(dev, "getEnergy")), num(call(dev, "getMaxEnergy"))
    if not stored or not capacity then return nil, "energy cube read failed" end
    return {stored = storage_utils.joulesToFE(stored), capacity = storage_utils.joulesToFE(capacity)}
end

local function notation(dev, method)
    local n = call(dev, method)
    if type(n) == "table" and num(n.coefficient) and num(n.exponent) then
        return n.coefficient * 10 ^ n.exponent
    end
end

function READERS.draconic(dev)
    local stored, capacity = num(call(dev, "getEnergyStored")), num(call(dev, "getMaxEnergyStored"))
    if not stored or not capacity then return nil, "pylon read failed" end
    -- Tier 8 cores pass Long.MAX; the notation methods carry the rest.
    if stored >= LONG_SATURATED then stored = notation(dev, "getEnergyStoredInNotation") or stored end
    if capacity >= LONG_SATURATED then capacity = notation(dev, "getMaxEnergyStoredInNotation") or capacity end
    local r = {stored = stored, capacity = capacity}
    r.input, r.output = num(call(dev, "getInputPerTick")), num(call(dev, "getOutputPerTick"))
    if not (r.input and r.output) then
        r.input, r.output = nil, nil
        r.net = num(call(dev, "getTransferPerTick"))
    end
    return r
end

function READERS.flux(dev)
    local stored, capacity = num(call(dev, "getEnergy")), num(call(dev, "getEnergyCapacity"))
    if not stored or not capacity then return nil, "flux controller read failed" end
    local stats = call(dev, "getStatistic")
    local r = {stored = stored, capacity = capacity}
    if type(stats) == "table" then
        r.input, r.output = num(stats.energyInput), num(stats.energyOutput)
    end
    return r
end

function READERS.powah(dev)
    local stored = num(call(dev, "getEnergy")) or num(call(dev, "getStoredEnergy"))
    local capacity = num(call(dev, "getMaxEnergy"))
    if not stored or not capacity then return nil, "cell read failed" end
    return {stored = stored, capacity = capacity}
end

function READERS.generic(dev)
    local stored, capacity = num(call(dev, "getEnergy")), num(call(dev, "getEnergyCapacity"))
    if not stored or not capacity then return nil, "energy read failed" end
    return {stored = stored, capacity = capacity,
            saturated = stored >= INT_MAX or capacity >= INT_MAX}
end

function READERS.meter(dev)
    local rate = num(call(dev, "getTransferRate"))
    if not rate then return nil, "energy detector read failed" end
    return {rate = rate, limit = num(call(dev, "getTransferRateLimit"))}
end

-- Kinds where several peripherals can be views of one store and the only
-- tell is identical readings (EnderIO bank blocks, Powah ender cells,
-- matrices without position data).
local function sharedType(kind, primary)
    primary = tostring(primary or "")
    return (kind == "generic" and (primary:find("capacitor_bank") or primary:find("ender_cell")))
        or (kind == "powah" and primary == "enderCell")
        or kind == "mek_matrix"
end

function storage_utils.wrap(kind, name, dev, primaryType)
    local reader = READERS[kind]
    if not reader then return nil end
    local a = {kind = kind, name = name, dev = dev, mod = MOD_LABELS[kind],
               type = primaryType, shared = sharedType(kind, primaryType) and true or false}
    function a.read()
        local ok, r, err = pcall(reader, a.dev)
        if not ok then return nil, tostring(r) end
        return r, err
    end
    -- Same physical store -> same key.
    function a.key()
        if kind == "mek_matrix" then
            local lo, hi = posKey(call(dev, "getMinPos")), posKey(call(dev, "getMaxPos"))
            if lo and hi then return "mek:" .. lo .. ":" .. hi end
        elseif kind == "flux" then
            local net = call(dev, "getNetwork")
            if type(net) == "table" and net.id ~= nil then return "flux:" .. tostring(net.id) end
        end
        return nil
    end
    return a
end

-- Default display name: "Energy Core", "Induction Matrix", or the block
-- id made readable ("enderio:basic_capacitor_bank" -> "Basic Capacitor Bank").
function storage_utils.defaultName(kind, primaryType)
    if kind == "draconic" then return "Energy Core" end
    if kind == "mek_matrix" then return "Induction Matrix" end
    if kind == "mek_cube" then return "Energy Cube" end
    if kind == "flux" then return "Flux Network" end
    if kind == "meter" then return "Energy Meter" end
    if kind == "powah" then return primaryType == "enderCell" and "Ender Cell" or "Energy Cell" end
    local id = tostring(primaryType or "storage"):gsub("^.-:", ""):gsub("_", " ")
    id = id:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end)
    -- Fit an overview card beside its status: drop trailing words.
    while #id > 17 and id:find(" ") do id = id:gsub(" [^ ]*$", "") end
    id = id:sub(1, 17)
    return id ~= "" and id or "Storage"
end

-- Shell-style matching for config include/exclude: exact or with * globs.
function storage_utils.matches(list, name)
    for _, pattern in ipairs(list or {}) do
        if pattern == name then return true end
        if type(pattern) == "string" and pattern:find("*", 1, true) then
            local lua = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
            if name:find(lua) then return true end
        end
    end
    return false
end

-- Two readings of one store taken moments apart.
function storage_utils.sameReading(a, b)
    if not a or not b or not a.capacity or not b.capacity then return false end
    return a.capacity == b.capacity and a.stored == b.stored
end

------------------------------------------------------------
-- FLOW TRACKING
------------------------------------------------------------
local function ema(prev, value, dt, tau)
    if value == nil then return nil end
    if prev == nil or not dt or dt <= 0 then return value end
    local alpha = 1 - math.exp(-dt / tau)
    return prev + (value - prev) * alpha
end
storage_utils.ema = ema

-- Seconds until full (net > 0) or empty (net < 0); net in FE/t.
function storage_utils.eta(stored, capacity, net)
    if not net or not stored or not capacity or net == 0 then return nil, nil end
    local perSecond = net * TICKS_PER_SECOND
    if net > 0 then return math.max(0, capacity - stored) / perSecond, nil end
    return nil, stored / -perSecond
end

local Tracker = {}
Tracker.__index = Tracker

function storage_utils.newTracker(tau)
    return setmetatable({tau = tau or FLOW_TAU}, Tracker)
end

-- raw: adapter reading; now: seconds (os.clock()). Mod-reported rates
-- win; otherwise net flow is the smoothed change in stored energy.
function Tracker:update(raw, now)
    if not raw or raw.formed == false then
        self.lastStored, self.lastAt = nil, nil
        return raw and {formed = false} or nil
    end
    if raw.rate then                                   -- flow meter
        self.rate = ema(self.rate, raw.rate, now and self.lastAt and now - self.lastAt, self.tau)
        self.lastAt = now
        return {rate = self.rate, limit = raw.limit, meter = true}
    end
    local dt = now and self.lastAt and (now - self.lastAt) or nil
    local derived
    if dt and dt > 0 and self.lastStored then
        derived = (raw.stored - self.lastStored) / (dt * TICKS_PER_SECOND)
    end
    self.lastStored, self.lastAt = raw.stored, now

    local measured = raw.input ~= nil or raw.output ~= nil or raw.net ~= nil
    self.input = ema(self.input, raw.input, dt, self.tau)
    self.output = ema(self.output, raw.output, dt, self.tau)
    local net
    if raw.input and raw.output then
        net = raw.input - raw.output
    elseif raw.net then
        net = raw.net
    else
        net = derived
    end
    if net ~= nil then
        self.net = ema(self.net, net, dt, self.tau)
    end

    local net2 = self.net
    local toFull, toEmpty = storage_utils.eta(raw.stored, raw.capacity, net2)
    return {
        stored = raw.stored, max = raw.capacity,
        pct = raw.capacity > 0 and math.min(1, raw.stored / raw.capacity) or 0,
        input = self.input, output = self.output,
        net = net2, transfer = net2,
        timeToFull = toFull, timeToEmpty = toEmpty,
        measured = measured, saturated = raw.saturated
    }
end

------------------------------------------------------------
-- ENERGY NETWORK
------------------------------------------------------------
local PASSIVE = {storage = true, meter = true, network = true}
storage_utils.PASSIVE = PASSIVE

-- units: manager units (with summary() and, for storage, info).
-- generation  sum of producing units' summary().power (FE/t)
-- net         sum of storage net flow (+ charging)
-- consumption generation - net (what the base used, incl. injectors)
function storage_utils.network(units)
    local agg = {generation = 0, stored = 0, capacity = 0, net = 0,
                 producers = 0, storages = 0, unknownFlow = 0}
    for _, u in ipairs(units or {}) do
        if PASSIVE[u.kind] then
            local i = u.kind == "storage" and u.info
            if i and i.max then
                agg.storages = agg.storages + 1
                agg.stored = agg.stored + (i.stored or 0)
                agg.capacity = agg.capacity + (i.max or 0)
                if i.net then agg.net = agg.net + i.net else agg.unknownFlow = agg.unknownFlow + 1 end
            end
        elseif u.summary then
            local ok, s = pcall(u.summary)
            if ok and type(s) == "table" and num(s.power) then
                agg.generation = agg.generation + math.max(0, s.power)
                agg.producers = agg.producers + 1
            end
        end
    end
    agg.pct = agg.capacity > 0 and math.min(1, agg.stored / agg.capacity) or 0
    agg.consumption = math.max(0, agg.generation - agg.net)
    agg.timeToFull, agg.timeToEmpty = storage_utils.eta(agg.stored, agg.capacity, agg.net)
    if agg.net > 0 then agg.state = "charging"
    elseif agg.net < 0 then agg.state = "draining"
    else agg.state = "balanced" end
    return agg
end

return storage_utils
