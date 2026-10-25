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
  core       = energy_core_utils.read() result or nil,
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

    function page.header(label, status, color)
        page.gap(TOP)
        if model.tabs and model.tabs.count > 1 then
            -- Several units: each monitor pages through them on its own.
            page.buttons({
                {"<", "unit:prev", colors.gray},
                {string.format("%s %d/%d", model.name or "Unit", model.tabs.index, model.tabs.count),
                 "noop", colors.blue},
                {">", "unit:next", colors.gray}
            }, {3, nil, 3})
        end
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
    local fuelC = pctColor(fuel, lim.lowFuel or 0.1, (lim.lowFuel or 0.1) * 3)
    lr("Fuel", string.format("%.1f%%", fuel * 100), fuelC)
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

local function drawDashboard(target, model)
    local win = target.win
    local w, h = win.getSize()
    local ctl = model.controller

    win.setBackgroundColor(colors.black)
    win.clear()
    target.buttons = {}

    local items = w >= MIN_WIDTH and fitLayout(buildLayout(model, w), h)
    if not items then
        text(win, 1, 1, "Screen too small", colors.red)
        text(win, 1, 2, string.format("Need %dx%d", MIN_WIDTH, MIN_HEIGHT), colors.white)
        return
    end

    for y, item in ipairs(items) do
        if item.kind == "lr" then
            labelValue(win, y, w, item.label, item.value, item.color)
        elseif item.kind == "bar" then
            bar(win, y, w, item.pct, item.color)
        elseif item.kind == "buttons" then
            buttonRow(target, y, w, item.defs, item.widths)
        elseif item.kind == "footer" then
            -- Alarms beat the last action.
            local alarm = ctl.alarms and ctl.alarms[1]
            if alarm then
                win.setBackgroundColor(colors.red)
                win.setCursorPos(1, y)
                win.write(string.rep(" ", w))
                centered(win, y, alarm:sub(1, w), colors.white, colors.red, w)
            elseif model.events and model.events[1] then
                text(win, 2, y, model.events[1].message:sub(1, w - 2), colors.gray)
            end
        end
    end
end

--[[
view = {
  units  = list of reactor models (unit.model()), one page each,
  core   = energy_core_utils.read() result or nil,
  events = stat_utils.recent
}
Every monitor remembers which reactor it is showing.
]]
function monitor_utils.render(view)
    local units = view.units or {}
    for _, name in ipairs(order) do
        local target = targets[name]
        local ok, err = target == nil, nil
        if not ok then ok, err = pcall(function()
            local count = #units
            target.selected = math.max(1, math.min(target.selected or 1, math.max(count, 1)))
            local model = {}
            for k, v in pairs(units[target.selected] or {}) do model[k] = v end
            model.core, model.events = view.core, view.events
            model.tabs = {index = target.selected, count = count}
            target.count = count
            target.unitId = model.id
            target.win.setVisible(false)
            if model.controller then
                drawDashboard(target, model)
            else
                target.win.setBackgroundColor(colors.black)
                target.win.clear()
                target.buttons = {}
                text(target.win, 2, 2, "No reactor connected", colors.orange)
            end
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

-- Returns the action under (x, y) on display `name` and the id of the
-- unit that display is showing, or nil. Paging is handled here.
function monitor_utils.handleTouch(name, x, y)
    local target = targets[name]
    if not target then return nil end
    for _, b in ipairs(target.buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then
            local count = target.count or 1
            if b.action == "unit:next" then
                target.selected = (target.selected or 1) % count + 1
                return "redraw"
            elseif b.action == "unit:prev" then
                target.selected = ((target.selected or 1) - 2) % count + 1
                return "redraw"
            elseif b.action == "noop" then
                return nil
            end
            return b.action, target.unitId
        end
    end
    return nil
end

monitor_utils.TERMINAL = TERMINAL
return monitor_utils
