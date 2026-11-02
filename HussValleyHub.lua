-- Huss Valley hub: Auto Dodge, Auto Ability, Immortal (best effort), Movement (no dash cooldown, longer dash, speed),
-- Threat ESP, Anti-AFK.
-- Verified against place 107535308163741 (v507): catcher swings/tackles are visible as character
-- attributes, a dash goes through ChickenOrHero.Movement.BoostInput, catches themselves are server-side.
-- Movement tweaks retune the game's own movement profile (MovementProfiles.get), so cooldown, recovery, distance and
-- speed all flow through the game's formulas; nothing is written into game memory.
-- UI: GlassUI (glassui.lua in the executor workspace, or the copy in the same GitHub repo).
if not shared then return warn("No shared, no script.") end

-- Singleton: replace a previous instance.
if shared.HussValley then
	pcall(shared.HussValley.detach)
end

local HussValley = {}

-- Constants.
local PLACE_ID = 107535308163741
local UI_FILE = "glassui.lua"
local UI_URL = "https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/GlassUI.lua"

-- Per-game values. Each one comes from the decompiled client config named next to it.
local CONFIG = {
	tickRate = 1 / 60,
	espRate = 0.25,
	-- ContactCatchConfig: ReachDistance 12, HitHalfWidth 1.4, RunnerRadius 0.9, ContactPadding 0.35.
	meleeForward = 13,
	meleeBehind = 1.5,
	meleeHalfWidth = 3.6,
	-- GameConfig.Tackle: MaxDistance 15, longest Reach 6.5, HumanBox width 4, TacklePredictionConfig tolerance 2.5.
	tackleForward = 22,
	tackleBehind = 1.5,
	tackleHalfWidth = 5.5,
	-- Slack on top of TackleDuration for clock skew; a TackleActive flag older than this is treated as stale.
	tackleGrace = 0.5,
	-- Tracking catcher locked on to us (only used by early dodge / immortal).
	trackingDistance = 9,
	-- How long the steered MoveDirection stays active; the game reads it once per frame.
	steerHold = 0.12,
	dashLockout = 0.3,
	-- Re-dodge gap while the dash cooldown is removed: a dash lasts 0.28s, so this only waits for it to finish.
	fastDashLockout = 0.12,
	abilityLockout = 1,
	-- MovementProfiles Runner Dash: MinIntentAngle 35, ~10.9 studs.
	minIntentCos = math.cos(math.rad(35)),
	dashDistance = 11,
	minDashSpeed = 3,
	wallPadding = 2,
	immortalMargin = 1.5,
	debug = false,
}

-- Services.
local playersService = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")
local virtualInputManager = game:GetService("VirtualInputManager")
local virtualUser = game:GetService("VirtualUser")

-- State.
local localPlayer = playersService.LocalPlayer
local connections = {}
local highlights = {}
local ui = nil
local guiParent = nil
local boostInput = nil
local participantDirectory = nil
local lastDash = 0
local lastAbility = 0
local lastDashCount = nil
local tickTimer = 0
local espTimer = 0
local lastError = 0
local alive = false
local uiWindow = nil
local detaching = false
local guardTripped = false
local lastRunStateAt = -10
local resetCharacter = nil
local lastReset = nil

-- Live movement switches. The profile wrapper reads this every frame; the UI callbacks write to it.
local movement = {
	noCooldown = false,
	-- Seconds the dash cooldown is capped at while noCooldown is on (0 = none).
	cooldownGap = 0,
	skipRecovery = true,
	longDash = false,
	dashScale = 1.5,
	-- Dash travel time as a percent of normal. Live tests: 15% and up was never refused, 10% was refused once in
	-- six dashes, 7% and below (and a zero-time dash) got the player snapped back by the server.
	fastDash = false,
	dashTime = 50,
	skipAnimation = false,
	speed = false,
	-- Percent added on top of the live top speed, which itself moves with the round's balance buffs (about 37-42).
	speedBoost = 5,
}
local movementProfiles = nil
local originalGet = nil
local dashAnimation = nil
local originalPlay = nil
local profileCache = setmetatable({}, { __mode = "k" })
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

