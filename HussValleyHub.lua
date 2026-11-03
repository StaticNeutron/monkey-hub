-- Huss Valley hub: Auto Dodge, Auto Ability, Immortal (best effort), Movement (no dash cooldown, longer dash, speed),
-- Threat ESP, Anti-AFK.
-- Auto Dodge / Immortal watch every attack within ~45 studs (all sides, any number at once), choose a landing spot that is
-- outside all of their danger zones, and dash there through the game's own BoostInput.
-- Verified against place 107535308163741 (v507): catcher swings/tackles are visible as character
-- attributes, a dash goes through ChickenOrHero.Movement.BoostInput, catches themselves are server-side.
-- Movement tweaks retune the game's own movement profile (MovementProfiles.get), so cooldown, recovery, distance and
-- speed all flow through the game's formulas; nothing is written into game memory.
-- UI: V18UI (V18UI.lua in the executor workspace, or the copy in the same GitHub repo), same look as the Da Hood hub.
if not shared then return warn("No shared, no script.") end

-- Singleton: replace a previous instance.
if shared.HussValley then
	pcall(shared.HussValley.detach)
end

local HussValley = {}

-- Constants.
local PLACE_ID = 107535308163741
local UI_FILE = "V18UI.lua"
local UI_URL = "https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/V18UI.lua"

-- Per-game values. Each one comes from the decompiled client config named next to it.
local CONFIG = {
	-- 0 = react on every frame; a dodge cannot afford to wait for a throttled tick.
	tickRate = 0,
	espRate = 0.25,
	-- Attackers further than this (studs) cannot reach us before we can react.
	vicinity = 45,
	-- Catchers spend their Q ability when a runner is this close (studs).
	catcherAbilityRange = 14,
	-- A catcher can still turn up to ContactCatchConfig.WindupAimLimit (20 degrees) while winding up, so a swing's danger zone
	-- widens with distance.
	aimSlack = math.tan(math.rad(20)),
	-- Directions tried when choosing where to dash.
	candidateDirections = 16,
	-- Immortal also steps away from a catcher that is locked on to us and this close (about to swing), at most this often.
	closeTrackingDistance = 7,
	trackingLockout = 0.25,
	-- MovementProfiles Runner Dash.Duration, and the settle time after it before another dash can be requested.
	dashDuration = 0.28,
	dashSettle = 0.03,
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
	-- Re-dodge gap while the dash cooldown is removed (the dash itself still has to finish first).
	fastDashLockout = 0.05,
	abilityLockout = 1,
	-- MovementProfiles Runner Dash: MinIntentAngle 35, ~10.9 studs.
	minIntentCos = math.cos(math.rad(35)),
	dashDistance = 11,
	minDashSpeed = 3,
	wallPadding = 2,
	immortalMargin = 3,
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
local tacklePrediction = nil
local originalRemaining = nil
local lastTackle = 0
local tackleHook = nil
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
local pendingReset = nil

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
	-- The game scales a dash by how fast you were already moving (Dash.ScaleDistanceWithSpeed), so a dash from a standstill
	-- barely moves. This keeps it full length.
	fullDash = false,
	-- Reach top speed immediately instead of ramping up (Acceleration is made effectively infinite).
	instantAccel = false,
	-- Catchers only have the tackle in the base game; this gives them the runner dash too (on by default, own key in the Catcher tab).
	catcherDash = true,
	-- Dash wherever you point it without turning away from your current direction first (the game normally refuses a dash
	-- unless it is at least 35 degrees away from where you were just travelling), including straight ahead.
	freeDash = false,
	-- Dash at any moment: a new dash cancels the one still playing (and its recovery and cooldown), so nothing locks you out.
	dashAnytime = false,
	-- Which way a free dash goes: the keys you are holding, the camera, or the way the character faces.
	dashDirection = "Movement keys",
	speed = false,
	-- Percent added on top of the live top speed, which itself moves with the round's balance buffs (about 37-42).
	speedBoost = 5,
	-- Immortal preset. While it is on, each part that is switched on (no cooldown, no recovery, full-length dash,
	-- fast dash at immortalDashTime percent of its normal duration, free direction) is applied on top of the
	-- individual switches above.
	immortal = false,
	-- Catcher-only boosts (Catcher tab): no cooldown on the runner dash AND the tackle, and a top-speed boost.
	catcherNoCooldown = false,
	catcherSpeed = false,
	catcherSpeedBoost = 5,
	-- Each part of the Immortal dash preset is its own switch (all on by default, like the UI toggles).
	immortalNoCooldown = true,
	immortalSkipRecovery = true,
	immortalFullDash = true,
	immortalFastDash = true,
	immortalFreeDash = true,
	immortalDashTime = 15,
	-- Immortal also spends the Q ability; turn this off to make it dash only.
	immortalAbility = true,
	-- Immortal extras: lead a moving catcher's swing origin, widen the danger zone with the catcher's speed, and prefer
	-- landing spots far from every catcher. All on by default (the UI toggles carry the same default).
	immortalPredict = true,
	immortalSpeedMargin = true,
	immortalBias = true,
}

-- What the movement wrapper applies right now: the user's own switches combined with the Immortal preset's.
local tuning = {
	noCooldown = false,
	gap = 0,
	skipRecovery = true,
	noRecovery = false,
	longDash = false,
	scale = 1.5,
	fastDash = false,
	dashTime = 100,
	fullDash = false,
	instantAccel = false,
	catcherDash = false,
	freeDash = false,
	speed = false,
	boost = 5,
}

-- True when Immortal is on and the named part of its dash preset is switched on.
---@param name string
---@return boolean
local function immortalPart(name)
	return movement.immortal == true and movement[name] == true
end

local function refreshTuning()
	local noCooldownPart = immortalPart("immortalNoCooldown")
	local fastPart = immortalPart("immortalFastDash")
	tuning.noCooldown = movement.noCooldown or noCooldownPart
	tuning.gap = noCooldownPart and 0 or movement.cooldownGap
	tuning.skipRecovery = movement.skipRecovery
	tuning.noRecovery = (movement.noCooldown and movement.skipRecovery) or immortalPart("immortalSkipRecovery")
	tuning.longDash = movement.longDash
	tuning.scale = movement.dashScale
	tuning.fastDash = movement.fastDash or fastPart
	if fastPart then
		tuning.dashTime = movement.fastDash and math.min(movement.dashTime, movement.immortalDashTime) or movement.immortalDashTime
	else
		tuning.dashTime = movement.dashTime
	end
	tuning.fullDash = movement.fullDash or immortalPart("immortalFullDash")
	tuning.instantAccel = movement.instantAccel
	tuning.catcherDash = movement.catcherDash
	tuning.freeDash = movement.freeDash or immortalPart("immortalFreeDash")
	tuning.speed = movement.speed
	tuning.boost = movement.speedBoost
end
local movementProfiles = nil
local originalGet = nil
local dashAnimation = nil
local originalPlay = nil
-- Catcher tab settings. The tackle is the catcher's dash.
local tackle = {
	auto = false,
	range = 5.5,
	aim = "Nearest runner",
	key = false,
	noCooldown = false,
	reachAssist = false,
	reach = 1.5,
	-- Report the catcher's top speed with every tackle so it starts at full length even from a standstill.
	fullFromStandstill = false,
}

-- Replacement for TacklePrediction.remaining: with no tackle cooldown the client no longer waits for its own timer.
---@return number
local function tackleRemaining()
	if tackle.noCooldown or movement.catcherNoCooldown then return 0 end

	return originalRemaining()
end

-- Keeps the position nudge applied to outgoing tackles in step with the Reach assist switch and slider.
local function syncReach()
	if tackleHook then
		tackleHook.reach = tackle.reachAssist and tackle.reach or 0
		tackleHook.fullSpeed = tackle.fullFromStandstill
	end
