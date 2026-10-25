--==============================================================
-- DRIVER: ENERGY STORAGE (read-only)
-- Save as: drivers/storage.lua
--==============================================================

--[[
README
-------
Wraps storage_utils as read-only units (same contract as
drivers/draconic.lua):

  kind "storage"  one per energy store (Draconic core pylon, Mekanism
                  induction matrix / energy cube, Flux network, Powah,
                  EnderIO, Thermal and any other Forge-energy block)
  kind "meter"    Advanced Peripherals energy detectors (flow only)
  kind "network"  one "Energy Network" aggregate: generation of every
                  producing unit, storage totals, net flow into storage
                  and estimated consumption (generation - net flow)

Peripherals owned by another driver (Draconic reactors and flux gates,
Extreme/Bigger Reactors reactors and turbines) are skipped, and two
peripherals that are views of one store (several ports of one induction
matrix, several blocks of one EnderIO capacitor bank) are counted once.

config.storage = {enabled, include, exclude, names, pollInterval}; the
old config.peripherals.energyCore still works and becomes the primary
storage (the one shown on Draconic reactor pages).

Discovery can run again for hot-plugged peripherals: when ctx.known(id)
exists, units it reports are skipped.
]]

local driver = {id = "storage", label = "Energy Storage"}

local POLL_INTERVAL = 1        -- seconds; every call costs a server tick
local LINK_LOST_LIMIT = 5      -- failed reads before re-wrapping
local NETWORK_ID = "storage:energy_network"
local STATS_COLUMNS = {"stored", "capacity", "pct", "input", "output", "net"}
local NETWORK_COLUMNS = {"generation", "consumption", "net", "stored", "capacity", "pct"}

-- Units created by this driver that are still running (hot-plug dedupe).
local live = {}