-- One MoveDirection hook per session, kept in getgenv so a re-execute never stacks a second one.
local hookState = getgenv().HussValleyHook
if not hookState then
	hookState = { steer = nil, expiresAt = 0, humanoid = nil }
	getgenv().HussValleyHook = hookState

	-- The game's movement step reads Humanoid.MoveDirection to pick the dash direction, so we answer that read.
	local oldIndex
	oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
		if key == "MoveDirection" and hookState.steer and self == hookState.humanoid and os.clock() < hookState.expiresAt and not checkcaller() then
			return hookState.steer
		end

		return oldIndex(self, key)
	end))
end

-- Resolved once from the executor thread: gethui() throws when called from an engine-created callback thread.
---@return Instance
local function resolveGuiParent()
	local success, container = pcall(function()
		return gethui()
	end)
	if success and typeof(container) == "Instance" then return container end

	local coreOk = pcall(function()
		local probe = Instance.new("Folder")
		probe.Parent = game:GetService("CoreGui")
		probe:Destroy()
	end)
	if coreOk then return game:GetService("CoreGui") end

	return localPlayer:WaitForChild("PlayerGui")
end

---@param ... any
local function log(...)
	if CONFIG.debug then print("[HV]", ...) end
end

---@param message string
local function onError(message)
	if os.clock() - lastError < 2 then return end
	lastError = os.clock()
	warn("[HV] " .. tostring(message) .. "\n" .. debug.traceback())
end

---@param path Instance
---@return any
local function loadModule(path)
	-- require on a game module leaks the executor environment unless the identity is lowered first.
	-- Done in a throwaway thread: restoring 8 on the main thread does not bring back every capability,
	-- and connections made later would inherit the reduced set.
	local done = false
	local result = nil
	task.spawn(function()
		setthreadidentity(2)
		local success, module = pcall(require, path)
		result = success and module or nil
		done = true
	end)

	local waited = 0
	while not done and waited < 5 do
		task.wait(0.05)
		waited = waited + 0.05
	end

	return result
end

-- Builds the retuned copy of a movement profile. Cooldown/Recovery/Distance live in profile.Dash and are consumed by
-- the game's own MovementModel when a dash starts, so changing them here is all the game needs.
---@param profile table
---@return table
local function tuneProfile(profile)
	local clone = table.clone(profile)

	if movement.speed and type(profile.MaxSpeed) == "number" and profile.MaxSpeed > 0 then
		local factor = 1 + movement.speedBoost / 100
		clone.MaxSpeed = profile.MaxSpeed * factor
		-- Scale acceleration with it so the new top speed is reached in the time the game intended.
		clone.Acceleration = profile.Acceleration * factor
	end

	local dash = profile.Dash
	if type(dash) == "table" and dash.Enabled then
		local tuned = table.clone(dash)
		if movement.noCooldown then
			tuned.Cooldown = math.min(dash.Cooldown, movement.cooldownGap)
			if movement.skipRecovery then tuned.RecoveryDuration = 0 end
		end
		if movement.longDash then tuned.Distance = dash.Distance * movement.dashScale end
		-- Same distance in less time. The game's dash model copes with a duration shorter than one frame by finishing in that frame.
		if movement.fastDash then tuned.Duration = math.max(0.001, dash.Duration * movement.dashTime / 100) end
		clone.Dash = table.freeze(tuned)
	end

	return table.freeze(clone)
end