end
local movementModel = nil
local originalStep = nil
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
local function tuneProfile(profile, tuning)
	local clone = table.clone(profile)

	if tuning.speed and type(profile.MaxSpeed) == "number" and profile.MaxSpeed > 0 then
		local factor = 1 + tuning.boost / 100
		clone.MaxSpeed = profile.MaxSpeed * factor
		-- Scale acceleration with it so the new top speed is reached in the time the game intended.
		clone.Acceleration = profile.Acceleration * factor
	end

	-- Top speed straight away: the game adds Acceleration * dt per frame, so a huge value reaches the cap in one frame.
	if tuning.instantAccel and type(profile.MaxSpeed) == "number" then
		clone.Acceleration = math.max(profile.Acceleration or 0, clone.MaxSpeed * 1000)
	end

	local dash = profile.Dash
	local dashAvailable = type(dash) == "table" and (dash.Enabled or tuning.catcherDash)
	if dashAvailable then
		local tuned = table.clone(dash)
		-- Catchers ship with the runner dash disabled; "Catcher: also get the runner dash" switches it on for them.
		if not dash.Enabled then tuned.Enabled = true end
		if tuning.noCooldown then
			tuned.Cooldown = math.min(dash.Cooldown, tuning.gap)
		end
		if tuning.noRecovery then tuned.RecoveryDuration = 0 end
		if tuning.longDash then tuned.Distance = dash.Distance * tuning.scale end
		-- Same distance in less time. The game's dash model copes with a duration shorter than one frame by finishing in that frame.
		if tuning.fastDash then tuned.Duration = math.max(0.001, dash.Duration * tuning.dashTime / 100) end
		if tuning.fullDash then tuned.ScaleDistanceWithSpeed = false end
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

	refreshTuning()

	-- Catcher-only switches are layered on a copy, so the runner profile never sees them.
	local effective = tuning
	if role == "Catcher" and (movement.catcherNoCooldown or movement.catcherSpeed) then
		effective = table.clone(tuning)
		if movement.catcherNoCooldown then
			effective.noCooldown = true
			effective.gap = 0
			effective.noRecovery = effective.noRecovery or movement.skipRecovery
		end
		if movement.catcherSpeed then
			effective.boost = math.max(tuning.speed and tuning.boost or 0, movement.catcherSpeedBoost)
			effective.speed = true
		end
	end

	if not (effective.noCooldown or effective.noRecovery or effective.longDash or effective.fastDash or effective.fullDash or effective.instantAccel or effective.catcherDash or effective.speed) then return profile end

	local success, result = pcall(function()
		local signature = string.format("%s|%.2f|%s|%s|%.2f|%s|%.0f|%s|%s|%s|%s|%.1f", tostring(effective.noCooldown), effective.gap, tostring(effective.noRecovery), tostring(effective.longDash), effective.scale, tostring(effective.fastDash), effective.dashTime, tostring(effective.fullDash), tostring(effective.instantAccel), tostring(effective.catcherDash), tostring(effective.speed), effective.boost)
		local variants = profileCache[profile]
		if not variants then
			variants = {}
			profileCache[profile] = variants
		end

		local cached = variants[signature]
		if not cached then
			cached = tuneProfile(profile, effective)
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

-- Which way a free dash should go.
---@param moveDirection Vector3
---@return Vector3?
local function chooseDashDirection(moveDirection, mode)
	mode = mode or movement.dashDirection
	local keys = Vector3.new(moveDirection.X, 0, moveDirection.Z)

	-- When the hub itself is steering (Auto Dodge / Immortal) the steered direction is already in moveDirection.
	if hookState.steer ~= nil and os.clock() < hookState.expiresAt and keys.Magnitude > 0.05 then return keys.Unit end

	local camera = workspace.CurrentCamera
	local look = camera and camera.CFrame.LookVector or Vector3.new(0, 0, -1)
	local cameraForward = Vector3.new(look.X, 0, look.Z)
	cameraForward = cameraForward.Magnitude > 0.01 and cameraForward.Unit or nil

	if mode == "Camera" then return cameraForward end

	if mode == "Character facing" then
		local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
		local facing = root and Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		if facing and facing.Magnitude > 0.01 then return facing.Unit end

		return cameraForward
	end

	-- Movement keys: the way you are pressing; nothing pressed means straight ahead of the camera.
	if keys.Magnitude > 0.05 then return keys.Unit end

	return cameraForward
end

-- Replacement for MovementModel.step. The game dashes along the part of your input that is not already your travel
-- direction, and only when that turn is wide enough, so you cannot dash the way you are running or from a standstill.
-- With free dash on, a dash request the game would accept anyway gets a fake history entry saying we were just
-- travelling the opposite way, plus the direction we picked as the input, so the game's own rule is satisfied.
-- Anything that is not a live dash request passes straight through untouched.
local function freeDashStep(model, moveDirection, speed, dt, profile, grounded, a, b, request, velocity, touch)
	local forcedFree = movement.freeDash or immortalPart("immortalFreeDash")
	if request == true and movementModel and (forcedFree or movement.dashAnytime) then
		pcall(function()
			if type(profile) ~= "table" or type(profile.Dash) ~= "table" or not profile.Dash.Enabled then return end

			local direction = chooseDashDirection(moveDirection)
			if not direction then return end

			-- Dash anytime: end the dash that is still playing so the game treats us as free to dash again. The cancelled
			-- dash leaves no travel history, so the redirect trick below is needed for the new one.
			local cancelled = false
			if movement.dashAnytime and grounded ~= false and (model.dashRemaining > 0 or model.recoveryRemaining > 0 or model.cooldown > 0) then
				model.dashRemaining, model.recoveryRemaining, model.cooldown = 0, 0, 0
				cancelled = true
			end

			if not movementModel.canBoost(model, profile, grounded ~= false) then return end
			if not (forcedFree or cancelled) then return end

			-- Full entry speed so the dash keeps its full length even from a standstill.
			table.insert(model.travelHistory, { at = model.travelClock, direction = -direction, speed = profile.MaxSpeed })
			moveDirection = direction
			speed = math.max(speed, profile.StopThreshold * 2 + 0.05)
		end)
	end

	return originalStep(model, moveDirection, speed, dt, profile, grounded, a, b, request, velocity, touch)
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

	movementModel = loadModule(folder:WaitForChild("MovementModel"))
	if movementModel and type(movementModel.step) == "function" and type(movementModel.canBoost) == "function" then
		originalStep = movementModel.step
		if not swapFunction(movementModel, "step", freeDashStep) then
			warn("[HV] could not patch MovementModel; free dash is unavailable")
			movementModel, originalStep = nil, nil
		end
	else
		movementModel = nil
	end
end

local function restoreMovement()
	if movementProfiles and movementProfiles.get == retunedProfile then swapFunction(movementProfiles, "get", originalGet) end
	if dashAnimation and dashAnimation.play == playDashAnimation then swapFunction(dashAnimation, "play", originalPlay) end
	dashAnimation, originalPlay = nil, nil
	if movementModel and movementModel.step == freeDashStep then swapFunction(movementModel, "step", originalStep) end
	movementModel, originalStep = nil, nil
	if tacklePrediction and originalRemaining and tacklePrediction.remaining == tackleRemaining then swapFunction(tacklePrediction, "remaining", originalRemaining) end
	originalRemaining = nil
	tackle.noCooldown, tackle.reachAssist, tackle.auto, tackle.key = false, false, false, false
	tackle.fullFromStandstill = false
	movement.catcherNoCooldown, movement.catcherSpeed = false, false
	syncReach()

	movement.noCooldown, movement.longDash, movement.fastDash, movement.speed = false, false, false, false
	movement.skipAnimation, movement.immortal, movement.fullDash = false, false, false
	movement.instantAccel, movement.catcherDash, movement.freeDash = false, false, false
	movement.dashAnytime = false
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

---@return boolean
local function catcherActive()
	return localPlayer:GetAttribute("InMatch") == true
		and localPlayer:GetAttribute("GameRole") == "Catcher"
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

-- Signed distance from a point to a threat's danger zone: positive = outside it by that many studs, zero or negative = inside.
---@param threat table
---@param point Vector3
---@return number
local function safety(threat, point)
	local forward, lateral = corridor(threat.origin, threat.dir, point)
	local outsideAlong = math.max(-threat.behind - forward, forward - threat.limit)
	local outsideSide = math.abs(lateral) - (threat.half + threat.slack * math.max(forward, 0))
	return math.max(outsideAlong, outsideSide)
end

-- Collects every attack near us, from any side: melee swings, tackle dives and (optionally) a catcher about to swing.
---@param position Vector3
---@return table
local function scanThreats(position)
	local extra = margin()
	local serverNow = workspace:GetServerTimeNow()
	local immortal = immortalOn()
	local threats = {}

	for _, participant in participants() do
		if participant == localPlayer or not isCatcher(participant) then continue end

		local character = participant.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then continue end

		local origin = root.Position
		if flat(position - origin).Magnitude > CONFIG.vicinity then continue end

		-- Immortal: a catcher that is running swings from where it will be, not where it was, and a faster one covers more
		-- ground while our dash plays, so its zone is widened a little.
		local catcherSpeed = flat(root.AssemblyLinearVelocity)
		local pad = extra
		if immortal and movement.immortalSpeedMargin then pad = extra + math.min(catcherSpeed.Magnitude * 0.04, 1.5) end

		-- Melee swing: Windup then Active, aimed along ReachDirection.
		local phase = character:GetAttribute("ReachPhase")
		local reachDirection = character:GetAttribute("ReachDirection")
		local meleeOrigin = origin
		if immortal and movement.immortalPredict then meleeOrigin = origin + catcherSpeed * (phase == "Windup" and 0.12 or 0.06) end
		if (phase == "Windup" or phase == "Active") and typeof(reachDirection) == "Vector3" and flat(reachDirection).Magnitude > 0.01 then
			table.insert(threats, {
				kind = "Melee", catcher = participant.Name, origin = meleeOrigin, dir = flat(reachDirection).Unit,
				limit = CONFIG.meleeForward, behind = CONFIG.meleeBehind, half = CONFIG.meleeHalfWidth + pad,
				slack = phase == "Windup" and CONFIG.aimSlack or 0,
			})
		end

		-- Tackle dive: TackleActive for TackleDuration along TackleDirection.
		local tackleDirection = character:GetAttribute("TackleDirection")
		if character:GetAttribute("TackleActive") == true and typeof(tackleDirection) == "Vector3" and flat(tackleDirection).Magnitude > 0.01 then
			local startedAt = tonumber(character:GetAttribute("TackleStartedAt"))
			local duration = tonumber(character:GetAttribute("TackleDuration")) or 0.4
			if not startedAt or (serverNow - startedAt) <= duration + CONFIG.tackleGrace then
				table.insert(threats, {
					kind = "Tackle", catcher = participant.Name, origin = origin, dir = flat(tackleDirection).Unit,
					limit = CONFIG.tackleForward, behind = CONFIG.tackleBehind, half = CONFIG.tackleHalfWidth + pad, slack = 0,
				})
			end
		end

		-- Proximity dodge: any live catcher inside the chosen range counts as a threat from every side, so the dash
		-- leaves before the swing even starts. Closer catchers get a tighter trigger.
		if flag("proximity") then
			local toUs = flat(position - origin)
			local range = numberFlag("proximityRange", 8) + extra
			if toUs.Magnitude <= range then
				local dir = toUs.Magnitude > 0.01 and toUs.Unit or Vector3.new(1, 0, 0)
				table.insert(threats, {
					kind = "Proximity", catcher = participant.Name, origin = origin, dir = dir,
					limit = range, behind = range, half = range, slack = 0,
				})
			end
		end

		-- A catcher locked on to us and close enough to swing next.
		if (flag("early") or immortal) and phase == "Tracking" and character:GetAttribute("ReachTargetUserId") == localPlayer.UserId then
			local toUs = flat(position - origin)
			local close = flag("early") and CONFIG.trackingDistance or CONFIG.closeTrackingDistance
			if toUs.Magnitude <= close + extra and toUs.Magnitude > 0.01 then
				table.insert(threats, {
					kind = "Tracking", catcher = participant.Name, origin = origin, dir = toUs.Unit,
					limit = close + extra, behind = 0, half = 3 + extra, slack = 0,
				})
			end
		end
	end

	return threats
end

-- Picks where to dash: tries every direction, lands each one against walls, and keeps the one that ends up furthest
-- outside ALL the attackers' danger zones, preferring directions the game's dash accepts as a redirect.
---@param threats table
---@param character Model
---@param position Vector3
---@param velocity Vector3
---@param standing boolean
---@return Vector3
local function pickEvasion(threats, character, position, velocity, standing)
	local planar = flat(velocity)
	local travel = (not standing and planar.Magnitude > 0.01) and planar.Unit or nil
	local reach = CONFIG.dashDistance * (movement.longDash and movement.dashScale or 1)

	rayParams.FilterDescendantsInstances = { character }

	local bestDirection = Vector3.new(1, 0, 0)
	local bestScore = -math.huge
	for index = 0, CONFIG.candidateDirections - 1 do
		local angle = index * 2 * math.pi / CONFIG.candidateDirections
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))

		local hit = workspace:Raycast(position, direction * (reach + CONFIG.wallPadding), rayParams)
		local clearance = hit and hit.Distance or reach + CONFIG.wallPadding
		local travelled = math.clamp(clearance - 1, 0, reach)
		local landing = position + direction * travelled

		local worst = math.huge
		for _, threat in threats do
			worst = math.min(worst, safety(threat, landing))
		end

		-- Immortal: between equally safe spots, take the one further from every catcher.
		local bias = 0
		if movement.immortal and movement.immortalBias then
			local nearest = math.huge
			for _, threat in threats do
				nearest = math.min(nearest, flat(landing - threat.origin).Magnitude)
			end
			bias = math.min(nearest, 20) * 0.5
		end

		local legal = travel == nil or direction:Dot(travel) <= CONFIG.minIntentCos
		local score = math.min(worst, 8) * 10 - (reach - travelled) * 2 - (legal and 0 or 60) + bias
		-- Tie-break toward the way we are already heading so dodges stay natural.
		if travel then score = score + direction:Dot(travel) * 0.5 end

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

-- Can a dash start right now? The game's DashReady attribute only refreshes every 0.1s, which is too slow once the
-- cooldown is gone, so with no cooldown we also trust our own clock (dash duration plus a short settle).
---@param character Model
---@param now number
---@return boolean
local function dashReady(character, now)
	if not boostInput then return false end

	refreshTuning()
	local seconds = CONFIG.dashDuration * (tuning.fastDash and tuning.dashTime / 100 or 1)
	local settled = movement.dashAnytime or (tuning.noCooldown and now - lastDash >= seconds + CONFIG.dashSettle)
	local ready = (character:GetAttribute("DashReady") == true or settled) and boostInput.available(localPlayer)
	setthreadidentity(8)

	return ready
end

