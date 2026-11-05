# FinishHim

Shows whether a spell you pick would kill your target right now. It tracks **Eviscerate** by default. Add
others in the options window (`/fh`):

- **Combo point spells** (Eviscerate, Ferocious Bite, Rupture): a row of five pips, one per combo point count.
- **Single cast spells** (Arcane Shot, Shadow Bolt, Fireball): a big skull with the damage next to it, plus a
  marker on the target's health bar.

Spells whose damage depends on your weapon ("weapon damage plus 68") can't be predicted yet.

Above the target frame there's one row per spell, with its icon on the left. For combo point spells:

- **Red with a skull:** the spell with that many points kills the target. The lowest lit pip is the fewest
  points you need, so you don't overkill.
- **Gold border:** your current combo points.
- **Big skull next to the icon:** the spell kills right now with the points you have.
- **Number under each pip:** the estimated damage at that many points. **Grey** means it's still a guess from
  the tooltip (no hit seen yet); **gold** means it's learned from your real hits.

For single cast spells, the big skull lights up when the spell kills, and the number next to it is its damage.

**Health bar marker:** a colored chunk at the end of the target's green health bar shows how much the spell takes
off. If it covers all the green that's left, the spell kills. Each spell has its own color. Every spell has one; for combo
point spells it shows the damage at your current combo points. Turn a spell's marker on or off with its **Bar** checkbox in the options window, or all of them with `/fh markers`.

Hover the row to see the estimates and where they come from.

## How the estimate works

- It starts from the spell's tooltip damage times 0.75, because the tooltip doesn't include armor (or, for some
  spells, attack power).
- After each fight it reads how much damage the spell did from the game's damage meter, and learns how hard you
  really hit, including armor and attack power. Forever hides single hit amounts from addons, so it learns per
  fight, not per hit.
- It always predicts the **lowest normal roll, without a crit**. A lit pip means "kills even on a bad roll".
  A dodge or parry can still save the target.
- Damage-over-time finishers (Rupture, Rip) use their tooltip total, since armor doesn't reduce bleeds. A lit pip
  on them means the target dies before the bleed runs out, not instantly.

Spells without combo points aren't supported yet.

Target health is hidden from addons in Forever, so the health check is done by hidden status bars (the same
trick DoesItDie uses for its kill icon).

## Commands

`/fh` opens the options window, or right-click the pips. In the window you can:

- add spells: pick one from the list of combo point spells in your spellbook, drag one in, or type its name
- reorder or remove your tracked spells
- change every setting below

Every option also has a command. `/fh help` lists them all:

| Command | What it does |
| --- | --- |
| `/fh add Ferocious Bite` | Track another combo point spell (or type `/fh add ` and shift-click it in your spellbook) |
| `/fh remove Rupture` | Stop tracking a spell (`/fh remove 2` works too) |
| `/fh list` | Show the tracked spells |
| `/fh unlock` / `/fh lock` | Drag the row somewhere else, then lock it |
| `/fh reset` | Put the row back above the target frame |
| `/fh scale 1.5` | Make the pips bigger |
| `/fh margin 5` | Take 5% off every estimate (more careful) |
| `/fh guess 0.75` | Tooltip multiplier used until a real hit has been seen |
| `/fh dots` | Also count DoesItDie's remaining DoT damage (Rupture, Garrote): "dies eventually", not instantly |
| `/fh test` | Light everything up for 10 seconds, to check placement |
| `/fh probe` | Print each spell's tooltip, combo point readings and estimates (for troubleshooting) |
| `/fh forget` | Forget learned hits |
