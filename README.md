# FinishHim

Shows whether **Eviscerate** would kill your target right now, for every combo point count.

Above the target frame there's a row of five pips, one per combo point count (1-5):

- **Red with a skull:** Eviscerate with that many points kills the target. The lowest lit pip is the fewest
  points you need, so you don't overkill.
- **Gold border:** your current combo points.
- **Big skull on the left:** Eviscerate kills right now with the points you have.
- **Number under each pip:** the estimated damage at that many points.

Hover the row to see the estimates and where they come from.

## How the estimate works

- It starts from Eviscerate's tooltip (damage per combo point) times 0.75, because the tooltip doesn't include armor.
- Every non-crit Eviscerate you land teaches it how hard you really hit, including armor and attack power. On a
  mob you've already hit, it uses that mob's numbers.
- It always predicts the **lowest normal roll, without a crit**. A lit pip means "kills even on a bad roll".
  A dodge or parry can still save the target.

Target health is hidden from addons in Forever, so the health check is done by hidden status bars (the same
trick DoesItDie uses for its kill icon).

## Commands

`/fh` lists everything. The useful ones:

| Command | What it does |
| --- | --- |
| `/fh unlock` / `/fh lock` | Drag the row somewhere else, then lock it |
| `/fh reset` | Put the row back above the target frame |
| `/fh scale 1.5` | Make the pips bigger |
| `/fh margin 5` | Take 5% off every estimate (more careful) |
| `/fh guess 0.75` | Tooltip multiplier used until a real hit has been seen |
| `/fh dots` | Also count DoesItDie's remaining DoT damage (Rupture, Garrote): "dies eventually", not instantly |
| `/fh test` | Light everything up for 10 seconds, to check placement |
| `/fh probe` | Print the tooltip, combo point readings and estimates (for troubleshooting) |
| `/fh forget` | Forget learned hits |