-- Closest live runner to a point, as its root part and flat distance.
---@param origin Vector3
---@return BasePart?, number
local function nearestRunner(origin)
	local bestRoot, bestDistance = nil, math.huge
	for _, participant in participants() do
		if participant == localPlayer then continue end
		if participant:GetAttribute("GameRole") ~= "Runner" or participant:GetAttribute("RunState") ~= "Active" then continue end

		local character = participant.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not (root and humanoid) or humanoid.Health <= 0 then continue end

		local distance = flat(root.Position - origin).Magnitude
		if distance < bestDistance then bestRoot, bestDistance = root, distance end
	end

	return bestRoot, bestDistance
end

-- Fires the catcher's own dash, the tackle, turned toward the chosen target first (the game dives along the way the
-- character faces). The game still applies its own readiness checks.
---@param aim string?
---@return boolean
local function fireTackle(aim)
	if not (tacklePrediction and catcherActive()) then return false end

	aim = aim or tackle.aim
	local fired = false
	pcall(function()
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not (root and humanoid) then return end

		local direction = nil
		if aim == "Nearest runner" then
			local target = nearestRunner(root.Position)
			if target then
				-- Aim a little ahead of a moving runner.
				local ahead = flat(target.Position + target.AssemblyLinearVelocity * 0.1 - root.Position)
				if ahead.Magnitude > 0.1 then direction = ahead.Unit end
			end
		elseif aim ~= "Character facing" then
			local keys = humanoid.MoveDirection
			if hookState.steer ~= nil and os.clock() < hookState.expiresAt then keys = hookState.steer end
			direction = chooseDashDirection(keys, aim)
		end

		if direction then root.CFrame = CFrame.lookAt(root.Position, root.Position + direction) end

		fired = tacklePrediction.request() == true
	end)
	setthreadidentity(8)
	lastTackle = os.clock()

	return fired
end

-- Key press for the tackle: needs the Catcher key switch on.
local function requestCatcherDash()
	if not tackle.key then return end

	fireTackle()
end

-- The runner dash for catchers (the second dash). Needs "Catcher: also get the runner dash"; every dash tweak in the
-- Movement tab (cooldown, distance, speed, direction, anytime) applies to it.
local function requestCatcherRunnerDash()
	if not (movement.catcherDash and boostInput and catcherActive()) then return end

	boostInput.request()
	setthreadidentity(8)
end

-- Auto Tackle: dive at the closest runner once it is inside the chosen range and the game says the tackle is ready.
---@param context table
local function autoTackle(context)
	if not (tackle.auto and tacklePrediction) or os.clock() - lastTackle < 0.25 then return end
	if context.character:GetAttribute("TackleActive") then return end

	local target, distance = nearestRunner(context.root.Position)
	if not target or distance > tackle.range then return end

	local ready = tacklePrediction.remaining() <= 0.02
	setthreadidentity(8)
	if not ready then return end

	fireTackle("Nearest runner")
end

-- Catcher counterpart of Auto Ability: spend the Q ability when a runner is within reach.
---@param context table
local function assistCatcher(context)
	if not flag("autoAbility") or os.clock() - lastAbility < CONFIG.abilityLockout then return end

	local position = context.root.Position
	for _, participant in participants() do
		if participant == localPlayer then continue end
		if participant:GetAttribute("GameRole") ~= "Runner" or participant:GetAttribute("RunState") ~= "Active" then continue end

		local character = participant.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and flat(root.Position - position).Magnitude <= CONFIG.catcherAbilityRange then
			pressAbility()
			return
		end
	end
end

-- Dashes out of every attack near us. State of an in-progress "standing still" prime lives in primeState.
local primeState = nil

---@param context table
local function react(context)
	local dodgeOn = flag("autoDodge") or immortalOn()
	local abilityOn = flag("autoAbility") or (immortalOn() and movement.immortalAbility)
	if not dodgeOn and not abilityOn then
		primeState = nil
		return
	end

	local position = context.root.Position
	local threats = scanThreats(position)

	-- Which of them can reach us where we stand right now?
	local inside, committed = false, false
	for _, threat in threats do
		if safety(threat, position) <= 0 then
			inside = true
			if threat.kind ~= "Tracking" and threat.kind ~= "Proximity" then committed = true end
		end
	end

	if not inside then
		primeState = nil
		return
	end

	local now = os.clock()
	local ready = dashReady(context.character, now)
	refreshTuning()

	log("threats", #threats, "committed", committed, "dashReady", ready, "sinceDash", string.format("%.2f", now - lastDash))

	local lockout = committed and (tuning.noCooldown and CONFIG.fastDashLockout or CONFIG.dashLockout) or CONFIG.trackingLockout
	if dodgeOn and ready and now - lastDash >= lockout then
		local velocity = context.root.AssemblyLinearVelocity
		local planar = flat(velocity).Magnitude

		-- Standing still: the game only dashes when it has seen us move in the last ~0.4s (it turns away from that
		-- travel), so nudge the opposite way for two frames first, then dash. Moving: dash straight away.
		if planar < CONFIG.minDashSpeed and not tuning.freeDash then
			if not primeState then
				primeState = { direction = pickEvasion(threats, context.character, position, velocity, true), frames = 0 }
			end

			primeState.frames = primeState.frames + 1
			steer(-primeState.direction, 0.1)
			if primeState.frames > 8 then primeState = nil end
			if not primeState or primeState.frames < 3 or planar < 0.2 then return end
		end

		local direction = primeState and primeState.direction or pickEvasion(threats, context.character, position, velocity, tuning.freeDash)
		primeState = nil

		lastDash = now
		lastDashCount = context.character:GetAttribute("DashCount")
		steer(direction, CONFIG.steerHold)
		boostInput.request()
		setthreadidentity(8)

		log("dodge", "dir", direction, "attackers", #threats)
		return
	end

	primeState = nil

	-- Dash spent (or off): fall back to the equipped Q ability while the attack is still on us.
	if abilityOn and committed and now - lastAbility >= CONFIG.abilityLockout and now - lastDash >= 0.1 then
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
	-- Immortal keeps dodging; only its forced no-cooldown / fast-dash part is withdrawn.
	for _, name in { "noCooldown", "longDash", "fastDash", "fullDash", "instantAccel", "catcherDash", "freeDash", "dashAnytime", "catcherRunnerDash", "tackleNoCooldown", "reachAssist", "speed", "catcherNoCooldown", "catcherSpeed", "catcherFullTackle", "immortalNoCooldown", "immortalSkipRecovery", "immortalFullDash", "immortalFastDash", "immortalFreeDash" } do
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

	if reset ~= lastReset then
		lastReset = reset
		pendingReset = os.clock()
	end

	-- Judge a reset only after a short delay: the server often moves us a moment before the round-state change that
	-- explains it (round end, caught, safe, respawn, teleport to the lobby).
	if not pendingReset or os.clock() - pendingReset < 0.8 then return end

	local resetAt = pendingReset
	pendingReset = nil

	-- Only a snap-back during a live match counts: we are Active now, and nothing changed state around the reset.
	if localPlayer:GetAttribute("RunState") ~= "Active" or character:GetAttribute("MovementLocked") then return end
	if lastRunStateAt > resetAt - 2.5 or os.clock() - lastRunStateAt < 3 then return end

	local forced = immortalPart("immortalFastDash")
	if not (movement.fastDash or forced or immortalPart("immortalFreeDash") or immortalPart("immortalNoCooldown") or movement.instantAccel or movement.freeDash or movement.dashAnytime or movement.catcherDash or movement.catcherNoCooldown or movement.catcherSpeed or tackle.noCooldown or tackle.reachAssist or tackle.fullFromStandstill) then return end

	-- No dash-time knob in play: the snap-back can only come from the acceleration or catcher-dash switches, so withdraw them.
	if not (movement.fastDash or forced) then
		for _, name in { "instantAccel", "freeDash", "dashAnytime", "catcherRunnerDash", "tackleNoCooldown", "reachAssist", "catcherNoCooldown", "catcherSpeed", "catcherFullTackle" } do
			local entry = ui and ui.Flags[name]
			if entry and entry.Value == true then entry.Set(false) end
		end
		log("server snapped us back; instant acceleration / free-direction dash switched off")
		if uiWindow then
			uiWindow:Notify({ Title = "Switched off", Text = "The server snapped you back, so instant acceleration and free-direction dash were turned off.", Duration = 6 })
		end
		return
	end

	-- Slow whichever fast dash is in force: the user's own slider and/or the Immortal preset's dash time.
	local slower = 0
	if movement.fastDash then
		slower = math.min(100, movement.dashTime + 15)
		local entry = ui and ui.Flags.dashTime
		if entry then entry.Set(slower) end
	end
	if forced then
		movement.immortalDashTime = math.min(100, movement.immortalDashTime + 15)
		slower = math.max(slower, movement.immortalDashTime)
	end

	log("server snapped us back; dash time raised to", slower)
	if uiWindow then
		uiWindow:Notify({ Title = "Dash slowed down", Text = string.format("The server snapped you back, so the dash time was raised to %d%%.", slower), Duration = 6 })
	end
end

-- One list drives both the on-screen HUD and the Settings "Keybinds" section: add a line here and it shows up in both.
-- kind "key" prints the bound key, kind "toggle" prints ON/OFF live from the flag.
local REGISTRY = {
	{ section = "Keybinds", label = "Menu", flag = "ui_toggleKey", kind = "key" },
	{ section = "Keybinds", label = "Auto Dodge on/off", flag = "autoDodgeKey", kind = "key" },
	{ section = "Keybinds", label = "Runner dash (catcher)", flag = "catcherRunnerDashKey", kind = "key" },
	{ section = "Keybinds", label = "Tackle (catcher)", flag = "catcherDashKey", kind = "key" },
	{ section = "Keybinds", label = "Keybind HUD", flag = "hudKey", kind = "key" },
	{ section = "Combat", label = "Auto Dodge", flag = "autoDodge", kind = "toggle" },
	{ section = "Combat", label = "Auto Ability (Q)", flag = "autoAbility", kind = "toggle" },
	{ section = "Combat", label = "Proximity dodge", flag = "proximity", kind = "toggle" },
	{ section = "Combat", label = "React to tracking", flag = "early", kind = "toggle" },
	{ section = "Combat", label = "Immortal", flag = "immortal", kind = "toggle" },
	{ section = "Combat", label = "Immortal: no cooldown", flag = "immortalNoCooldown", kind = "toggle" },
	{ section = "Combat", label = "Immortal: skip recovery", flag = "immortalSkipRecovery", kind = "toggle" },
	{ section = "Combat", label = "Immortal: full dash", flag = "immortalFullDash", kind = "toggle" },
	{ section = "Combat", label = "Immortal: fastest dash", flag = "immortalFastDash", kind = "toggle" },
	{ section = "Combat", label = "Immortal: free direction", flag = "immortalFreeDash", kind = "toggle" },
	{ section = "Combat", label = "Immortal: abilities", flag = "immortalAbility", kind = "toggle" },
	{ section = "Combat", label = "Immortal: lead catchers", flag = "immortalPredict", kind = "toggle" },
	{ section = "Combat", label = "Immortal: speed margin", flag = "immortalSpeedMargin", kind = "toggle" },
	{ section = "Combat", label = "Immortal: escape bias", flag = "immortalBias", kind = "toggle" },
	{ section = "Movement", label = "No dash cooldown", flag = "noCooldown", kind = "toggle" },
	{ section = "Movement", label = "Skip recovery", flag = "skipRecovery", kind = "toggle" },
	{ section = "Movement", label = "Longer dash", flag = "longDash", kind = "toggle" },
	{ section = "Movement", label = "Dash anytime", flag = "dashAnytime", kind = "toggle" },
	{ section = "Movement", label = "Free-direction dash", flag = "freeDash", kind = "toggle" },
	{ section = "Movement", label = "Full-distance dash", flag = "fullDash", kind = "toggle" },
	{ section = "Movement", label = "Faster dash", flag = "fastDash", kind = "toggle" },
	{ section = "Movement", label = "Skip dash animation", flag = "skipAnimation", kind = "toggle" },
	{ section = "Movement", label = "Instant acceleration", flag = "instantAccel", kind = "toggle" },
	{ section = "Movement", label = "Speed tuning", flag = "speed", kind = "toggle" },
	{ section = "Movement", label = "Auto-off on warning", flag = "guardStop", kind = "toggle" },
	{ section = "Catcher", label = "Auto Tackle", flag = "autoTackle", kind = "toggle" },
	{ section = "Catcher", label = "Runner dash", flag = "catcherRunnerDash", kind = "toggle" },
	{ section = "Catcher", label = "Tackle key", flag = "catcherDash", kind = "toggle" },
	{ section = "Catcher", label = "No tackle cooldown", flag = "tackleNoCooldown", kind = "toggle" },
	{ section = "Catcher", label = "Reach assist", flag = "reachAssist", kind = "toggle" },
	{ section = "Catcher", label = "Full-length tackle", flag = "catcherFullTackle", kind = "toggle" },
	{ section = "Catcher", label = "No cooldown (dash + tackle)", flag = "catcherNoCooldown", kind = "toggle" },
	{ section = "Catcher", label = "Catcher speed", flag = "catcherSpeed", kind = "toggle" },
	{ section = "Visuals", label = "Threat ESP", flag = "esp", kind = "toggle" },
	{ section = "Misc", label = "Anti-AFK", flag = "antiAfk", kind = "toggle" },
	{ section = "Misc", label = "Keybind HUD", flag = "hud", kind = "toggle" },
}
local REGISTRY_SECTIONS = { "Keybinds", "Combat", "Movement", "Catcher", "Visuals", "Misc" }

local hudGui = nil
local hudLabel = nil
local hudText = ""
local hudStamp = 0
local keybindLabel = nil
local keybindText = ""

-- Text for one registry pass. rich = true gives coloured RichText for the HUD, false gives plain text for GlassUI labels.
---@param rich boolean
---@return string
local function registryText(rich)
	local lines = {}
	for _, name in REGISTRY_SECTIONS do
		local rows = {}
		for _, entry in REGISTRY do
			if entry.section ~= name then continue end

			local flagEntry = ui and ui.Flags[entry.flag]
			if not flagEntry then continue end

			if entry.kind == "key" then
				local key = typeof(flagEntry.Value) == "EnumItem" and flagEntry.Value.Name or "None"
				table.insert(rows, rich and string.format("%s: <b>%s</b>", entry.label, key) or string.format("%s: %s", entry.label, key))
			else
				local on = flagEntry.Value == true
				if rich then
					table.insert(rows, on and string.format("<font color=\"#3ddc97\">●</font> %s", entry.label)
						or string.format("<font color=\"#6b7280\">○ %s</font>", entry.label))
				else
					table.insert(rows, string.format("%s  %s", on and "[ON]  " or "[off]", entry.label))
				end
			end
		end

		if #rows > 0 then
			table.insert(lines, rich and string.format("<b><font color=\"#5eead4\">%s</font></b>", string.upper(name)) or string.upper(name))
			for _, row in rows do table.insert(lines, row) end
			table.insert(lines, "")
		end
	end

	return table.concat(lines, "\n")
end

-- Builds the small draggable panel once. It lives next to the hub's other GUI and is removed on unload.
local function createHud()
	if hudGui or not guiParent then return end

	local gui = Instance.new("ScreenGui")
	gui.Name = "HussValleyHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.IgnoreGuiInset = true

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Size = UDim2.fromOffset(230, 0)
	frame.Position = UDim2.new(1, -250, 0, 70)
	frame.BackgroundColor3 = Color3.fromRGB(14, 17, 26)
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(94, 234, 212)
	stroke.Transparency = 0.45
	stroke.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
	padding.PaddingTop, padding.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
	padding.Parent = frame

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Size = UDim2.new(1, 0, 0, 0)
	label.RichText = true
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 12
	label.TextColor3 = Color3.fromRGB(226, 232, 240)
	label.Text = ""
	label.Parent = frame

	-- Drag with the mouse or a finger.
	local dragging, dragStart, startPosition = false, nil, nil
	table.insert(connections, frame.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end

		dragging, dragStart, startPosition = true, input.Position, frame.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then dragging = false end
		end)
	end))
	table.insert(connections, game:GetService("UserInputService").InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end

		local delta = input.Position - dragStart
		frame.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
	end))

	gui.Parent = guiParent
	hudGui, hudLabel = gui, label