-- Replacement for MovementProfiles.get. It runs inside the game's per-frame movement code, so any failure falls back
-- to the untouched profile instead of breaking movement. The same clone is returned every frame (the game compares
-- profiles by reference and resets the dash state when it changes).
---@param role string
---@param player Instance
---@return table
local function retunedProfile(role, player)
	local profile = originalGet(role, player)
	if player ~= localPlayer or type(profile) ~= "table" then return profile end
	if not (movement.noCooldown or movement.longDash or movement.fastDash or movement.speed) then return profile end

	local success, result = pcall(function()
		local signature = string.format("%s|%.2f|%s|%s|%.2f|%s|%.0f|%s|%.1f", tostring(movement.noCooldown), movement.cooldownGap, tostring(movement.skipRecovery), tostring(movement.longDash), movement.dashScale, tostring(movement.fastDash), movement.dashTime, tostring(movement.speed), movement.speedBoost)
		local variants = profileCache[profile]
		if not variants then
			variants = {}
			profileCache[profile] = variants
		end

		local cached = variants[signature]
		if not cached then
			cached = tuneProfile(profile)
			variants[signature] = cached
		end

		return cached
	end)

	return success and result or profile
end

-- Swaps one function on a module table, unfreezing it just long enough if the game froze it.
---@param module table
---@param key string
---@param replacement function
---@return boolean
local function swapFunction(module, key, replacement)
	return pcall(function()
		local frozen = table.isfrozen(module)
		if frozen then setreadonly(module, false) end
		module[key] = replacement
		if frozen then setreadonly(module, true) end
	end)
end

-- Replacement for DashAnimation.play: lets the dash happen without the dash animation, for our own character only.
---@param character Instance
---@param ... any
---@return any
local function playDashAnimation(character, ...)
	if movement.skipAnimation and character == localPlayer.Character then return end

	return originalPlay(character, ...)
end

local function installMovement()
	local folder = replicatedStorage:WaitForChild("ChickenOrHero"):WaitForChild("Movement")
	movementProfiles = loadModule(folder:WaitForChild("MovementProfiles"))
	if not movementProfiles or type(movementProfiles.get) ~= "function" then
		warn("[HV] MovementProfiles unavailable; movement tweaks are disabled")
		movementProfiles = nil
		return
	end

	originalGet = movementProfiles.get
	if not swapFunction(movementProfiles, "get", retunedProfile) then
		warn("[HV] could not patch MovementProfiles; movement tweaks are disabled")
		movementProfiles, originalGet = nil, nil
	end

	dashAnimation = loadModule(replicatedStorage.ChickenOrHero:WaitForChild("Animation"):WaitForChild("DashAnimation"))
	if dashAnimation and type(dashAnimation.play) == "function" then
		originalPlay = dashAnimation.play
		if not swapFunction(dashAnimation, "play", playDashAnimation) then
			warn("[HV] could not patch DashAnimation; skipping the dash animation is unavailable")
			dashAnimation, originalPlay = nil, nil
		end
	else
		dashAnimation = nil
	end
end

local function restoreMovement()
	if movementProfiles and movementProfiles.get == retunedProfile then swapFunction(movementProfiles, "get", originalGet) end
	if dashAnimation and dashAnimation.play == playDashAnimation then swapFunction(dashAnimation, "play", originalPlay) end
	dashAnimation, originalPlay = nil, nil

	movement.noCooldown, movement.longDash, movement.fastDash, movement.speed = false, false, false, false
	movement.skipAnimation = false
	movementProfiles, originalGet = nil, nil
	table.clear(profileCache)
end

---@param name string
---@return boolean
local function flag(name)
	local entry = ui and ui.Flags[name]
	return entry ~= nil and entry.Value == true
end

---@param name string
---@param default number
---@return number
local function numberFlag(name, default)
	local entry = ui and ui.Flags[name]
	return entry and tonumber(entry.Value) or default
end

