# FinishHim

WoW addon for **WoW: Forever** (`## Interface: 16001`). For each spell the player picks (`/fh add`), it shows whether
casting it would kill the target, at each combo point count (1-5). Eviscerate is tracked by default. Only combo
point spells are supported so far, but the code is built so spells without combo points can be added later. Modeled on the DoesItDie addon next door (`../DoesItDie`), which solves
the same problems for DoTs. Check there first when unsure how Forever behaves.

## Forever's restrictions (the reason the code looks the way it does)

- **Target health is secret.** Lua can't read or compare it. Any "damage >= health" check has to be done by a
  widget: a StatusBar with `max = UnitHealth("target")` (secret values are accepted) and `value = damage`. The
  bar is very long, and only its last pip-width shows through a `SetClipsChildren(true)` frame. The lit texture
  is anchored to the fill's right edge, so you only see it when the fill reaches the end. Never try to compare
  health in Lua.
- **Never register `COMBAT_LOG_EVENT_UNFILTERED`.** Forever blocks it and shows a popup. Hit amounts come from
  `UNIT_COMBAT` instead. That event doesn't say who dealt the hit, so a tracked spell's hit is picked by timing:
  the largest plausible non-glancing physical hit within `HIT_WINDOW` after the cast, or `HIT_LOOKBACK` before it.
- **UNIT_COMBAT amounts are hidden on the user's client (seen 2026-11-05).** Every Eviscerate in the log ended
  in "no plausible hit seen", and DoesItDie never saw a single DoT tick either. So `Meter.lua` learns from the
  game's damage meter instead: `C_DamageMeter.GetCombatSessionSourceFromType(Enum.DamageMeterSessionType.Overall,
  Enum.DamageMeterType.DamageDone, playerGUID).combatSpells[i].spellID/.totalAmount`, readable out of combat
  (Details' `core/parser_nocleu1.lua` reads it the same way). The per-hit path stays in case hits become readable;
  a cast learned that way is marked `record.learned`, so the meter doesn't count it twice.
- **Any value can be secret**: GUIDs, combo points, units, flags, amounts, descriptions. Wrap API calls in
  `pcall` and check `ns.isSecret(v)` before using a value as a number, string or table key. Combo points can be
  secret in combat. The fallbacks, in order: the API, then reading the game's `ComboFrame` display, then the
  addon's own count of builders.
- **Err low.** A false kill skull is worse than a missed one. Estimates use the tooltip's minimum roll, no crits,
  and learned ratios (a cautious low quartile across mobs). Keep it that way.

## Files

- `FinishHim.toc`: load order is `Core.lua`, `Meter.lua`, then `Display.lua`. SavedVariables: `FinishHimDB`.
- `Core.lua`: settings, log (`ns.trace`, kept in `db.log`), spell kinds (`KINDS`), the tracked spell list,
  learning (`db.samples[spellName]` ratios, plus per-mob ratios kept for the session), combo points, cast and
  hit events, and the `/fh` commands.
- `Meter.lua`: learning from the damage meter. Out of combat it keeps a baseline of the Overall total per tracked
  spell. Core reports each cast (`ns.meter.recordCast`). After the fight (retries at 1-12s), it computes
  (total - baseline) / sum of tooltip middles / (1 + crit chance) and saves that through `ns.learnRatio`.
  Unverified in-game so far.
- `Display.lua`: one row per tracked spell, stacked upward above the target frame. Each row has an icon, a big
  skull and one pip per entry. Also dragging, tooltips, and the 0.1s refresh driver. It talks to Core only
  through `ns.*` (`ns.spells`, `ns.kinds`, `ns.estimate`, `ns.comboPoints`, `ns.dotDamage`, `ns.housekeep`).

## Tracked spells

- Saved as `db.spells = { { name, kind } }` in display order, **by name**, so every rank matches and no rank ID
  tables are needed. `ns.spells` is the same list with session info: `spellID` (the highest rank the player
  knows, from looking up the name; nil hides the row), `icon`, and `periodic`.
- Casts are matched by the name of the cast spell ID (`trackedSpell`). Names are in the client's language.
- `/fh add` takes a name, an ID or a shift-clicked link. The spell's kind is detected from its tooltip, and
  spells no kind can parse are refused. On first run, Eviscerate (ID 2098, named in the client's language) is added.
- `periodic` spells (tooltip says "over N sec", like Rupture and Rip) use the tooltip total at ratio 1, since
  armor doesn't reduce bleeds. Nothing is learned from them, because their hits are ticks. A lit pip on them means
  "dies before the DoT ends".

## Spell kinds (and adding spells without combo points)

`KINDS` in `Core.lua` maps a kind to `{ label, parse, usesPoints, pips }`. `parse(desc)` returns
`{ [n] = { min, max } }`, one entry per pip. Estimates, learning and the display all work per entry `n`. For
`usesPoints` kinds, `n` is the number of combo points, and the "now" pip is the current combo points.
Otherwise it's always entry 1.

To support direct-damage spells (Sinister Strike, Shadow Bolt, ...), add a kind with `usesPoints = false`,
`pips = 1`, and a parser that fills only `[1]`. Then handle:
- `onUnitCombat` only accepts Physical (school 1) hits right now. Non-physical spells need their school checked
  against the spell instead.
- Weapon-based tooltips ("weapon damage plus 68") have no fixed range. These need a learned absolute value,
  not a tooltip ratio.
- Picking the spell's hit out of white hits by "largest plausible" is weaker for small direct hits.

## Working on it

- No Lua interpreter on this machine. To syntax-check, use Python's `luaparser` (`python -m pip install
  luaparser`, then `luaparser.ast.parse(source)`). Use `python`, not `py`: they're different installs here.
- Lua 5.1 rules: no `goto`, no integer division `//`, and a 200-locals-per-scope limit.
- Testing happens in-game. `/fh probe` prints each tracked spell's tooltip parse and estimates, and the combo point readings. `/fh debug`
  echoes the log to chat. `/fh test` lights everything up. The full log is in
  `WTF/Account/<account>/SavedVariables/FinishHim.lua` after a `/reload` or logout.
- A new file in the `.toc` needs a full game restart. `/reload` won't pick it up.
- DoesItDie integration is optional (`## OptionalDeps`), through its public API `DoesItDie.GetRemainingDamage(unit)`.
  Always check that it exists first.
- Keep `README.md` (the user-facing docs) in step with the commands in `HELP`.
