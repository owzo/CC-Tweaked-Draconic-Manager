--==============================================================
-- SIMULATED PLANT FOR CRAFTOS-PC (development only)
-- Loaded by tools/craftos/sim_world.lua and tools/craftos/scenario.lua
--==============================================================

--[[
README
-------
CraftOS-PC cannot load Draconic Evolution, Extreme Reactors or Mekanism.
This module stands in for them: it wraps the peripheral API so the test
simulators (tests/*_sim.lua) appear as peripherals, next to anything
real (such as periphemu monitors).

  local plant = dofile(".../plant.lua")
  local p = plant.setup(root, "all")   -- or "draconic", "extreme", "mekanism"
  p.tick()                             -- advance every simulator 1 game tick
  p.mek                                -- Mekanism simulator (fault injection)
  p.de, p.er, p.core                   -- the other simulators

Peripheral names match what the mods expose in game: draconic_reactor_0,
flow_gate_0/1, draconic_rf_storage_0, BigReactors-Reactor_0,
BigReactors-Turbine_0, fissionReactorPort_0, turbineValve_0.
]]

local plant = {}

-- Replaces peripheral.* so `fakes` (name -> {types, dev}) are visible.
local function installShim(fakes)
    local real = {}
    for k, v in pairs(peripheral) do real[k] = v end
    plant.real = real

    local function fakeOf(p)
        if type(p) == "string" then return fakes[p] end
        for _, f in pairs(fakes) do
            if f.dev == p then return f end
        end
    end

    function peripheral.getNames()
        local names = real.getNames()
        for name in pairs(fakes) do table.insert(names, name) end
        table.sort(names)
        return names
    end

    function peripheral.isPresent(name)
        return fakes[name] ~= nil or real.isPresent(name)
    end

    function peripheral.getType(p)
        local f = fakeOf(p)
        if f then return table.unpack(f.types) end
        return real.getType(p)
    end

    function peripheral.hasType(p, kind)
        local f = fakeOf(p)
        if not f then return real.hasType(p, kind) end
        for _, t in ipairs(f.types) do
            if t == kind then return true end
        end
        return false
    end

    function peripheral.wrap(name)
        local f = fakes[name]
        if f then return f.dev end
        return real.wrap(name)
    end

    function peripheral.getName(p)
        for name, f in pairs(fakes) do
            if f.dev == p then return name end
        end
        return real.getName(p)
    end

    function peripheral.getMethods(name)
        local f = fakes[name]
        if not f then return real.getMethods(name) end
        local out = {}
        for method in pairs(f.dev) do table.insert(out, method) end
        return out
    end

    function peripheral.call(name, method, ...)
        local f = fakes[name]
        if f then return f.dev[method](...) end
        return real.call(name, method, ...)
    end

    function peripheral.find(kind, filter)
        local out = {}
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.hasType(name, kind) then
                local dev = peripheral.wrap(name)
                if not filter or filter(name, dev) then table.insert(out, dev) end
            end
        end
        return table.unpack(out)
    end
end

-- root: repository directory (CC path, no leading slash needed).
function plant.setup(root, which)
    which = which or "all"
    local function path(p) return "/" .. fs.combine(root, p) end
    local Sim = dofile(path("tests/reactor_sim.lua"))
    local ErSim = dofile(path("tests/er_sim.lua"))
    local MekSim = dofile(path("tests/mek_sim.lua"))

    local fakes, tickers, p = {}, {}, {}
    local function add(name, kind, dev)
        fakes[name] = {types = type(kind) == "table" and kind or {kind}, dev = dev}
    end

    if which == "all" or which == "draconic" then
        local de = Sim.new({version = "1.20"})
        add("draconic_reactor_0", "draconic_reactor", de.reactor)
        add("flow_gate_0", "flow_gate", de.inGate)
        add("flow_gate_1", "flow_gate", de.outGate)
        settings.set("draconic.inputGate", "flow_gate_0")
        settings.set("draconic.outputGate", "flow_gate_1")
        -- Energy core: fills with the reactor's output, drained by a fixed load.
        local core = {stored = 4.2e11, max = 1e12, transfer = 0, load = 2e7}
        add("draconic_rf_storage_0", "draconic_rf_storage", {
            getEnergyStored = function() return core.stored end,
            getMaxEnergyStored = function() return core.max end,
            getTransferPerTick = function() return core.transfer end})
        table.insert(tickers, function()
            de:tick()
            core.transfer = (de.outFlow or 0) - (de.inFlow or 0) - core.load
            core.stored = math.max(0, math.min(core.max, core.stored + core.transfer))
        end)
        p.de, p.core = de, core
    end

    if which == "all" or which == "extreme" then
        local er = ErSim.new({activelyCooled = true, maxOutput = 3000, turbines = 1, turbineLoad = 6000})
        add("BigReactors-Reactor_0", "BigReactors-Reactor", er.erReactor)
        add("BigReactors-Turbine_0", "BigReactors-Turbine", er.erTurbines[1])
        table.insert(tickers, function() er:tick() end)
        p.er = er
    end

    if which == "all" or which == "mekanism" then
        local mek = MekSim.new({active = true, burn = 12, temperature = 600})
        add("fissionReactorPort_0", "fissionReactorPort", mek.fission)
        add("turbineValve_0", "turbineValve", mek.turbine)
        table.insert(tickers, function() mek:tick() end)
        p.mek = mek
    end

    if #tickers == 0 then return nil, "unknown plant '" .. tostring(which) .. "'" end
    installShim(fakes)
    function p.tick()
        for _, tick in ipairs(tickers) do tick() end
    end
    return p
end

-- sleep() that ignores "terminate", so Ctrl+T stops the manager (which
-- then runs its fail-safe) rather than the simulators first.
function plant.sleep(seconds)
    local timer = os.startTimer(seconds)
    repeat
        local _, id = os.pullEventRaw("timer")
    until id == timer
end

-- Coroutine body: advances the simulators by the real time elapsed
-- (20 ticks per second, at most 1 s at once).
function plant.loop(p)
    local TICK = 0.05
    local last = os.clock()
    while true do
        plant.sleep(TICK)
        local now = os.clock()
        local steps = math.min(20, math.floor((now - last) / TICK + 0.5))
        for _ = 1, steps do p.tick() end
        last = last + steps * TICK
    end
end

return plant
