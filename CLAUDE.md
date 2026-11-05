# FinishHim

WoW addon for **WoW: Forever** (`## Interface: 16001`). For a rogue, it shows whether Eviscerate would kill the
target at each combo point count (1-5). Modeled on the DoesItDie addon next door (`../DoesItDie`), which solves
the same problems for DoTs. Check there first when unsure how Forever behaves.

## Forever's restrictions (the reason the code looks the way it does)

- **Target health is secret.** Lua can't read or compare it. Any "damage >= health" check has to be done by a
  widget: a StatusBar with `max = UnitHealth("target")` (secret values are accepted) and `value = damage`. The
  bar is very long, and only its last pip-width shows through a `SetClipsChildren(true)` frame. The lit texture
  is anchored to the fill's right edge, so you only see it when the fill reaches the end. Never try to compare
  health in Lua.
- **Never register `COMBAT_LOG_EVENT_UNFILTERED`.** Forever blocks it and shows a popup. Hit amounts come from
  `UNIT_COMBAT` instead. That event doesn't say who dealt the hit, so Eviscerate's hit is picked by timing:
  the largest plausible non-glancing physical hit within `HIT_WINDOW` after the cast, or `HIT_LOOKBACK` before it.
- **Any value can be secret**: GUIDs, combo points, units, flags, amounts, descriptions. Wrap API calls in
  `pcall` and check `ns.isSecret(v)` before using a value as a number, string or table key. Combo points can be
  secret in combat. The fallbacks, in order: the API, then reading the game's `ComboFrame` display, then the
  addon's own count of builders.
- **Err low.** A false kill skull is worse than a missed one. Estimates use the tooltip's minimum roll, no crits,
  and learned ratios (a cautious low quartile across mobs). Keep it that way.

## Files

- `FinishHim.toc`: load order is `Core.lua`, then `Display.lua`. SavedVariables: `FinishHimDB`.
- `Core.lua`: settings, log (`ns.trace`, kept in `db.log`), tooltip parsing (`parseRanges`), learning
  (`db.samples` ratios, per-mob ratios kept for the session), combo points, cast and hit events, `/fh` commands.
- `Display.lua`: the pip row, the big skull, dragging, the tooltip, and the 0.1s refresh driver. It talks to
  Core only through `ns.*` (`ns.estimate`, `ns.comboPoints`, `ns.dotDamage`, `ns.activeRank`, `ns.housekeep`).

## Adding finishers

Add an entry to `FINISHERS` in `Core.lua` with every rank's spell ID. The display currently only uses
`ns.finishers[1]`, so a second finisher also needs its own display work.

## Working on it

- No Lua interpreter on this machine. To syntax-check, use Python's `luaparser` (`python -m pip install
  luaparser`, then `luaparser.ast.parse(source)`). Use `python`, not `py`: they're different installs here.
- Lua 5.1 rules: no `goto`, no integer division `//`, and a 200-locals-per-scope limit.
- Testing happens in-game. `/fh probe` prints the tooltip parse, combo point readings and estimates. `/fh debug`
  echoes the log to chat. `/fh test` lights everything up. The full log is in
  `WTF/Account/<account>/SavedVariables/FinishHim.lua` after a `/reload` or logout.
- A new file in the `.toc` needs a full game restart. `/reload` won't pick it up.
- DoesItDie integration is optional (`## OptionalDeps`), through its public API `DoesItDie.GetRemainingDamage(unit)`.
  Always check that it exists first.
- Keep `README.md` (the user-facing docs) in step with the commands in `HELP`.
