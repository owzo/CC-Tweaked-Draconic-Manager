--==============================================================
-- MONITOR UTILITIES
-- Save as: monitor_utils.lua
--==============================================================

--[[
README
-------
Touchscreen dashboard. Works on any number of monitors and falls back
to the computer's own screen (mouse clicks) when no monitor exists.

  monitor_utils.init(monitorNames, uiCfg)  Prepare display targets
  monitor_utils.render(model)              Redraw every target
  monitor_utils.handleTouch(name, x, y)    Return the action string of the
                                           button at (x, y), or nil

Layout needs 29x15 characters and looks best at 29x19 or larger: a 3x3
block advanced monitor at text scale 1.0, or a 2x2 at scale 0.5 (chosen
automatically). Spacer rows are dropped first on smaller screens.

Button actions:
  "out:<delta>"  adjust manual output (switches to manual mode)
  "start"        charge + activate, clear a latched trip
  "stop"         controlled shutdown
  "auto"         toggle automatic output regulation (AU / MA button)
]]

local monitor_utils = {}

local MIN_WIDTH, MIN_HEIGHT = 29, 15
local TERMINAL = "term"

local targets = {}     -- name -> {name, dev, win, buttons}
local order = {}       -- names in display order
local uiSettings = {manualStep = {1000, 10000, 100000}}

------------------------------------------------------------
-- FORMATTING
------------------------------------------------------------
local SUFFIXES = {{1e12, "T"}, {1e9, "G"}, {1e6, "M"}, {1e3, "k"}}

function monitor_utils.formatRF(value)
    value = tonumber(value) or 0
    local magnitude = math.abs(value)
    for _, s in ipairs(SUFFIXES) do
        if magnitude >= s[1] then
            return string.format("%.1f%s", value / s[1], s[2])
        end
    end
    return string.format("%.0f", value)
end

local function pctColor(pct, low, high)
    if pct < low then return colors.red end
    if pct < high then return colors.orange end
    return colors.green
end

local function tempColor(temp, target, max)
    if temp > max then return colors.red end
    if temp > target + (max - target) * 0.5 then return colors.orange end
    return colors.green
end

local STATUS_COLORS = {
    running = colors.green, warming_up = colors.yellow,
    stopping = colors.orange, cooling = colors.lightBlue,
    cold = colors.lightGray, beyond_hope = colors.red
}

------------------------------------------------------------
-- TARGET SETUP
------------------------------------------------------------
local function pickScale(dev, preferred)
    if preferred then
        dev.setTextScale(preferred)
        return
    end
    for _, scale in ipairs({1, 0.5}) do
        dev.setTextScale(scale)
        local w, h = dev.getSize()
        if w >= MIN_WIDTH and h >= MIN_HEIGHT then
            return
        end
    end
end

local function addTarget(name, dev)
    local w, h = dev.getSize()
    targets[name] = {
        name = name,
        dev = dev,
        win = window.create(dev, 1, 1, w, h, true),
        buttons = {}
    }
    table.insert(order, name)
end

-- monitorNames: list of names, or empty to use every attached monitor.
-- Returns the number of monitors in use (0 = terminal fallback).
function monitor_utils.init(monitorNames, uiCfg)
    targets, order = {}, {}
    for k, v in pairs(uiCfg or {}) do uiSettings[k] = v end

    local names = {}
    if monitorNames and #monitorNames > 0 then
        names = monitorNames
    else
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "monitor" then
                table.insert(names, name)
            end
        end
        table.sort(names)
    end

    for _, name in ipairs(names) do
        if peripheral.isPresent(name) and peripheral.getType(name) == "monitor" then
            local dev = peripheral.wrap(name)
            pickScale(dev, uiSettings.textScale)
            addTarget(name, dev)
        end
    end

    local monitors = #order
    if monitors == 0 then
        addTarget(TERMINAL, term.current())
    end
    return monitors
end

function monitor_utils.usesTerminal()
    return targets[TERMINAL] ~= nil
end

function monitor_utils.targetNames()
    return order
end

------------------------------------------------------------
-- DRAWING PRIMITIVES (operate on a window)
------------------------------------------------------------
local function text(win, x, y, str, fg, bg)
    win.setCursorPos(x, y)
    win.setTextColor(fg or colors.white)
    win.setBackgroundColor(bg or colors.black)
    win.write(str)
end

