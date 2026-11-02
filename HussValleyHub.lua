-- Huss Valley hub: Auto Dodge, Auto Ability, Immortal (best effort), Movement (no dash cooldown, longer dash, speed),
-- Threat ESP, Anti-AFK.
-- Auto Dodge / Immortal watch every attack within ~45 studs (all sides, any number at once), choose a landing spot that is
-- outside all of their danger zones, and dash there through the game's own BoostInput.
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
	-- Catchers have no runner dash; their own dash is the tackle. With this on, catcherDashKey fires that tackle.
	catcherDash = false,
	-- Dash wherever you point it without turning away from your current direction first (the game normally refuses a dash
	-- unless it is at least 35 degrees away from where you were just travelling), including straight ahead.
	freeDash = false,
	-- Which way a free dash goes: the keys you are holding, the camera, or the way the character faces.
	dashDirection = "Movement keys",
	speed = false,
	-- Percent added on top of the live top speed, which itself moves with the round's balance buffs (about 37-42).
	speedBoost = 5,
	-- Immortal preset. While it is on (and immortalTweaks is allowed) the dash has no cooldown and runs at
	-- immortalDashTime percent of its normal duration, whatever the individual switches above say.
	immortal = false,
	immortalTweaks = true,
	immortalDashTime = 15,
	-- Immortal also spends the Q ability; turn this off to make it dash only.
	immortalAbility = true,
}

