# FinishHim

Shows whether a combo point spell would kill your target right now, for every combo point count. It tracks
**Eviscerate** by default. Add any other combo point spell with `/fh add <spell>`, for example Ferocious Bite or Rupture.

Above the target frame there's one row per spell, with its icon on the left and five pips, one per combo point
count (1-5):

- **Red with a skull:** the spell with that many points kills the target. The lowest lit pip is the fewest
  points you need, so you don't overkill.
- **Gold border:** your current combo points.
- **Big skull next to the icon:** the spell kills right now with the points you have.
- **Number under each pip:** the estimated damage at that many points. **Grey** means it's still a guess from
  the tooltip (no hit seen yet); **gold** means it's learned from your real hits.

Hover the row to see the estimates and where they come from.

## How the estimate works

- It starts from the spell's tooltip (damage per combo point) times 0.75, because the tooltip doesn't include armor.
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

`/fh` lists everything. The useful ones:

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
