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

Auto Dodge (dashes out of catcher swings and tackles through the game's own dash), Auto Ability (Q), Immortal (best effort), Movement tweaks, Threat ESP and Anti-AFK. Catches are decided by the server, so Immortal cannot be true god mode; it dodges every committed hit it can see. **RightShift** opens and closes the menu. It uses `ui.lua` and downloads it automatically.

Movement tab (retunes the game's own movement profile, nothing is written into game memory):

- **No dash cooldown** (with an optional cooldown cap and "skip recovery"): a dash every ~0.3 s instead of every ~0.7 s. Auto Dodge re-arms right after each dash.
- **Longer dash**: 1.1x to 3x dash distance.
- **Faster / instant dash**: the dash covers the same distance in 15% to 100% of the normal time (15% is about 0.04 s, near-instant). Truly instant (0%) is refused by the server, which snaps you back, so the slider stops at 15%; if a snap-back still happens the hub raises the dash time for you.
- **Skip dash animation**: the dash happens without the dash animation (your character only).
- **Speed boost**: 0 to 25 percent on top of the live top speed.
- **Auto-off on a fair-play warning**: if the game's anti-cheat warns you, all three switch themselves off.

The server watches movement; short tests of 2x dash rate, a 1.5x dash and +10% speed drew no warning, but pushing further raises the risk.

## GlassUI

Translucent "glass" UI library with a stepper intro, glowing animated border, beat-pulse equalizer, blur-style tab transitions and a dark/light theme. Same API shape as `ui.lua`:

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
