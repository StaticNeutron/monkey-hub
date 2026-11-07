# Script hub

Roblox executor scripts. Each one loads with a single loadstring.

| Script | Game | Loadstring |
|---|---|---|
| Monkey Hub | Survive a Million Monkeys | `loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/MonkeyHub.lua"))()` |
| RoWorld Hub | RoWorld [World PvP] | `loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/RoWorldHub.lua"))()` |
| Huss Valley Hub | [BOSS] Huss Valley | `loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/HussValleyHub.lua"))()` |
| Da Hood Hub | Da Hood | `loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/DaHoodHub.lua"))()` (Potassium) / `loadstring(httpget("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/DaHoodHub.lua"))()` (Matcha) |
| HussUI + HussEdits (libraries) | Huss Valley hub | loaded automatically by the hub (`HussUI.lua`, `HussEdits.lua`) |
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

**Immortal** watches every attack within about 45 studs, from any side and any number at once (melee swings, tackle dives, and a locked-on catcher that is about to swing). It picks the landing spot that is outside all of their hit zones, accounting for walls and the game's dash turn rule, and dashes there. While it is on it also forces **no dash cooldown**, **no recovery**, **full-distance dashes even from a standstill**, and the fastest dash the server accepted in testing (about 0.04 s), so it can dash again the instant the next attack lands. Catches are decided by the server, so this cannot be true god mode, and a very high ping can still be too slow. Two toggles under it: "Immortal: no cooldown + fastest dash" (turn it off to keep the dodging with the normal dash) and "Immortal: also use abilities (Q)" (turn it off to make Immortal dash only). **RightShift** opens and closes the menu. The window is built with `HussUI` (loaded from `HussUI.lua` in your executor workspace if present, otherwise downloaded from this repo), and "Unload Script" in its Settings tab unloads the whole script.

**Edits** (new look and start-up film): the whole interface is a near-black, ivory, serif "private edition" skin. When the script starts it plays one of five edits fullscreen (Space or the Skip button ends it; the hub keeps loading behind it and the window opens afterwards). The **Edits** tab is a viewer with play/pause, previous/next, a timeline and the list of edits, plus "Use at start", "Play an edit when the script starts", "Edit to play at start" (Random or one by name), the volume and "Play the start-up film now". The choices are remembered in `HussValley/edits.json` without saving a config. Potassium's `VideoFrame` cannot load local video, so each edit is stored in `edits/` as a `.pack` (JPEG pages of 6 frames each plus an mp3) and `HussEdits.lua` downloads one the first time it plays (4 to 11 MB) into `HussValley/edits/`, then plays it from disk.

**Configs** (Settings tab): pick a slot (Config 1 to 5) and Save, Load or Delete it. A config stores every switch, slider, dropdown and keybind in `HussValley/configs/` in your executor workspace. "Load this config when the script starts" restores the chosen slot every time you run the script.

**Proximity dodge** (Combat tab): also dashes away from any live catcher that gets within the chosen range (4 to 14 studs), before it even starts a swing, using the same landing-spot picker as Auto Dodge. An "Auto Dodge on/off key" (G by default) toggles Auto Dodge in game.

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
- **Catchers**: see the Catcher tab below.
- **Snap-back protection**: if the server really snaps you back during a live match, the dash time is raised or instant acceleration / free dash are switched off. Resets around round ends, catches, safe, respawns and lobby teleports are ignored.
- **Auto-off on a fair-play warning**: if the game's anti-cheat warns you, every movement tweak switches itself off.