local function slug(text)
    return (tostring(text):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

local function typesOf(name)
    local types = {peripheral.getType(name)}
    return types
end

-- Is the peripheral controlled by another driver?
local function ownedElsewhere(ctx, name, dev)
    local okR, reac = pcall(ctx.import, "reac_utils")
    if okR and type(reac) == "table" then
        if reac.isReactor and reac.isReactor(dev) then return true end
        if reac.isGate and reac.isGate(dev) then return true end
    end
    local okE, er = pcall(ctx.import, "er_utils")
    if okE and type(er) == "table" and er.classify then
        local ok, kind = pcall(er.classify, name, dev)
        if ok and kind then return true end
    end
    return false
end

------------------------------------------------------------
-- UNITS
------------------------------------------------------------
local function newStorageUnit(ctx, su, adapter, name, poll)
    local isMeter = adapter.kind == "meter"
    local unit = {
        id = (adapter.kind == "draconic" and "energy_core:" or "storage:") .. adapter.name,
        name = name,
        kind = isMeter and "meter" or "storage",
        driver = driver.id,
        mod = adapter.mod,
        adapter = adapter,
        tracker = su.newTracker(),
        info = nil
    }
    local failed = 0

    function unit.poll()
        local raw, err = unit.adapter.read()
        unit.info = unit.tracker:update(raw, os.clock())
        if raw then
            failed = 0
        else
            failed = failed + 1
            if failed == 1 then ctx.log.log("WARN", "[" .. unit.name .. "] " .. tostring(err)) end
            if failed >= LINK_LOST_LIMIT and peripheral.isPresent(adapter.name) then
                unit.adapter.dev = peripheral.wrap(adapter.name)
                failed = 0
            end
        end
        return raw
    end

    function unit.run()
        while true do
            unit.poll()
            sleep(poll)
        end
    end

    function unit.model()
        return {id = unit.id, name = unit.name, kind = unit.kind, info = unit.info,
                mod = unit.mod, peripheral = adapter.name}
    end

    function unit.summary()
        local i = unit.info
        local status = "no signal"
        if i then status = i.formed == false and "unformed" or "online" end
        return {status = status, power = nil, alarm = nil}
    end

    function unit.act() return false end
    function unit.failSafe() end
    function unit.record()
        local i = unit.info
        if not i or isMeter or not i.max then return end
        ctx.log.recordRow("storage_" .. slug(unit.name), STATS_COLUMNS, {
            stored = i.stored, capacity = i.max, pct = i.pct,
            input = i.input, output = i.output, net = i.net})
    end
    return unit
end

local function newNetworkUnit(ctx, su)
    local unit = {id = NETWORK_ID, name = "Energy Network", kind = "network",
                  driver = driver.id, info = nil}

    local function allUnits()
        if ctx.units then return ctx.units() end
        local list = {}
        for _, u in pairs(live) do table.insert(list, u) end
        return list
    end

    function unit.refresh()
        unit.info = su.network(allUnits())
        return unit.info
    end

    function unit.run()
        while true do
            unit.refresh()
            sleep(POLL_INTERVAL)
        end
    end

    function unit.model()
        return {id = unit.id, name = unit.name, kind = unit.kind, info = unit.refresh()}
    end

    function unit.summary()
        return {status = unit.info and unit.info.state or "no signal", power = nil, alarm = nil}
    end

    function unit.act() return false end
    function unit.failSafe() end
    function unit.record()
        local a = unit.info
        if not a then return end
        ctx.log.recordRow("energy_network", NETWORK_COLUMNS, {
            generation = a.generation, consumption = a.consumption, net = a.net,
            stored = a.stored, capacity = a.capacity, pct = a.pct})
    end
    return unit
end

------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------
local RANK = {draconic = 1, mek_matrix = 2, flux = 3, mek_cube = 4, powah = 5, generic = 6, meter = 9}

function driver.discover(ctx)
    local su = ctx.import("storage_utils")
    local scfg = ctx.config.storage or {}
    local pcfg = ctx.config.peripherals or {}
    local primary = pcfg.energyCore
    if scfg.enabled == false then return {} end
    local include, exclude, names = scfg.include or {}, scfg.exclude or {}, scfg.names or {}
    local poll = tonumber(scfg.pollInterval) or POLL_INTERVAL
    local known = ctx.known

    -- A full discovery starts over; a rescan keeps what is still running.
    if not known then
        live = {}
    else
        for id in pairs(live) do
            if not known(id) then live[id] = nil end
        end
    end

    local problem
    if primary and not peripheral.isPresent(primary) then
        problem = "Energy core: " .. primary .. " is not attached"
    end

    local candidates = {}
    for _, name in ipairs(peripheral.getNames()) do
        local forced = name == primary or su.matches(include, name)
        local allowed = not su.matches(exclude, name) and (#include == 0 or forced)
        local dev = allowed and peripheral.wrap(name)
        if dev and not ownedElsewhere(ctx, name, dev) then
            local types = typesOf(name)
            local kind, why = su.classify(name, dev, types)
            if not kind and why == "transit" and forced then kind = "generic" end
            if kind then
                local adapter = su.wrap(kind, name, dev, types[1])
                if adapter then table.insert(candidates, adapter) end
            elseif name == primary then
                problem = "Energy core: " .. name .. " is not an energy storage peripheral"
            end
        end
    end

    -- Units already running: their readings and keys take part in dedupe.
    local seen = {}
    for _, u in pairs(live) do
        if u.adapter then
            table.insert(seen, {adapter = u.adapter, key = u.adapter.key(),
                                raw = u.adapter.shared and u.adapter.read() or nil, live = true})
        end
    end

    local kept = {}
    for _, a in ipairs(candidates) do
        local id = (a.kind == "draconic" and "energy_core:" or "storage:") .. a.name
        if not (known and known(id)) then
            local key = a.key()
            local raw = a.shared and a.read() or nil
            local dup
            for _, s in ipairs(seen) do
                if key and s.key == key then dup = s
                elseif a.shared and s.adapter.shared and s.adapter.kind == a.kind
                        and s.adapter.type == a.type and su.sameReading(raw, s.raw) then
                    dup = s
                end
                if dup then break end
            end
            if dup then
                ctx.log.log("INFO", "Storage: " .. a.name .. " is part of " .. dup.adapter.name .. "; counted once")
            else
                local entry = {adapter = a, key = key, raw = raw}
                table.insert(seen, entry)
                table.insert(kept, a)
            end
        end
    end

    table.sort(kept, function(x, y)
        local px, py = x.name == primary and 0 or RANK[x.kind], y.name == primary and 0 or RANK[y.kind]
        if px ~= py then return px < py end
        return x.name < y.name
    end)

    -- Names: config wins, then a default numbered per name.
    local used = {}
    for _, u in pairs(live) do used[u.name] = true end
    local units = {}
    for _, a in ipairs(kept) do
        local name = names[a.name]
        if not name then
            local base, n = su.defaultName(a.kind, a.type), 1
            name = base
            while used[name] do
                n = n + 1
                name = base .. " " .. n
            end
        end
        used[name] = true
        local unit = newStorageUnit(ctx, su, a, name, poll)
        unit.poll()
        live[unit.id] = unit
        table.insert(units, unit)
        ctx.log.log("INFO", string.format("Storage: %s (%s, %s)", name, a.name, a.mod))
    end

    -- One network aggregate once any real store exists.
    local hasStore, hasNetwork = false, live[NETWORK_ID] ~= nil or (known and known(NETWORK_ID))
    for _, u in pairs(live) do
        if u.kind == "storage" then hasStore = true end
    end
    if hasStore and not hasNetwork then
        local net = newNetworkUnit(ctx, su)
        live[net.id] = net
        table.insert(units, net)
    end
    return units, problem
end

return driver