end

-- Servers ---------------------------------------------------------------------------------------------------------------
-- A floating browser that lists every public server with what it is doing right now (boss fight, in game, intermission,
-- lobby). The phase comes from the game's own server list (ServerBrowserEvent "List"), which only answers in lobby
-- servers. When it does not answer, Roblox's public server list fills in player counts and ping, without a status.

local teleportService = game:GetService("TeleportService")
local httpService = game:GetService("HttpService")

local SERVER_PAGE_URL = "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100"
local SERVER_REFRESH_GAP = 2
local SERVER_AUTO_GAP = 15
local SERVER_ROWS_SHOWN = 60
local PANEL_WIDTH = 600
local PANEL_HEIGHT = 470

local PANEL_COLORS = {
	bg = Color3.fromRGB(24, 19, 16),
	card = Color3.fromRGB(34, 27, 23),
	row = Color3.fromRGB(255, 244, 232),
	text = Color3.fromRGB(248, 242, 236),
	muted = Color3.fromRGB(182, 170, 158),
	accent = Color3.fromRGB(70, 108, 226),
	accent2 = Color3.fromRGB(122, 152, 244),
	stroke = Color3.fromRGB(255, 240, 224),
}

local STATUS = {
	boss = { label = "Boss fight", color = Color3.fromRGB(240, 96, 112) },
	game = { label = "In game", color = Color3.fromRGB(96, 214, 150) },
	intermission = { label = "Intermission", color = Color3.fromRGB(240, 190, 90) },
	lobby = { label = "Lobby", color = Color3.fromRGB(122, 152, 244) },
	starting = { label = "Starting", color = Color3.fromRGB(250, 160, 100) },
	ending = { label = "Round ending", color = Color3.fromRGB(200, 140, 240) },
	unknown = { label = "No status", color = Color3.fromRGB(182, 170, 158) },
}
local STATUS_ORDER = { "boss", "game", "starting", "intermission", "lobby", "ending", "unknown" }
local STATUS_RANK = { boss = 1, game = 2, starting = 3, intermission = 4, lobby = 5, ending = 6, unknown = 7 }

-- The game's own Session.Phase values (from its client scripts) and what each one means.
local PHASE_STATUS = {
	Lobby = "lobby", MapVote = "lobby", RankedLoadout = "lobby",
	Intermission = "intermission",
	Countdown = "starting", Prepare = "starting", SelectHero = "starting", HeroChoice = "starting", ChoiceReveal = "starting",
	HeroRun = "game", GroupRun = "game", FinalRun = "game", RunResolution = "game",
	Results = "ending",
}
local PHASE_LABEL = {
	Lobby = "Lobby", MapVote = "Map vote", RankedLoadout = "Loadout", Intermission = "Lobby break", Countdown = "Starting",
	Prepare = "Get ready", SelectHero = "Hero selection", HeroChoice = "Hero choice", ChoiceReveal = "Choice reveal",
	HeroRun = "Hero run", GroupRun = "Crossing", FinalRun = "Final run", RunResolution = "Round complete", Results = "Results",
}

local servers = {
	rows = {},
	source = "",
	notice = "Press Refresh to look for servers.",
	busy = false,
	dirty = true,
	lastRefresh = -100,
	lastAuto = 0,
	gameRows = {},
	gameAt = nil,
	remote = nil,
	filter = "all",
	hideFull = false,
	localKey = "unknown",
	localText = "",
	localKing = "",
	king = nil,
	localStamp = -10,
	summary = nil,
}
local serverGui = nil
local serverRoot = nil
local serverList = nil
local serverNotice = nil
local serverCount = nil
local serverThis = nil
local serverChips = {}

-- Maps the game's own phase text (or anything similar) to one of the status buckets above.
---@param phase any
---@return string
local function classifyPhase(phase)
	if PHASE_STATUS[phase] then return PHASE_STATUS[phase] end

	local text = string.lower(tostring(phase or ""))
	if text == "" or text == "nil" then return "unknown" end
	if string.find(text, "boss", 1, true) or string.find(text, "king", 1, true) then return "boss" end
	if string.find(text, "end", 1, true) or string.find(text, "result", 1, true) or string.find(text, "finish", 1, true) then return "ending" end
	for _, word in { "inter", "wait", "vot", "countdown", "prepar", "start", "queue", "break" } do
		if string.find(text, word, 1, true) then return "intermission" end
	end
	if string.find(text, "lobby", 1, true) then return "lobby" end
	for _, word in { "round", "match", "active", "game", "play", "run", "progress", "live", "chase" } do
		if string.find(text, word, 1, true) then return "game" end
	end

	return "unknown"
end

-- Short text for the Fallen King event: how full the cauldron is and what stage the summon is at.
---@param king table?
---@return string
servers.kingText = function(king)
	if type(king) ~= "table" or not king.progress then return "" end

	local text = string.format("Fallen King %d%%", math.floor(king.progress * 100 + 0.5))
	if king.state and king.state ~= "" then text = text .. "  ·  " .. tostring(king.state) end
	if king.won then text = text .. "  ·  beaten" end
	return text
end