local function centered(win, y, str, fg, bg, width)
    local x = math.max(1, math.floor((width - #str) / 2) + 1)
    text(win, x, y, str, fg, bg)
end

local function bar(win, y, width, pct, color)
    local inner = width - 2
    local filled = math.floor(math.max(0, math.min(1, pct)) * inner + 0.5)
    win.setCursorPos(2, y)
    win.setBackgroundColor(color)
    win.write(string.rep(" ", filled))
    win.setBackgroundColor(colors.gray)
    win.write(string.rep(" ", inner - filled))
    win.setBackgroundColor(colors.black)
end

local function labelValue(win, y, width, label, value, color)
    -- The value wins: a long label is cut rather than overlapped.
    local room = width - #value - 3
    if #label > room then label = label:sub(1, math.max(0, room)) end
    text(win, 2, y, label, colors.white)
    text(win, width - #value, y, value, color or colors.white)
end

-- Lays out `defs` ({label, action, color}) across a row. Buttons share
-- the width equally unless `widths` fixes some of them (nil = flexible).
local function buttonRow(target, y, width, defs, widths)
    local gap = 1
    local count = #defs
    local usable = width - 2 - gap * (count - 1)
    local fixed, flexible = 0, 0
    for i = 1, count do
        if widths and widths[i] then fixed = fixed + widths[i] else flexible = flexible + 1 end
    end
    local each = flexible > 0 and math.floor((usable - fixed) / flexible) or 0
    local sizes, total = {}, 0
    for i = 1, count do
        sizes[i] = (widths and widths[i]) or each
        total = total + sizes[i]
    end
    local x = math.floor((width - (total + gap * (count - 1))) / 2) + 1
    for i, def in ipairs(defs) do
        local size = sizes[i]
        local label = def[1]
        if #label > size then label = label:sub(1, size) end
        local pad = size - #label
        local left = math.floor(pad / 2)
        text(target.win, x, y,
             string.rep(" ", left) .. label .. string.rep(" ", pad - left),
             colors.white, def[3] or colors.blue)
        table.insert(target.buttons, {x1 = x, x2 = x + size - 1, y = y, action = def[2]})
        x = x + size + gap
    end
end

-- 1234567 -> "1,234,567"
local function formatInt(value)
    local s = string.format("%.0f", tonumber(value) or 0)
    local sign, digits = s:match("^(-?)(%d+)$")
    if not digits then return s end
    local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return sign .. (grouped:gsub("^,", ""))
end
monitor_utils.formatInt = formatInt

-- Full figure when it fits beside its label, compact (53.0M) otherwise.
local function fitRate(label, value, width, unit)
    unit = unit or " rf/t"
    local full = formatInt(value) .. unit
    if #label + #full + 3 <= width then return full end
    return monitor_utils.formatRF(value) .. unit
end

------------------------------------------------------------
-- DASHBOARD
------------------------------------------------------------
--[[
model = {
  info       = reac_utils.readInfo() result or nil,
  controller = reac_utils controller,
  core       = primary storage info (storage_utils tracker) or nil,
  limits     = config.reactor,
  events     = stat_utils.recent
}

The screen is built as a list of one-row items, then fitted to the
monitor: spacer rows (and the optional energy core block) carry a
priority and the lowest are dropped first when space runs out. A 3x3
monitor at scale 1 (29x19) shows everything except some spacers.
]]
-- Spacer priorities: the top margin goes first, then all spacers between
-- the bar sections together (so they stay evenly spaced), then the one
-- above the controls, then the one under the status.
local TOP, BARS, CONTROLS, HEADER = 1, 2, 3, 4

-- Shared page scaffolding: tab row, status line, controls and footer.
local function newPage(model)
    local page = {items = {}}
    function page.add(item) table.insert(page.items, item); return item end
    function page.gap(priority, group) page.add({kind = "gap", priority = priority, group = group}) end
    function page.lr(label, value, color) page.add({kind = "lr", label = label, value = value, color = color}) end
    function page.bar(pct, color) page.add({kind = "bar", pct = pct, color = color}) end
    function page.buttons(defs, widths) page.add({kind = "buttons", defs = defs, widths = widths}) end

    -- Navigation row: back to the overview (unless this monitor is pinned
    -- or there is only one unit), the unit's name, graphs and settings.
    function page.nav(title)
        local nav = model.nav or {}
        local defs, widths = {}, {}
        local function add(def, width) table.insert(defs, def); table.insert(widths, width or false) end
        if nav.back then add({"<", "nav:overview", colors.gray}, 3) end
        add({title or model.name or "Unit", "noop", colors.blue})
        if nav.page == "detail" then
            add({"G", "nav:graphs", colors.gray}, 3)
            if model.settings and #model.settings > 0 then add({"S", "nav:settings", colors.gray}, 3) end
        else
            add({"X", "nav:detail", colors.gray}, 3)
        end
        for i, wv in ipairs(widths) do if wv == false then widths[i] = nil end end
        page.buttons(defs, widths)
    end

    function page.header(label, status, color)
        page.gap(TOP)
        page.nav()
        page.lr(label, status, color)
        page.gap(HEADER)
    end

    function page.controls()
        page.gap(CONTROLS)
        page.buttons({{"START", "start", colors.green}, {"STOP", "stop", colors.red}})
        page.add({kind = "footer"})
        return page.items
    end
    return page
end

local LAYOUTS = {}

-- Draconic reactor (drmon-style) ---------------------------------------
function LAYOUTS.draconic(model, w)
    local info, ctl, lim = model.info, model.controller, model.limits
    local page = newPage(model)
    local lr, bar, gap = page.lr, page.bar, page.gap

    local status, statusColor = "NO SIGNAL", colors.red
    if info then
        status = string.upper((info.status:gsub("_", " ")))
        statusColor = STATUS_COLORS[info.status] or colors.red
    end
    page.header("Reactor Status", status, statusColor)

    lr("Generation", info and fitRate("Generation", info.generationRate, w) or "--", colors.lime)
    local tc = info and tempColor(info.temperature, lim.targetTemperature, lim.maxTemperature) or colors.red
    lr("Temperature", info and (formatInt(info.temperature) .. "C") or "--", tc)
    lr(ctl.autoOutput and "Output Gate" or "Output (man)",
       fitRate("Output Gate", ctl.outputRate, w), colors.lightBlue)

    local steps = uiSettings.manualStep
    page.buttons({
        {"<<<", "out:" .. -steps[3], colors.gray},
        {"<<", "out:" .. -steps[2], colors.gray},
        {"<", "out:" .. -steps[1], colors.gray},
        {ctl.autoOutput and "AU" or "MA", "auto", ctl.autoOutput and colors.green or colors.orange},
        {">", "out:" .. steps[1], colors.gray},
        {">>", "out:" .. steps[2], colors.gray},
        {">>>", "out:" .. steps[3], colors.gray}
    })
    lr("Input Gate", fitRate("Input Gate", ctl.inputRate, w), colors.lightBlue)
    gap(BARS, "bars")

    local sat = info and info.satPct or 0
    lr("Energy Saturation", string.format("%.1f%%", sat * 100), colors.white)
    bar(sat, colors.blue)
    gap(BARS, "bars")

    local field = info and info.fieldPct or 0
    local fc = pctColor(field, lim.minField * 1.5, lim.targetField * 0.9)
    lr(string.format("Field Strength T:%d", math.floor(lim.targetField * 100 + 0.5)),
       string.format("%.1f%%", field * 100), fc)
    bar(field, fc)
    gap(BARS, "bars")

    local fuel = info and info.fuelRemaining or 0
    local fuelC = pctColor(fuel, lim.minFuel, lim.minFuel * 3)
    lr("Fuel", string.format("%.1f%%", fuel * 100), fuelC)
    bar(fuel, fuelC)

    local core = model.core
    if core then
        local cc = pctColor(core.pct, 0.1, 0.25)
        local value = string.format("%.1f%%", core.pct * 100)
        if core.transfer then
            local flow = (core.transfer >= 0 and "+" or "") .. monitor_utils.formatRF(core.transfer)
            if #("Energy Core") + #flow + #value + 4 <= w then value = flow .. "  " .. value end
        end
        -- Kept over every spacer; dropped (label and bar together) only
        -- when the essentials would not fit otherwise.
        gap(BARS, "bars")
        page.add({kind = "lr", label = "Energy Core", value = value, color = cc, priority = 10, group = "core"})
        page.add({kind = "bar", pct = core.pct, color = cc, priority = 10, group = "core"})
    end
    return page.controls()
end

-- Shared status line for Extreme/Bigger units.
local function erStatus(d, onText, onColor)
    if not d then return "NO SIGNAL", colors.red end
    if d.assembled == false then return "UNASSEMBLED", colors.orange end
    if d.active then return onText or "ONLINE", onColor or colors.green end
    return "OFFLINE", colors.lightGray
end

-- Extreme / Bigger Reactors fission reactor ----------------------------
function LAYOUTS.fission(model, w)
    local d, ctl, lim = model.data or {}, model.controller, model.limits
    local page = newPage(model)
    local lr, bar, gap = page.lr, page.bar, page.gap
    local ok = model.data and model.data.assembled ~= false

    local status, color = erStatus(model.data, d.activelyCooled and "ONLINE STEAM" or "ONLINE")
    page.header("Reactor Status", status, color)

    if d.activelyCooled then
        lr("Steam", ok and (formatInt(d.steamMade or 0) .. " mB/t") or "--", colors.lime)
    else
        lr("Generation", ok and fitRate("Generation", d.produced or 0, w, " FE/t") or "--", colors.lime)
    end
    lr("Fuel Temp", ok and (formatInt(d.fuelTemp or 0) .. "C") or "--", colors.orange)
    lr("Casing Temp", ok and (formatInt(d.caseTemp or 0) .. "C") or "--", colors.orange)
    lr(ctl.auto and "Control Rods" or "Rods (manual)",
       ok and string.format("%.0f%%", d.rods or 0) or "--", colors.lightBlue)
    page.buttons({
        {"-10", "rods:-10", colors.gray},
        {"-1", "rods:-1", colors.gray},
        {ctl.auto and "AU" or "MA", "auto", ctl.auto and colors.green or colors.orange},
        {"+1", "rods:1", colors.gray},
        {"+10", "rods:10", colors.gray}
    })
    gap(BARS, "bars")

    local level = 0
    if ok then
        if d.activelyCooled then
            level = (d.steamMax or 0) > 0 and d.steam / d.steamMax or 0
        else
            level = (d.capacity or 0) > 0 and d.stored / d.capacity or 0
        end
    end
    local inBand = level >= lim.bufferLow and level <= lim.bufferHigh
    local bc = inBand and colors.green or (level < lim.bufferLow and colors.orange or colors.lightBlue)
    lr(string.format("%s %d-%d", d.activelyCooled and "Steam Tank" or "Energy Buffer",
                     math.floor(lim.bufferLow * 100 + 0.5), math.floor(lim.bufferHigh * 100 + 0.5)),
       string.format("%.1f%%", level * 100), bc)
    bar(level, bc)
    gap(BARS, "bars")

    local fuel = ok and (d.fuelMax or 0) > 0 and d.fuel / d.fuelMax or 0
    local waste = ok and (d.fuelMax or 0) > 0 and (d.waste or 0) / d.fuelMax or 0
    local fuelC = pctColor(fuel, lim.lowFuel or 0.1, (lim.lowFuel or 0.1) * 3)
    lr(string.format("Fuel  Waste %.0f%%", waste * 100), string.format("%.1f%%", fuel * 100), fuelC)
    bar(fuel, fuelC)
    return page.controls()
end

-- Extreme / Bigger Reactors turbine ------------------------------------
local MODE_TEXT = {
    ["spin-up"] = {"SPINNING UP", colors.yellow}, run = {"ONLINE", colors.green},
    idle = {"IDLE (FULL)", colors.lightBlue}, overspeed = {"OVERSPEED", colors.red}
}

function LAYOUTS.turbine(model, w)
    local d, ctl, lim = model.data or {}, model.controller, model.limits
    local page = newPage(model)
    local lr, bar, gap = page.lr, page.bar, page.gap
    local ok = model.data and model.data.assembled ~= false

    local mode = MODE_TEXT[ctl.mode] or {"ONLINE", colors.green}
    local status, color = erStatus(model.data, mode[1], mode[2])
    page.header("Turbine Status", status, color)

    lr("Generation", ok and fitRate("Generation", d.produced or 0, w, " FE/t") or "--", colors.lime)
    local rpm = ok and d.rpm or 0
    local rc = colors.green
    if rpm > lim.maxRPM then rc = colors.red
    elseif math.abs(rpm - lim.targetRPM) > lim.targetRPM * 0.05 then rc = colors.orange end
    lr(string.format("Rotor T:%d", lim.targetRPM), ok and (formatInt(rpm) .. " RPM") or "--", rc)
    bar(rpm / lim.maxRPM, rc)
    lr("Steam Flow", ok and (formatInt(d.flow or 0) .. " mB/t") or "--", colors.lightBlue)
    lr("Coils", ok and (d.coils and "ENGAGED" or "DISENGAGED") or "--",
       d.coils and colors.green or colors.lightGray)
    gap(BARS, "bars")

    local level = ok and (d.capacity or 0) > 0 and d.stored / d.capacity or 0
    lr("Energy Buffer", string.format("%.1f%%", level * 100), colors.white)
    bar(level, colors.blue)
    return page.controls()
end

-- Mekanism ---------------------------------------------------------------
local function mekStatus(d, onText)
    if not d then return "NO SIGNAL", colors.red end
    if d.formed == false then return "NOT FORMED", colors.orange end
    return onText, colors.green
end

local function fracBar(page, label, v, color)
    page.lr(label, v and string.format("%.1f%%", v * 100) or "--", color)
    page.bar(v or 0, color)
end

function LAYOUTS.mek_fission(model, w)
    local d, ctl, lim = model.data or {}, model.controller, model.limits
    local page = newPage(model)
    local status, color
    if ctl.trip then
        status, color = "SCRAMMED", colors.red
    else
        status, color = mekStatus(model.data, d.active and "ACTIVE" or "OFF")
        if model.data and model.data.formed ~= false and not d.active then color = colors.lightGray end
    end
    page.header("Fission Status", status, color)
    page.lr("Burn", string.format("%.1f / %.1f mB/t", d.burnRate or 0, lim.targetBurnRate or d.burnRate or 0),
            colors.lime)
    page.buttons({{"-10", "burn:-10", colors.gray}, {"-1", "burn:-1", colors.gray},
                  {"+1", "burn:1", colors.gray}, {"+10", "burn:10", colors.gray}})
    local t = d.temperature or 0
    local tc = t >= lim.maxTemperature - lim.tempMargin and colors.orange or colors.green
    if t >= lim.maxTemperature then tc = colors.red end
    page.lr(string.format("Temp (scram %d)", lim.maxTemperature), formatInt(t) .. "K", tc)
    page.bar(t / 1200, tc)
    page.lr("Damage", string.format("%d%%", d.damage or 0), (d.damage or 0) > 0 and colors.red or colors.green)
    page.gap(BARS, "bars")
    fracBar(page, "Coolant", d.coolant, pctColor(d.coolant or 0, lim.minCoolant, lim.minCoolant * 2))
    fracBar(page, "Heated Coolant", d.heated, (d.heated or 0) > 0.8 and colors.orange or colors.lightBlue)
    page.gap(BARS, "bars")
    fracBar(page, string.format("Fuel  Waste %.0f%%", (d.waste or 0) * 100), d.fuel,
            pctColor(d.fuel or 0, lim.lowFuel or 0.05, (lim.lowFuel or 0.05) * 3))
    page.gap(CONTROLS)
    page.buttons({{"START", "start", colors.green}, {"SCRAM", "stop", colors.red}})
    page.add({kind = "footer"})
    return page.items
end

function LAYOUTS.mek_turbine(model, w)
    local d = model.data or {}
    local page = newPage(model)
    page.header("Turbine Status", mekStatus(model.data, "ONLINE"))
    page.lr("Generation", fitRate("Generation", d.production or 0, w, " FE/t"), colors.lime)
    page.lr("Steam Flow", formatInt(d.flow or 0) .. " mB/t", colors.lightBlue)
    page.lr("Dumping", tostring(d.dumping or "--"), colors.white)
    page.gap(BARS, "bars")
    fracBar(page, "Steam", d.steam, (d.steam or 0) > 0.9 and colors.orange or colors.lightBlue)
    page.gap(BARS, "bars")
    local e = (d.maxEnergy or 0) > 0 and d.energy / d.maxEnergy or nil
    fracBar(page, "Energy Buffer", e, colors.blue)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

function LAYOUTS.mek_boiler(model, w)
    local d = model.data or {}
    local page = newPage(model)
    page.header("Boiler Status", mekStatus(model.data, "ONLINE"))
    page.lr("Boil Rate", formatInt(d.boilRate or 0) .. " mB/t", colors.lime)
    page.lr("Temperature", formatInt(d.temperature or 0) .. "K", colors.orange)
    page.gap(BARS, "bars")
    fracBar(page, "Water", d.water, pctColor(d.water or 0, 0.1, 0.3))
    page.gap(BARS, "bars")
    fracBar(page, "Steam", d.steam, colors.lightBlue)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

function LAYOUTS.mek_fusion(model, w)
    local d = model.data or {}
    local page = newPage(model)
    page.header("Fusion Status", mekStatus(model.data, d.ignited and "IGNITED" or "COLD"))
    page.lr("Generation", fitRate("Generation", d.production or 0, w, " FE/t"), colors.lime)
    page.lr("Plasma", monitor_utils.formatRF(d.plasma or 0) .. "K", colors.orange)
    page.lr("Case", monitor_utils.formatRF(d.case or 0) .. "K", colors.orange)
    page.lr("Injection", tostring(d.injection or "--"), colors.lightBlue)
    page.buttons({{"-2", "inj:-2", colors.gray}, {"+2", "inj:2", colors.gray}})
    page.gap(BARS, "bars")
    fracBar(page, "D-T Fuel", d.dtFuel, pctColor(d.dtFuel or 0, 0.05, 0.2))
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

local function buildLayout(model, w)
    return (LAYOUTS[model.kind] or LAYOUTS.draconic)(model, w)
end

-- Drops the lowest-priority rows (spacers first, then the core block) until
-- the layout fits `h` rows. Returns nil when even the essentials don't.
local function fitLayout(items, h)
    while #items > h do
        local lowest = nil
        for _, item in ipairs(items) do
            if item.priority and (not lowest or item.priority < lowest) then
                lowest = item.priority
            end
        end
        if not lowest then return nil end
        local group
        for _, item in ipairs(items) do
            if item.priority == lowest then group = item.group; break end
        end
        local kept = {}
        for _, item in ipairs(items) do
            local drop = item.priority == lowest or (group and item.group == group)
            if not drop then table.insert(kept, item) end
        end
        items = kept
    end
    return items
end

-- Energy storage, meters and the energy network ----------------------
-- All in FE (= RF) per tick; see storage_utils.lua.
local function signedRF(v)
    if v == nil then return "--" end
    return (v > 0 and "+" or "") .. monitor_utils.formatRF(v)
end
monitor_utils.signedRF = signedRF

local function flowColor(v)
    if v == nil then return colors.lightGray end
    return v < 0 and colors.orange or colors.lime
end

-- Seconds -> "45s" / "12m 05s" / "3h 20m" / "2d 04h".
local function duration(seconds)
    if not seconds or seconds ~= seconds then return "--" end
    if seconds > 99 * 86400 then return ">99d" end
    seconds = math.floor(seconds + 0.5)
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60) end
    if seconds < 86400 then
        return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
    end
    return string.format("%dd %02dh", math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
end

local function etaRow(page, i)
    if i and i.timeToFull then
        page.lr("Full in", duration(i.timeToFull), colors.lime)
    elseif i and i.timeToEmpty then
        page.lr("Empty in", duration(i.timeToEmpty), colors.orange)
    else
        page.lr("Full/Empty in", "--", colors.lightGray)
    end
end

local function chargeRows(page, pct)
    local c = pctColor(pct, 0.1, 0.25)
    page.lr("Charge", string.format("%.1f%%", pct * 100), c)
    page.bar(pct, c)
end

local function storageStatus(i)
    if not i then return "NO SIGNAL", colors.red end
    if i.formed == false then return "NOT FORMED", colors.orange end
    if i.saturated then return "OVER 2.1G", colors.orange end
    return "ONLINE", colors.green
end

function LAYOUTS.storage(model, w)
    local i = model.info
    local ok = i and i.max ~= nil
    local page = newPage(model)
    local status, sc = storageStatus(i)
    page.header("Storage", status, sc)
    page.lr("Stored", ok and (monitor_utils.formatRF(i.stored) .. " FE") or "--", colors.lime)
    page.lr("Capacity", ok and (monitor_utils.formatRF(i.max) .. " FE") or "--", colors.white)
    page.lr("Input", ok and i.input and (monitor_utils.formatRF(i.input) .. " FE/t") or "--", colors.lightBlue)
    page.lr("Output", ok and i.output and (monitor_utils.formatRF(i.output) .. " FE/t") or "--", colors.lightBlue)
    local net = ok and i.net
    page.lr(ok and not i.measured and "Net (est.)" or "Net Flow",
            net and (signedRF(net) .. " FE/t") or "--", flowColor(net or nil))
    etaRow(page, ok and i)
    page.gap(BARS, "bars")
    chargeRows(page, ok and i.pct or 0)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

function LAYOUTS.meter(model, w)
    local i = model.info
    local page = newPage(model)
    page.header("Energy Meter", i and "ONLINE" or "NO SIGNAL", i and colors.green or colors.red)
    page.lr("Flow", i and (fitRate("Flow", i.rate, w, " FE/t")) or "--", colors.lime)
    page.lr("Limit", i and i.limit and (fitRate("Limit", i.limit, w, " FE/t")) or "--", colors.white)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

local NETWORK_STATES = {charging = {"CHARGING", colors.lime}, draining = {"DRAINING", colors.orange},
                        balanced = {"BALANCED", colors.green}}

function LAYOUTS.network(model, w)
    local a = model.info
    local page = newPage(model)
    local st = a and NETWORK_STATES[a.state] or {"NO DATA", colors.red}
    page.header("Network Status", st[1], st[2])
    page.lr("Generation", a and fitRate("Generation", a.generation, w, " FE/t") or "--", colors.lime)
    page.lr("Consumption", a and fitRate("Consumption", a.consumption, w, " FE/t") or "--", colors.orange)
    page.lr("Storage Net", a and (signedRF(a.net) .. " FE/t") or "--", flowColor(a and a.net))
    page.lr("Stored", a and (monitor_utils.formatRF(a.stored) .. " / " .. monitor_utils.formatRF(a.capacity))
            or "--", colors.white)
    etaRow(page, a)
    page.gap(BARS, "bars")
    chargeRows(page, a and a.pct or 0)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

------------------------------------------------------------
-- OVERVIEW CARDS
------------------------------------------------------------
-- Each returns status, statusColor, line label, line value, value
-- colour, bar fraction, bar colour, power (for the total).
local CARDS = {}

function CARDS.draconic(m)
    local i, ctl, lim = m.info, m.controller, m.limits
    if not i then return "NO SIGNAL", colors.red, "Out --", "--", colors.red, 0, colors.gray, 0 end
    local fc = pctColor(i.fieldPct, lim.minField * 1.5, lim.targetField * 0.9)
    return string.upper((i.status:gsub("_", " "))), STATUS_COLORS[i.status] or colors.red,
        "Out " .. monitor_utils.formatRF(ctl.outputRate),
        formatInt(i.temperature) .. "C", tempColor(i.temperature, lim.targetTemperature, lim.maxTemperature),
        i.fieldPct, fc, ctl.outputRate
end

function CARDS.fission(m)
    local d, lim = m.data, m.limits
    if not d or d.assembled == false then
        return d and "UNASSEMBLED" or "NO SIGNAL", colors.orange, "--", "--", colors.gray, 0, colors.gray, 0
    end
    local level = d.activelyCooled and ((d.steamMax or 0) > 0 and d.steam / d.steamMax or 0)
        or ((d.capacity or 0) > 0 and d.stored / d.capacity or 0)
    local line = d.activelyCooled and ("Steam " .. formatInt(d.steamMade or 0) .. " mB/t")
        or ("Gen " .. monitor_utils.formatRF(d.produced or 0) .. " FE/t")
    local inBand = level >= lim.bufferLow and level <= lim.bufferHigh
    return d.active and "ONLINE" or "OFFLINE", d.active and colors.green or colors.lightGray,
        line, string.format("%.0f%%", level * 100), inBand and colors.green or colors.orange,
        level, inBand and colors.green or colors.orange, d.activelyCooled and 0 or (d.produced or 0)
end

function CARDS.turbine(m)
    local d, ctl, lim = m.data, m.controller, m.limits
    if not d or d.assembled == false then
        return d and "UNASSEMBLED" or "NO SIGNAL", colors.orange, "--", "--", colors.gray, 0, colors.gray, 0
    end
    local mode = (d.active and MODE_TEXT[ctl.mode]) or {"OFFLINE", colors.lightGray}
    local rc = math.abs(d.rpm - lim.targetRPM) <= lim.targetRPM * 0.05 and colors.green or colors.orange
    return mode[1], mode[2], "Gen " .. monitor_utils.formatRF(d.produced or 0) .. " FE/t",
        formatInt(d.rpm) .. " RPM", rc, d.rpm / lim.maxRPM, rc, d.produced or 0
end

function CARDS.mek_fission(m)
    local d, ctl = m.data, m.controller
    if not d or d.formed == false then
        return d and "NOT FORMED" or "NO SIGNAL", colors.orange, "--", "--", colors.gray, 0, colors.gray, 0
    end
    local status = ctl.trip and "SCRAMMED" or (d.active and "ACTIVE" or "OFF")
    local sc = ctl.trip and colors.red or (d.active and colors.green or colors.lightGray)
    local cc = pctColor(d.coolant or 0, m.limits.minCoolant, m.limits.minCoolant * 2)
    return status, sc, string.format("Burn %.1f mB/t", d.burnRate or 0),
        formatInt(d.temperature or 0) .. "K", (d.damage or 0) > 0 and colors.red or colors.green,
        d.coolant or 0, cc, 0
end

local function mekSimple(line, value, pct)
    return function(m)
        local d = m.data
        if not d or d.formed == false then
            return d and "NOT FORMED" or "NO SIGNAL", colors.orange, "--", "--", colors.gray, 0, colors.gray, 0
        end
        return "ONLINE", colors.green, line(d), value(d), colors.white, pct(d) or 0, colors.lightBlue,
            (m.kind == "mek_turbine" or m.kind == "mek_fusion") and (d.production or 0) or 0
    end
end
CARDS.mek_turbine = mekSimple(function(d) return "Gen " .. monitor_utils.formatRF(d.production or 0) .. " FE/t" end,
    function(d) return string.format("Steam %.0f%%", (d.steam or 0) * 100) end,
    function(d) return d.steam end)
CARDS.mek_boiler = mekSimple(function(d) return "Boil " .. formatInt(d.boilRate or 0) .. " mB/t" end,
    function(d) return string.format("Water %.0f%%", (d.water or 0) * 100) end,
    function(d) return d.water end)
CARDS.mek_fusion = mekSimple(function(d) return "Gen " .. monitor_utils.formatRF(d.production or 0) .. " FE/t" end,
    function(d) return d.ignited and "IGNITED" or "COLD" end,
    function(d) return d.dtFuel end)

function CARDS.storage(m)
    local i = m.info
    if not i or not i.max then
        local status, sc = storageStatus(i)
        return status, sc, "--", "--", colors.gray, 0, colors.gray, 0
    end
    local c = pctColor(i.pct, 0.1, 0.25)
    local status, sc = "STORAGE", colors.lightBlue
    if i.net then status, sc = signedRF(i.net) .. "/t", flowColor(i.net) end
    return status, sc, "Stored " .. monitor_utils.formatRF(i.stored),
        string.format("%.1f%%", i.pct * 100), c, i.pct, c, 0
end

function CARDS.meter(m)
    local i = m.info
    if not i then return "NO SIGNAL", colors.red, "--", "--", colors.gray, 0, colors.gray, 0 end
    return "METER", colors.lightBlue, "Flow", monitor_utils.formatRF(i.rate) .. " FE/t",
        colors.lime, 0, colors.gray, 0
end

function CARDS.network(m)
    local a = m.info
    if not a then return "NO DATA", colors.red, "--", "--", colors.gray, 0, colors.gray, 0 end
    local st = NETWORK_STATES[a.state] or NETWORK_STATES.balanced
    local c = pctColor(a.pct, 0.1, 0.25)
    return st[1], st[2], "Use " .. monitor_utils.formatRF(a.consumption),
        signedRF(a.net) .. "/t", flowColor(a.net), a.pct, c, 0
end

local CARD_ROWS = 4             -- name/status, metric, bar, spacer

local function buildOverview(units, w, h, view)
    local page = newPage({})
    local total, alarms = 0, {}
    for _, m in ipairs(units) do
        local fn = CARDS[m.kind]
        if fn then total = total + (select(8, fn(m)) or 0) end
        local a = m.controller and m.controller.alarms and m.controller.alarms[1]
        if a then table.insert(alarms, m.name .. ": " .. a) end
    end
    -- Tap the header for the System page (version, updates, totals, alarms).
    page.add({kind = "lr", label = "[i] Overview", value = monitor_utils.formatRF(total) .. " rf/t",
              color = colors.lime, action = "nav:system"})
    -- Energy network line (consumption, storage flow and charge) when any
    -- storage is attached.
    local headerRows = 2
    for _, m in ipairs(units) do
        if m.kind == "network" and m.info then
            local a = m.info
            page.add({kind = "lr", label = "Use " .. monitor_utils.formatRF(a.consumption),
                      value = signedRF(a.net) .. " " .. string.format("%.0f%%", a.pct * 100),
                      color = flowColor(a.net), action = "nav:detail:" .. m.id})
            headerRows = 3
            break
        end
    end
    page.gap(nil)

    -- Rows: header + gap (headerRows), cards (4 each, minus the last
    -- spacer), footer (1), and gap + pager (2) when the cards need more
    -- than one page.
    local perPage = math.max(1, math.floor((h - headerRows) / CARD_ROWS))
    if #units > perPage then perPage = math.max(1, math.floor((h - headerRows - 2) / CARD_ROWS)) end
    local pages = math.max(1, math.ceil(#units / perPage))
    view.overviewPage = math.max(1, math.min(view.overviewPage or 1, pages))
    local first = (view.overviewPage - 1) * perPage + 1
    for n = first, math.min(#units, first + perPage - 1) do
        local m = units[n]
        local status, sc, line, value, vc, pct, bc = CARDS[m.kind](m)
        local action = "nav:detail:" .. m.id
        page.add({kind = "lr", label = m.name, value = status, color = sc, action = action})
        page.add({kind = "lr", label = line, value = value, color = vc, action = action, dim = true})
        page.add({kind = "bar", pct = pct, color = bc, action = action})
        if n < first + perPage - 1 and n < #units then page.gap(nil) end
    end
    if pages > 1 then
        page.gap(nil)
        page.buttons({{"<", "ovr:prev", colors.gray},
                      {string.format("%d/%d", view.overviewPage, pages), "noop", colors.blue},
                      {">", "ovr:next", colors.gray}}, {3, nil, 3})
    end
    page.add({kind = "footer", alarms = alarms})
    return page.items
end

------------------------------------------------------------
-- SETTINGS PAGE
------------------------------------------------------------
local function buildSettings(model, w)
    local page = newPage(model)
    page.gap(TOP)
    page.nav(model.name .. " Settings")
    page.gap(HEADER)
    for _, item in ipairs(model.settings or {}) do
        page.add({kind = "setting", label = item.label, key = item.key,
                  value = model.formatSetting(item, model.limits[item.key])})
    end
    page.gap(CONTROLS)
    page.buttons({
        {model.nav.pinned and "UNPIN" or "PIN HERE", "pin", model.nav.pinned and colors.orange or colors.blue},
        {"RESET", "reset", colors.red}
    })
    page.add({kind = "footer"})
    return page.items
end

------------------------------------------------------------
-- GRAPHS
------------------------------------------------------------
local HISTORY_SIZE = 300
local history = {}             -- unit id -> {metric index -> samples}

-- Metrics per unit kind: {label, value, max (nil = autoscale), colour, fmt}
local function metricsOf(m)
    local lim = m.limits or {}
    if m.kind == "draconic" then
        local i, ctl = m.info, m.controller
        return {
            {"Temperature", i and i.temperature, lim.maxTemperature, colors.orange, "temp"},
            {"Field", i and i.fieldPct, 1, colors.green, "pct"},
            {"Saturation", i and i.satPct, 1, colors.blue, "pct"},
            {"Output", ctl and ctl.outputRate, nil, colors.lime, "rate"}
        }
    elseif m.kind == "fission" then
        local d = m.data or {}
        local level, production = 0, 0
        if d.activelyCooled then
            level = (d.steamMax or 0) > 0 and d.steam / d.steamMax or 0
            production = d.steamMade
        else
            level = (d.capacity or 0) > 0 and d.stored / d.capacity or 0
            production = d.produced
        end
        return {
            {d.activelyCooled and "Steam Tank" or "Buffer", m.data and level, 1, colors.green, "pct"},
            {d.activelyCooled and "Steam mB/t" or "Generation", production, nil, colors.lime, "rate"},
            {"Rods", d.rods, 100, colors.lightBlue, "int"}
        }
    elseif m.kind == "turbine" then
        local d = m.data or {}
        return {
            {"Rotor RPM", d.rpm, lim.maxRPM, colors.green, "int"},
            {"Generation", d.produced, nil, colors.lime, "rate"},
            {"Steam Flow", d.flow, d.flowLimit, colors.lightBlue, "int"}
        }
    elseif m.kind == "mek_fission" then
        local d = m.data or {}
        return {
            {"Temperature K", d.temperature, 1200, colors.orange, "int"},
            {"Burn mB/t", d.burnRate, d.maxBurnRate, colors.lime, "num"},
            {"Coolant", d.coolant, 1, colors.lightBlue, "pct"},
            {"Heated", d.heated, 1, colors.blue, "pct"}
        }
    elseif m.kind == "mek_turbine" then
        local d = m.data or {}
        return {{"Generation", d.production, nil, colors.lime, "rate"},
                {"Steam", d.steam, 1, colors.lightBlue, "pct"}}
    elseif m.kind == "mek_boiler" then
        local d = m.data or {}
        return {{"Boil mB/t", d.boilRate, d.maxBoilRate, colors.lime, "int"},
                {"Water", d.water, 1, colors.lightBlue, "pct"}}
    elseif m.kind == "mek_fusion" then
        local d = m.data or {}
        return {{"Generation", d.production, nil, colors.lime, "rate"},
                {"Plasma K", d.plasma, nil, colors.orange, "rate"}}
    elseif m.kind == "storage" then
        local i = m.info
        return {
            {"Charge", i and i.pct, 1, colors.green, "pct"},
            {"Net Flow", i and i.net, nil, colors.lime, "rate"},
            {"Input", i and i.input, nil, colors.lightBlue, "rate"},
            {"Output", i and i.output, nil, colors.orange, "rate"}
        }
    elseif m.kind == "meter" then
        local i = m.info
        return {{"Flow", i and i.rate, nil, colors.lime, "rate"}}
    elseif m.kind == "network" then
        local a = m.info
        return {
            {"Generation", a and a.generation, nil, colors.lime, "rate"},
            {"Consumption", a and a.consumption, nil, colors.orange, "rate"},
            {"Storage Net", a and a.net, nil, colors.lightBlue, "rate"},
            {"Charge", a and a.pct, 1, colors.green, "pct"}
        }
    end
    return {}
end

-- Records one sample per metric for every unit (called on a timer).
function monitor_utils.sample(units)
    for _, m in ipairs(units) do
        local h = history[m.id] or {}
        history[m.id] = h
        for i, metric in ipairs(metricsOf(m)) do
            h[i] = h[i] or {}
            table.insert(h[i], tonumber(metric[2]) or false)
            if #h[i] > HISTORY_SIZE then table.remove(h[i], 1) end
        end
    end
end

local function fmtMetric(v, fmt)
    if v == nil or v == false then return "--" end
    if fmt == "temp" then return formatInt(v) .. "C" end
    if fmt == "pct" then return string.format("%.1f%%", v * 100) end
    if fmt == "rate" then return monitor_utils.formatRF(v) end
    if fmt == "num" then return string.format("%.1f", v) end
    return formatInt(v)
end

local function buildGraphs(model, w, h)
    local page = newPage(model)
    page.gap(TOP)
    page.nav(model.name .. " Graphs")
    local metrics = metricsOf(model)
    local hist = history[model.id] or {}
    -- Energy per hour over the last day, from the long-term totals.
    if model.hourly then
        local hourly = {}
        for i, v in ipairs(model.hourly) do hourly[i] = v end
        table.insert(metrics, 1, {"Energy/h (24h)", hourly[#hourly], nil, colors.yellow, "rate"})
        hist = {hourly}
        for i, series in pairs(history[model.id] or {}) do hist[i + 1] = series end
    end
    -- Fit as many charts as leave at least 3 rows each.
    local free = h - 3                     -- top gap, nav, footer
    local charts = math.max(1, math.min(#metrics, math.floor(free / 4)))
    local rows = math.max(1, math.floor(free / charts) - 1)
    local width = w - 2
    for c = 1, charts do
        local label, current, max, color, fmt = (table.unpack or unpack)(metrics[c])
        local samples = {}
        local series = hist[c] or {}
        for k = math.max(1, #series - width + 1), #series do table.insert(samples, series[k]) end
        local lo, hi = 0, max
        for _, v in ipairs(samples) do
            if v then
                lo = math.min(lo, v)
                if not max then hi = math.max(hi or v, v) end
            end
        end
        if not hi or hi <= lo then hi = lo + 1 end
        page.add({kind = "lr", label = label, value = fmtMetric(current, fmt), color = color})
        for r = 1, rows do
            page.add({kind = "graph", samples = samples, lo = lo, hi = hi, row = r,
                      rows = rows, color = color, width = width})
        end
    end
    page.add({kind = "footer"})
    return page.items
end

------------------------------------------------------------
-- SYSTEM PAGE
------------------------------------------------------------
--[[
view.system = {
  version, update = {text, color, confirm}, alarms = {count, silenced},
  hourly = network energy per hour (oldest first), lifetime
}
]]
local function buildSystem(view, w, h)
    local sys = view.system or {}
    local page = newPage({nav = {back = true, page = "system"}, name = "System"})
    page.gap(TOP)
    page.buttons({{"<", "nav:overview", colors.gray}, {"System", "noop", colors.blue}}, {3, nil})
    page.lr("Version", "v" .. tostring(sys.version or "?"), colors.white)
    local upd = sys.update or {}
    page.lr("Update", upd.text or "not checked", upd.color or colors.lightGray)
    page.buttons({{"CHECK", "sys:check", colors.gray},
                  {upd.confirm and "CONFIRM" or "UPDATE", "sys:update",
                   upd.confirm and colors.orange or colors.blue}})
    page.gap(BARS)
    local hourly = sys.hourly or {}
    local today = 0
    for _, v in ipairs(hourly) do today = today + v end
    page.lr("Energy 24h", monitor_utils.formatRF(today), colors.lime)
    page.lr("Lifetime", monitor_utils.formatRF(sys.lifetime or 0), colors.lime)
    local hi = 1
    for _, v in ipairs(hourly) do hi = math.max(hi, v) end
    local rows = math.max(1, math.min(4, h - 13))
    for r = 1, rows do
        page.add({kind = "graph", samples = hourly, lo = 0, hi = hi, row = r, rows = rows,
                  color = colors.yellow, width = w - 2})
    end
    page.gap(BARS)
    local al = sys.alarms or {}
    page.lr("Alarms", (al.count or 0) == 0 and "none"
            or (tostring(al.count) .. (al.silenced and " (silenced)" or " active")),
            (al.count or 0) == 0 and colors.green or colors.red)
    page.buttons({{"SILENCE", "alarm:silence", colors.gray}})
    page.add({kind = "footer"})
    return page.items
end

------------------------------------------------------------
-- DRAWING
------------------------------------------------------------
local function drawGraphRow(win, y, item)
    -- Columns fill bottom-up; row 1 is the top row of the chart.
    local offset = item.width - #item.samples
    for x = 1, item.width do
        local v = item.samples[x - offset]
        local filled = false
        if v then
            local height = (v - item.lo) / (item.hi - item.lo) * item.rows
            filled = height >= (item.rows - item.row + 0.5)
        end
        win.setCursorPos(x + 1, y)
        win.setBackgroundColor(filled and item.color or (v and colors.black or colors.black))
        win.write(" ")
    end
    win.setBackgroundColor(colors.black)
end

local function drawSetting(target, y, w, item)
    local win = target.win
    -- Label, one space, value, then the two 3-wide buttons.
    local room = (w - 8 - #item.value) - 2 - 1
    text(win, 2, y, item.label:sub(1, math.max(0, room)), colors.white)
    text(win, w - 8 - #item.value, y, item.value, colors.lightBlue)
    text(win, w - 7, y, " - ", colors.white, colors.gray)
    text(win, w - 3, y, " + ", colors.white, colors.gray)
    table.insert(target.buttons, {x1 = w - 7, x2 = w - 5, y = y, action = "set:" .. item.key .. ":-1"})
    table.insert(target.buttons, {x1 = w - 3, x2 = w - 1, y = y, action = "set:" .. item.key .. ":1"})
end

local function drawItems(target, items, model)
    local win = target.win
    local w = win.getSize()
    local ctl = model.controller
    for y, item in ipairs(items) do
        if item.kind == "lr" then
            labelValue(win, y, w, item.label, item.value, item.color)
        elseif item.kind == "bar" then
            bar(win, y, w, item.pct, item.color)
        elseif item.kind == "buttons" then
            buttonRow(target, y, w, item.defs, item.widths)
        elseif item.kind == "setting" then
            drawSetting(target, y, w, item)
        elseif item.kind == "graph" then
            drawGraphRow(win, y, item)
        elseif item.kind == "footer" then
            -- Alarms beat the last action.
            local alarm = item.alarms and item.alarms[1] or (ctl and ctl.alarms and ctl.alarms[1])
            if alarm then
                win.setBackgroundColor(colors.red)
                win.setCursorPos(1, y)
                win.write(string.rep(" ", w))
                centered(win, y, alarm:sub(1, w), colors.white, colors.red, w)
                -- Tapping the alarm bar silences repeating alarm sounds.
                table.insert(target.buttons, {x1 = 1, x2 = w, y = y, action = "alarm:silence"})
            elseif model.events and model.events[1] then
                text(win, 2, y, model.events[1].message:sub(1, w - 2), colors.gray)
            end
        end
        if item.action then
            table.insert(target.buttons, {x1 = 1, x2 = w, y = y, action = item.action})
        end
    end
end

------------------------------------------------------------
-- RENDER AND NAVIGATION
------------------------------------------------------------
local views = {}               -- monitor name -> {page, unit, overviewPage}

local function findUnit(units, id)
    for _, m in ipairs(units) do
        if m.id == id then return m end
    end
end

--[[
view = {
  units   = every unit model (unit.model()), including storage,
  core    = energy core reading shown on Draconic pages, or nil,
  events  = stat_utils.recent,
  pins    = monitor name -> unit id,
  formatSetting = persist.format
}
Each monitor keeps its own page: overview, or a unit's detail /
settings / graphs page. A pinned monitor stays on its unit.
]]
local function pageFor(name, view)
    local units = view.units or {}
    local v = views[name] or {page = "overview"}
    views[name] = v
    local pinned = view.pins and view.pins[name]
    if pinned and findUnit(units, pinned) then
        v.unit = pinned
        if v.page == "overview" then v.page = "detail" end
    else
        pinned = nil
    end
    if v.page ~= "overview" and v.page ~= "system" and not findUnit(units, v.unit) then
        v.page = "overview"
    end
    if #units == 1 and v.page == "overview" and not v.chosenOverview then
        v.page, v.unit = "detail", units[1].id
    end
    return v, pinned
end

local function renderTarget(target, view)
    local win = target.win
    local w, h = win.getSize()
    win.setBackgroundColor(colors.black)
    win.clear()
    target.buttons = {}
    local units = view.units or {}
    if #units == 0 then
        text(win, 2, 2, "No reactor connected", colors.orange)
        return
    end
    if w < MIN_WIDTH or h < MIN_HEIGHT then
        text(win, 1, 1, "Screen too small", colors.red)
        text(win, 1, 2, string.format("Need %dx%d", MIN_WIDTH, MIN_HEIGHT), colors.white)
        return
    end

    local v, pinned = pageFor(target.name, view)
    target.view = v
    if v.page == "system" then
        drawItems(target, fitLayout(buildSystem(view, w, h), h) or {}, {events = view.events})
        return
    end
    if v.page == "overview" then
        drawItems(target, fitLayout(buildOverview(units, w, h, v), h) or {}, {events = view.events})
        return
    end

    local model = {}
    for k, val in pairs(findUnit(units, v.unit)) do model[k] = val end
    model.core, model.events = view.core, view.events
    model.hourly = view.hourlyFor and view.hourlyFor(model.id) or nil
    model.formatSetting = view.formatSetting or function(_, val) return tostring(val) end
    model.nav = {back = not pinned, pinned = pinned ~= nil, page = v.page}
    if v.page == "settings" and not (model.settings and #model.settings > 0) then v.page = "detail" end

    local items
    if v.page == "settings" then
        items = buildSettings(model, w)
    elseif v.page == "graphs" then
        items = buildGraphs(model, w, h)
    else
        model.nav.page = "detail"
        items = buildLayout(model, w)
    end
    items = fitLayout(items, h)
    if not items then
        text(win, 1, 1, "Screen too small", colors.red)
        return
    end
    drawItems(target, items, model)
end

function monitor_utils.render(view)
    for _, name in ipairs(order) do
        local target = targets[name]
        local ok, err = target == nil, nil
        if not ok then ok, err = pcall(function()
            target.win.setVisible(false)
            renderTarget(target, view)
            target.win.setVisible(true)
        end) end
        if not ok then
            -- A detached monitor is re-initialised by the peripheral event;
            -- anything else is a bug, shown on the screen and reported once
            -- through lastError rather than silently freezing the display.
            monitor_utils.lastError = tostring(err)
            pcall(function()
                target.win.setVisible(true)
                target.win.setBackgroundColor(colors.black)
                target.win.clear()
                text(target.win, 1, 1, "Display error:", colors.red)
                text(target.win, 1, 2, tostring(err):sub(1, 200), colors.white)
            end)
        end
    end
end

-- Handles a touch on display `name`. Navigation is handled here and
-- returns "redraw"; anything else returns action, unit id, display name
-- for the caller to apply. Returns nil when nothing was hit.
function monitor_utils.handleTouch(name, x, y)
    local target = targets[name]
    if not target then return nil end
    local v = views[name] or {page = "overview"}
    views[name] = v
    for _, b in ipairs(target.buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then
            local a = b.action
            local unitId = a:match("^nav:detail:(.+)$")
            if unitId then
                v.page, v.unit = "detail", unitId
            elseif a == "nav:overview" then
                v.page = "overview"
                v.chosenOverview = true
            elseif a == "nav:system" then
                v.page = "system"
            elseif a == "nav:detail" or a == "nav:graphs" or a == "nav:settings" then
                v.page = a:sub(5)
            elseif a == "ovr:next" then
                v.overviewPage = (v.overviewPage or 1) + 1
            elseif a == "ovr:prev" then
                v.overviewPage = math.max(1, (v.overviewPage or 1) - 1)
            elseif a == "noop" then
                return nil
            else
                return a, v.unit, name
            end
            return "redraw"
        end
    end
    return nil
end

-- Which page a display shows (for tests and diagnostics).
function monitor_utils.viewOf(name)
    return views[name]
end

monitor_utils.TERMINAL = TERMINAL
return monitor_utils
