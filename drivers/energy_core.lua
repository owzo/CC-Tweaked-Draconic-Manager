--==============================================================
-- DRIVER: DRACONIC ENERGY CORE (read-only)
-- Save as: drivers/energy_core.lua
--==============================================================

--[[
README
-------
Wraps energy_core_utils as read-only "storage" units, one per energy
pylon. Same contract as drivers/draconic.lua; storage units have no
actions and leave nothing to make safe on exit.
]]

local driver = {id = "energy_core", label = "Draconic Energy Core"}

local POLL_INTERVAL = 1        -- seconds; storage changes slowly

function driver.discover(ctx)
    local ecu = ctx.import("energy_core_utils")
    local configured = ctx.config.peripherals and ctx.config.peripherals.energyCore
    local core, why = ecu.discover(configured)
    if not core then
        return {}, configured and ("Energy core: " .. tostring(why)) or nil
    end

    local unit = {
        id = "energy_core:" .. core.name,
        name = "Energy Core",
        kind = "storage",
        driver = driver.id,
        core = core,
        info = nil
    }
    ctx.log.log("INFO", "Energy core: " .. core.name)

    function unit.run()
        while true do
            unit.info = ecu.read(unit.core, os.clock())
            sleep(POLL_INTERVAL)
        end
    end

    function unit.model() return {id = unit.id, name = unit.name, kind = unit.kind, info = unit.info} end

    function unit.summary()
        return {status = unit.info and "online" or "no signal",
                power = unit.info and unit.info.transfer, alarm = nil}
    end

    function unit.act() return false end
    function unit.failSafe() end
    function unit.record() end

    return {unit}
end

return driver
