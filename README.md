# CC:Tweaked-Draconic Manager

A ComputerCraft: Tweaked program that runs a Draconic Evolution reactor:
it charges and starts the reactor, holds the containment field and core
temperature at their targets, trips to a controlled shutdown on unsafe
conditions, and shows everything on a touchscreen dashboard.

## Features

- **Field regulation**: input gate set to `fieldDrainRate / (1 - targetField)`, which holds the field at 50% by default.
- **Temperature regulation**: output gate holds the core at `targetTemperature` (7000 °C by default). There is also a manual output mode with ±1k / 10k / 100k buttons.
- **Trips**: when a limit is crossed the reactor gets a controlled stop. The containment field stays fed until the reactor is cold. The limits are:
  - temperature above `maxTemperature` (8000 °C)
  - field below `minField` (20%)
  - remaining fuel below `minFuel` (10%)
- **Auto-restart**: after a temperature or field trip the reactor restarts once it has cooled below `safeTemperature`. This is capped at 3 restarts per hour, after which a person has to press START. A low-fuel trip never restarts on its own.
- **Fail-safe exit**: if the program stops (Ctrl+T, crash, reactor link lost), the input gate goes to `maxInflow` and the output gate goes to 0.
- **Plug-and-play detection**: peripherals are found by the methods they expose, not by their names. This covers DE 1.12 `flux_gate`, DE 1.16+ `flow_gate`, and any modem name. If two gates are found you are asked once which one is the input, and the answer is saved.
- **Dashboard**: shows status, generation, temperature, field, saturation, fuel, gate rates, an optional energy core readout and alarms. It works on any number of monitors and falls back to the computer screen when none are attached.
- **Logging**: events go to `logs/draconic.log` and a stats CSV to `logs/reactor_stats.csv`. Both rotate in size so the disk can never fill up.

## Requirements

- Minecraft with **Draconic Evolution** and **CC:Tweaked**
- A fully built reactor (core, 4 stabilizers, 1+ injector) with fuel
- Two **flux gates**:
  - **input gate**: energy source → gate → reactor **energy injector**
  - **output gate**: reactor **stabilizer** → gate → your storage (energy core)
- An **Advanced Computer**
- Optional: advanced monitors (3x3 recommended) and an energy core pylon

### Wiring (read this first)

```text
  [Computer]--wired modem
                  |  networking cable
                  +--wired modem--[Reactor Stabilizer]
                  +--wired modem--[Input Flux Gate]   (feeds Energy Injector)
                  +--wired modem--[Output Flux Gate]  (fed by a Stabilizer)
                  +--wired modem--[Monitor]           (optional)
                  +--wired modem--[Energy Pylon]      (optional)
```

- Use **wired** modems and networking cable. *Wireless and ender modems
  cannot attach peripherals.* Earlier versions of this README said to use
  wireless modems, and that is why "input flux gate not found" happened ([issue 5](https://github.com/owzo/CC-Tweaked-Draconic-Manager/issues/5)).
- **Right-click every wired modem** after placing it. The ring turns red and
  chat prints `Peripheral "flow_gate_0" connected to network`. A modem that
  hasn't been right-clicked is invisible to the computer.
- Instead of a modem you can place a peripheral directly against the computer.
- Run `peripherals` in the computer shell to see what it can reach.

## Installation

```shell
wget https://raw.githubusercontent.com/owzo/CC-Tweaked-Draconic-Manager/main/install.lua install.lua
install
```

The installer downloads every file before writing any of them, so a failed
download changes nothing. It keeps an existing `config.lua` and creates
`startup.lua`, so the manager restarts after reboots and chunk reloads.
Running `install` again updates the program.

### Offline (HTTP API disabled)

1. Put all `.lua` files from this repository on a floppy disk. In single
   player you can copy them into
   `saves/<world>/computercraft/disk/<disk id>/`.
2. Insert the disk into a disk drive next to the computer.
3. Run `disk/offline_install`.
4. Remove the disk, then run `main_control` (or reboot).

## First run

1. Run `main_control`.
2. If it lists two flux gates, enter the number of the gate that feeds the
   **energy injector**. This is saved. To change it later:
   `set draconic.inputGate flow_gate_1` and `set draconic.outputGate flow_gate_0`.
3. Press **START** on the monitor. The manager charges the reactor, activates
   it when warm-up is complete, then regulates it.

A reactor that is already running when the program starts keeps running. A
cold reactor is only charged after START, unless `autoStartOnBoot = true`.

## Controls

| Button | Action |
| --- | --- |
| `<<<` `<<` `<` / `>` `>>` `>>>` | Output −/+ 100k, 10k, 1k RF/t (switches to manual) |
| `START` | Charge + activate; clears a latched trip |
| `STOP` | Controlled shutdown (field stays fed until cold) |
| `MANUAL` / `AUTO` | Toggle automatic temperature regulation |

In manual mode an interlock switches back to AUTO once the temperature passes
halfway between the target and the trip limit.

## Configuration (`config.lua`)

| Key | Default | Meaning |
| --- | --- | --- |
| `peripherals.*` | `nil` | Force a peripheral name instead of auto-detecting |
| `reactor.targetTemperature` | 7000 | Regulated core temperature (°C) |
| `reactor.targetField` | 0.50 | Regulated field strength |
| `reactor.maxTemperature` | 8000 | Trip above this |
| `reactor.minField` | 0.20 | Trip below this |
| `reactor.minFuel` | 0.10 | Trip when remaining fuel is below this |
| `reactor.safeTemperature` | 3000 | Auto-restart only below this |
| `reactor.autoRestart` | true | Restart after temperature/field trips |
| `reactor.chargeInflow` | 2,000,000 | Input during warm-up (RF/t) |
| `reactor.maxInflow` | 20,000,000 | Input cap, also used in emergencies |
| `reactor.maxOutflow` | 30,000,000 | Output cap |
| `reactor.outputAggressiveness` | 1.0 | Temperature loop gain multiplier |
| `ui.textScale` | auto | Monitor text scale |
| `logging.statsInterval` | 10 | Seconds between CSV rows |

The program checks the config at startup and refuses to run with
inconsistent limits (for example a target above the trip temperature).

## Operational notes

- **Your energy source has to be able to supply `maxInflow`.** If the core
  that feeds the injector runs dry, nothing can hold the field.
- **Keep the computer and reactor chunk-loaded.** If the chunk unloads,
  the program stops while the gates hold their last setting.
- A full energy core is safe. The reactor can't output, so saturation rises
  and the temperature falls.

## Development

```text
main_control.lua       entry point: loops, input dispatch, fail-safe exit
reac_utils.lua         discovery, gate adapter, controller (pure logic)
monitor_utils.lua      dashboard rendering and touch hit-testing
energy_core_utils.lua  optional energy pylon readout
stat_utils.lua         event log, stats CSV, rotation
config.lua             user settings
install.lua            online installer
offline_install.lua    floppy-disk installer
tests/                 CC mock, reactor simulator, test suite
```

Run the tests with any Lua 5.2+ interpreter from the repository root:

```shell
lua tests/run_tests.lua
```

The suite has controller unit tests, closed-loop runs against an approximate
reactor model (`tests/reactor_sim.lua`, based on DE 1.12.2 physics), and an
end-to-end run of `main_control.lua` under a virtual-time CC:Tweaked mock.
The simulator is only an approximation. Test new settings on a reactor you
can afford to lose.

## Disclaimer

Use at your own risk. The simulator is no substitute for in-game testing,
and reactor explosions are permanent.

## License

MIT. See [LICENSE](LICENSE).
