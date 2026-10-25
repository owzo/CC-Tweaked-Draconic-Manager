--==============================================================
-- ALARM OUTPUTS
-- Save as: alarms.lua
--==============================================================

--[[
README
-------
Turns unit alarms (trips, low fuel, link lost, charging stalled,
overspeed...) into things players notice away from the monitor:

  speaker    any attached speaker plays a bell; repeats every
             repeatSeconds while an alarm is active and not silenced
  chat       Advanced Peripherals Chat Box ("chatBox") posts one message
             per NEW alarm, and one when everything has cleared
  redstone   a computer side (or a Redstone Integrator) is held on while
             any alarm is active, for lamps, sirens or a hardware scram

  alarms.update(active)   active = {{unit = name, text = alarm}, ...};
                          call once per UI refresh. Returns the list of
                          newly raised alarms (for logging).
  alarms.silence()        stop repeats until a NEW alarm appears

An alarm is identified by unit + text with digits removed, so a value
that changes ("LOW FUEL 18%" -> "17%") does not count as a new alarm.
]]

local alarms = {}

local settings = {
    enabled = true,
    speaker = true,
    chat = true,
    chatPrefix = "Reactor",
    redstoneSide = nil,         -- e.g. "top"; nil = no redstone output
    redstoneIntegrator = nil,   -- peripheral name of an AP Redstone Integrator
    repeatSeconds = 10
}

local active = {}               -- key -> {unit, text}
local silenced = false
local lastSound = nil

local function keyOf(a)
    return a.unit .. "|" .. tostring(a.text):gsub("%d", "")
end

local function each(kind, fn)
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == kind then
            pcall(fn, peripheral.wrap(name))
        end
    end
end

local function sound()
    if not settings.speaker then return end
    each("speaker", function(s)
        if s.playNote then
            s.playNote("bell", 3, 24)
        elseif s.playSound then
            s.playSound("minecraft:block.note_block.bell")
        end
    end)
end

local function chat(message)
    if not settings.chat then return end
    each("chatBox", function(box)
        box.sendMessage(message, settings.chatPrefix)
    end)
end

local function setRedstone(on)
    if settings.redstoneSide then
        if settings.redstoneIntegrator and peripheral.isPresent(settings.redstoneIntegrator) then
            local ri = peripheral.wrap(settings.redstoneIntegrator)
            pcall(ri.setOutput, settings.redstoneSide, on)
        elseif redstone then
            pcall(redstone.setOutput, settings.redstoneSide, on)
        end
    end
end

function alarms.init(cfg)
    for k, v in pairs(cfg or {}) do settings[k] = v end
    active, silenced, lastSound = {}, false, nil
    setRedstone(false)
end

function alarms.silence()
    silenced = true
end

function alarms.isSilenced()
    return silenced
end

function alarms.update(list, now)
    if not settings.enabled then return {} end
    now = now or os.clock()
    local seen, raised = {}, {}
    for _, a in ipairs(list) do
        local key = keyOf(a)
        seen[key] = true
        if not active[key] then
            active[key] = a
            table.insert(raised, a)
        end
    end
    local cleared = false
    for key in pairs(active) do
        if not seen[key] then active[key] = nil; cleared = true end
    end
    local any = next(active) ~= nil

    if #raised > 0 then
        silenced = false
        for _, a in ipairs(raised) do chat(a.unit .. ": " .. a.text) end
    end
    if cleared and not any then
        chat("All alarms cleared")
        silenced = false
    end
    setRedstone(any)

    if any and not silenced and (#raised > 0 or not lastSound
            or now - lastSound >= settings.repeatSeconds) then
        sound()
        lastSound = now
    end
    return raised
end

return alarms
