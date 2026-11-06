# Project Golf x A-Life (prototype)

A friendly A-Life NPC plays a round with you at West Maple.

Requires: Project Golf (ProjectGolf) and Project A-Life (ProjectALifeNPCs). Jeem is not needed.

## Quick test (single player)
1. Enable Project Golf, Project A-Life and this mod. Go to a West Maple tee box with a golf club and golf balls.
2. In the sandbox settings (page **Project Golf x A-Life**), turn on **Test partner spawn** (off by default).
   Then right-click the ground: **Golf partner (test) > Spawn a test golf partner**. A friendly civilian appears
   within a few tiles, already holding a golf club, and says hello. They are your partner straight away.
   (Or talk to any friendly A-Life NPC: **Golf** tab > *Fancy a round of golf?*)
3. Tee off as usual (Golf > Tee off). After your ball stops, they walk to their side of the tee box, line up and
   drive. After each of your shots they play theirs. Once you're in, they play on until they're in
   (or pick up at par + 4). You get a halo with both scores, e.g. "Hole 1: you 4 (E) - Dave 5 (+1)".
4. To stop: talk to them, **Golf** tab > *Let's call it a day on the golf.* (Walking 80+ tiles away for a minute ends it too.)

## Tuning
`PGA_Shared.lua`, `ProjectGolfALife.Config`: partner skill (Aiming 0-10), pick-up score, timings.
`ProjectGolfALife.DEBUG = true` logs every partner shot to console.txt (lines start with `[ProjectGolfALife]`).

## How it works
- **Talk:** two rows in A-Life's talk window (Golf tab), answered through A-Life's `Talk.choiceHandlers`.
- **Walking:** an A-Life behaviour module `golfPartner` (kind orders, priority 5: before A-Life's own orders).
  It follows you, or walks to the spot beside their ball. A-Life's movement does the pathing; zombies still come first.
- **Swing:** an A-Life animation preset `pg_golf_swing` (the two-handed attack clip, golf club prop in both hands).
- **Shot:** club by distance (putt <= 9, chip <= 18, else drive), power by test shots with Project Golf's own physics,
  then the miss from the partner's Aiming skill. The server flies it like any other shot, so everyone sees it.
  Their ball rests on the ground as a real golf ball.
- **Your shots:** Project Golf's Hit is watched (not changed): a tee shot from a tee box starts the hole for both.

## Known limits (prototype)
- One partner per player. Multiplayer is untested.
- Their ball is an ordinary golf ball: if you hit or pick it up, they play from where it was.
- No scorecard column yet: scores show as a halo at the end of each hole.