-- What the movement wrapper applies right now: the user's own switches combined with the Immortal preset's.
local tuning = {
	noCooldown = false,
	gap = 0,
	skipRecovery = true,
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

local function refreshTuning()
	local forced = movement.immortal and movement.immortalTweaks
	tuning.noCooldown = movement.noCooldown or forced
	tuning.gap = forced and 0 or movement.cooldownGap
	tuning.skipRecovery = movement.skipRecovery or forced
	tuning.longDash = movement.longDash
	tuning.scale = movement.dashScale
	tuning.fastDash = movement.fastDash or forced
	if forced then
		tuning.dashTime = movement.fastDash and math.min(movement.dashTime, movement.immortalDashTime) or movement.immortalDashTime
	else
		tuning.dashTime = movement.dashTime
	end
	tuning.fullDash = movement.fullDash or forced
	tuning.instantAccel = movement.instantAccel
	tuning.catcherDash = movement.catcherDash
	tuning.freeDash = movement.freeDash or forced
	tuning.speed = movement.speed
	tuning.boost = movement.speedBoost
end
local movementProfiles = nil
local originalGet = nil
local dashAnimation = nil
local originalPlay = nil
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
local function tuneProfile(profile)
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
	local dashAvailable = type(dash) == "table" and dash.Enabled
	if dashAvailable then
		local tuned = table.clone(dash)
		if tuning.noCooldown then
			tuned.Cooldown = math.min(dash.Cooldown, tuning.gap)
			if tuning.skipRecovery then tuned.RecoveryDuration = 0 end
		end
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
	if not (tuning.noCooldown or tuning.longDash or tuning.fastDash or tuning.fullDash or tuning.instantAccel or tuning.catcherDash or tuning.speed) then return profile end

	local success, result = pcall(function()
		local signature = string.format("%s|%.2f|%s|%s|%.2f|%s|%.0f|%s|%s|%s|%s|%.1f", tostring(tuning.noCooldown), tuning.gap, tostring(tuning.skipRecovery), tostring(tuning.longDash), tuning.scale, tostring(tuning.fastDash), tuning.dashTime, tostring(tuning.fullDash), tostring(tuning.instantAccel), tostring(tuning.catcherDash), tostring(tuning.speed), tuning.boost)
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

-- Which way a free dash should go.
---@param moveDirection Vector3
---@return Vector3?
local function chooseDashDirection(moveDirection)
	local keys = Vector3.new(moveDirection.X, 0, moveDirection.Z)

	-- When the hub itself is steering (Auto Dodge / Immortal) the steered direction is already in moveDirection.
	if hookState.steer ~= nil and os.clock() < hookState.expiresAt and keys.Magnitude > 0.05 then return keys.Unit end

	local camera = workspace.CurrentCamera
	local look = camera and camera.CFrame.LookVector or Vector3.new(0, 0, -1)
	local cameraForward = Vector3.new(look.X, 0, look.Z)
	cameraForward = cameraForward.Magnitude > 0.01 and cameraForward.Unit or nil

	if movement.dashDirection == "Camera" then return cameraForward end

	if movement.dashDirection == "Character facing" then
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
	if request == true and movementModel and (movement.freeDash or (movement.immortal and movement.immortalTweaks)) then
		pcall(function()
			if type(profile) ~= "table" or type(profile.Dash) ~= "table" or not profile.Dash.Enabled then return end
			if not movementModel.canBoost(model, profile, grounded ~= false) then return end

			local direction = chooseDashDirection(moveDirection)
			if not direction then return end

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

	movement.noCooldown, movement.longDash, movement.fastDash, movement.speed = false, false, false, false
	movement.skipAnimation, movement.immortal, movement.fullDash = false, false, false
	movement.instantAccel, movement.catcherDash, movement.freeDash = false, false, false
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

		-- Melee swing: Windup then Active, aimed along ReachDirection.
		local phase = character:GetAttribute("ReachPhase")
		local reachDirection = character:GetAttribute("ReachDirection")
		if (phase == "Windup" or phase == "Active") and typeof(reachDirection) == "Vector3" and flat(reachDirection).Magnitude > 0.01 then
			table.insert(threats, {
				kind = "Melee", catcher = participant.Name, origin = origin, dir = flat(reachDirection).Unit,
				limit = CONFIG.meleeForward, behind = CONFIG.meleeBehind, half = CONFIG.meleeHalfWidth + extra,
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
					limit = CONFIG.tackleForward, behind = CONFIG.tackleBehind, half = CONFIG.tackleHalfWidth + extra, slack = 0,
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

		local legal = travel == nil or direction:Dot(travel) <= CONFIG.minIntentCos
		local score = math.min(worst, 8) * 10 - (reach - travelled) * 2 - (legal and 0 or 60)
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
	local settled = tuning.noCooldown and now - lastDash >= seconds + CONFIG.dashSettle
	local ready = (character:GetAttribute("DashReady") == true or settled) and boostInput.available(localPlayer)
	setthreadidentity(8)

	return ready
end

-- The catcher's own dash is the tackle (the game's Space / E / F). This fires it from the catcher dash key, facing the
-- chosen direction first when free-direction dash is on. The game still applies its own readiness and cooldown rules.
local function requestCatcherDash()
	if not (movement.catcherDash and tacklePrediction and catcherActive()) then return end

	pcall(function()
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return end

		if movement.freeDash then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local keys = humanoid and humanoid.MoveDirection or Vector3.zero
			if hookState.steer ~= nil and os.clock() < hookState.expiresAt then keys = hookState.steer end
			local direction = chooseDashDirection(keys)
			if direction then root.CFrame = CFrame.lookAt(root.Position, root.Position + direction) end
		end

		tacklePrediction.request()
	end)
	setthreadidentity(8)
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
			if threat.kind ~= "Tracking" then committed = true end
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
	for _, name in { "noCooldown", "longDash", "fastDash", "fullDash", "instantAccel", "catcherDash", "freeDash", "speed", "immortalTweaks" } do
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

	local forced = movement.immortal and movement.immortalTweaks
	if not (movement.fastDash or forced or movement.instantAccel or movement.freeDash) then return end

	-- No dash-time knob in play: the snap-back can only come from the acceleration or catcher-dash switches, so withdraw them.
	if not (movement.fastDash or forced) then
		for _, name in { "instantAccel", "freeDash" } do
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

	local context = { character = character, humanoid = humanoid, root = root }
	if runnerActive() then
		react(context)
	elseif catcherActive() then
		assistCatcher(context)
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
	combat:AddToggle({ Text = "Auto Ability (Q): runners when the dash is spent, catchers when a runner is close", Default = false, Flag = "autoAbility" })
	combat:AddToggle({ Text = "React to tracking catchers", Default = false, Flag = "early" })
	combat:AddSlider({ Text = "Danger margin (studs)", Min = 0, Max = 4, Default = 0, Increment = 0.5, Flag = "margin" })
	combat:AddSection("Immortal")
	combat:AddToggle({ Text = "Immortal (best effort)", Default = false, Flag = "immortal", Callback = function(on) movement.immortal = on end })
	combat:AddToggle({ Text = "Immortal: no cooldown + fastest dash", Default = true, Flag = "immortalTweaks", Callback = function(on) movement.immortalTweaks = on end })
	combat:AddToggle({ Text = "Immortal: also use abilities (Q)", Default = true, Flag = "immortalAbility", Callback = function(on) movement.immortalAbility = on end })
	combat:AddLabel("Dashes out of every attack near you from any side, even two at once, with no dash cooldown and the fastest dash the server accepts (about 0.04 s). Catches are decided by the server, so this cannot be true god mode, and a very high ping can still be too slow.")

	window:CreateCategory("Movement")
	local move = window:CreateTab("Movement")
	move:AddSection("Dash cooldown")
	move:AddToggle({ Text = "No dash cooldown", Default = false, Flag = "noCooldown", Callback = function(on) movement.noCooldown = on end })
	move:AddSlider({ Text = "Cooldown cap (s, 0 = none)", Min = 0, Max = 0.7, Default = 0, Increment = 0.05, Flag = "cooldownGap", Callback = function(value) movement.cooldownGap = value end })
	move:AddToggle({ Text = "Skip dash recovery", Default = true, Flag = "skipRecovery", Callback = function(on) movement.skipRecovery = on end })
	move:AddSection("Dash distance")
	move:AddToggle({ Text = "Longer dash", Default = false, Flag = "longDash", Callback = function(on) movement.longDash = on end })
	move:AddSlider({ Text = "Distance multiplier", Min = 1.1, Max = 3, Default = 1.5, Increment = 0.1, Flag = "dashScale", Callback = function(value) movement.dashScale = value end })
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
	move:AddSection("Catcher")
	move:AddToggle({ Text = "Catcher: dash key uses the tackle", Default = false, Flag = "catcherDash", Callback = function(on) movement.catcherDash = on end })
	move:AddKeybind({ Text = "Catcher dash key", Default = Enum.KeyCode.LeftShift, Flag = "catcherDashKey", Pressed = function() requestCatcherDash() end })
	move:AddLabel("A catcher's own dash is the tackle, not the runner dash. This binds it to the key below (the game's cooldown still applies). With free-direction dash on it also turns you toward the direction you picked first. Auto Ability (Q) also fires for catchers when a runner is close.")
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
	tacklePrediction = loadModule(replicatedStorage.ChickenOrHero:WaitForChild("Game"):WaitForChild("TacklePrediction"))
	if tacklePrediction and type(tacklePrediction.request) ~= "function" then tacklePrediction = nil end
	setthreadidentity(8)
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
		movement.fullDash, movement.immortalTweaks = false, false
		movement.instantAccel, movement.catcherDash, movement.freeDash = false, false, false
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
