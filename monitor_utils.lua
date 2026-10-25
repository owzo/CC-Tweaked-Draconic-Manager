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

-- Lays out `defs` ({label, action, color}) as equal buttons across a row.
local function buttonRow(target, y, width, defs)
    local gap = 1
    local count = #defs
    local each = math.floor((width - 2 - gap * (count - 1)) / count)
    local x = math.floor((width - (each * count + gap * (count - 1))) / 2) + 1
    for _, def in ipairs(defs) do
        local label = def[1]
        if #label > each then label = label:sub(1, each) end
        local pad = each - #label
        local left = math.floor(pad / 2)
        text(target.win, x, y,
             string.rep(" ", left) .. label .. string.rep(" ", pad - left),
             colors.white, def[3] or colors.blue)
        table.insert(target.buttons, {x1 = x, x2 = x + each - 1, y = y, action = def[2]})
        x = x + each + gap
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
local function fitRate(label, value, width)
    local full = formatInt(value) .. " rf/t"
    if #label + #full + 3 <= width then return full end
    return monitor_utils.formatRF(value) .. " rf/t"
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
local function buildLayout(model, w)
    local info, ctl, lim = model.info, model.controller, model.limits
    local items = {}
    local function add(item) table.insert(items, item); return item end
    local function gap(priority, group) add({kind = "gap", priority = priority, group = group}) end
    -- Spacer priorities: the top margin goes first, then all spacers
    -- between the bar sections together (so they stay evenly spaced),
    -- then the one above the controls, then the one under the status.
    local TOP, BARS, CONTROLS, HEADER = 1, 2, 3, 4
    local function lr(label, value, color) add({kind = "lr", label = label, value = value, color = color}) end
    local function bar(pct, color) add({kind = "bar", pct = pct, color = color}) end

    local status, statusColor = "NO SIGNAL", colors.red
    if info then
        status = string.upper((info.status:gsub("_", " ")))
        statusColor = STATUS_COLORS[info.status] or colors.red
    end

    gap(TOP)
    lr("Reactor Status", status, statusColor)
    gap(HEADER)

    lr("Generation", info and fitRate("Generation", info.generationRate, w) or "--", colors.lime)
    local tc = info and tempColor(info.temperature, lim.targetTemperature, lim.maxTemperature) or colors.red
    lr("Temperature", info and (formatInt(info.temperature) .. "C") or "--", tc)
    lr(ctl.autoOutput and "Output Gate" or "Output (man)",
       fitRate("Output Gate", ctl.outputRate, w), colors.lightBlue)

    local steps = uiSettings.manualStep
    add({kind = "buttons", defs = {
        {"<<<", "out:" .. -steps[3], colors.gray},
        {"<<", "out:" .. -steps[2], colors.gray},
        {"<", "out:" .. -steps[1], colors.gray},
        {ctl.autoOutput and "AU" or "MA", "auto", ctl.autoOutput and colors.green or colors.orange},
        {">", "out:" .. steps[1], colors.gray},
        {">>", "out:" .. steps[2], colors.gray},
        {">>>", "out:" .. steps[3], colors.gray}
    }})
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
        add({kind = "lr", label = "Energy Core", value = value, color = cc, priority = 10, group = "core"})
        add({kind = "bar", pct = core.pct, color = cc, priority = 10, group = "core"})
    end

    gap(CONTROLS)
    add({kind = "buttons", defs = {
        {"START", "start", colors.green},
        {"STOP", "stop", colors.red}
    }})
    add({kind = "footer"})
    return items
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
            buttonRow(target, y, w, item.defs)
        elseif item.kind == "footer" then
            -- Alarms beat the last action.
            local alarm = ctl.alarms[1]
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

function monitor_utils.render(model)
    for _, name in ipairs(order) do
        local target = targets[name]
        local ok = target == nil or pcall(function()
            target.win.setVisible(false)
            drawDashboard(target, model)
            target.win.setVisible(true)
        end)
        if not ok then
            -- Monitor was broken or detached mid-draw; drop it until the
            -- next re-init (triggered by a peripheral event).
            targets[name] = nil
        end
    end
end

-- Returns the action string under (x, y) on display `name`, or nil.
function monitor_utils.handleTouch(name, x, y)
    local target = targets[name]
    if not target then return nil end
    for _, b in ipairs(target.buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then
            return b.action
        end
    end
    return nil
end

monitor_utils.TERMINAL = TERMINAL
return monitor_utils
