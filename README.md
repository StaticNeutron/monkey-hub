# Script hub

Roblox executor scripts. Each one loads with a single loadstring.

| Script | Game | Loadstring |
|---|---|---|
| Monkey Hub | Survive a Million Monkeys | `loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/MonkeyHub.lua"))()` |
| RoWorld Hub | RoWorld [World PvP] | `loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/RoWorldHub.lua"))()` |
| Huss Valley Hub | [BOSS] Huss Valley | `loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/HussValleyHub.lua"))()` |
| GlassUI (library) | any | `local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/GlassUI.lua"))()` |
| ui.lua (library) | any | `local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/ui.lua"))()` |

## Monkey Hub

Script hub for **Survive a Million Monkeys** with a premium UI (hypercar intro, loading screen, draggable window). Start a match, then execute the loadstring above.

- **RightCtrl** opens and closes the menu.
- Settings are saved to `MonkeyHub/settings/config.json` in your executor workspace.
- Optional: put an `intro.mp3` in your executor workspace folder to play music during the intro (it plays silently without one).
- The hub only runs inside a match, not the lobby.

## Huss Valley Hub

Auto Dodge (dashes out of catcher swings and tackles through the game's own dash), Auto Ability (Q), Immortal (best effort), Movement tweaks, Threat ESP and Anti-AFK.

**Immortal** watches every attack within about 45 studs, from any side and any number at once (melee swings, tackle dives, and a locked-on catcher that is about to swing). It picks the landing spot that is outside all of their hit zones, accounting for walls and the game's dash turn rule, and dashes there. While it is on it also forces **no dash cooldown**, **no recovery**, **full-distance dashes even from a standstill**, and the fastest dash the server accepted in testing (about 0.04 s), so it can dash again the instant the next attack lands. Catches are decided by the server, so this cannot be true god mode, and a very high ping can still be too slow. Two toggles under it: "Immortal: no cooldown + fastest dash" (turn it off to keep the dodging with the normal dash) and "Immortal: also use abilities (Q)" (turn it off to make Immortal dash only). **RightShift** opens and closes the menu. The window is built with `GlassUI` (loaded from `glassui.lua` in your executor workspace if present, otherwise downloaded from this repo), and "Unload UI" in its Settings tab unloads the whole script.

Movement tab (retunes the game's own movement profile, nothing is written into game memory):

- **No dash cooldown** (with an optional cooldown cap and "skip recovery"): a dash every ~0.3 s instead of every ~0.7 s. Auto Dodge re-arms right after each dash.
- **Longer dash**: 1.1x to 3x dash distance.
- **Faster / instant dash**: the dash covers the same distance in 15% to 100% of the normal time (15% is about 0.04 s, near-instant). Truly instant (0%) is refused by the server, which snaps you back, so the slider stops at 15%; if a snap-back still happens the hub raises the dash time for you.
- **Full-distance dash from a standstill**: the game normally shortens a dash by how fast you were already moving, so a dash from standing still barely moves; this keeps it full length.
- **Skip dash animation**: the dash happens without the dash animation (your character only).
- **No stun: dash during another dash**: pressing dash while a dash is still playing (or recovering, or on cooldown) cancels it and starts a new one right away, so nothing locks you out. Works for runners and for catchers that have a dash. Chained dashes are shorter because each one is cut off by the next.
- **Free-direction dash**: dash wherever you point it without turning away first, and dash straight ahead while running that way (the game normally needs a turn of at least 35 degrees, so a forward dash or a dash from a standstill is refused). Use your normal dash key. "Dash toward": Movement keys (the keys you hold; camera forward if none), Camera, or Character facing. Auto Dodge / Immortal use it too, so they can dash in any direction with no priming.
- **Instant acceleration**: reach top speed immediately instead of ramping up (runners go from about 0.6 s to 0.04 s to 30 studs/s; catchers already accelerate almost instantly).
- **Speed boost**: 0 to 25 percent on top of the live top speed.
- **Catcher: dash key uses the tackle**: a catcher's own dash is the tackle (Space / E / F in the game), not the runner dash. This binds it to the Catcher dash key (default LeftShift); the game's cooldown still applies. With free-direction dash on it turns you toward your chosen direction first. Auto Ability (Q) also fires for catchers when a runner is within 14 studs. ESP shows runners when you are a catcher.
- **Snap-back protection**: if the server really snaps you back during a live match, the dash time is raised or instant acceleration / free dash are switched off. Resets around round ends, catches, safe, respawns and lobby teleports are ignored.
- **Auto-off on a fair-play warning**: if the game's anti-cheat warns you, every movement tweak switches itself off.

The server watches movement; short tests of 2x dash rate, a 1.5x dash and +10% speed drew no warning, but pushing further raises the risk.

## GlassUI

Translucent "glass" UI library with a stepper intro, glowing animated border, beat-pulse equalizer, blur-style tab transitions and a dark/light theme. Same API shape as `ui.lua`, plus `OnDestroy` so a script can unload itself when its window is unloaded:

```lua
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/GlassUI.lua"))()
local window = UI:CreateWindow({ Title = "My Hub", Subtitle = "game", ToggleKey = Enum.KeyCode.RightShift })
local tab = window:CreateTab("Main")
tab:AddToggle({ Text = "Example", Flag = "example", Callback = function(on) end })
```

## Files

- `MonkeyHub.lua`, `RoWorldHub.lua`, `HussValleyHub.lua` - the hubs.
- `ui.lua`, `GlassUI.lua` - UI libraries.

Game API details can change with game updates.