---@param vector Vector3
---@return Vector3
local function flat(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Immortal is a preset: it forces dodge + ability on, widens the danger box and reacts to tracking catchers.
---@return boolean
local function immortalOn()
	return flag("immortal")
end

---@return number
local function margin()
	return numberFlag("margin", 0) + (immortalOn() and CONFIG.immortalMargin or 0)
end

---@return boolean
local function runnerActive()
	return localPlayer:GetAttribute("InMatch") == true
		and localPlayer:GetAttribute("GameRole") == "Runner"
		and localPlayer:GetAttribute("RunState") == "Active"
end

---@return table
local function participants()
	if participantDirectory then
		local success, list = pcall(participantDirectory.list)
		-- Running game code leaves this thread with the game script's reduced capabilities.
		setthreadidentity(8)
		if success and type(list) == "table" then return list end
	end

	return playersService:GetPlayers()
end

---@param participant any
---@return boolean
local function isCatcher(participant)
	return participant:GetAttribute("GameRole") == "Catcher" and participant:GetAttribute("RunState") == "Active"
end

-- Forward/lateral offset of a point from an attack origin along its direction. Lateral > 0 is the +perp side.
---@param origin Vector3
---@param direction Vector3
---@param position Vector3
---@return number, number
local function corridor(origin, direction, position)
	local relative = flat(position - origin)
	local forward = relative:Dot(direction)
	local lateral = relative:Dot(Vector3.new(-direction.Z, 0, direction.X))
	return forward, lateral
end

-- Finds the most urgent committed attack that will pass through our position.
---@param position Vector3
---@return table?
local function scanThreat(position)
	local extra = margin()
	local serverNow = workspace:GetServerTimeNow()
	local best = nil

	for _, participant in participants() do
		if participant == localPlayer or not isCatcher(participant) then continue end

		local character = participant.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then continue end

		local origin = root.Position
		local candidates = {}

		-- Melee swing: Windup then Active, aimed along ReachDirection.
		local phase = character:GetAttribute("ReachPhase")
		local reachDirection = character:GetAttribute("ReachDirection")
		if (phase == "Windup" or phase == "Active") and typeof(reachDirection) == "Vector3" and flat(reachDirection).Magnitude > 0.01 then
			table.insert(candidates, { kind = "Melee", dir = flat(reachDirection).Unit, forward = CONFIG.meleeForward, behind = CONFIG.meleeBehind, half = CONFIG.meleeHalfWidth })
		end

		-- Tackle dive: TackleActive for TackleDuration along TackleDirection.
		local tackleDirection = character:GetAttribute("TackleDirection")
		if character:GetAttribute("TackleActive") == true and typeof(tackleDirection) == "Vector3" and flat(tackleDirection).Magnitude > 0.01 then
			local startedAt = tonumber(character:GetAttribute("TackleStartedAt"))
			local duration = tonumber(character:GetAttribute("TackleDuration")) or 0.4
			if not startedAt or (serverNow - startedAt) <= duration + CONFIG.tackleGrace then
				table.insert(candidates, { kind = "Tackle", dir = flat(tackleDirection).Unit, forward = CONFIG.tackleForward, behind = CONFIG.tackleBehind, half = CONFIG.tackleHalfWidth })
			end
		end

		-- A catcher locked on to us that is already close; only when the user wants early reactions.
		if (flag("early") or immortalOn()) and phase == "Tracking" and character:GetAttribute("ReachTargetUserId") == localPlayer.UserId then
			local toUs = flat(position - origin)
			if toUs.Magnitude <= CONFIG.trackingDistance + extra and toUs.Magnitude > 0.01 then
				table.insert(candidates, { kind = "Tracking", dir = toUs.Unit, forward = CONFIG.trackingDistance + extra, behind = 0, half = 3 + extra })
			end
		end

		for _, candidate in candidates do
			local forward, lateral = corridor(origin, candidate.dir, position)
			if forward >= -candidate.behind and forward <= candidate.forward and math.abs(lateral) <= candidate.half + extra then
				if not best or forward < best.forward then
					best = { kind = candidate.kind, dir = candidate.dir, forward = forward, lateral = lateral, catcher = participant.Name }
				end
			end
		end
	end

	return best
end

-- Picks the sideways direction with the best clearance that the game's dash will accept as a redirect.
---@param threat table
---@param character Model
---@param position Vector3
---@param velocity Vector3
---@return Vector3
local function pickEvasion(threat, character, position, velocity)
	local perp = Vector3.new(-threat.dir.Z, 0, threat.dir.X)
	local preferred = threat.lateral >= 0 and perp or -perp
	local planar = flat(velocity)
	local travel = planar.Magnitude > CONFIG.minDashSpeed and planar.Unit or nil
	local reach = CONFIG.dashDistance + CONFIG.wallPadding

	rayParams.FilterDescendantsInstances = { character }

	local bestDirection = preferred
	local bestScore = -math.huge
	for _, direction in { preferred, -preferred } do
		local hit = workspace:Raycast(position, direction * reach, rayParams)
		local clearance = hit and hit.Distance or reach
		local legal = not travel or direction:Dot(travel) <= CONFIG.minIntentCos
		local score = clearance * (legal and 1 or 0.4) + (direction == preferred and 0.5 or 0)
		if score > bestScore then
			bestScore = score
			bestDirection = direction
		end
	end

	return bestDirection
end

---@param direction Vector3
---@param duration number
local function steer(direction, duration)
	hookState.steer = direction
	hookState.expiresAt = os.clock() + duration
end

local function clearSteer()
	hookState.steer = nil
	hookState.expiresAt = 0
end

-- Presses Q, the game's own ability key, so every cooldown/role rule stays the game's.
local function pressAbility()
	if userInputService:GetFocusedTextBox() then return end
	if (localPlayer:GetAttribute("AbilityReadyAt") or 0) > workspace:GetServerTimeNow() then return end

	lastAbility = os.clock()
	virtualInputManager:SendKeyEvent(true, Enum.KeyCode.Q, false, game)

	-- task.delay threads start at a low identity and cannot send input; spawn + wait keeps ours.
	task.spawn(function()
		task.wait(0.05)
		setthreadidentity(8)
		virtualInputManager:SendKeyEvent(false, Enum.KeyCode.Q, false, game)
	end)
	log("ability pressed")
end

---@param context table
local function react(context)
	local dodgeOn = flag("autoDodge") or immortalOn()
	local abilityOn = flag("autoAbility") or immortalOn()
	if not dodgeOn and not abilityOn then return end

	local threat = scanThreat(context.root.Position)
	if not threat then return end

	local now = os.clock()
	local dashReady = boostInput ~= nil
		and context.character:GetAttribute("DashReady") == true
		and boostInput.available(localPlayer)
	setthreadidentity(8)

	log("threat", threat.kind, threat.catcher, "dashReady", dashReady, "sinceDash", string.format("%.2f", now - lastDash))

	local lockout = movement.noCooldown and CONFIG.fastDashLockout or CONFIG.dashLockout
	if dodgeOn and dashReady and now - lastDash >= lockout then
		local velocity = context.root.AssemblyLinearVelocity
		local direction = pickEvasion(threat, context.character, context.root.Position, velocity)
		lastDash = now
		lastDashCount = context.character:GetAttribute("DashCount")
		steer(direction, CONFIG.steerHold)

		-- The dash only fires while we are already moving; standing still just sidesteps.
		local moving = flat(velocity).Magnitude >= CONFIG.minDashSpeed
		if moving then
			boostInput.request()
			setthreadidentity(8)
		end

		log("dodge", threat.kind, threat.catcher, string.format("fwd %.1f lat %.1f", threat.forward, threat.lateral), "requested", moving, "dir", direction)
		return
	end

	-- Dash spent (or off): fall back to the equipped Q ability while the attack is still on us.
	if abilityOn and now - lastAbility >= CONFIG.abilityLockout and now - lastDash >= 0.1 then
		pressAbility()
	end
end

-- Highlights whoever is hunting us (or, as a catcher, whoever we hunt).
local function updateEsp()
	local wanted = {}

	if flag("esp") then
		local myRole = localPlayer:GetAttribute("GameRole")
		local targetRole = myRole == "Catcher" and "Runner" or "Catcher"
		for _, participant in participants() do
			if participant == localPlayer then continue end
			if participant:GetAttribute("GameRole") ~= targetRole or participant:GetAttribute("RunState") ~= "Active" then continue end

			local character = participant.Character
			if character and character.Parent then wanted[character] = targetRole end
		end
	end

	for character, highlight in highlights do
		if not wanted[character] then
			highlight:Destroy()
			highlights[character] = nil
		end
	end

	for character, role in wanted do
		if highlights[character] then continue end

		local highlight = Instance.new("Highlight")
		highlight.Name = "HV_Esp"
		highlight.Adornee = character
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.FillColor = role == "Catcher" and Color3.fromRGB(255, 70, 90) or Color3.fromRGB(0, 212, 255)
		highlight.FillTransparency = 0.6
		highlight.OutlineColor = Color3.new(1, 1, 1)
		highlight.OutlineTransparency = 0.2
		highlight.Parent = guiParent
		highlights[character] = highlight
	end
end

-- The game's fair-play system warned us: put every movement tweak back to normal and say so.
local function stopRiskyMovement()
	for _, name in { "noCooldown", "longDash", "fastDash", "speed" } do
		local entry = ui and ui.Flags[name]
		if entry and entry.Value == true then entry.Set(false) end
	end

	if uiWindow then
		uiWindow:Notify({ Title = "Fair-play warning", Text = "Movement tweaks were switched off automatically.", Duration = 8 })
	end
end

-- The server moves a player back to where it believes they are by bumping MovementReset. If that happens while the
-- fast dash is on (and not because the round changed state), the dash was too fast for it: slow the dash down.
---@param character Model
local function watchServerSnapBack(character)
	local reset = character:GetAttribute("MovementReset")
	if resetCharacter ~= character then
		resetCharacter, lastReset = character, reset
		return
	end

	if reset == lastReset then return end
	lastReset = reset

	if not movement.fastDash or os.clock() - lastRunStateAt < 1.5 then return end

	local slower = math.min(100, movement.dashTime + 15)
	log("server snapped us back; dash time", movement.dashTime, "->", slower)
	local entry = ui and ui.Flags.dashTime
	if entry then entry.Set(slower) end
	if uiWindow then
		uiWindow:Notify({ Title = "Dash slowed down", Text = string.format("The server snapped you back, so the dash time was raised to %d%%.", slower), Duration = 6 })
	end
end

---@param deltaTime number
local function step(deltaTime)
	if guardTripped then
		guardTripped = false
		stopRiskyMovement()
	end

	tickTimer = tickTimer + deltaTime
	espTimer = espTimer + deltaTime

	if espTimer >= CONFIG.espRate then
		espTimer = 0
		updateEsp()
	end

	if tickTimer < CONFIG.tickRate then return end
	tickTimer = 0

	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and root) or humanoid.Health <= 0 then
		clearSteer()
		return
	end

	hookState.humanoid = humanoid
	watchServerSnapBack(character)

	-- The dash fired: stop steering so the character does not keep sidestepping after it.
	if lastDashCount ~= nil and character:GetAttribute("DashCount") ~= lastDashCount then
		lastDashCount = nil
		clearSteer()
	end

	if not runnerActive() then return end

	react({ character = character, humanoid = humanoid, root = root })
