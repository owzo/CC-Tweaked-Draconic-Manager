--==============================================================
-- INTERACTIVE SIMULATED PLANT FOR CRAFTOS-PC (development only)
-- Inside CraftOS-PC, with the repository copied or mounted:
--   <repo>/tools/craftos/sim_world [all|draconic|extreme|mekanism]
--==============================================================

--[[
README
-------
CraftOS-PC (https://www.craftos-pc.cc) emulates a ComputerCraft computer
on your desktop: monitors open in their own windows with the real CC
font, palette and teletext characters, and clicking a monitor window is
a monitor touch. This script:

  1. creates two emulated monitors (periphemu) on the top and left sides
  2. adds the simulated reactors as peripherals (tools/craftos/plant.lua)
  3. ticks the simulators 20 times per second
  4. runs main_control.lua unchanged

It shows real CC rendering and touch handling. It does not show the
mods' real peripheral behaviour or Minecraft server timing: the
simulators are approximations (tests/*_sim.lua).

Keys on the computer screen while it runs:
  c  cut / restore the Mekanism reactor's coolant supply (SCRAM test)
  Hold Ctrl+T to stop.
]]

local args = {...}

-- CC paths are absolute: find the repository from this script's location
-- (<root>/tools/craftos/sim_world.lua).
local root = fs.getDir(fs.getDir(fs.getDir(shell.getRunningProgram())))
local function path(p) return "/" .. fs.combine(root, p) end

if not periphemu then
    printError("periphemu not found: this script needs CraftOS-PC (https://www.craftos-pc.cc).")
    return
end
if not fs.exists(path("main_control.lua")) or not fs.exists(path("tests/reactor_sim.lua")) then
    printError("main_control.lua or tests/ not found under /" .. root .. ": copy the whole repository.")
    return
end

local plant = dofile(path("tools/craftos/plant.lua"))
local p, err = plant.setup(root, args[1] or "all")
if not p then
    printError(err .. ". Use all, draconic, extreme or mekanism.")
    return
end

-- Monitors: each opens as a window; click it to touch.
for _, name in ipairs({"top", "left"}) do
    if not plant.real.isPresent(name) then periphemu.create(name, "monitor") end
end

local function keyLoop()
    while true do
        local _, ch = os.pullEventRaw("char")
        if ch == "c" and p.mek then
            p.mek.coolantSupply = (p.mek.coolantSupply or 0) > 0 and 0 or 0.05
            print(p.mek.coolantSupply > 0 and "[sim] coolant restored" or "[sim] coolant supply cut")
        end
    end
end

print("[sim] plant: " .. (args[1] or "all") .. "  (c = toggle Mekanism coolant)")
parallel.waitForAny(function() shell.run(path("main_control.lua")) end,
                    function() plant.loop(p) end, keyLoop)
