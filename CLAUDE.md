# FinishHim

WoW addon for **WoW: Forever** (`## Interface: 16001`). For each spell the player picks (`/fh add` or the options
window), it shows whether casting it would kill the target. Combo point spells (Eviscerate, tracked by default) get
a pip per combo point count (1-5). Single cast spells (Arcane Shot, Shadow Bolt) get a damage marker on the target's
health bar, like DoesItDie's. Modeled on the DoesItDie addon next door (`../DoesItDie`), which solves the same
problems for DoTs. Check there first when unsure how Forever behaves.

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

- `FinishHim.toc`: load order is `Core.lua`, `Meter.lua`, `Display.lua`, then `Options.lua`. SavedVariables: `FinishHimDB`.
- `Core.lua`: settings, log (`ns.trace`, kept in `db.log`), spell kinds (`KINDS`), the tracked spell list,
  learning (`db.samples[spellName]` ratios, plus per-mob ratios kept for the session), combo points, cast and
  hit events, and the `/fh` commands.
- `Meter.lua`: learning from the damage meter. Out of combat it keeps a baseline of the Overall total per tracked
  spell. Core reports each cast (`ns.meter.recordCast`). After the fight (retries at 1-12s), it computes
  (total - baseline) / sum of tooltip middles / (1 + crit chance) and saves that through `ns.learnRatio`.
  Unverified in-game so far.
- `Options.lua`: the options window (`/fh` with no arguments, or right-click the pips), plus a page under
  Options > AddOns that opens it. It's built from plain frames with `BackdropTemplate`, like DoesItDie's. Sliders are
  a bare `Slider`, not `OptionsSliderTemplate`, so they don't depend on which templates the client still has. All
  layout happens in `refresh()`, top to bottom. Spell changes go through `ns.addSpell`, `ns.removeSpell` and
  `ns.moveSpell`; the "Add" list comes from `ns.candidateSpells()`, which scans the spellbook with
  `C_SpellBook` or the old `GetSpellTabInfo` API. Call `ns.refreshOptions()` after changing the spell list.
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

## Spell kinds

`KINDS` in `Core.lua` maps a kind to `{ label, short, parse, usesPoints, pips }`. `parse(desc)` returns
`{ [n] = { min, max }, school = mask }`, one entry per pip. Estimates, learning and the display all work per
entry `n`. For `usesPoints` kinds, `n` is the number of combo points, and the "now" entry is the current combo
points. Otherwise it's always entry 1. `detectKind` tries the kinds in `KIND_ORDER` (combo before direct, since
Eviscerate's tooltip also matches the direct parser).

- **combo:** `parseComboRanges`, the "1 point: 6-10 damage" table. DoT finishers (Rupture, Rip) are `periodic`.
- **direct:** `parseDirect`, the first fixed damage clause that isn't followed by "over N sec": "13 Arcane damage",
  "14 to 23 Fire damage", or "...attack power plus 273 Arcane damage" (the attack power part is learned through
  the ratio). It reads the school from the word before "damage" (`SCHOOLS`, English and German). It refuses
  weapon-based tooltips ("weapon damage plus 68"): there's no fixed base, so they'd need a learned absolute
  value instead of a tooltip ratio. Pure DoTs are left to DoesItDie.
- Hits are matched to the spell's school in `resolvePending` (when the hit's school is readable).
- Crits in the damage meter path: the highest of melee, ranged and spell crit chance, counted as double damage.
  Both choices err careful.

## Health bar markers (Display.lua)

Spells with `marker` on (the default for direct spells; the "Bar" checkbox in options) get a chunk drawn at the
end of the target's health fill, reaching left. It's a StatusBar as wide as the health bar, pinned with its right
edge to the health bar's fill texture (`GetStatusBarTexture()`), `SetReverseFill(true)`, max = `UnitHealthMax`,
value = damage. A clipping frame over the health bar cuts off overkill. Biggest damage first, so smaller chunks
draw on top. Only Blizzard's target frame health bar is found (`findTargetHealthBar`, same paths as DoesItDie).
Unverified in-game so far.

## Working on it

- No standalone Lua on this machine. Use `python`, not `py`: they're different installs here.
  - Syntax check: Python's `luaparser` (`luaparser.ast.parse(source)`).
  - Running Lua: `lupa` embeds real interpreters. Use `from lupa.lua51 import LuaRuntime`; the default is 5.5,
    which rejects things 5.1 allows, such as assigning to a for-loop variable. Good for testing tooltip patterns:
    cut the parser functions out of `Core.lua` and call them on sample tooltips.
- Lua 5.1 rules: no `goto`, no integer division `//`, and a 200-locals-per-scope limit.
- Testing happens in-game. `/fh probe` prints each tracked spell's tooltip parse and estimates, and the combo point readings. `/fh debug`
  echoes the log to chat. `/fh test` lights everything up. The full log is in
  `WTF/Account/<account>/SavedVariables/FinishHim.lua` after a `/reload` or logout.
- A new file in the `.toc` needs a full game restart. `/reload` won't pick it up.
- DoesItDie integration is optional (`## OptionalDeps`), through its public API `DoesItDie.GetRemainingDamage(unit)`.
  Always check that it exists first.
- Keep `README.md` (the user-facing docs) in step with the commands in `HELP`.