-- What THIS server is doing, read from the state the game replicates to us. Cheap, polled about once a second.
local function updateLocalStatus()
	if os.clock() - servers.localStamp < 1 then return end
	servers.localStamp = os.clock()

	local role = localPlayer:GetAttribute("GameRole")
	local runState = localPlayer:GetAttribute("RunState")

	-- The server's own phase and the Fallen King event live in ReplicatedStorage.ChickenOrHero.Game.
	local chicken = replicatedStorage:FindFirstChild("ChickenOrHero")
	local gameFolder = chicken and chicken:FindFirstChild("Game")
	local session = gameFolder and gameFolder:FindFirstChild("Session")
	local kingEvent = gameFolder and gameFolder:FindFirstChild("FallenKingEvent")
	local phase = session and session:GetAttribute("Phase")

	local king = {
		progress = gameFolder and tonumber(gameFolder:GetAttribute("FallenKingProgress")),
		state = kingEvent and kingEvent:GetAttribute("SummonState"),
		won = gameFolder ~= nil and gameFolder:GetAttribute("FallenKingLiveWon") == true,
		pot = kingEvent and tonumber(kingEvent:GetAttribute("SummonPot")),
		target = kingEvent and tonumber(kingEvent:GetAttribute("SummonTarget")),
	}
	servers.king = king

	local key = "unknown"
	local fighting = king.state == "Summoning" or king.state == "Live" or king.state == "Fighting" or king.state == "Boss"
	if fighting then
		key = "boss"
	elseif phase then
		key = classifyPhase(phase)
	elseif runState == "Active" or runState == "Caught" or runState == "Safe" then
		key = "game"
	elseif runState == "Waiting" then
		key = "intermission"
	elseif runState == "Lobby" or role == "Lobby" then
		key = "lobby"
	end

	-- The server's own number for the catcher's top speed (the unmodified profile), cached for the tackle hook.
	if tackleHook and originalGet then
		local catcherProfile = originalGet("Catcher", localPlayer)
		if type(catcherProfile) == "table" and type(catcherProfile.MaxSpeed) == "number" then tackleHook.top = catcherProfile.MaxSpeed end
	end

	local text = fighting and ("Fallen King: " .. tostring(king.state)) or (phase and (PHASE_LABEL[phase] or tostring(phase))) or string.format("%s / %s", tostring(role or "?"), tostring(runState or "?"))
	local kingText = servers.kingText(king)
	if key ~= servers.localKey or text ~= servers.localText or kingText ~= servers.localKing then
		servers.localKey, servers.localText, servers.localKing = key, text, kingText
		servers.dirty = true
	end
end

---@param title string
---@param text string
local function serverNotify(title, text)
	if uiWindow then pcall(function() uiWindow:Notify({ Title = title, Text = text, Duration = 4 }) end) end
end

-- Looks through a server-list row (two levels deep) for anything about the Fallen King / boss event: a progress number
-- (0-1 or a percent) and a state string. The list's exact fields are not documented, so this goes by key names.
---@param raw table
---@return table?
local function findKingInfo(raw)
	local info = { progress = false, state = false }
	local function scan(tableValue, depth)
		for key, value in tableValue do
			local name = string.lower(tostring(key))
			if type(value) == "table" and depth < 2 then
				scan(value, depth + 1)
			elseif string.find(name, "king", 1, true) or string.find(name, "boss", 1, true) or string.find(name, "summon", 1, true) or string.find(name, "cauldron", 1, true) then
				if type(value) == "number" and (string.find(name, "progress", 1, true) or string.find(name, "percent", 1, true)) then
					info.progress = value > 1.5 and value / 100 or value
				elseif type(value) == "string" and not info.state then
					info.state = value
				end
			end
		end
	end
	scan(raw, 0)

	if not info.progress and not info.state then return nil end
	return info
end

-- Normalises one row of the game's own list.
---@param raw table
---@return table
local function gameRow(raw)
	local location = type(raw.location) == "table" and raw.location or nil
	local region = location and (location.country or "Region unknown") or (raw.region or "Region unknown")
	if location and location.subdivision and location.subdivision ~= "" then region = region .. " · " .. location.subdivision end

	return {
		id = raw.id,
		source = "game",
		players = tonumber(raw.players) or 0,
		capacity = tonumber(raw.capacity) or 0,
		phase = PHASE_LABEL[raw.phase] or tostring(raw.phase or ""),
		status = classifyPhase(raw.phase),
		region = region,
		ping = tonumber(raw.averagePing),
		current = raw.current == true,
		full = raw.full == true,
		king = findKingInfo(raw),
	}
end

-- Roblox's public server list: player counts and ping only.
---@return table?, string?
local function fetchPublicRows()
	local success, response = pcall(request, { Url = string.format(SERVER_PAGE_URL, PLACE_ID), Method = "GET" })
	if not success or type(response) ~= "table" then return nil, "Could not reach Roblox's server list." end
	if response.StatusCode == 429 then return nil, "Roblox is rate limiting the server list. Wait a moment and refresh." end
	if response.StatusCode ~= 200 then return nil, "Roblox's server list answered " .. tostring(response.StatusCode) .. "." end

	local decoded, data = pcall(function() return httpService:JSONDecode(response.Body) end)
	if not decoded or type(data) ~= "table" or type(data.data) ~= "table" then return nil, "Roblox's server list came back unreadable." end

	local rows = {}
	for _, entry in data.data do
		table.insert(rows, {
			id = entry.id,
			source = "roblox",
			players = tonumber(entry.playing) or 0,
			capacity = tonumber(entry.maxPlayers) or 0,
			phase = "",
			status = "unknown",
			region = "Server " .. string.sub(tostring(entry.id), 1, 6),
			ping = tonumber(entry.ping),
			current = entry.id == game.JobId,
			full = (tonumber(entry.playing) or 0) >= (tonumber(entry.maxPlayers) or 1),
		})
	end

	return rows
end

local function refreshServers()
	if servers.busy or os.clock() - servers.lastRefresh < SERVER_REFRESH_GAP then return end
	servers.busy = true
	servers.lastRefresh = os.clock()
	servers.notice = "Looking for servers..."
	servers.dirty = true

	local askedAt = os.clock()
	if servers.remote then pcall(function() servers.remote:FireServer("List") end) end

	task.spawn(function()
		local publicRows, failure = fetchPublicRows()

		-- Give the game's own list a few seconds to answer; it never does outside the lobby.
		local waited = 0
		while waited < 4 and not (servers.gameAt and servers.gameAt >= askedAt) do
			task.wait(0.25)
			waited += 0.25
		end

		if servers.gameAt and servers.gameAt >= askedAt and #servers.gameRows > 0 then
			servers.rows, servers.source = servers.gameRows, "game"
			servers.notice = "Status comes straight from the game's own server list."
		elseif publicRows then
			servers.rows, servers.source = publicRows, "roblox"
			servers.notice = "The game only shares what each server is doing with players in the lobby. Showing Roblox's list instead: player counts and ping, no status. Join from the lobby to see boss fights and rounds."
		else
			servers.notice = failure or "No servers found."
		end

		servers.busy = false
		servers.dirty = true
	end)
end

---@param row table
local function joinServer(row)
	if row.current then return serverNotify("Servers", "You are already in this server") end
	if row.full then return serverNotify("Servers", "That server is full") end

	if row.source == "game" and servers.remote then
		pcall(function() servers.remote:FireServer("Join", row.id) end)
		serverNotify("Servers", "Asking the game to switch servers")
	else
		local success = pcall(function() teleportService:TeleportToPlaceInstance(PLACE_ID, row.id, localPlayer) end)
		serverNotify("Servers", success and "Teleporting..." or "Could not teleport to that server")
	end
end

---@param className string
---@param props table
---@param parent Instance?
---@return Instance
local function make(className, props, parent)
	local object = Instance.new(className)
	for key, value in props do object[key] = value end
	object.Parent = parent
	return object
end

---@param parent Instance
---@param text string
---@param size number
---@param color Color3
---@param font Enum.Font
---@param props table?
---@return TextLabel
local function makeLabel(parent, text, size, color, font, props)
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		TextColor3 = color,
		Font = font,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, parent)
	if props then for key, value in props do label[key] = value end end
	return label
end

local function sortedRows()
	local shown = {}
	for _, row in servers.rows do
		if servers.hideFull and row.full and not row.current then continue end
		if servers.filter ~= "all" and row.status ~= servers.filter and not row.current then continue end
		table.insert(shown, row)
	end

	table.sort(shown, function(first, second)
		if first.current ~= second.current then return first.current end
		if first.full ~= second.full then return not first.full end
		if STATUS_RANK[first.status] ~= STATUS_RANK[second.status] then return STATUS_RANK[first.status] < STATUS_RANK[second.status] end
		if first.players ~= second.players then return first.players > second.players end
		return tostring(first.id) < tostring(second.id)
	end)

	return shown
end

