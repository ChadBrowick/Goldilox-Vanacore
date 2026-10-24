# Goldilox

Goldilox is an Ashita4 addon exclusively for the [CatsEye XI](https://www.catseyexi.com/) custom daily content
consisting of goblin dailies, including the goblin by the same name.

Version 3.6 is a UI rewrite of Dewin's original addon.  Saved state works as before; the status display is now a
frameless card styled like YunaUI's settings window (dark panel with a thin violet border, section labels with a rule,
rounded status pills, outlined buttons and a switch for transparency), and chat parsing works on VanaCore.

## Usage

Load Goldilox with `/addon load goldilox`.  With the addon loaded, talk to the goblins in Lower Jeuno to track what
your dailies are.  Leave the addon loaded while working on said dailies (i.e. killing required creatures or finding
the secret chest).

| Command | What it does |
| --- | --- |
| `/goldilox` or `/dailies` | Show or hide the card |
| `/goldilox show` / `hide` | Show or hide explicitly |
| `/goldilox mini` / `full` | Switch the card size (also the MINI / FULL button on the card) |
| `/goldilox clear` | Toggle a see-through background (also the switch on the card) |
| `/goldilox min` | Collapse the card to just the word Goldilox (click it, or `/goldilox show`, to reopen) |
| `/goldilox chat` | Print the status to chat (the 1.0 output) |
| `/goldilox debug` | Toggle a list of goblin-related chat lines (troubleshooting) |
| `/goldilox help` | List commands |

The card stays hidden until you have talked to a goblin, and lists only the goblins you have talked to today.  It shows each goblin's state (not started, in progress, turn in, done), the zone, kill progress for Murdox,
whether the Goldilox reward has been collected, and the time until JP midnight, when dailies reset.  Mini size is one line per goblin (name and status, or kills for Murdox).  Drag it to move
it; drag the grip in its bottom right corner sideways to change its width (its height always follows what is listed).
The `-` button minimizes it to a small pill that shows just the word Goldilox; click the pill (without dragging) to bring the card back.
The small switch (or `/goldilox clear`) makes the card background see-through; text and bars stay solid.
Position, width, size, transparency and minimized state are remembered per character.  The small x closes it (same as `/goldilox hide`).

If YunaUI is installed, Goldilox borrows its font so the two match.  If ImGui can't be loaded, the addon keeps
tracking and `/goldilox` prints to chat instead.

## Sea (Palalumin)

Talk to Palalumin and a **SEA** section is added to the card with his three dailies: Find the Flux (with the zone), Item
request (each item is a link, with its count) and Defeat mobs (target, zone and a kill bar that follows the
"Defeat Mobs n/m" system line).  Each shows not started / in progress / turn in / done.  The card also appears if you
have only talked to Palalumin.  The header count includes the Sea quests, and the Goldilox reward line still follows only
the goblins.

Completion is picked up from the "Quest Completed" message, using your current target (Lumorian Flux, or Palalumin
together with a recent trade or finished kills).  If it ever misses one, talk to Palalumin again: his list marks finished
quests with a filled diamond and the card syncs to it.  `/goldilox chat` includes the Sea quests, and Sea resets at JP
midnight with everything else.

## Links

In the full-size card, the NM or item named in a task is a link (violet, underlined): Murdox's mobs, Saltlix's NM,
Mistrix's and Beetrix's items, plus Palalumin's requested items and kill target.  Click one to open [catseyexi.com's database](https://catseyexi.com/database) searched
for that name in your browser.  The database always opens on its Items tab, so for a monster click its Monsters tab.
Links are not shown in mini size or once a goblin is done or waiting for turn-in.  If your browser can't be opened,
the link is printed to chat instead.

## Notes

* Chat lines are recognized by what they say, not by chat mode, so it works whichever mode the client uses.
* Existing saved data is still read.
* Not yet confirmed in the real game on VanaCore.  If the card doesn't update, run `/goldilox debug`, talk to a goblin,
  and share what it prints.

## Credits

The Palalumin chat formats come from seekey13's Goldilox-UI (MIT).  No code was copied.

## License

MIT.  Original work (c) 2025 Daniel Grace; see LICENSE.md.
