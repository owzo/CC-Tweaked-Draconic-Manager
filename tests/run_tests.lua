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
                 "energy_core_utils"}
local TICK = 0.05

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
    local files = {"config.lua", "main_control.lua", "reac_utils.lua", "monitor_utils.lua",
                   "stat_utils.lua", "energy_core_utils.lua", "install.lua", "offline_install.lua"}
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
    ui.render({info = reac.readInfo(sim.reactor), controller = ctl, limits = cfg.reactor, events = {}})
    local screen = mon.text()
    check(screen:find("RUNNING"), "status missing:\n%s", screen)
    check(screen:find("Core: not connected"), "core line missing")
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
test("main_control: boot, prompt, START, regulate, Ctrl+T fail-safe", function()
    cc.reset({inputs = {"1"}})
    freshModules()
    local sim = Sim.new()
    wireSim(sim, "flow_gate")
    local mon = cc.newScreen(29, 19)
    cc.addPeripheral("monitor_0", "monitor", mon)
    local pylon = {stored = 5e9}
    pylon.getEnergyStored = function() return pylon.stored end
    pylon.getMaxEnergyStored = function() return 1e10 end
    cc.addPeripheral("draconic_rf_storage_0", "draconic_rf_storage", pylon)

    local fn = assert((loadfile or load)("main_control.lua"))
    -- Touch START once the dashboard has been drawn.
    cc.schedule(3, "__touch_start")
    local tick = advancer(sim)
    local started = false
    local ok, err = cc.run(function()
        -- Translate the marker into a real touch at START's coordinates.
        local realPull = os.pullEvent
        os.pullEvent = function(filter)
            while true do
                local ev = {realPull(filter == "__touch_start" and nil or filter)}
                if ev[1] == "__touch_start" then
                    local x, y = mon.find("START")
                    started = x ~= nil
                    if x then os.queueEvent("monitor_touch", "monitor_0", x, y) end
                elseif filter == nil or ev[1] == filter then
                    return (table.unpack or unpack)(ev)
                end
            end
        end
        fn()
        os.pullEvent = realPull
    end, {untilTime = 1200, onAdvance = tick})

    check(ok, "program crashed: %s\n%s", tostring(err), cc.outputText())
    check(started, "START never appeared on monitor:\n%s", mon.text())
    check(not cc.outputText():find("Fatal"), "fatal error:\n%s", cc.outputText())
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
    check(mon.text():find("Core 50.0%%"), "core not displayed:\n%s", mon.text())
end)

test("modules never call require (os.loadAPI environments lack it)", function()
    for _, f in ipairs({"config.lua", "reac_utils.lua", "monitor_utils.lua",
                        "stat_utils.lua", "energy_core_utils.lua"}) do
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
    for _, f in ipairs({"config.lua", "reac_utils.lua", "monitor_utils.lua",
                        "stat_utils.lua", "energy_core_utils.lua"}) do
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
    for _, f in ipairs({"main_control.lua", "reac_utils.lua", "monitor_utils.lua",
                        "stat_utils.lua", "energy_core_utils.lua", "config.lua"}) do
        check(cc.readFile(f) == readRepoFile(f), "%s not installed", f)
    end
    check(cc.readFile("startup.lua"):find("main_control"), "startup.lua missing")
    for _, url in ipairs(requested) do
        check(url:find("^https://raw.githubusercontent.com/owzo/CC%-Tweaked%-Draconic%-Manager/main/"),
              "bad url %s", url)
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
    for _, f in ipairs({"main_control.lua", "reac_utils.lua", "monitor_utils.lua",
                        "stat_utils.lua", "energy_core_utils.lua", "config.lua"}) do
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
