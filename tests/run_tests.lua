--==============================================================
-- TEST SUITE
-- Run from the repository root with any Lua 5.1+ interpreter:
--     lua tests/run_tests.lua
--==============================================================

package.path = "./?.lua;./tests/?.lua;" .. package.path

local realPrint = print
local cc = require("mock_cc")
local Sim = require("reactor_sim")

local MODULES = {"config", "reac_utils", "monitor_utils", "stat_utils",
                 "storage_utils", "drivers.storage"}
local TICK = 0.05

-- Everything the installers must ship; MODULE_FILES are loaded by
-- main_control and must never call require themselves.
PROGRAM_FILES = {"main_control.lua", "config.lua", "reac_utils.lua", "monitor_utils.lua",
                 "stat_utils.lua", "storage_utils.lua", "er_utils.lua", "persist.lua",
                 "drivers/draconic.lua", "drivers/extreme.lua", "drivers/storage.lua"}
MODULE_FILES = {}
for _, f in ipairs(PROGRAM_FILES) do
    if f ~= "main_control.lua" then table.insert(MODULE_FILES, f) end
end

------------------------------------------------------------
-- TEST HARNESS
------------------------------------------------------------
local results = {passed = 0, failed = 0}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        results.passed = results.passed + 1
        realPrint("PASS  " .. name)
    else
        results.failed = results.failed + 1
        realPrint("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end

local function check(cond, msg, ...)
    if not cond then error(string.format(msg, ...), 2) end
end

local function readRepoFileEarly(name)
    local h = assert(io.open(name, "r"))
    local s = h:read("*a")
    h:close()
    return s
end

local function freshModules()
    for _, m in ipairs(MODULES) do package.loaded[m] = nil end
end

local function loadConfig()
    freshModules()
    return require("config")
end

-- Advances the sim by dt seconds of game ticks.
local function advancer(sim)
    local carry = 0
    return function(dt)
        carry = carry + dt
        while carry >= TICK - 1e-9 do
            sim:tick()
            carry = carry - TICK
        end
    end
end

-- Runs the controller directly against the sim for `seconds`.
local function closedLoop(sim, ctl, seconds, onCycle)
    local cfg = ctl.cfg
    local ticksPerCycle = math.floor(cfg.controlInterval / TICK + 0.5)
    local hw = {
        reactor = sim.reactor,
        input = (require("reac_utils")).wrapGate("in", sim.inGate),
        output = (require("reac_utils")).wrapGate("out", sim.outGate)
    }
    local reac = require("reac_utils")
    local t = 0
    while t < seconds do
        local info = reac.readInfo(sim.reactor)
        local actions = ctl:step(info, t)
        local errs = reac.apply(hw, actions)
        check(#errs == 0, "apply errors: %s", table.concat(errs, "; "))
        if onCycle then onCycle(t, info, actions) end
        for _ = 1, ticksPerCycle do sim:tick() end
        t = t + ticksPerCycle * TICK
        if sim.exploded then return t end
    end
    return t
end

local function newCtl(sim, overrides)
    cc.reset()
    local cfg = loadConfig()
    for k, v in pairs(overrides or {}) do cfg.reactor[k] = v end
    local reac = require("reac_utils")
    return reac.newController(cfg.reactor, reac.readInfo(sim.reactor)), cfg
end

------------------------------------------------------------
-- STATIC CHECKS
------------------------------------------------------------
test("every program file compiles", function()
    local files = {"install.lua", "offline_install.lua"}
    for _, f in ipairs(PROGRAM_FILES) do table.insert(files, f) end
    for _, f in ipairs(files) do
        local handle = assert(io.open(f, "r"))
        local src = handle:read("*a")
        handle:close()
        check(not src:find("goto%s") and not src:find("::%w+::"),
              "%s uses goto (unsupported by older CC:Tweaked)", f)
        local fn, err = (loadstring or load)(src, f)
        check(fn, "%s: %s", f, tostring(err))
    end
end)

------------------------------------------------------------
-- CONTROLLER UNIT TESTS
------------------------------------------------------------
test("field input matches drain / (1 - target)", function()
    local sim = Sim.new({state = "running"})
    local ctl = newCtl(sim)
    local info = require("reac_utils").readInfo(sim.reactor)
    info.fieldDrainRate = 100000
    info.fieldPct = 0.5
    local a = ctl:step(info, 0)
    check(math.abs(a.input - 200000) < 1, "input %.0f", a.input)
end)

test("cold reactor at boot is not charged unless requested", function()
    local sim = Sim.new()
    local ctl = newCtl(sim)
    local a = ctl:step(require("reac_utils").readInfo(sim.reactor), 0)
    check(a.command == nil, "unexpected command %s", tostring(a.command))
    check(a.input == 0 and a.output == 0, "gates should idle")
    ctl:requestStart()
    a = ctl:step(require("reac_utils").readInfo(sim.reactor), 10)
    check(a.command == "charge", "expected charge, got %s", tostring(a.command))
end)

test("running reactor at boot keeps running", function()
    local sim = Sim.new({state = "running"})
    local ctl = newCtl(sim)
    check(ctl.desired == "run", "desired %s", ctl.desired)
end)

test("legacy status strings are normalised", function()
    local reac = (function() cc.reset(); freshModules(); return require("reac_utils") end)()
    for raw, want in pairs({offline = "cold", charging = "warming_up",
                            charged = "warming_up", online = "running"}) do
        local info = reac.readInfo({getReactorInfo = function()
            return {status = raw, temperature = 20, fieldStrength = 0, maxFieldStrength = 1,
                    energySaturation = 0, maxEnergySaturation = 1,
                    fuelConversion = 0, maxFuelConversion = 1}
        end})
        check(info.status == want, "%s -> %s", raw, info.status)
    end
end)

test("missing fuel data is treated as empty, never NaN", function()
    cc.reset(); freshModules()
    local reac = require("reac_utils")
    local info = reac.readInfo({getReactorInfo = function()
        return {status = "cold", fuelConversion = 0, maxFuelConversion = 0}
    end})
    check(info.fuelRemaining == 0, "fuel %s", tostring(info.fuelRemaining))
    check(info.fieldPct == 0, "field %s", tostring(info.fieldPct))
end)

test("lost reactor link: output 0, input 2x last demand, no runaway", function()
    local sim = Sim.new({state = "running", temperature = 7000})
    local ctl, cfg = newCtl(sim)
    local info = require("reac_utils").readInfo(sim.reactor)
    info.fieldDrainRate, info.fieldPct = 2000000, 0.5
    ctl:step(info, 0)                         -- demand 4M
    local a
    for i = 1, 5 do a = ctl:step(nil, i) end
    check(a.output == 0, "output %s", tostring(a.output))
    check(a.input == 8000000, "input %s (should stay 2x, not compound)", tostring(a.input))
    check(a.input <= cfg.reactor.maxInflow, "over cap")
end)

test("gate adapter skips unchanged writes and enables override", function()
    cc.reset(); freshModules()
    local calls = 0
    local dev = {override = false}
    dev.getFlow = function() return 0 end
    dev.getOverrideEnabled = function() calls = calls + 1; return dev.override end
    dev.setOverrideEnabled = function(v) calls = calls + 1; dev.override = v end
    dev.setFlowOverride = function() calls = calls + 1 end
    local gate = require("reac_utils").wrapGate("g", dev)
    gate.set(5)
    check(dev.override, "override not enabled")
    local before = calls
    for _ = 1, 10 do gate.set(5) end
    check(calls == before, "unchanged rate cost %d calls", calls - before)
    gate.set(6)
    check(calls == before + 1, "changed rate should be one call, was %d", calls - before)
end)

test("stopping reactor keeps its field fed (old code zeroed it)", function()
    local sim = Sim.new({state = "running", temperature = 7000})
    sim.state = "stopping"
    sim.fieldDrain = 50000
    local ctl = newCtl(sim)
    local info = require("reac_utils").readInfo(sim.reactor)
    local a = ctl:step(info, 0)
    check(a.input > 0, "stopping input was %s", tostring(a.input))
    check(a.output == 0, "stopping output was %s", tostring(a.output))
end)

test("low fuel trips and blocks restart", function()
    local sim = Sim.new({state = "running", temperature = 7000})
    sim.convertedFuel, sim.reactableFuel = 9500, 868
    local ctl = newCtl(sim)
    local reac = require("reac_utils")
    local a = ctl:step(reac.readInfo(sim.reactor), 0)
    check(a.command == "stop", "expected stop")
    check(ctl.desired == "stop", "low fuel must not auto-restart")
end)

test("auto-restart budget latches after repeated trips", function()
    local sim = Sim.new()
    local ctl = newCtl(sim)
    local reac = require("reac_utils")
    ctl.desired = "run"
    local t = 0
    local charges = 0
    for _ = 1, 6 do
        ctl.trip = {reason = "test", restartable = true}
        t = t + 10
        local a = ctl:step(reac.readInfo(sim.reactor), t)
        if a.command == "charge" then charges = charges + 1 end
    end
    check(charges == 3, "charges %d", charges)
    ctl:requestStart()
    local a = ctl:step(reac.readInfo(sim.reactor), t + 10)
    check(a.command == "charge", "START should clear the latch")
end)

------------------------------------------------------------
-- CLOSED LOOP SIMULATION (both rule sets)
------------------------------------------------------------
for _, V in ipairs({"1.12", "1.20"}) do
    test("[DE " .. V .. "] cold start -> charge -> run, then holds temperature and field", function()
        local sim = Sim.new({version = V})
        local ctl, cfg = newCtl(sim)
        ctl:requestStart()
        local r = cfg.reactor
        local late = {minT = math.huge, maxT = 0, minF = 1, maxF = 0}
        closedLoop(sim, ctl, 1200, function(t, info)
            if t > 600 and info and info.status == "running" then
                late.minT = math.min(late.minT, info.temperature)
                late.maxT = math.max(late.maxT, info.temperature)
                late.minF = math.min(late.minF, info.fieldPct)
                late.maxF = math.max(late.maxF, info.fieldPct)
            end
        end)
        check(not sim.exploded, "reactor exploded")
        check(sim.state == "running", "state %s", sim.state)
        check(sim.maxTempSeen < r.maxTemperature, "peak %.0fC", sim.maxTempSeen)
        check(late.minT > r.targetTemperature - 100 and late.maxT < r.targetTemperature + 100,
              "temperature band %.0f-%.0f", late.minT, late.maxT)
        check(late.minF > r.targetField - 0.03 and late.maxF < r.targetField + 0.03,
              "field band %.3f-%.3f", late.minF, late.maxF)
        realPrint(string.format("      peak %.0fC, steady %.0f-%.0fC, field %.1f-%.1f%%, gen %.0f RF/t",
            sim.maxTempSeen, late.minT, late.maxT, late.minF * 100, late.maxF * 100, sim.generationRate))
    end)

    test("[DE " .. V .. "] controlled stop keeps containment until cold", function()
        local sim = Sim.new({version = V, state = "running", temperature = 7000, sat = 0.2})
        local ctl = newCtl(sim)
        closedLoop(sim, ctl, 60)
        ctl:requestStop()
        sim.minFieldWhileHot = 1
        closedLoop(sim, ctl, 900)
        check(not sim.exploded, "exploded during shutdown")
        check(sim.state == "cooling" or sim.state == "cold", "state %s", sim.state)
        check(sim.minFieldWhileHot > 0.3, "field dipped to %.2f", sim.minFieldWhileHot)
    end)

    test("[DE " .. V .. "] full energy core then sudden drain does not overheat", function()
        local sim = Sim.new({version = V, state = "running", temperature = 7000, sat = 0.2})
        local ctl, cfg = newCtl(sim)
        closedLoop(sim, ctl, 300)
        sim.extractScale = 0          -- core full: nothing leaves the reactor
        closedLoop(sim, ctl, 300)
        sim.extractScale = 1          -- core suddenly has room again
        sim.maxTempSeen = 0
        closedLoop(sim, ctl, 300)
        check(not sim.exploded, "exploded")
        check(sim.maxTempSeen < cfg.reactor.maxTemperature, "peak %.0fC", sim.maxTempSeen)
    end)

    test("[DE " .. V .. "] manual overdrive is caught by the interlock before the trip", function()
        local sim = Sim.new({version = V, state = "running", temperature = 7000, sat = 0.2})
        local ctl, cfg = newCtl(sim)
        closedLoop(sim, ctl, 120)
        ctl:adjustManualOutput(math.max(5000000, ctl.outputRate))
        closedLoop(sim, ctl, 300)
        check(not sim.exploded, "exploded")
        check(ctl.autoOutput, "interlock did not restore auto output")
        check(sim.maxTempSeen < cfg.reactor.maxTemperature, "reached trip limit: %.0fC", sim.maxTempSeen)
        check(sim.state == "running", "interlock failed, reactor tripped (%s)", sim.state)
    end)

    test("[DE " .. V .. "] field collapse trips, recovers and auto-restarts", function()
        local sim = Sim.new({version = V, state = "running", temperature = 7000, sat = 0.2})
        local ctl = newCtl(sim)
        closedLoop(sim, ctl, 60)
        sim.field = sim.maxField * 0.15
        local tripped = false
        closedLoop(sim, ctl, 2400, function(_, _, a)
            if a.command == "stop" then tripped = true end
        end)
        check(tripped, "no trip")
        check(not sim.exploded, "exploded")
        check(sim.state == "running", "did not auto-restart, state %s", sim.state)
    end)
end

test("[DE 1.20] holds target with 3-tick cycles (server-thread latency)", function()
    local sim = Sim.new({version = "1.20"})
    local ctl, cfg = newCtl(sim, {controlInterval = 0.15})
    ctl:requestStart()
    local band = {lo = math.huge, hi = 0, minF = 1}
    closedLoop(sim, ctl, 900, function(t, info)
        if t > 450 and info and info.status == "running" then
            band.lo = math.min(band.lo, info.temperature)
            band.hi = math.max(band.hi, info.temperature)
            band.minF = math.min(band.minF, info.fieldPct)
        end
    end)
    check(not sim.exploded, "exploded")
    check(sim.maxTempSeen < cfg.reactor.maxTemperature, "peak %.0fC", sim.maxTempSeen)
    check(band.lo > 6900 and band.hi < 7100, "band %.0f-%.0f", band.lo, band.hi)
    check(band.minF > 0.45, "field dipped to %.3f", band.minF)
end)

test("[DE 1.20] edge tuning: 8000C target, 25% field, 12% trip", function()
    local sim = Sim.new({version = "1.20"})
    local ctl = newCtl(sim, {targetTemperature = 7900, maxTemperature = 8200,
                             targetField = 0.25, minField = 0.12, controlInterval = 0.15})
    ctl:requestStart()
    closedLoop(sim, ctl, 900)
    check(not sim.exploded, "exploded")
    check(sim.state == "running", "state %s (tripped?)", sim.state)
    check(sim.maxTempSeen < 8200, "peak %.0fC", sim.maxTempSeen)
    check(sim.minFieldWhileHot > 0.12, "field dipped to %.3f", sim.minFieldWhileHot)
    realPrint(string.format("      edge: peak %.0fC, min field %.1f%%, gen %.1fM RF/t",
        sim.maxTempSeen, sim.minFieldWhileHot * 100, sim.generationRate / 1e6))
end)

------------------------------------------------------------
-- UI
------------------------------------------------------------
test("dashboard renders on a 3x3 monitor and buttons map to actions", function()
    cc.reset(); freshModules()
    local cfg = require("config")
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    local ui = require("monitor_utils")
    local reac = require("reac_utils")
    check(ui.init({}, cfg.ui) == 1, "monitor not found")
    local sim = Sim.new({state = "running", temperature = 7000})
    local ctl = reac.newController(cfg.reactor, reac.readInfo(sim.reactor))
    ui.render({units = {{id = "r1", name = "Main", info = reac.readInfo(sim.reactor),
                         controller = ctl, limits = cfg.reactor}},
               events = {{level = "INFO", message = "Charging reactor"}}})
    local screen = mon.text()
    check(screen:find("RUNNING"), "status missing:\n%s", screen)
    check(not screen:find("Energy Core"), "core row shown without a core")
    check(screen:find("Field Strength T:50"), "field row missing:\n%s", screen)
    local ax, ay = mon.find(" AU ")
    check(ax and ui.handleTouch("monitor_0", ax + 1, ay) == "auto", "AU toggle hit-test failed")
    check(screen:find("Charging reactor"), "last action missing:\n%s", screen)
    local x, y = mon.find("START")
    check(x, "START button missing:\n%s", screen)
    check(ui.handleTouch("monitor_0", x, y) == "start", "START hit-test failed")
    x, y = mon.find(">>>")
    check(ui.handleTouch("monitor_0", x, y) == "out:100000", "+100k hit-test failed")
end)

test("small monitor falls back to scale 0.5", function()
    cc.reset(); freshModules()
    local mon = cc.newScreen(18, 12)    -- 2x2 at scale 1
    cc.addPeripheral("left", "monitor", mon)
    local ui = require("monitor_utils")
    ui.init({}, {})
    check(mon.scale == 0.5, "scale %s", tostring(mon.scale))
end)

test("no monitor uses the terminal", function()
    cc.reset(); freshModules()
    local ui = require("monitor_utils")
    check(ui.init({}, {}) == 0 and ui.usesTerminal(), "terminal fallback missing")
end)

------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------
local function wireSim(sim, gateType)
    cc.addPeripheral("draconic_reactor_0", "draconic_reactor", sim.reactor)
    cc.addPeripheral(gateType .. "_0", gateType, sim.inGate)
    cc.addPeripheral(gateType .. "_1", gateType, sim.outGate)
end

test("discovery works by method, any gate type name, asks once", function()
    for _, gateType in ipairs({"flux_gate", "flow_gate"}) do
        cc.reset(); freshModules()
        local sim = Sim.new()
        wireSim(sim, gateType)
        local reac = require("reac_utils")
        local asked = 0
        local hw = assert(reac.discover({}, function(g)
            asked = asked + 1
            return g[2], g[1]
        end))
        check(asked == 1, "asked %d times", asked)
        check(hw.input.name == gateType .. "_1", "input %s", hw.input.name)
        check(cc.settingsSaved, "mapping not saved")
        hw = assert(reac.discover({}, function() error("asked again") end))
        check(hw.output.name == gateType .. "_0", "saved mapping not reused")
    end
end)

test("discovery explains a missing gate", function()
    cc.reset(); freshModules()
    local sim = Sim.new()
    cc.addPeripheral("draconic_reactor_0", "draconic_reactor", sim.reactor)
    cc.addPeripheral("flow_gate_0", "flow_gate", sim.inGate)
    local hw, err = require("reac_utils").discover({}, nil)
    check(not hw and err:find("two flux gates"), "err %s", tostring(err))
end)

test("old DE build (generic energy_storage only) gets an update hint", function()
    cc.reset(); freshModules()
    local generic = {getEnergy = function() return 0 end,
                     getEnergyCapacity = function() return 1 end}
    cc.addPeripheral("energy_storage_0", "energy_storage", generic)
    cc.addPeripheral("energy_storage_1", "energy_storage", generic)
    local _, err = require("reac_utils").discover({}, nil)
    check(err and err:find("3.1.2.604"), "err %s", tostring(err))
end)

test("gate writes share one server tick (main-thread call cost)", function()
    cc.reset(); freshModules()
    local reac = require("reac_utils")
    local function slowGate()
        -- Mimic DE 1.20: every call waits for the next server tick.
        local g = {override = true}
        g.getFlow = function() sleep(0.05); return 0 end
        g.getOverrideEnabled = function() sleep(0.05); return true end
        g.setFlowOverride = function() sleep(0.05) end
        return g
    end
    local hw = {input = reac.wrapGate("in", slowGate()),
                output = reac.wrapGate("out", slowGate()),
                reactor = {}}
    -- Prime the override check so only the writes are timed.
    local ok, err = cc.run(function()
        reac.apply(hw, {input = 1, output = 1, events = {}})
        local t0 = os.clock()
        reac.apply(hw, {input = 2, output = 2, events = {}})
        cc.elapsed = os.clock() - t0
    end)
    check(ok, "crashed: %s", tostring(err))
    check(math.abs(cc.elapsed - 0.05) < 1e-6, "two writes took %.2fs", cc.elapsed)
end)

test("config names win and are validated", function()
    cc.reset(); freshModules()
    local sim = Sim.new()
    wireSim(sim, "flow_gate")
    local reac = require("reac_utils")
    local hw = assert(reac.discover({inputGate = "flow_gate_0", outputGate = "flow_gate_1"}))
    check(hw.input.name == "flow_gate_0", "config ignored")
    local _, err = reac.discover({inputGate = "draconic_reactor_0"})
    check(err and err:find("not a flux gate"), "err %s", tostring(err))
end)

------------------------------------------------------------
-- END TO END: main_control.lua under the virtual scheduler
------------------------------------------------------------
------------------------------------------------------------
-- MULTI-REACTOR
------------------------------------------------------------
-- Runs main_control.lua under the virtual scheduler.
--   opts.sims      simulators to tick with game time
--   opts.config    function(cfg) to edit config.lua before start
--   opts.at        {{t = seconds, fn = function() ... end}, ...}
--   opts.untilTime when Ctrl+T is "pressed"
local function runProgram(opts)
    freshModules()
    local cfg = require("config")
    if opts.config then opts.config(cfg) end
    local fn = assert((loadfile or load)("main_control.lua"))
    for i, step in ipairs(opts.at or {}) do cc.schedule(step.t, "__step", i) end
    local carry = 0
    local ok, err = cc.run(function()
        local realPull = os.pullEvent
        os.pullEvent = function(filter)
            while true do
                local ev = {realPull(filter == "__step" and nil or filter)}
                if ev[1] == "__step" then
                    opts.at[ev[2]].fn()
                elseif filter == nil or ev[1] == filter then
                    return (table.unpack or unpack)(ev)
                end
            end
        end
        fn()
        os.pullEvent = realPull
    end, {untilTime = opts.untilTime, onAdvance = function(dt)
        carry = carry + dt
        while carry >= TICK - 1e-9 do
            for _, sim in ipairs(opts.sims or {}) do sim:tick() end
            carry = carry - TICK
        end
    end})
    check(ok, "program crashed: %s\n%s", tostring(err), cc.outputText())
    check(not cc.outputText():find("Fatal"), "fatal error:\n%s", cc.outputText())
end

local function touchText(mon, needle)
    local x, y = mon.find(needle)
    check(x, "%q not on monitor:\n%s", needle, mon.text())
    os.queueEvent("monitor_touch", "monitor_0", x, y)
end

local function twoReactors()
    local a, b = Sim.new({version = "1.20"}), Sim.new({version = "1.12"})
    cc.addPeripheral("draconic_reactor_0", "draconic_reactor", a.reactor)
    cc.addPeripheral("draconic_reactor_1", "draconic_reactor", b.reactor)
    cc.addPeripheral("flow_gate_0", "flow_gate", a.inGate)
    cc.addPeripheral("flow_gate_1", "flow_gate", a.outGate)
    cc.addPeripheral("flow_gate_2", "flow_gate", b.inGate)
    cc.addPeripheral("flow_gate_3", "flow_gate", b.outGate)
    return a, b
end

local function configureTwo(cfg)
    cfg.reactor.autoStartOnBoot = true
    cfg.peripherals.reactors = {
        {name = "Alpha", reactor = "draconic_reactor_0",
         inputGate = "flow_gate_0", outputGate = "flow_gate_1"},
        {name = "Beta", reactor = "draconic_reactor_1",
         inputGate = "flow_gate_2", outputGate = "flow_gate_3",
         settings = {targetTemperature = 6500}}
    }
end

test("main_control: boot, prompt, overview, START, regulate, Ctrl+T fail-safe", function()
    cc.reset({inputs = {"1"}})
    local sim = Sim.new()
    wireSim(sim, "flow_gate")
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    local pylon = {stored = 5e9}
    pylon.getEnergyStored = function() return pylon.stored end
    pylon.getMaxEnergyStored = function() return 1e10 end
    cc.addPeripheral("draconic_rf_storage_0", "draconic_rf_storage", pylon)

    local sawOverview = false
    runProgram({sims = {sim}, untilTime = 1200, at = {
        -- Reactor + energy core: the monitor opens on the overview.
        {t = 3, fn = function()
            sawOverview = mon.text():find("Overview") ~= nil
            touchText(mon, "Reactor ")
        end},
        {t = 4, fn = function() touchText(mon, "START") end}
    }})
    check(sawOverview, "monitor did not open on the overview")
    check(not sim.exploded, "exploded")
    check(sim.state == "running", "state %s\n%s", sim.state, cc.outputText())
    check(math.abs(sim.temperature - 7000) < 150, "temperature %.0f", sim.temperature)
    -- Ctrl+T leaves gates fail-safe.
    check(sim.outFlow == 0, "output after exit %s", tostring(sim.outFlow))
    check(sim.inFlow >= 2000000 and sim.inFlow < 2000000 * 2.5,
          "input after exit %s", tostring(sim.inFlow))
    check(cc.readFile("logs/draconic.log"):find("Program exiting"), "exit not logged")
    local stats = cc.readFile("logs/reactor_stats.csv")
    check(stats and select(2, stats:gsub("\n", "")) > 50, "stats not recorded")
    check(mon.text():find("Energy Core") and mon.text():find("50.0%%"),
          "core not displayed:\n%s", mon.text())
end)

test("two reactors: independent control, per-reactor settings, paging", function()
    cc.reset()
    local a, b = twoReactors()
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    local sawAlphaPage = false
    runProgram({sims = {a, b}, config = configureTwo, untilTime = 1200, at = {
        {t = 5, fn = function() touchText(mon, "Alpha ") end},
        {t = 6, fn = function()
            sawAlphaPage = mon.text():find("Reactor Status") ~= nil and mon.text():find("Alpha") ~= nil
            touchText(mon, " < ")      -- back to the overview
        end},
        {t = 7, fn = function() touchText(mon, "Beta ") end}
    }})
    check(sawAlphaPage, "tapping Alpha's card did not open its page")
    check(mon.text():find("Beta") and mon.text():find("Reactor Status"),
          "navigation to Beta failed:\n%s", mon.text())
    check(a.state == "running" and b.state == "running", "states %s / %s", a.state, b.state)
    check(math.abs(a.temperature - 7000) < 150, "Alpha temperature %.0f", a.temperature)
    check(math.abs(b.temperature - 6500) < 150, "Beta override ignored: %.0f", b.temperature)
    check(cc.readFile("logs/draconic_alpha.csv"), "Alpha stats missing")
    check(cc.readFile("logs/draconic_beta.csv"), "Beta stats missing")
    check(cc.readFile("logs/draconic.log"):find("%[Beta%]"), "log lines not tagged by reactor")
end)

test("two reactors: one failing does not disturb the other", function()
    cc.reset()
    local a, b = twoReactors()
    runProgram({sims = {a, b}, config = configureTwo, untilTime = 900, at = {
        {t = 600, fn = function()
            b.reactor.getReactorInfo = function() error("peripheral detached") end
        end}
    }})
    check(a.state == "running" and math.abs(a.temperature - 7000) < 150,
          "Alpha disturbed: %s %.0f", a.state, a.temperature)
    check(not b.exploded, "Beta exploded")
    check(cc.readFile("logs/draconic.log"):find("%[Beta%] Reactor read failed"),
          "Beta failure not logged")
end)

test("setup wizard assigns gates per reactor and skips duplicates", function()
    -- reactor_2 is a second modem on Alpha's reactor: the player skips it.
    cc.reset({inputs = {"1", "2", "Alpha", "3", "4", "", ""}})
    local a, b = twoReactors()
    cc.addPeripheral("draconic_reactor_2", "draconic_reactor", a.reactor)
    runProgram({sims = {a, b}, untilTime = 5})
    local units = settings.get("draconic.units")
    check(type(units) == "table" and #units == 2, "saved %s", tostring(units and #units))
    check(units[1].name == "Alpha" and units[1].inputGate == "flow_gate_0", "Alpha wrong")
    check(units[2].name == "Reactor 2" and units[2].outputGate == "flow_gate_3", "Reactor 2 wrong")
    check(cc.outputText():find("Running 2 unit"), "did not start 2 units:\n%s", cc.outputText())
end)

------------------------------------------------------------
-- EXTREME / BIGGER REACTORS
------------------------------------------------------------
local ErSim = require("er_sim")

local ER_CFG = {bufferLow = 0.3, bufferHigh = 0.7, lowFuel = 0.1, targetRPM = 1800,
                maxRPM = 2000, coilsOffAbove = 0.95, coilsOnBelow = 0.8,
                autoStartOnBoot = true, controlInterval = 0.25}

local function erUtils() cc.reset(); freshModules(); return require("er_utils") end

-- Runs reactor + turbine controllers against the sim, steam-coupled the
-- same way drivers/extreme.lua couples them.
local function erLoop(er, sim, mod, seconds, onCycle)
    local units = {{a = er.wrap(mod .. "_reactor", "r", sim[mod .. "Reactor"]),
                    c = er.newBufferController(ER_CFG), last = {}}}
    for i, t in ipairs(sim[mod .. "Turbines"]) do
        table.insert(units, {a = er.wrap(mod .. "_turbine", "t" .. i, t),
                             c = er.newTurbineController(ER_CFG), last = {}})
    end
    local t = 0
    while t < seconds do
        local hint = nil
        if #units > 1 then
            hint = 0
            for i = 2, #units do hint = hint + (units[i].c.flow or 0) end
        end
        for i, u in ipairs(units) do
            local d = er.read(u.a)
            local out = u.c:step(d, t, i == 1 and sim.activelyCooled and hint or nil)
            local errs = er.apply(u.a, out, u.last)
            check(#errs == 0, "apply: %s", table.concat(errs, "; "))
        end
        for _ = 1, 5 do sim:tick() end
        t = t + 0.25
        if onCycle then onCycle(t, units) end
    end
    return units
end

test("ER/BR adapters normalise both APIs (Kelvin, battery vs steam, unassembled)", function()
    local er = erUtils()
    for _, mod in ipairs({"er", "br"}) do
        local sim = ErSim.new({active = true, rods = 50})
        for _ = 1, 400 do sim:tick() end
        local d = er.read(er.wrap(mod .. "_reactor", "r", sim[mod .. "Reactor"]))
        check(d.assembled and d.active and not d.activelyCooled, "%s flags", mod)
        check(math.abs(d.fuelTemp - sim:fuelTemp()) < 0.01, "%s fuel temp %.2f (Kelvin?)", mod, d.fuelTemp)
        check(math.abs(d.rods - 50) < 0.01 and d.capacity == sim.capacity, "%s rods/battery", mod)
        local steam = ErSim.new({activelyCooled = true})
        local ds = er.read(er.wrap(mod .. "_reactor", "r", steam[mod .. "Reactor"]))
        check(ds.activelyCooled and ds.steamMax == steam.steamMax and ds.capacity == nil, "%s steam mode", mod)
        local broken = ErSim.new({assembled = false})
        local du = er.read(er.wrap(mod .. "_reactor", "r", broken[mod .. "Reactor"]))
        check(du and du.assembled == false, "%s unassembled not reported", mod)
    end
end)

test("passive ER/BR reactor holds its FE buffer through load changes", function()
    for _, mod in ipairs({"er", "br"}) do
        local er = erUtils()
        local sim = ErSim.new({load = 10000})
        local lo, hi, rlo, rhi = 1, 0, 100, 0
        erLoop(er, sim, mod, 1200, function(t)
            if t == 400 then sim.load = 18000 elseif t == 700 then sim.load = 3000 end
            if t > 300 then
                local l = sim.stored / sim.capacity
                lo, hi = math.min(lo, l), math.max(hi, l)
            end
            if t > 1000 then rlo, rhi = math.min(rlo, sim.rods), math.max(rhi, sim.rods) end
        end)
        check(lo > 0.3 and hi < 0.7, "%s buffer left band: %.2f-%.2f", mod, lo, hi)
        check(rhi - rlo <= 6, "%s rods chatter in steady state: %.1f-%.1f", mod, rlo, rhi)
    end
end)

test("idle passive reactor with full buffer pushes rods in (saves fuel)", function()
    local er = erUtils()
    local sim = ErSim.new({load = 0, rods = 0, stored = 9500000})
    erLoop(er, sim, "er", 60)
    check(sim.rods == 100, "rods %s", tostring(sim.rods))
end)

test("steam reactor + 2 turbines: 1800 RPM, tank in band, no overspeed", function()
    for _, mod in ipairs({"er", "br"}) do
        local er = erUtils()
        local sim = ErSim.new({activelyCooled = true, maxOutput = 3000, turbines = 2,
                               turbineLoad = 6000, coilsEngaged = (mod == "br")})
        local lo, hi, rlo, rhi = 1, 0, 1e9, 0
        erLoop(er, sim, mod, 1200, function(t)
            if t > 600 then
                local l = sim.steam / sim.steamMax
                lo, hi = math.min(lo, l), math.max(hi, l)
                for _, tb in ipairs(sim.turbines) do
                    rlo, rhi = math.min(rlo, tb.rpm), math.max(rhi, tb.rpm)
                end
            end
        end)
        check(rlo > 1750 and rhi < 1850, "%s RPM %.0f-%.0f", mod, rlo, rhi)
        check(lo > 0.1 and hi < 0.9, "%s steam tank %.2f-%.2f", mod, lo, hi)
        for _, tb in ipairs(sim.turbines) do
            check(tb.maxRPMSeen < ER_CFG.maxRPM + 50, "%s overspeed %.0f", mod, tb.maxRPMSeen)
            check(tb.coils, "%s coils not engaged at speed", mod)
        end
    end
end)

test("turbine with a full buffer idles: coils off, speed held", function()
    local er = erUtils()
    local sim = ErSim.new({activelyCooled = true, maxOutput = 3000, turbines = 1, turbineLoad = 0})
    local units = erLoop(er, sim, "er", 1500)
    local tb = sim.turbines[1]
    check(units[2].c.mode == "idle", "mode %s", tostring(units[2].c.mode))
    check(not tb.coils, "coils still engaged with a full buffer")
    check(tb.rpm > 1700 and tb.maxRPMSeen < 2050, "rpm %.0f, peak %.0f", tb.rpm, tb.maxRPMSeen)
end)

test("Bigger Reactors turbine: default-engaged coils are released to spin up", function()
    local er = erUtils()
    local sim = ErSim.new({activelyCooled = true, maxOutput = 3000, turbines = 1,
                           turbineLoad = 6000, coilsEngaged = true})
    local sawRelease = false
    erLoop(er, sim, "br", 30, function() if not sim.turbines[1].coils then sawRelease = true end end)
    check(sawRelease, "coils never disengaged for spin-up")
end)

local function wireEr(sim, prefix)
    cc.addPeripheral(prefix .. "Reactor_0", "BigReactors-Reactor", sim.erReactor)
    for i, t in ipairs(sim.erTurbines) do
        cc.addPeripheral(prefix .. "Turbine_" .. (i - 1), "BigReactors-Turbine", t)
    end
end

test("program runs Extreme Reactors alone (no Draconic installed)", function()
    cc.reset()
    local sim = ErSim.new({activelyCooled = true, maxOutput = 3000, turbines = 2, turbineLoad = 6000})
    wireEr(sim, "BigReactors-")
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    local overview = ""
    runProgram({sims = {sim}, untilTime = 900,
                config = function(cfg) cfg.extreme.autoStartOnBoot = true end,
                at = {{t = 850, fn = function()
                    overview = mon.text()
                    touchText(mon, "Fission 1")
                end}}})
    check(overview:find("Overview") and overview:find("Turbine 2") and overview:find("1,800 RPM"),
          "overview:\n%s", overview)
    check(cc.outputText():find("Running 3 unit"), "units:\n%s", cc.outputText())
    check(math.abs(sim.turbines[1].rpm - 1800) < 60, "turbine rpm %.0f", sim.turbines[1].rpm)
    check(mon.text():find("Reactor Status") and mon.text():find("ONLINE STEAM"),
          "fission page:\n%s", mon.text())
    check(cc.readFile("logs/extreme_fission_1.csv"), "reactor stats missing")
    check(cc.readFile("logs/extreme_turbine_2.csv"), "turbine stats missing")
end)

test("program runs Draconic and Extreme side by side", function()
    cc.reset()
    local de = Sim.new({version = "1.20"})
    wireSim(de, "flow_gate")
    settings.set("draconic.inputGate", "flow_gate_0")
    settings.set("draconic.outputGate", "flow_gate_1")
    local er = ErSim.new({load = 10000})
    wireEr(er, "BigReactors-")
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    runProgram({sims = {de, er}, untilTime = 900, config = function(cfg)
        cfg.reactor.autoStartOnBoot = true
        cfg.extreme.autoStartOnBoot = true
    end, at = {{t = 5, fn = function() touchText(mon, "Fission 1") end}}})
    check(cc.outputText():find("Running 2 unit"), "units:\n%s", cc.outputText())
    check(de.state == "running" and math.abs(de.temperature - 7000) < 150, "draconic %s %.0f", de.state, de.temperature)
    local level = er.stored / er.capacity
    check(level > 0.3 and level < 0.7, "fission buffer %.2f", level)
    check(mon.text():find("Fission 1") and mon.text():find("Control Rods"),
          "opening the fission page failed:\n%s", mon.text())
end)

------------------------------------------------------------
-- MENUS, SETTINGS, PINS, GRAPHS
------------------------------------------------------------
-- Touches the - (dir < 0) or + button of the setting row `label`.
local function touchSetting(mon, label, dir)
    local _, y = mon.find(label)
    check(y, "setting %q not on screen:\n%s", label, mon.text())
    local w = mon.getSize()
    os.queueEvent("monitor_touch", "monitor_0", dir > 0 and w - 2 or w - 6, y)
end

test("persist.adjust: steps, linked limits, booleans, no float drift", function()
    cc.reset(); freshModules()
    local persist = require("persist")
    local schema = {
        {key = "t", step = 100, min = 1000, max = function(c) return c.m - 100 end},
        {key = "m", step = 100, min = function(c) return c.t + 100 end, max = 9000},
        {key = "f", step = 0.05, min = 0.1, max = 0.9},
        {key = "b", fmt = "bool"}
    }
    local cfg = {t = 7000, m = 8000, f = 0.5, b = true}
    for _ = 1, 30 do persist.adjust(cfg, schema, "t", 1) end
    check(cfg.t == 7900, "target passed trip: %s", tostring(cfg.t))
    for _ = 1, 30 do persist.adjust(cfg, schema, "m", -1) end
    check(cfg.m == 8000, "trip went below target: %s", tostring(cfg.m))
    for _ = 1, 7 do persist.adjust(cfg, schema, "f", -1) end
    check(math.abs(cfg.f - 0.15) < 1e-9, "fraction drifted: %.17g", cfg.f)
    check(persist.format({fmt = "pct"}, cfg.f) == "15%", "pct format")
    persist.adjust(cfg, schema, "b", 1)
    check(cfg.b == false, "bool did not toggle")
    check(persist.adjust(cfg, schema, "nope", 1) == nil, "unknown key accepted")
end)

local function oneReactorWithCore()
    local sim = Sim.new({version = "1.20"})
    wireSim(sim, "flow_gate")
    settings.set("draconic.inputGate", "flow_gate_0")
    settings.set("draconic.outputGate", "flow_gate_1")
    local pylon = {getEnergyStored = function() return 5e9 end,
                   getMaxEnergyStored = function() return 1e10 end}
    cc.addPeripheral("draconic_rf_storage_0", "draconic_rf_storage", pylon)
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    return sim, mon
end

test("settings page: live change, persisted across restart, reset", function()
    cc.reset()
    local sim, mon = oneReactorWithCore()
    local auto = function(cfg) cfg.reactor.autoStartOnBoot = true end
    runProgram({sims = {sim}, config = auto, untilTime = 900, at = {
        {t = 3, fn = function() touchText(mon, "Reactor ") end},
        {t = 4, fn = function() touchText(mon, " S ") end},
        -- Five presses of - on Target Temp: 7000 -> 6500.
        {t = 5, fn = function() touchSetting(mon, "Target Temp", -1) end},
        {t = 6, fn = function() touchSetting(mon, "Target Temp", -1) end},
        {t = 7, fn = function() touchSetting(mon, "Target Temp", -1) end},
        {t = 8, fn = function() touchSetting(mon, "Target Temp", -1) end},
        {t = 9, fn = function() touchSetting(mon, "Target Temp", -1) end}
    }})
    check(mon.text():find("6,500C"), "settings page value:\n%s", mon.text())
    check(math.abs(sim.temperature - 6500) < 150, "live change ignored: %.0f", sim.temperature)
    check(cc.readFile("data/manager.db"):find("targetTemperature"), "override not saved")

    -- Restart: the override must be back, then RESET returns to config.lua.
    cc.output = {}
    runProgram({sims = {sim}, config = auto, untilTime = 1800, at = {
        {t = 905, fn = function() touchText(mon, "Reactor ") end},
        {t = 906, fn = function() touchText(mon, " S ") end},
        {t = 907, fn = function()
            check(mon.text():find("6,500C"), "override lost on restart:\n%s", mon.text())
            touchText(mon, "RESET")
        end}
    }})
    check(mon.text():find("7,000C"), "reset did not restore config:\n%s", mon.text())
    check(math.abs(sim.temperature - 7000) < 150, "reset not applied live: %.0f", sim.temperature)
end)

test("pinning a monitor keeps it on its unit across restarts", function()
    cc.reset()
    local sim, mon = oneReactorWithCore()
    runProgram({sims = {sim}, untilTime = 10, at = {
        {t = 3, fn = function() touchText(mon, "Reactor ") end},
        {t = 4, fn = function() touchText(mon, " S ") end},
        {t = 5, fn = function() touchText(mon, "PIN HERE") end},
        {t = 6, fn = function() touchText(mon, " X ") end}
    }})
    check(mon.text():find("Reactor Status"), "not on the unit page:\n%s", mon.text())
    check(mon.getLine(2):sub(1, 3) ~= " < ", "pinned monitor still offers the overview:\n%s", mon.text())
    cc.output = {}
    runProgram({sims = {sim}, untilTime = 20})
    check(mon.text():find("Reactor Status") and not mon.text():find("Overview"),
          "pin lost on restart:\n%s", mon.text())
end)

test("config.ui.monitorUnits pins a monitor by unit name", function()
    cc.reset()
    local sim, mon = oneReactorWithCore()
    runProgram({sims = {sim}, untilTime = 5, config = function(cfg)
        cfg.ui.monitorUnits = {monitor_0 = "Energy Core"}
    end})
    check(mon.text():find("Storage") and mon.text():find("Charge"), "not pinned to core:\n%s", mon.text())
end)

test("graphs page draws history charts", function()
    cc.reset()
    local sim, mon = oneReactorWithCore()
    runProgram({sims = {sim}, untilTime = 300, config = function(cfg)
        cfg.reactor.autoStartOnBoot = true
        cfg.ui.graphInterval = 2
    end, at = {
        {t = 280, fn = function() touchText(mon, "Reactor ") end},
        {t = 281, fn = function() touchText(mon, " G ") end}
    }})
    local text = mon.text()
    check(text:find("Temperature") and text:find("Field"), "chart labels:\n%s", text)
    local filled = 0
    for y = 1, 19 do
        for x = 2, 28 do
            local bg = mon.bgRows[y][x]
            if bg == colors.orange or bg == colors.green then filled = filled + 1 end
        end
    end
    check(filled > 40, "charts look empty (%d filled cells):\n%s", filled, text)
end)

test("overview pages through many units", function()
    cc.reset()
    local sim = ErSim.new({activelyCooled = true, maxOutput = 9000, turbines = 6, turbineLoad = 2000})
    wireEr(sim, "BigReactors-")
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    local first = ""
    runProgram({sims = {sim}, untilTime = 10, at = {
        {t = 3, fn = function() first = mon.text(); touchText(mon, " > ") end}
    }})
    -- 7 units, 3 cards per page on a 3x3 monitor.
    check(first:find("1/3") and first:find("Fission 1") and not first:find("Turbine 3"),
          "first overview page:\n%s", first)
    check(mon.text():find("2/3") and mon.text():find("Turbine 3") and not mon.text():find("Fission 1"),
          "second page:\n%s", mon.text())
end)

------------------------------------------------------------
-- ENERGY STORAGE
------------------------------------------------------------
-- Mock peripherals, one per supported API.
local function genericStore(stored, capacity)
    local d = {stored = stored, capacity = capacity}
    d.getEnergy = function() return math.min(d.stored, 2147483647) end
    d.getEnergyCapacity = function() return math.min(d.capacity, 2147483647) end
    return d
end

local function pylonDev(stored, capacity, rates)
    local d = {stored = stored, input = 0, output = 0}
    d.getEnergyStored = function() return d.stored end
    d.getMaxEnergyStored = function() return capacity end
    if rates then
        d.getInputPerTick = function() return d.input end
        d.getOutputPerTick = function() return d.output end
        d.getTransferPerTick = function() return d.input - d.output end
    end
    return d
end

-- Mekanism induction port: everything in Joules.
local function matrixDev(storedJ, capacityJ, lo, hi)
    local d = {stored = storedJ, inJ = 0, outJ = 0, formed = true}
    d.isFormed = function() return d.formed end
    d.getEnergy = function() return d.stored end
    d.getMaxEnergy = function() return capacityJ end
    d.getEnergyNeeded = function() return capacityJ - d.stored end
    d.getEnergyFilledPercentage = function() return d.stored / capacityJ end
    d.getLastInput = function() return d.inJ end
    d.getLastOutput = function() return d.outJ end
    d.getTransferCap = function() return 1e9 end
    d.getMinPos = function() return lo or {x = 0, y = 64, z = 0} end
    d.getMaxPos = function() return hi or {x = 4, y = 68, z = 4} end
    return d
end

local function cubeDev(storedJ, capacityJ)
    return {getEnergy = function() return storedJ end, getMaxEnergy = function() return capacityJ end,
            getEnergyNeeded = function() return capacityJ - storedJ end,
            getEnergyFilledPercentage = function() return storedJ / capacityJ end}
end

-- Flux Networks controller through UnlimitedPeripheralWorks.
local function fluxDev(stored, capacity, input, output, id)
    return {getEnergy = function() return stored end, getEnergyCapacity = function() return capacity end,
            getEnergyUnit = function() return "FORGE" end,
            getNetwork = function() return {id = id or 1, name = "Base"} end,
            getStatistic = function() return {energyInput = input, energyOutput = output,
                                               totalEnergy = stored, totalBuffer = 0} end}
end

local function detectorDev(rate)
    return {getTransferRate = function() return rate end,
            getTransferRateLimit = function() return 2147483647 end,
            setTransferRateLimit = function() error("must not be called") end}
end

local function storageCtx(cfg, known)
    local logged = {}
    return {config = cfg, import = function(n) return require(n) end, known = known,
            log = {log = function(_, m) table.insert(logged, m) end, recordRow = function() end},
            logged = logged}
end

local function storageDriver()
    freshModules()
    return require("drivers.storage"), require("config")
end

local function byName(units)
    local out = {}
    for _, u in ipairs(units) do out[u.name] = u end
    return out
end

local function namesOf(units)
    local t = {}
    for _, u in ipairs(units) do t[#t + 1] = u.name end
    return table.concat(t, ", ")
end

test("storage: every API classified, other drivers' blocks and duplicates skipped", function()
    cc.reset()
    local sim = Sim.new()
    wireSim(sim, "flow_gate")
    local er = ErSim.new({})
    wireEr(er, "BigReactors-")
    cc.addPeripheral("monitor_0", "monitor", cc.newScreen(29, 19))
    cc.addPeripheral("draconic_rf_storage_0", "draconic_rf_storage", pylonDev(5e9, 1e10, true))
    -- Two ports of ONE induction matrix (same bounds) and a second matrix.
    cc.addPeripheral("inductionPort_0", "inductionPort", matrixDev(2.5e9, 5e9))
    cc.addPeripheral("inductionPort_1", "inductionPort", matrixDev(2.5e9, 5e9))
    cc.addPeripheral("inductionPort_2", "inductionPort",
                     matrixDev(1e6, 2e6, {x = 100, y = 0, z = 0}, {x = 103, y = 3, z = 3}))
    cc.addPeripheral("ultimateEnergyCube_0", "ultimateEnergyCube", cubeDev(1e6, 2.56e8))
    -- Two blocks of one EnderIO bank report the whole bank; Thermal cells
    -- with the same numbers are different stores.
    local bank = {"enderio:vibrant_capacitor_bank", "energy_storage"}
    local cell = {"thermal:energy_cell", "energy_storage"}
    cc.addPeripheral("enderio:vibrant_capacitor_bank_0", bank, genericStore(3e6, 2.5e7))
    cc.addPeripheral("enderio:vibrant_capacitor_bank_1", bank, genericStore(3e6, 2.5e7))
    cc.addPeripheral("thermal:energy_cell_0", cell, genericStore(3e6, 2.5e7))
    cc.addPeripheral("thermal:energy_cell_1", cell, genericStore(3e6, 2.5e7))
    -- Transit buffers and reactor power taps are not storage.
    cc.addPeripheral("fluxnetworks:flux_point_0", {"fluxnetworks:flux_point", "energy_storage"}, genericStore(5, 100))
    cc.addPeripheral("bigreactors:reactorpowertap_0", {"bigreactors:reactorpowertap", "energy_storage"},
                     genericStore(1, 10))
    cc.addPeripheral("fluxnetworks:flux_controller_0", {"fluxnetworks:flux_controller", "flux_controller"},
                     fluxDev(4e9, 8e9, 3000, 1000))
    cc.addPeripheral("energyDetector_0", "energyDetector", detectorDev(4096))

    local drv, cfg = storageDriver()
    local units = drv.discover(storageCtx(cfg))
    local n = byName(units)
    local kinds = {}
    for _, u in ipairs(units) do kinds[u.kind] = (kinds[u.kind] or 0) + 1 end
    check(kinds.storage == 8 and kinds.meter == 1 and kinds.network == 1,
          "storage %s meter %s network %s: %s", tostring(kinds.storage), tostring(kinds.meter),
          tostring(kinds.network), namesOf(units))
    check(units[1].name == "Energy Core" and units[1].id == "energy_core:draconic_rf_storage_0",
          "pylon is not the primary storage: %s", namesOf(units))
    check(n["Induction Matrix"] and n["Induction Matrix 2"] and not n["Induction Matrix 3"],
          "matrix ports not deduplicated: %s", namesOf(units))
    check(n["Vibrant Capacitor"] and not n["Vibrant Capacitor 2"], "capacitor bank: %s", namesOf(units))
    check(n["Energy Cell"] and n["Energy Cell 2"], "two Thermal cells merged: %s", namesOf(units))
    check(n["Flux Network"] and n["Energy Meter"] and n["Energy Cube"], "flux/meter/cube missing")
    for _, u in ipairs(units) do
        local p = u.adapter and u.adapter.name or ""
        check(not p:find("flux_point") and not p:find("powertap") and not p:find("flow_gate")
              and not p:find("draconic_reactor") and not p:find("BigReactors"), "%s claimed", p)
    end
    local flux = n["Flux Network"].info
    check(flux.input == 3000 and flux.output == 1000 and flux.net == 2000, "flux rates %s/%s/%s",
          tostring(flux.input), tostring(flux.output), tostring(flux.net))
    check(n["Energy Meter"].info.rate == 4096, "meter rate")
    check(n["Energy Cube"].info.max == 2.56e8 / 2.5, "cube not converted to FE")
end)

test("storage: config include/exclude/names and energyCore", function()
    cc.reset()
    cc.addPeripheral("thermal:energy_cell_0", {"thermal:energy_cell", "energy_storage"}, genericStore(1, 10))
    cc.addPeripheral("thermal:energy_cell_1", {"thermal:energy_cell", "energy_storage"}, genericStore(2, 10))
    cc.addPeripheral("fluxnetworks:flux_plug_0", {"fluxnetworks:flux_plug", "energy_storage"}, genericStore(5, 100))
    local drv, cfg = storageDriver()
    cfg.storage.exclude = {"thermal:*_1"}
    cfg.storage.names = {["thermal:energy_cell_0"] = "Cell A"}
    local n = byName(drv.discover(storageCtx(cfg)))
    check(n["Cell A"] and not n["Energy Cell"] and not n["Energy Cell 2"] and not n["Flux Plug"],
          "exclude/names ignored")
    cfg.storage.exclude, cfg.storage.include = {}, {"fluxnetworks:flux_plug_0"}
    n = byName(drv.discover(storageCtx(cfg)))
    check(n["Flux Plug"] and not n["Cell A"], "include did not whitelist / force")
    cfg.storage.include = {}
    cfg.storage.enabled = false
    check(#drv.discover(storageCtx(cfg)) == 0, "disabled storage still found units")
    cfg.storage.enabled = true
    cfg.peripherals.energyCore = "thermal:energy_cell_1"
    local units = drv.discover(storageCtx(cfg))
    check(units[1].adapter.name == "thermal:energy_cell_1", "configured energyCore is not primary")
    cfg.peripherals.energyCore = "missing_0"
    local _, err = drv.discover(storageCtx(cfg))
    check(err and err:find("not attached"), "err %s", tostring(err))
end)

test("storage: Mekanism Joules become FE (default 2.5 and server rate)", function()
    cc.reset(); freshModules()
    local su = require("storage_utils")
    su.resetConversion()
    local m = matrixDev(2.5e9, 5e9)
    m.inJ, m.outJ = 25000, 5000
    local a = su.wrap(su.classify("inductionPort_0", m, {"inductionPort"}), "inductionPort_0", m, "inductionPort")
    local info = su.newTracker():update(a.read(), 0)
    check(info.stored == 1e9 and info.max == 2e9, "stored %s max %s", tostring(info.stored), tostring(info.max))
    check(info.input == 10000 and info.output == 2000 and info.net == 8000, "rates %s %s %s",
          tostring(info.input), tostring(info.output), tostring(info.net))
    m.formed = false
    check(su.newTracker():update(a.read(), 1).formed == false, "unformed matrix not reported")
    -- Server configured 4 J per FE: the in-game helper wins.
    su.resetConversion()
    mekanismEnergyHelper = {joulesToFE = function(j) return j / 4 end}
    local c = cubeDev(4e6, 8e6)
    local cube = su.wrap(su.classify("basicEnergyCube_0", c, {"basicEnergyCube"}), "basicEnergyCube_0", c,
                         "basicEnergyCube")
    local r = cube.read()
    mekanismEnergyHelper = nil
    su.resetConversion()
    check(r.stored == 1e6 and r.capacity == 2e6, "helper rate ignored: %s", tostring(r.stored))
end)

test("storage: flow derived from stored energy over virtual time, ETA", function()
    cc.reset()
    local drv, cfg = storageDriver()
    local store = genericStore(1e8, 1e9)
    cc.addPeripheral("powah:energy_cell_0", {"powah:energy_cell", "energy_storage"}, store)
    local unit = drv.discover(storageCtx(cfg))[1]
    local rate = 1000                                   -- FE/t into the cell
    local function feed(dt) store.stored = store.stored + rate * dt * 20 end
    cc.run(unit.run, {untilTime = 60, onAdvance = feed})
    local i = unit.info
    check(math.abs(i.net - 1000) < 20, "derived net %.1f", i.net)
    check(not i.measured and i.input == nil, "derived flow reported as measured")
    local expect = (1e9 - i.stored) / (1000 * 20)
    check(math.abs(i.timeToFull - expect) / expect < 0.03, "time to full %.0f vs %.0f", i.timeToFull, expect)
    check(i.timeToEmpty == nil, "time to empty while charging")
    rate = -2000
    cc.run(unit.run, {untilTime = 120, onAdvance = feed})
    i = unit.info
    check(math.abs(i.net + 2000) < 60, "draining net %.1f", i.net)
    local empty = i.stored / 40000
    check(i.timeToFull == nil and math.abs(i.timeToEmpty - empty) < empty * 0.05,
          "time to empty %s vs %.0f", tostring(i.timeToEmpty), empty)
    -- 32-bit generic values saturate.
    store.stored, store.capacity = 5e9, 6e9
    check(unit.adapter.read().saturated, "int cap not flagged")
end)

test("storage: hot-plug rescan skips known units and known stores", function()
    cc.reset()
    local bank = {"enderio:basic_capacitor_bank", "energy_storage"}
    cc.addPeripheral("enderio:basic_capacitor_bank_0", bank, genericStore(5e5, 1e6))
    local drv, cfg = storageDriver()
    local first = drv.discover(storageCtx(cfg))
    check(#first == 2, "first discovery: %s", namesOf(first))
    local ids = {}
    for _, u in ipairs(first) do ids[u.id] = true end
    local known = function(id) return ids[id] == true end
    local again = drv.discover(storageCtx(cfg, known))
    check(#again == 0, "known units rediscovered: %s", namesOf(again))
    -- A second block of the same bank and a new matrix are hot-plugged.
    cc.addPeripheral("enderio:basic_capacitor_bank_1", bank, genericStore(5e5, 1e6))
    cc.addPeripheral("inductionPort_0", "inductionPort", matrixDev(1e6, 2e6))
    local added = drv.discover(storageCtx(cfg, known))
    check(#added == 1 and added[1].name == "Induction Matrix", "rescan added: %s", namesOf(added))
end)

test("energy network: Draconic reactor feeding a core, overview and network page on 29x19", function()
    cc.reset()
    local sim = Sim.new({version = "1.20"})
    wireSim(sim, "flow_gate")
    settings.set("draconic.inputGate", "flow_gate_0")
    settings.set("draconic.outputGate", "flow_gate_1")
    local LOAD = 2e6                                     -- base consumption, FE/t
    local core = pylonDev(4e10, 1e13, true)
    -- The core takes the output gate's flow and feeds the injector + load.
    local coreSim = {tick = function()
        core.input, core.output = sim.outFlow or 0, (sim.inFlow or 0) + LOAD
        core.stored = core.stored + core.input - core.output
    end}
    cc.addPeripheral("draconic_rf_storage_0", "draconic_rf_storage", core)
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    local overview, netPage, graphs, flows = "", "", "", nil
    runProgram({sims = {sim, coreSim}, untilTime = 900, config = function(cfg)
        cfg.reactor.autoStartOnBoot = true
        cfg.ui.graphInterval = 2
    end, at = {
        {t = 840, fn = function()
            overview = mon.text()
            flows = {gen = sim.outFlow, use = sim.inFlow + LOAD}
            touchText(mon, "Energy Network")
        end},
        {t = 841, fn = function() netPage = mon.text(); touchText(mon, " G ") end},
        {t = 842, fn = function() graphs = mon.text() end}
    }})
    check(sim.state == "running", "reactor %s", sim.state)
    -- Overview: total, network line, 3 cards (reactor, core, network) on one page.
    check(overview:find("Overview") and overview:find("Use ") and overview:find("Energy Core")
          and overview:find("Energy Network") and overview:find("Reactor") and not overview:find("1/2"),
          "overview:\n%s", overview)
    check(netPage:find("Generation") and netPage:find("Consumption") and netPage:find("Storage Net")
          and netPage:find("CHARGING"), "network page:\n%s", netPage)
    check(graphs:find("Generation") and graphs:find("Consumption"), "network graphs:\n%s", graphs)
    -- Consumption = generation - net storage flow = injector draw + load.
    local csv = cc.readFile("logs/energy_network.csv")
    check(csv, "network stats missing")
    local last = csv:match("([^\n]+)\n$")
    local cells = {}
    for c in (last .. ","):gmatch("([^,]*),") do table.insert(cells, tonumber(c) or false) end
    local gen, use, net = cells[2], cells[3], cells[4]
    check(gen and math.abs(gen - flows.gen) / flows.gen < 0.05, "generation %s vs %.0f", tostring(gen), flows.gen)
    check(math.abs(use - flows.use) / flows.use < 0.1, "consumption %.0f, expected ~%.0f (gen %.0f net %.0f)",
          use, flows.use, gen, net)
    check(math.abs(net - (gen - use)) < 1, "net %.0f", net)
    check(cc.readFile("logs/storage_energy_core.csv"), "storage stats missing")
end)

test("modules never call require (os.loadAPI environments lack it)", function()
    for _, f in ipairs(MODULE_FILES) do
        local h = assert(io.open(f, "r"))
        local src = h:read("*a")
        h:close()
        check(not src:find("require%s*%("), "%s calls require", f)
        check(not src:find("os%.loadAPI"), "%s uses os.loadAPI", f)
    end
end)

test("main_control starts without require (issue 3: os.run / dofile)", function()
    cc.reset()
    freshModules()
    for _, f in ipairs(MODULE_FILES) do
        cc.writeFile(f, readRepoFileEarly(f))
    end
    local savedRequire = require
    local chunk = assert((loadfile or load)("main_control.lua"))
    require = nil
    local ok, err = cc.run(chunk, {untilTime = 1})
    require = savedRequire
    check(ok, "crashed: %s", tostring(err))
    local out = cc.outputText()
    check(not out:find("attempt to call"), "require error:\n%s", out)
    check(out:find("No reactor found"), "did not reach discovery:\n%s", out)
end)

------------------------------------------------------------
-- INSTALLERS
------------------------------------------------------------
local function readRepoFile(name)
    local h = assert(io.open(name, "r"))
    local s = h:read("*a")
    h:close()
    return s
end

test("install.lua downloads all files and creates startup.lua", function()
    local requested = {}
    cc.reset({http = {get = function(url)
        table.insert(requested, url)
        local name = url:match("/main/(.+)$")
        local ok, body = pcall(readRepoFile, name)
        if not ok then return nil, "404" end
        return {getResponseCode = function() return 200 end,
                readAll = function() return body end, close = function() end}
    end}})
    local fn = assert((loadfile or load)("install.lua"))
    local ok, err = cc.run(fn)
    check(ok, "installer crashed: %s", tostring(err))
    for _, f in ipairs(PROGRAM_FILES) do
        check(cc.readFile(f) == readRepoFile(f), "%s not installed", f)
    end
    check(cc.readFile("startup.lua"):find("main_control"), "startup.lua missing")
    for _, url in ipairs(requested) do
        check(url:find("^https://raw.githubusercontent.com/owzo/CC%-Tweaked%-Draconic%-Manager/main/"),
              "bad url %s", url)
    end
end)

test("installers ship exactly the program files", function()
    for _, installer in ipairs({"install.lua", "offline_install.lua"}) do
        local src = readRepoFile(installer)
        local listed = {}
        for name in src:gmatch('"([%w_/]+%.lua)",?%s*\n') do listed[name] = true end
        for _, f in ipairs(PROGRAM_FILES) do
            check(listed[f], "%s does not ship %s", installer, f)
        end
        for name in pairs(listed) do
            local known = false
            for _, f in ipairs(PROGRAM_FILES) do if f == name then known = true end end
            check(known, "%s ships unknown file %s", installer, name)
        end
    end
end)

test("install.lua leaves files untouched when a download fails", function()
    cc.reset({http = {get = function() return nil, "blocked" end}})
    cc.writeFile("main_control.lua", "old")
    local ok = cc.run(assert((loadfile or load)("install.lua")))
    check(ok, "installer crashed")
    check(cc.readFile("main_control.lua") == "old", "partial install happened")
end)

test("offline_install.lua copies from a disk drive", function()
    cc.reset()
    cc.addPeripheral("drive_0", "drive", {})
    cc.drives["drive_0"] = "disk"
    for _, f in ipairs(PROGRAM_FILES) do
        cc.writeFile("disk/" .. f, readRepoFile(f))
    end
    cc.writeFile("config.lua", "-- tuned by player")
    local ok, err = cc.run(assert((loadfile or load)("offline_install.lua")))
    check(ok, "offline installer crashed: %s", tostring(err))
    check(cc.readFile("reac_utils.lua") == readRepoFile("reac_utils.lua"), "not copied")
    check(cc.readFile("config.lua") == "-- tuned by player", "config overwritten")
    check(cc.readFile("startup.lua"), "startup.lua missing")
end)

------------------------------------------------------------
realPrint(string.format("\n%d passed, %d failed", results.passed, results.failed))
if results.failed > 0 then os.exit(1) end