local function renderServers()
	if not serverGui then return end

	-- Our own server is known better than any list: use the live local state for its row.
	for _, row in servers.rows do
		if row.current or row.id == game.JobId then
			row.current = true
			row.status = servers.localKey
			row.phase = servers.localText
			row.king = servers.king
		end
	end

	local counts = {}
	for _, row in servers.rows do counts[row.status] = (counts[row.status] or 0) + 1 end
	servers.counts = counts

	if servers.summary then
		local parts = {}
		for _, key in STATUS_ORDER do
			if counts[key] and (key ~= "unknown" or servers.source == "roblox") then table.insert(parts, string.format("%s %d", STATUS[key].label, counts[key])) end
		end
		pcall(function() servers.summary:SetText(#parts > 0 and table.concat(parts, "   ·   ") or "No servers loaded yet.") end)
	end

	local mine = STATUS[servers.localKey]
	serverThis.Text = string.format("THIS SERVER   %s   ·   %s%s", string.upper(mine.label), servers.localText, servers.localKing ~= "" and ("   ·   " .. servers.localKing) or "")
	serverThis.TextColor3 = mine.color
	serverNotice.Text = servers.notice

	for key, chip in serverChips do
		local active = key == "hideFull" and servers.hideFull or key == servers.filter
		chip.BackgroundTransparency = active and 0.1 or 0.9
		chip.TextColor3 = active and PANEL_COLORS.text or PANEL_COLORS.muted
		if key ~= "all" and key ~= "hideFull" and counts[key] then chip.Text = string.format("%s  %d", STATUS[key].label, counts[key]) end
	end

	for _, child in serverList:GetChildren() do
		if child:IsA("GuiObject") then child:Destroy() end
	end

	local shown = sortedRows()
	serverCount.Text = string.format("%d of %d servers", math.min(#shown, SERVER_ROWS_SHOWN), #servers.rows)

	for index = 1, math.min(#shown, SERVER_ROWS_SHOWN) do
		local row = shown[index]
		local status = STATUS[row.status]
		local frame = make("Frame", { Size = UDim2.new(1, -6, 0, 70), BackgroundColor3 = PANEL_COLORS.row, BackgroundTransparency = row.current and 0.86 or 0.93, BorderSizePixel = 0, LayoutOrder = index }, serverList)
		make("UICorner", { CornerRadius = UDim.new(0, 10) }, frame)
		local accent = make("Frame", { Size = UDim2.new(0, 4, 1, -16), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = status.color, BorderSizePixel = 0 }, frame)
		make("UICorner", { CornerRadius = UDim.new(0, 2) }, accent)

		makeLabel(frame, (row.current and "YOUR SERVER  ·  " or "") .. row.region, 13, PANEL_COLORS.text, Enum.Font.GothamBold, { Position = UDim2.fromOffset(24, 8), Size = UDim2.new(1, -260, 0, 18) })
		local detail = (row.phase ~= "" and row.phase ~= status.label) and (status.label .. "  ·  " .. row.phase) or status.label
		makeLabel(frame, detail, 12, status.color, Enum.Font.GothamMedium, { Position = UDim2.fromOffset(24, 28), Size = UDim2.new(1, -260, 0, 16) })

		-- Fallen King progress: the game's cauldron percentage (can pass 100%) with a bar.
		local kingLine, kingFill = "Fallen King: not shared by the list", 0
		if row.king and row.king.progress then
			kingLine = servers.kingText(row.king)
			kingFill = math.clamp(row.king.progress, 0, 1)
		elseif row.king and row.king.state then
			kingLine = "Fallen King  ·  " .. tostring(row.king.state)
		end
		makeLabel(frame, kingLine, 11, PANEL_COLORS.muted, Enum.Font.GothamMedium, { Position = UDim2.fromOffset(24, 46), Size = UDim2.new(1, -260, 0, 14) })
		local barBack = make("Frame", { Position = UDim2.new(1, -230, 0, 51), Size = UDim2.fromOffset(120, 6), BackgroundColor3 = PANEL_COLORS.row, BackgroundTransparency = 0.88, BorderSizePixel = 0 }, frame)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, barBack)
		local barFill = make("Frame", { Size = UDim2.fromScale(kingFill, 1), BackgroundColor3 = kingFill >= 1 and Color3.fromRGB(240, 96, 112) or PANEL_COLORS.accent2, BorderSizePixel = 0 }, barBack)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, barFill)
		makeLabel(frame, string.format("%d / %d players", row.players, row.capacity), 12, PANEL_COLORS.text, Enum.Font.GothamMedium, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -96, 0, 8), Size = UDim2.fromOffset(130, 18), TextXAlignment = Enum.TextXAlignment.Right })
		makeLabel(frame, row.ping and string.format("%d ms", row.ping) or "ping n/a", 11, PANEL_COLORS.muted, Enum.Font.GothamMedium, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -96, 0, 28), Size = UDim2.fromOffset(130, 16), TextXAlignment = Enum.TextXAlignment.Right })

		local blocked = row.current or row.full
		local join = make("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(70, 30),
			BackgroundColor3 = PANEL_COLORS.accent,
			BackgroundTransparency = blocked and 0.7 or 0.05,
			AutoButtonColor = false,
			Text = row.current and "HERE" or (row.full and "FULL" or "JOIN"),
			TextSize = 12,
			Font = Enum.Font.GothamBold,
			TextColor3 = PANEL_COLORS.text,
			BorderSizePixel = 0,
		}, frame)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, join)
		join.Activated:Connect(function() joinServer(row) end)
	end

	if #shown == 0 then
		local empty = makeLabel(serverList, #servers.rows == 0 and "No servers loaded yet." or "No server matches this filter.", 13, PANEL_COLORS.muted, Enum.Font.GothamMedium, { Size = UDim2.new(1, 0, 0, 40), TextXAlignment = Enum.TextXAlignment.Center })
		empty.LayoutOrder = 1
	end
end

local function createServerGui()
	if serverGui or not guiParent then return end

	serverGui = make("ScreenGui", { Name = "HussValleyServers", ResetOnSpawn = false, DisplayOrder = 1001, IgnoreGuiInset = true, Enabled = false }, nil)
	serverRoot = make("Frame", { Name = "Root", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT), BackgroundColor3 = PANEL_COLORS.bg, BackgroundTransparency = 0, BorderSizePixel = 0, Active = true }, serverGui)
	make("UICorner", { CornerRadius = UDim.new(0, 18) }, serverRoot)
	make("UIStroke", { Color = PANEL_COLORS.stroke, Transparency = 0.88 }, serverRoot)

	local header = make("Frame", { Size = UDim2.new(1, 0, 0, 56), BackgroundTransparency = 1, Active = true }, serverRoot)
	makeLabel(header, "Servers", 30, PANEL_COLORS.text, Enum.Font.Garamond, { Position = UDim2.fromOffset(20, 8), Size = UDim2.fromOffset(160, 36) })
	serverCount = makeLabel(header, "", 12, PANEL_COLORS.muted, Enum.Font.GothamMedium, { Position = UDim2.fromOffset(150, 20), Size = UDim2.fromOffset(180, 18) })

	local function headerButton(text, width, offset, callback)
		local button = make("TextButton", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, offset, 0, 13), Size = UDim2.fromOffset(width, 30), BackgroundColor3 = PANEL_COLORS.accent, BackgroundTransparency = 0.08, AutoButtonColor = false, Text = text, TextSize = 12, Font = Enum.Font.GothamBold, TextColor3 = PANEL_COLORS.text, BorderSizePixel = 0 }, header)
		make("UICorner", { CornerRadius = UDim.new(0, 9) }, button)
		button.Activated:Connect(callback)
		return button
	end
	headerButton("X", 30, -14, function() serverGui.Enabled = false end)
	headerButton("REFRESH", 86, -52, refreshServers)

	serverThis = makeLabel(serverRoot, "", 13, PANEL_COLORS.text, Enum.Font.GothamBold, { Position = UDim2.fromOffset(20, 58), Size = UDim2.new(1, -40, 0, 20) })

	local chips = make("Frame", { Position = UDim2.fromOffset(20, 84), Size = UDim2.new(1, -40, 0, 28), BackgroundTransparency = 1 }, serverRoot)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, chips)
	local function chip(key, text, width, order)
		local button = make("TextButton", { Size = UDim2.fromOffset(width, 28), BackgroundColor3 = PANEL_COLORS.accent, BackgroundTransparency = 0.9, AutoButtonColor = false, Text = text, TextSize = 11, Font = Enum.Font.GothamBold, TextColor3 = PANEL_COLORS.muted, BorderSizePixel = 0, LayoutOrder = order }, chips)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, button)
		button.Activated:Connect(function()
			if key == "hideFull" then
				servers.hideFull = not servers.hideFull
			else
				servers.filter = key
			end
			servers.dirty = true
		end)
		serverChips[key] = button
	end
	chip("all", "All", 46, 1)
	chip("boss", "Boss fight", 92, 2)
	chip("game", "In game", 84, 3)
	chip("intermission", "Intermission", 104, 4)
	chip("lobby", "Lobby", 68, 5)
	chip("hideFull", "Hide full", 76, 6)

	serverList = make("ScrollingFrame", { Position = UDim2.fromOffset(20, 120), Size = UDim2.new(1, -40, 1, -184), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = PANEL_COLORS.accent2, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y }, serverRoot)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, serverList)

	serverNotice = makeLabel(serverRoot, "", 11, PANEL_COLORS.muted, Enum.Font.GothamMedium, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 20, 1, -10), Size = UDim2.new(1, -40, 0, 48), TextWrapped = true, TextTruncate = Enum.TextTruncate.None, TextYAlignment = Enum.TextYAlignment.Bottom })

	-- Drag the panel by its header.
	local dragging, dragStart, startPosition = false, nil, nil
	table.insert(connections, header.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end

		dragging, dragStart, startPosition = true, input.Position, serverRoot.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then dragging = false end
		end)
	end))
	table.insert(connections, userInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end

		local delta = input.Position - dragStart
		serverRoot.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
	end))

	serverGui.Parent = guiParent
end

local function toggleServerBrowser()
	createServerGui()
	if not serverGui then return end

	serverGui.Enabled = not serverGui.Enabled
	if serverGui.Enabled then
		servers.dirty = true
		refreshServers()
	end
end

-- Called every frame from the main loop (identity 8): keeps the status current, auto-refreshes while open, redraws on change.
local function serversTick()
	updateLocalStatus()

	if serverGui and serverGui.Enabled then
		local entry = ui and ui.Flags.serverAuto
		if (entry == nil or entry.Value == true) and os.clock() - servers.lastAuto >= SERVER_AUTO_GAP then
			servers.lastAuto = os.clock()
			refreshServers()
		end
	end

	if servers.dirty and serverGui then
		servers.dirty = false
		renderServers()
	end
end

-- Brings the HUD and the Settings keybind list up to date with the flags. Cheap enough to poll, which also catches
-- changes made by config loads, the fair-play auto-off and snap-back protection without any extra hooks.
local function refreshHud()
	if os.clock() - hudStamp < 0.25 then return end
	hudStamp = os.clock()

	pcall(function()
		if not ui then return end

		if not hudGui then createHud() end
		if hudGui then hudGui.Enabled = flag("hud") end
		if hudLabel and hudGui and hudGui.Enabled then
			local text = registryText(true)
			if text ~= hudText then hudText, hudLabel.Text = text, text end
		end

		if keybindLabel then
			local plain = registryText(false)
			if plain ~= keybindText then keybindText = plain keybindLabel:SetText(plain) end
		end
	end)
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

	refreshHud()
	serversTick()

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

	local context = { character = character, humanoid = humanoid, root = root }
	if runnerActive() then
		react(context)
	elseif catcherActive() then
		assistCatcher(context)
		autoTackle(context)
	end
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

-- Local V18UI.lua first, the public copy as fallback.
---@return table
local function loadLibrary()
	local success, library = pcall(function()
		local chunk = loadstring(readfile(UI_FILE))
		return chunk and chunk()
	end)
	if success and type(library) == "table" and library.CreateWindow then return library end

	local response = request({ Url = UI_URL, Method = "GET" })
	local chunk = loadstring(response.Body)
	assert(chunk, "V18UI failed to compile")
	return chunk()
end

local CONFIG_FOLDER = "HussValley/configs"
local AUTOLOAD_FILE = "HussValley/autoload.txt"

local function notify(title, text)
	if uiWindow then uiWindow:Notify({ Title = title, Text = text, Duration = 4 }) end
end

-- Applies a config the Settings tab saved (HussValley/configs/<name>.json); used by "load on start".
---@param name string
---@param quiet boolean?
local function loadConfig(name, quiet)
	local path = CONFIG_FOLDER .. "/" .. name .. ".json"
	local success, data = pcall(function()
		if not isfile(path) then return nil end

		return game:GetService("HttpService"):JSONDecode(readfile(path))
	end)

	if not success or type(data) ~= "table" then
		if not quiet then notify("No config", name .. " has nothing saved yet") end
		return
	end

	local applied = 0
	for flagName, value in data do
		local entry = ui.Flags[flagName]
		if entry and string.sub(flagName, 1, 4) ~= "cfg_" and pcall(entry.Set, value) then applied += 1 end
	end

	if not quiet then notify("Config loaded", string.format("%s (%d settings)", name, applied)) end
end

---@param role string?
---@return string, number, string
local function roleCard()
	local role = localPlayer:GetAttribute("GameRole")
	local runState = localPlayer:GetAttribute("RunState")
	local alpha = (role == "Runner" or role == "Catcher") and runState == "Active" and 1 or 0.12
	return tostring(role or "?"), alpha, tostring(runState or "")
end

