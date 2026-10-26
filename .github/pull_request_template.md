## Summary

<!-- What changes and why. Link the issue it fixes, if any. -->

## Testing

<!-- What you ran and what you saw. -->

- [ ] `lua5.4 tests/run_tests.lua` (or 5.2) passes
- [ ] `python3 -m unittest discover -s tools` passes (if you touched `tools/`)
- [ ] New or changed behaviour has a test
- [ ] Tried in CraftOS-PC (`tools/craftos/`) for UI changes
- [ ] Tried in Minecraft with the real mod (say which versions):

## Checklist

- [ ] Shipped files still parse as Lua 5.1 and don't use `require`
- [ ] Docs updated (`README.md`, `docs/GUIDE.md`; the wiki is generated from them)
- [ ] Screenshots regenerated if the UI changed (`tools/screenshots/render.py`)