end

local function setupAntiAfk()
	-- Silence the default idle kick and answer Idled with a click, like any normal anti-AFK.
	local success, list = pcall(getconnections, localPlayer.Idled)
	if success then
		for _, connection in list do
			pcall(function() connection:Disable() end)
		end
	end

	table.insert(connections, localPlayer.Idled:Connect(function()
		if not flag("antiAfk") then return end

		setthreadidentity(8)
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.new())
	end))
end

-- Local glassui.lua first, the public copy as fallback.
---@return table
local function loadLibrary()
	local success, library = pcall(function()
		local chunk = loadstring(readfile(UI_FILE))
		return chunk and chunk()
	end)
	if success and type(library) == "table" then return library end

	local response = request({ Url = UI_URL, Method = "GET" })
	local chunk = loadstring(response.Body)
	assert(chunk, "GlassUI failed to compile")
	return chunk()
end

local function buildUi()
	ui = loadLibrary()
	local window = ui:CreateWindow({
		Title = "Huss Valley",
		Subtitle = "Auto Dodge  /  Immortal  /  Movement",
		-- Pressing "Unload UI" in the window's Settings tab unloads the whole script, not just the window.
		OnDestroy = function()
			if not detaching then HussValley.detach() end
		end,
	})
	uiWindow = window

	-- A hub overlay should not blur the game while you play; the Settings tab can turn it back on.
	ui.Flags.ui_blur.Set(false)

	window:CreateCategory("Survival")
	local combat = window:CreateTab("Combat")
	combat:AddSection("Dodge")
	combat:AddToggle({ Text = "Auto Dodge", Default = false, Flag = "autoDodge" })
	combat:AddToggle({ Text = "Auto Ability (Q) when dash is spent", Default = false, Flag = "autoAbility" })
	combat:AddToggle({ Text = "React to tracking catchers", Default = false, Flag = "early" })
	combat:AddSlider({ Text = "Danger margin (studs)", Min = 0, Max = 4, Default = 0, Increment = 0.5, Flag = "margin" })
	combat:AddSection("Immortal")
	combat:AddToggle({ Text = "Immortal (best effort)", Default = false, Flag = "immortal" })
	combat:AddLabel("Catches are decided by the server, so this cannot give true god mode. It dashes out of every attack it can see and spends your Q ability.")

	window:CreateCategory("Movement")
	local move = window:CreateTab("Movement")
	move:AddSection("Dash cooldown")
	move:AddToggle({ Text = "No dash cooldown", Default = false, Flag = "noCooldown", Callback = function(on) movement.noCooldown = on end })
	move:AddSlider({ Text = "Cooldown cap (s, 0 = none)", Min = 0, Max = 0.7, Default = 0, Increment = 0.05, Flag = "cooldownGap", Callback = function(value) movement.cooldownGap = value end })
	move:AddToggle({ Text = "Skip dash recovery", Default = true, Flag = "skipRecovery", Callback = function(on) movement.skipRecovery = on end })
	move:AddSection("Dash distance")
	move:AddToggle({ Text = "Longer dash", Default = false, Flag = "longDash", Callback = function(on) movement.longDash = on end })
	move:AddSlider({ Text = "Distance multiplier", Min = 1.1, Max = 3, Default = 1.5, Increment = 0.1, Flag = "dashScale", Callback = function(value) movement.dashScale = value end })
	move:AddSection("Instant dash")
	move:AddToggle({ Text = "Faster / instant dash", Default = false, Flag = "fastDash", Callback = function(on) movement.fastDash = on end })
	move:AddSlider({ Text = "Dash time (% of normal)", Min = 15, Max = 100, Default = 50, Increment = 5, Flag = "dashTime", Callback = function(value) movement.dashTime = value end })
	move:AddLabel("15% is the fastest the server accepted in testing. Truly instant (0%) gets you snapped back, so the slider stops at 15%; if a snap-back still happens the dash time is raised for you.")
	move:AddToggle({ Text = "Skip dash animation", Default = false, Flag = "skipAnimation", Callback = function(on) movement.skipAnimation = on end })
	move:AddSection("Speed")
	move:AddToggle({ Text = "Speed tuning", Default = false, Flag = "speed", Callback = function(on) movement.speed = on end })
	move:AddSlider({ Text = "Speed boost (%)", Min = 0, Max = 25, Default = 5, Increment = 1, Flag = "speedBoost", Callback = function(value) movement.speedBoost = value end })
	move:AddSection("Safety")
	move:AddToggle({ Text = "Auto-off on a fair-play warning", Default = true, Flag = "guardStop" })
	move:AddLabel("The server watches movement. Short tests of no cooldown, a 1.5x dash and +10% speed drew no warning, but the further you push past the game's own numbers the more likely one gets. If it warns you, these switch themselves off.")

	window:CreateCategory("Utility")
	local visuals = window:CreateTab("Visuals")
	visuals:AddToggle({ Text = "Threat ESP", Default = false, Flag = "esp" })
	local misc = window:CreateTab("Misc")
	misc:AddToggle({ Text = "Anti-AFK", Default = true, Flag = "antiAfk" })

	window:Notify({ Title = "Huss Valley", Text = "RightShift toggles the menu", Duration = 4 })