local function buildUi()
	ui = loadLibrary()
	local window = ui:CreateWindow({
		Title = "Huss Valley",
		Subtitle = "Dodge  /  Movement  /  Servers",
		ToggleKey = Enum.KeyCode.RightShift,
		-- Pressing "Unload Script" in Settings unloads the whole script, not just the window.
		OnDestroy = function()
			if not detaching then HussValley.detach() end
		end,
	})
	uiWindow = window

	-- A hub overlay should not blur the game while you play; Settings can turn it back on.
	ui.Flags.ui_blur.Set(false)

	-- Overview ----------------------------------------------------------------------------------------------------
	local overview = window:CreateTab("Overview", "layout-dashboard", "Your hub at a glance")
	overview:AddStatRow({
		{ Title = "Role", Get = roleCard },
		{ Title = "Auto Dodge", Get = function()
			local on = flag("autoDodge") or flag("immortal")
			return on and (flag("immortal") and "IMMORTAL" or "ON") or "OFF", on and 1 or 0.04, flag("proximity") and "proximity on" or ""
		end },
		{ Title = "This server", Get = function()
			local status = STATUS[servers.localKey]
			return status.label, servers.localKey == "unknown" and 0.04 or 1, servers.localText
		end },
	})
	overview:AddSection("Keybinds")
	overview:AddLabel("Every toggle has a key chip on its row: click it, press a key. Esc or Backspace clears it. The keybind list (Insert) shows what is on, even with the menu closed.")
	overview:AddSection("Panic")
	overview:AddButton({ Text = "Turn every feature off", Callback = function()
		for name, entry in ui.Flags do
			if entry.Type == "Toggle" and string.sub(name, 1, 3) ~= "ui_" and entry.Value then entry.Set(false) end
		end
		window:Notify({ Title = "Panic", Text = "All features disabled" })
	end })

	-- Survival ----------------------------------------------------------------------------------------------------
	window:CreateCategory("Survival")
	local combat = window:CreateTab("Combat", "swords", "Auto dodge and immortal")
	combat:AddSection("Auto Dodge")
	combat:AddToggle({ Text = "Auto Dodge", Default = false, Flag = "autoDodge" })
	combat:AddKeybind({ Text = "Auto Dodge on/off key", Default = Enum.KeyCode.G, Flag = "autoDodgeKey", Pressed = function()
		local entry = ui.Flags.autoDodge
		if entry then entry.Set(not entry.Value) end
	end })
	combat:AddToggle({ Text = "React to tracking catchers (dodge before the swing starts)", Default = false, Flag = "early" })
	combat:AddSlider({ Text = "Danger margin (studs)", Min = 0, Max = 4, Default = 0, Increment = 0.5, Flag = "margin" })
	combat:AddSection("Auto Dodge: extras")
	combat:AddToggle({ Text = "Auto Ability (Q): runners when the dash is spent, catchers when a runner is close", Default = false, Flag = "autoAbility" })
	combat:AddToggle({ Text = "Proximity dodge (dash away from any catcher that gets close)", Default = false, Flag = "proximity" })
	combat:AddSlider({ Text = "Proximity range (studs)", Min = 4, Max = 14, Default = 8, Increment = 1, Flag = "proximityRange" })
	combat:AddSection("Immortal")
	combat:AddToggle({ Text = "Immortal (best effort): dodge every attack it can see, from any side", Default = false, Flag = "immortal", Callback = function(on) movement.immortal = on end })
	combat:AddLabel("Immortal dashes out of every attack near you, even two at once. Catches are decided by the server, so this cannot be true god mode, and a very high ping can still be too slow. Each part below is its own switch, so you can use Immortal with any mix of them.")
	combat:AddSection("Immortal: dash tweaks")
	combat:AddToggle({ Text = "Immortal: no dash cooldown", Default = true, Flag = "immortalNoCooldown", NoList = true, Callback = function(on) movement.immortalNoCooldown = on end })
	combat:AddToggle({ Text = "Immortal: skip dash recovery (no wait after a dash)", Default = true, Flag = "immortalSkipRecovery", NoList = true, Callback = function(on) movement.immortalSkipRecovery = on end })
	combat:AddToggle({ Text = "Immortal: full-length dash, even from a standstill", Default = true, Flag = "immortalFullDash", NoList = true, Callback = function(on) movement.immortalFullDash = on end })
	combat:AddToggle({ Text = "Immortal: fastest dash the server accepts (about 0.04 s)", Default = true, Flag = "immortalFastDash", NoList = true, Callback = function(on) movement.immortalFastDash = on end })
	combat:AddToggle({ Text = "Immortal: dash in any direction, even straight ahead", Default = true, Flag = "immortalFreeDash", NoList = true, Callback = function(on) movement.immortalFreeDash = on end })
	combat:AddSection("Immortal: behavior")
	combat:AddToggle({ Text = "Immortal: also use abilities (Q)", Default = true, Flag = "immortalAbility", NoList = true, Callback = function(on) movement.immortalAbility = on end })
	combat:AddToggle({ Text = "Immortal: lead running catchers (predict where the swing starts)", Default = true, Flag = "immortalPredict", NoList = true, Callback = function(on) movement.immortalPredict = on end })
	combat:AddToggle({ Text = "Immortal: wider danger zone for fast catchers", Default = true, Flag = "immortalSpeedMargin", NoList = true, Callback = function(on) movement.immortalSpeedMargin = on end })
	combat:AddToggle({ Text = "Immortal: prefer landing spots far from every catcher", Default = true, Flag = "immortalBias", NoList = true, Callback = function(on) movement.immortalBias = on end })

	-- Player ------------------------------------------------------------------------------------------------------
	window:CreateCategory("Player")
	local move = window:CreateTab("Movement", "wind", "Dash, speed and acceleration")
	move:AddSection("Dash cooldown")
	move:AddToggle({ Text = "No dash cooldown", Default = false, Flag = "noCooldown", Callback = function(on) movement.noCooldown = on end })
	move:AddSlider({ Text = "Cooldown cap (s, 0 = none)", Min = 0, Max = 0.7, Default = 0, Increment = 0.05, Flag = "cooldownGap", Callback = function(value) movement.cooldownGap = value end })
	move:AddToggle({ Text = "Skip dash recovery", Default = true, Flag = "skipRecovery", NoList = true, Callback = function(on) movement.skipRecovery = on end })
	move:AddSection("Dash distance")
	move:AddToggle({ Text = "Longer dash", Default = false, Flag = "longDash", Callback = function(on) movement.longDash = on end })
	move:AddSlider({ Text = "Distance multiplier", Min = 1.1, Max = 3, Default = 1.5, Increment = 0.1, Flag = "dashScale", Callback = function(value) movement.dashScale = value end })
	move:AddSection("Dash anytime")
	move:AddToggle({ Text = "No stun: dash during another dash", Default = false, Flag = "dashAnytime", Callback = function(on) movement.dashAnytime = on end })
	move:AddLabel("A new dash cancels the one still playing (and its recovery and cooldown), for runners and for catchers with a dash. Chain dashes as fast as you press the key.")
	move:AddSection("Dash direction")
	move:AddToggle({ Text = "Free-direction dash (no turning, dash forward too)", Default = false, Flag = "freeDash", Callback = function(on) movement.freeDash = on end })
	move:AddDropdown({ Text = "Dash toward", Options = { "Movement keys", "Camera", "Character facing" }, Default = "Movement keys", Flag = "dashDirection", Callback = function(value) movement.dashDirection = value end })
	move:AddLabel("Use your normal dash key. The dash goes the way you point it, even straight ahead while running that way, or from a standstill. Movement keys = the keys you hold (camera forward if none); Camera and Character facing ignore the keys.")
	move:AddToggle({ Text = "Full-distance dash from a standstill", Default = false, Flag = "fullDash", Callback = function(on) movement.fullDash = on end })
	move:AddSection("Instant dash")
	move:AddToggle({ Text = "Faster / instant dash", Default = false, Flag = "fastDash", Callback = function(on) movement.fastDash = on end })
	move:AddSlider({ Text = "Dash time (% of normal)", Min = 15, Max = 100, Default = 50, Increment = 5, Flag = "dashTime", Callback = function(value) movement.dashTime = value end })
	move:AddLabel("15% is the fastest the server accepted in testing. Truly instant (0%) gets you snapped back, so the slider stops at 15%; if a snap-back still happens the dash time is raised for you.")
	move:AddToggle({ Text = "Skip dash animation", Default = false, Flag = "skipAnimation", Callback = function(on) movement.skipAnimation = on end })
	move:AddSection("Speed")
	move:AddToggle({ Text = "Instant acceleration", Default = false, Flag = "instantAccel", Callback = function(on) movement.instantAccel = on end })
	move:AddToggle({ Text = "Speed tuning", Default = false, Flag = "speed", Callback = function(on) movement.speed = on end })
	move:AddSlider({ Text = "Speed boost (%)", Min = 0, Max = 25, Default = 5, Increment = 1, Flag = "speedBoost", Callback = function(value) movement.speedBoost = value end })
	move:AddSection("Safety")
	move:AddToggle({ Text = "Auto-off on a fair-play warning", Default = true, Flag = "guardStop", NoList = true })
	move:AddLabel("The server watches movement. Short tests of no cooldown, a 1.5x dash and +10% speed drew no warning, but the further you push past the game's own numbers the more likely one gets. If it warns you, these switch themselves off.")

	local catch = window:CreateTab("Catcher", "target", "Tackle, dash and reach")
	catch:AddSection("Tackle")
	catch:AddToggle({ Text = "Auto Tackle (dives at the closest runner in range)", Default = false, Flag = "autoTackle", Callback = function(on) tackle.auto = on end })
	catch:AddSlider({ Text = "Tackle range (studs)", Min = 3, Max = 9, Default = 5.5, Increment = 0.5, Flag = "tackleRange", Callback = function(value) tackle.range = value end })
	catch:AddDropdown({ Text = "Tackle aim", Options = { "Nearest runner", "Movement keys", "Camera", "Character facing" }, Default = "Nearest runner", Flag = "tackleAim", Callback = function(value) tackle.aim = value end })
	catch:AddToggle({ Text = "Tackle on a key (the catcher's dash)", Default = false, Flag = "catcherDash", Callback = function(on) tackle.key = on end })
	catch:AddKeybind({ Text = "Tackle key", Default = Enum.KeyCode.LeftControl, Flag = "catcherDashKey", Pressed = function() requestCatcherDash() end })
	catch:AddToggle({ Text = "Catcher: also get the runner dash (both dashes)", Default = true, Flag = "catcherRunnerDash", Callback = function(on) movement.catcherDash = on end })
	catch:AddKeybind({ Text = "Runner dash key", Default = Enum.KeyCode.LeftShift, Flag = "catcherRunnerDashKey", Pressed = function() requestCatcherRunnerDash() end })
	catch:AddLabel("Catchers normally only have the tackle. This also gives them the runner dash on its own key, so you can tackle with one key and dash with the other. Every dash tweak in the Movement tab (no cooldown, longer, faster, free direction, dash anytime, instant acceleration) applies to it. Hold a direction and press the key; without free-direction dash the game wants a turn of at least 35 degrees away from where you are running.")
	catch:AddToggle({ Text = "No tackle cooldown", Default = false, Flag = "tackleNoCooldown", Callback = function(on) tackle.noCooldown = on end })
	catch:AddLabel("A catcher's own dash is the tackle, so these are the catcher versions of the runner dash tweaks. The key and Auto Tackle turn you toward the chosen aim first, then dive; the game's own readiness checks still apply. The server keeps its own tackle timer, so No tackle cooldown may be refused or snap you back, and the hub then switches it off by itself.")
	catch:AddSection("Catcher boosts")
	catch:AddToggle({ Text = "Full-length tackle from a standstill (tackle as far as a full sprint)", Default = false, Flag = "catcherFullTackle", Callback = function(on) tackle.fullFromStandstill = on syncReach() end })
	catch:AddToggle({ Text = "No cooldown: runner dash + tackle (catcher only)", Default = false, Flag = "catcherNoCooldown", Callback = function(on) movement.catcherNoCooldown = on end })
	catch:AddToggle({ Text = "Catcher speed boost (top speed, catcher only)", Default = false, Flag = "catcherSpeed", Callback = function(on) movement.catcherSpeed = on end })
	catch:AddSlider({ Text = "Catcher speed boost (%)", Min = 1, Max = 25, Default = 5, Increment = 1, Flag = "catcherSpeedBoost", Callback = function(value) movement.catcherSpeedBoost = value end })
	catch:AddLabel("The game picks how far a tackle goes from the speed you enter it at, so a tackle from a standstill is the short one. Full-length reports your top speed with the tackle instead. No cooldown removes the wait on both the runner dash and the tackle while you are a catcher; the server keeps its own timers and may refuse or snap you back. Speed raises your catcher top speed by a percent. None of these are confirmed against the server yet, and all switch themselves off on a snap-back or a fair-play warning.")
	catch:AddSection("Hitbox")
	catch:AddToggle({ Text = "Reach assist (hitbox expander, experimental)", Default = false, Flag = "reachAssist", Callback = function(on) tackle.reachAssist = on syncReach() end })
	catch:AddSlider({ Text = "Extra reach (studs)", Min = 0.5, Max = 2, Default = 1.5, Increment = 0.5, Flag = "tackleReach", Callback = function(value) tackle.reach = value syncReach() end })
	catch:AddLabel("Catches are decided by the server, so a hitbox cannot be resized from here. This instead starts each tackle a little further forward than you are (the server tolerates about 2.5 studs of position error), which lengthens your effective reach by that much. Untested against the server's hit rules; it switches itself off on a snap-back or a fair-play warning.")

	-- Servers -----------------------------------------------------------------------------------------------------
	window:CreateCategory("Servers")
	local serverTab = window:CreateTab("Servers", "gauge", "What every server is doing")
	serverTab:AddStatRow({
		{ Title = "This server", Get = function()
			local status = STATUS[servers.localKey]
			return status.label, servers.localKey == "unknown" and 0.04 or 1, servers.localText
		end },
		{ Title = "Servers found", Get = function()
			local total = #servers.rows
			return tostring(total), math.clamp(total / 30, 0, 1), servers.source == "game" and "with status" or (servers.source == "roblox" and "no status" or "press refresh")
		end },
		{ Title = "Fallen King", Get = function()
			local king = servers.king
			if not (king and king.progress) then return "-", 0.04, "this server" end
			return string.format("%d%%", math.floor(king.progress * 100 + 0.5)), math.clamp(king.progress, 0, 1), tostring(king.state or "")
		end },
		{ Title = "Boss fights", Get = function()
			local bosses = servers.counts and servers.counts.boss or 0
			return tostring(bosses), math.clamp(bosses / 5, 0, 1), servers.source == "roblox" and "needs lobby" or ""
		end },
	})
	serverTab:AddSection("Server browser")
	serverTab:AddButton({ Text = "Open server browser", Callback = toggleServerBrowser })
	serverTab:AddKeybind({ Text = "Open / close key", Default = Enum.KeyCode.K, Flag = "serverKey", Pressed = toggleServerBrowser })
	serverTab:AddToggle({ Text = "Auto refresh every 15 s while open", Default = true, Flag = "serverAuto", NoList = true })
	serverTab:AddSection("Right now")
	servers.summary = serverTab:AddLabel("No servers loaded yet. Open the browser to load them.")
	serverTab:AddLabel("Each row shows the region, how many players, ping and what the server is doing: Boss fight, In game, Intermission or Lobby. Join switches you to that server. Your own server is always marked and uses live data.")
	serverTab:AddButton({ Text = "Copy this server's JobId", Callback = function()
		setclipboard(game.JobId)
		window:Notify({ Title = "Copied", Text = game.JobId })
	end })

	-- Visuals -----------------------------------------------------------------------------------------------------
	window:CreateCategory("Visuals")
	local visuals = window:CreateTab("Visuals", "eye", "See threats through walls")
	visuals:AddSection("ESP")
	visuals:AddToggle({ Text = "Threat ESP", Default = false, Flag = "esp" })

	-- Misc --------------------------------------------------------------------------------------------------------
	window:CreateCategory("Misc")
	local misc = window:CreateTab("Misc", "sliders-horizontal", "Utilities")
	misc:AddSection("Session")
	misc:AddToggle({ Text = "Anti-AFK", Default = true, Flag = "antiAfk", NoList = true })
	-- The V18UI keybind list (Insert) replaces the old panel; keep the old one available but off by default.
	misc:AddToggle({ Text = "Old keybind HUD (draggable panel)", Default = false, Flag = "hud", NoList = true })
	misc:AddKeybind({ Text = "Old HUD show/hide key", Default = Enum.KeyCode.J, Flag = "hudKey", Pressed = function()
		local entry = ui.Flags.hud
		if entry then entry.Set(not entry.Value) end
	end })

	-- Saving and loading configs is built into V18UI's Settings tab (HussValley/configs/<name>.json).
	local settingsTab = window.Settings or misc
	settingsTab:AddSection("Start-up")
	settingsTab:AddToggle({
		Text = "Load the selected config when the script starts",
		Default = false,
		Flag = "cfg_autoload",
		NoList = true,
		Bind = false,
		Callback = function(on)
			pcall(function()
				if not isfolder("HussValley") then makefolder("HussValley") end
				local pick = ui.Flags.cfg_pick and ui.Flags.cfg_pick.Value
				if on and pick and pick ~= "(none)" then
					writefile(AUTOLOAD_FILE, pick)
				elseif isfile(AUTOLOAD_FILE) then
					delfile(AUTOLOAD_FILE)
				end
			end)
		end,
	})

	-- Live widgets beside the window.
	window:AddWidget({ Title = "Server", Icon = "gauge", Kind = "stat", Get = function()
		local status = STATUS[servers.localKey]
		return status.label, servers.localKey == "unknown" and 0.04 or 1, servers.localText
	end })

	createServerGui()
	window:Notify({ Title = "Huss Valley", Text = "Loaded. RightShift toggles the menu, K opens the server browser.", Duration = 5 })