Catcher tab (a catcher's own dash is the tackle, so these are the catcher versions of the dash tweaks):

- **Both dashes**: "Catcher: also get the runner dash" gives catchers the runner dash (on by default) on LeftShift, with the tackle key on LeftControl. Every dash tweak in the Movement tab applies to it.
- **Auto Tackle**: dives at the closest runner once it is inside the chosen range (3 to 9 studs) and the game says the tackle is ready.
- **Tackle aim**: nearest runner (leads a moving runner slightly), movement keys, camera or character facing; the character turns that way before diving.
- **Tackle on a key**: LeftShift by default.
- **No tackle cooldown**: the client stops waiting for its own timer. The server keeps its own, so it may refuse early tackles; the hub switches it off if the server snaps you back.
- **Reach assist (hitbox expander, experimental)**: catches are decided by the server, so the hitbox itself cannot be resized. This starts each tackle 0.5 to 2 studs further forward than you are (the server tolerates about 2.5 studs of position error). Untested against the server's hit rules.
- Not included: a longer / faster / cancellable tackle, because the server checks the tackle's motion against its own numbers.

The server watches movement; short tests of 2x dash rate, a 1.5x dash and +10% speed drew no warning, but pushing further raises the risk.

## Da Hood Hub

One entry point (`DaHoodHub.lua`) for two executors. It detects Matcha and hands over to `DaHoodMatcha.lua`; anywhere else it runs the Potassium edition with the `V18UI.lua` window (**RightShift** opens the menu).

**Potassium edition**: aimbot, silent aim and bullet redirect (through the game's own `getAim` and the `ShootGun` report), trigger bot, rapid fire, auto fire, hitboxes, auto stomp / reload, fly, speed, noclip, ESP, chams, world tweaks, spectate. Silent aim, bullet redirect and rapid fire rely on hooks and are only verified up to hook installation, not against the server.

**Matcha edition** (Matcha is an external VM: no hooks, no `Instance`, part writes cost 20-40 ms each, so it is built from what that VM has):

- Aimbot with three aim types: Mouse (`mousemoverel`), Memory (camera rotation written into the camera object, layout verified before writing) and Camera. Rage mode, resolver, ping-based prediction, team check, flick shot, trigger bot.
- ESP drawn with pooled Drawing objects (boxes, 3D box, fill, glow, skeleton, silhouette chams, health / armor bars, flags, avatars), radar, off-screen arrows, optional native `RegisterModel` ESP.
- Hitbox expander (part, width / height, range, outline), timer manipulator (exact gun cooldown, melee repeat, fast stomp / reload), infinite ammo and rapid fire (client side only), waypoints, click TP, speed through `setgc`, fly, noclip, jump boost, target hovering, desync, godmode (dodges aim lines; dry run by default).
- Hotkeys: Z aimbot, X fly, V noclip, C flick, J hitbox, Y timer, H target hover, G desync, End panic.
- Not possible on Matcha: freecam, lighting, real silent aim. Config is saved to `DaHoodMatcha.json`.

Infinite ammo, rapid fire, hitboxes and godmode are client side or predictive: the server makes the final call, so treat them as best effort.

## GlassUI

Translucent "glass" UI library with a stepper intro, glowing animated border, beat-pulse equalizer, blur-style tab transitions and a dark/light theme. Same API shape as `ui.lua`, plus `OnDestroy` so a script can unload itself when its window is unloaded:

```lua
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/GlassUI.lua"))()
local window = UI:CreateWindow({ Title = "My Hub", Subtitle = "game", ToggleKey = Enum.KeyCode.RightShift })
local tab = window:CreateTab("Main")
tab:AddToggle({ Text = "Example", Flag = "example", Callback = function(on) end })
```

## Files

- `MonkeyHub.lua`, `RoWorldHub.lua`, `HussValleyHub.lua`, `DaHoodHub.lua`, `DaHoodMatcha.lua` - the hubs.
- `ui.lua`, `GlassUI.lua`, `V18UI.lua`, `HussUI.lua` - UI libraries (`HussUI.lua` is the Huss Valley hub's skin, with the film viewer).
- `HussEdits.lua` - downloads and plays the edits; `edits/` holds `manifest.json`, `thumbs.jpg` and one `.pack` per edit.

Game API details can change with game updates.