end

function HussValley.init()
	if game.PlaceId ~= PLACE_ID then
		warn("[HV] wrong place, expected Huss Valley")
		return
	end

	local movementFolder = replicatedStorage:WaitForChild("ChickenOrHero"):WaitForChild("Movement")
	boostInput = loadModule(movementFolder:WaitForChild("BoostInput"))
	participantDirectory = loadModule(replicatedStorage.ChickenOrHero:WaitForChild("Presentation"):WaitForChild("ParticipantDirectory"))

	guiParent = resolveGuiParent()
	buildUi()
	setupAntiAfk()
	installMovement()

	-- The server's fair-play system announces a warning on this remote; flag it for the main loop to act on.
	-- Plain table writes only: this callback starts at a low thread identity and must not touch the UI.
	local guardEvent = replicatedStorage.ChickenOrHero:WaitForChild("Presentation"):WaitForChild("MovementGuardEvent")
	table.insert(connections, guardEvent.OnClientEvent:Connect(function(kind)
		if kind ~= "Warning" or not flag("guardStop") then return end

		movement.noCooldown, movement.longDash, movement.fastDash, movement.speed = false, false, false, false
		guardTripped = true
		log("fair-play warning: movement tweaks off")
	end))

	-- Signal callbacks start at a low thread identity; SendKeyEvent and the hidden UI container need 8.
	-- A spawned loop (not a Connect callback) keeps the executor's full capabilities for input and hidden-UI parenting.
	alive = true
	task.spawn(function()
		while alive do
			local deltaTime = runService.Heartbeat:Wait()
			setthreadidentity(8)
			xpcall(step, onError, deltaTime)
		end
	end)

	-- Round-state changes (caught, safe, new round) legitimately reset movement; remember when one just happened.
	table.insert(connections, localPlayer:GetAttributeChangedSignal("RunState"):Connect(function()
		lastRunStateAt = os.clock()
	end))

	-- Never carry a steer across a respawn.
	table.insert(connections, localPlayer.CharacterAdded:Connect(function()
		lastRunStateAt = os.clock()
		clearSteer()
	end))
end

function HussValley.detach()
	if detaching then return end
	detaching = true
	alive = false

	for _, connection in connections do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(connections)

	restoreMovement()
	clearSteer()
	for character, highlight in highlights do
		highlight:Destroy()
		highlights[character] = nil
	end

	if ui then pcall(function() ui:Destroy() end) end
	if shared.HussValley == HussValley then shared.HussValley = nil end
end

-- Tunables (reaction boxes, lockouts, debug logging) stay reachable at runtime: shared.HussValley.config.debug = true
HussValley.config = CONFIG
HussValley.movement = movement

shared.HussValley = HussValley
xpcall(HussValley.init, onError)

return HussValley
