--==============================================================
-- ENERGY CORE UTILITIES
-- Save as: energy_core_utils.lua
--==============================================================

--[[
README
-------
Optional, read-only monitoring of a Draconic Evolution energy core
through its energy pylon. The reactor is controlled without it; when no
core is found the UI simply shows "Core: not connected".

  energy_core_utils.discover(name)  Wrap a configured or detected core
  energy_core_utils.read(core)      {stored, max, pct, transfer}

The transfer rate comes from getTransferPerTick() when the pylon offers
it, otherwise it is estimated from the change in stored energy.
]]

local energy_core_utils = {}

local function hasMethod(dev, name)
    return type(dev) == "table" and type(dev[name]) == "function"
end

local function isCore(dev)
    -- Flux gates and the reactor never expose getMaxEnergyStored.
    return hasMethod(dev, "getEnergyStored")
        and hasMethod(dev, "getMaxEnergyStored")
        and not hasMethod(dev, "getReactorInfo")
        and not hasMethod(dev, "getFlow")
end

-- Returns {name, dev} or nil plus a reason.
function energy_core_utils.discover(configuredName)
    if configuredName then
        if peripheral.isPresent(configuredName) then
            local dev = peripheral.wrap(configuredName)
            if isCore(dev) then
                return {name = configuredName, dev = dev}
            end
            return nil, configuredName .. " is not an energy storage peripheral"
        end
        return nil, configuredName .. " is not attached"
    end

    -- Prefer Draconic pylons by type, then any RF storage peripheral.
    local fallback = nil
    for _, name in ipairs(peripheral.getNames()) do
        local dev = peripheral.wrap(name)
        if isCore(dev) then
            local kind = tostring(peripheral.getType(name))
            if kind:find("draconic") or kind:find("pylon") then
                return {name = name, dev = dev}
            end
            fallback = fallback or {name = name, dev = dev}
        end
    end
    if fallback then
        return fallback
    end
    return nil, "no energy core found"
end

function energy_core_utils.read(core, now)
    if not core then
        return nil
    end
    local ok, stored = pcall(core.dev.getEnergyStored)
    local okMax, max = pcall(core.dev.getMaxEnergyStored)
    if not ok or not okMax or type(stored) ~= "number" or type(max) ~= "number" then
        return nil
    end

    local transfer = nil
    if hasMethod(core.dev, "getTransferPerTick") then
        local okT, value = pcall(core.dev.getTransferPerTick)
        if okT and type(value) == "number" then
            transfer = value
        end
    end
    if transfer == nil and now and core.lastStored and core.lastAt and now > core.lastAt then
        -- 20 game ticks per second.
        transfer = (stored - core.lastStored) / ((now - core.lastAt) * 20)
    end
    core.lastStored, core.lastAt = stored, now

    return {
        stored   = stored,
        max      = max,
        pct      = max > 0 and stored / max or 0,
        transfer = transfer
    }
end

return energy_core_utils
