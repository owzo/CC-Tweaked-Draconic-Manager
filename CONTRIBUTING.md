# Contributing

Thanks for helping! The most useful contribution right now is testing in
Minecraft: the program has only been tested against simulators and in the
[CraftOS-PC](https://www.craftos-pc.cc) emulator (see the
[roadmap](https://github.com/owzo/CC-Tweaked-Draconic-Manager/wiki/Roadmap-and-Status)).

Please follow the [code of conduct](CODE_OF_CONDUCT.md).

## Reporting results and bugs

Open an [issue](https://github.com/owzo/CC-Tweaked-Draconic-Manager/issues/new/choose)
with the matching form:

- **In-game test report**: you ran it with real mods. Successes count too.
- **Bug report**: something is wrong.
- **Feature request**: something is missing.

Always include:

- your Minecraft, CC: Tweaked and mod versions;
- the manager version (on the System page);
- your monitor size;
- the relevant part of `logs/draconic.log` on the computer.

Security problems go through the [security policy](SECURITY.md), not
public issues.

## Changing the code

1. Fork the repository and create a branch from `main`.
2. Make the change. For a new mod, see "Adding support for another mod" in
   the README (Development section).
3. Run the tests (below), and add a test for what you changed.
4. Open a pull request. The template asks what you changed and how you
   tested it.

### Running the tests

From the repository root:

```text
lua5.4 tests/run_tests.lua            # or lua5.2; the whole Lua suite
python3 -m unittest discover -s tools # log collector and wiki generator
```

CI runs both, plus a Lua 5.1 parse of every shipped file. For the UI on
real ComputerCraft rendering, use `tools/craftos/sim_world.lua` or
`tools/craftos/run_scenario.sh` in CraftOS-PC (see the README).

### Code style

The program runs on CC: Tweaked, so shipped files must:

- **parse as Lua 5.1**: no `goto`, no `//` integer division, no bitwise
  operators;
- **not use `require`**: modules are loaded through `import()` in
  `main_control.lua` (some setups start programs with `os.loadAPI`);
- **guard peripheral calls**: a block can disappear at any moment, so use
  `pcall` and keep running.

Write code that matches the code around it:

- 4-space indentation;
- a `README` comment block at the top of each file describing its API;
- comments that explain *why*.

Python tools follow PEP 8 and use only the standard library.

### Documentation

The wiki is generated from `README.md`, `docs/GUIDE.md` and
`tools/wiki/pages/`, and published on every push to `main`. Edit those
files, never the wiki pages. If you change the UI, rerun
`python3 tools/screenshots/render.py` to update the screenshots.

## Licence

Contributions are accepted under the project's [MIT licence](LICENSE).