end

function HussValley.init()
	if game.PlaceId ~= PLACE_ID then
		warn("[HV] wrong place, expected Huss Valley")
		return
	end

	local movementFolder = replicatedStorage:WaitForChild("ChickenOrHero"):WaitForChild("Movement")
	boostInput = loadModule(movementFolder:WaitForChild("BoostInput"))
	tacklePrediction = loadModule(replicatedStorage.ChickenOrHero:WaitForChild("Game"):WaitForChild("TacklePrediction"))
	if tacklePrediction and type(tacklePrediction.request) ~= "function" then tacklePrediction = nil end
	setthreadidentity(8)
	if tacklePrediction and type(tacklePrediction.remaining) == "function" then
		originalRemaining = tacklePrediction.remaining
		if not swapFunction(tacklePrediction, "remaining", tackleRemaining) then originalRemaining = nil end
	end

	-- Reach assist: shift the start position sent with a tackle forward a little (the server accepts a few studs of
	-- position error). One hook per session, kept in getgenv so a re-execute never stacks a second one; it does nothing
	-- while the reach is 0.
	local gameAction = replicatedStorage.ChickenOrHero:WaitForChild("Game"):WaitForChild("GameAction")
	tackleHook = getgenv().HussValleyTackleHook2
	if not tackleHook then
		tackleHook = { remote = gameAction, reach = 0, fullSpeed = false, topSpeed = nil }
		getgenv().HussValleyTackleHook2 = tackleHook
		local hookData = tackleHook
		local originalNamecall
		originalNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			local method = getnamecallmethod()
			if (hookData.reach > 0 or hookData.fullSpeed) and self == hookData.remote and method == "FireServer" then
				local kind, payload = ...
				if kind == "Tackle" and type(payload) == "table" and typeof(payload.position) == "Vector3" and typeof(payload.direction) == "Vector3" then
					local shifted = table.clone(payload)
					if hookData.reach > 0 then shifted.position = payload.position + payload.direction * hookData.reach end
					-- Full-length tackle: the game picks the tackle's reach and distance from the speed you enter it
					-- at (0 = shortest). Report the catcher's top speed instead of the real one.
					-- Only plain reads here: anything that makes its own method calls would clobber the namecall method.
					if hookData.fullSpeed and type(payload.speed) == "number" and type(hookData.top) == "number" and hookData.top > payload.speed then
						shifted.speed = hookData.top
					end
					setnamecallmethod(method)
					return originalNamecall(self, kind, shifted)
				end
			end

			return originalNamecall(self, ...)
		end))
	end
	tackleHook.remote = gameAction
	syncReach()
	participantDirectory = loadModule(replicatedStorage.ChickenOrHero:WaitForChild("Presentation"):WaitForChild("ParticipantDirectory"))

	guiParent = resolveGuiParent()

	-- The game answers server-list requests on this remote (only for players in the lobby); keep the latest reply.
	local browserRemote = replicatedStorage.ChickenOrHero:WaitForChild("Presentation"):FindFirstChild("ServerBrowserEvent")
	if browserRemote then
		servers.remote = browserRemote
		table.insert(connections, browserRemote.OnClientEvent:Connect(function(kind, data)
			if kind ~= "List" or type(data) ~= "table" or type(data.rows) ~= "table" then return end

			-- Plain table writes only: this callback runs at a low thread identity.
			local rows = {}
			for _, raw in data.rows do
				if type(raw) == "table" and (raw.current or (raw.updatedAt and os.time() - raw.updatedAt <= 60)) then table.insert(rows, gameRow(raw)) end
			end
			servers.gameRows, servers.gameAt = rows, os.clock()
		end))
	end
	buildUi()
	setupAntiAfk()
	installMovement()

	-- The server's fair-play system announces a warning on this remote; flag it for the main loop to act on.
	-- Plain table writes only: this callback starts at a low thread identity and must not touch the UI.
	local guardEvent = replicatedStorage.ChickenOrHero:WaitForChild("Presentation"):WaitForChild("MovementGuardEvent")
	table.insert(connections, guardEvent.OnClientEvent:Connect(function(kind)
		if kind ~= "Warning" or not flag("guardStop") then return end

		movement.noCooldown, movement.longDash, movement.fastDash, movement.speed = false, false, false, false
		movement.fullDash = false
		movement.immortalNoCooldown, movement.immortalSkipRecovery, movement.immortalFullDash = false, false, false
		movement.immortalFastDash, movement.immortalFreeDash = false, false
		movement.instantAccel, movement.catcherDash, movement.freeDash = false, false, false
		tackle.noCooldown, tackle.reachAssist, tackle.fullFromStandstill = false, false, false
		movement.catcherNoCooldown, movement.catcherSpeed = false, false
		syncReach()
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

	table.insert(connections, localPlayer:GetAttributeChangedSignal("GameRole"):Connect(function()
		lastRunStateAt = os.clock()
	end))

	-- Auto-load: restore the slot the player chose to start with.
	task.spawn(function()
		local success, slot = pcall(function()
			if isfile(AUTOLOAD_FILE) then return readfile(AUTOLOAD_FILE) end
		end)
		if not (success and type(slot) == "string" and slot ~= "" and ui and ui.Flags.cfg_pick) then return end

		setthreadidentity(8)
		pcall(ui.Flags.cfg_pick.Set, slot)
		loadConfig(slot, true)
		pcall(ui.Flags.cfg_autoload.Set, true)
	end)

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

	if hudGui then pcall(function() hudGui:Destroy() end) end
	if serverGui then pcall(function() serverGui:Destroy() end) end
	hudGui, hudLabel, keybindLabel = nil, nil, nil
	if ui then pcall(function() ui:Destroy() end) end
	if shared.HussValley == HussValley then shared.HussValley = nil end
end

-- Tunables (reaction boxes, lockouts, debug logging) stay reachable at runtime: shared.HussValley.config.debug = true
HussValley.config = CONFIG
HussValley.movement = movement
HussValley.tackle = tackle

shared.HussValley = HussValley
xpcall(HussValley.init, onError)

return HussValley
