-- Da Hood hub on V18UI: aimbot, silent aim, bullet redirect, trigger bot, rapid fire, auto fire, hitboxes, auto stomp / reload,
-- fly (up to 10000), speed, noclip, infinite jump, ESP (boxes, skeleton, chams, arrows ...), crosshair, world tweaks, spectate.
-- Every toggle has its own keybind (chip on the row) and shows in the on-screen keybind list while enabled.
-- Verified against place 2788229376 (v3282) with the recon kit:
--   * Every gun's LocalScript asks ReplicatedStorage.Modules.GunHandler.getAim(muzzle) for the shot direction, then
--     GunHandler.shoot raycasts and the client reports the result: MainEvent:FireServer("ShootGun", Handle, muzzle, hitPos,
--     hitInstance, normal, ...). Silent aim swaps getAim; bullet redirect rewrites hitPos / hitInstance / normal.
--   * Framework rewrites Humanoid.WalkSpeed every frame, so speed is CFrame based.
--   * StarterCharacterScripts.CheckingKOED reports any BodyVelocity / BodyPosition / BodyGyro added to the root part
--     (MainEvent "CHECKER_1"), so fly moves the root part directly and never adds a body mover.
--   * Knocked-out players have Character.BodyEffects["K.O"].Value == true; Stomp is MainEvent:FireServer("Stomp").
-- UI: V18UI (V18UI.lua in the executor workspace).
-- Matcha is an external LuaVM (no Instance, no hooks, no V18UI), so it gets its own edition: DaHoodMatcha.lua in the Matcha
-- workspace. This runs before anything Potassium-specific is touched.
local executorName = identifyexecutor and select(1, identifyexecutor()) or ""
if string.find(string.lower(tostring(executorName)), "matcha", 1, true) then
	local success, source = pcall(readfile, "DaHoodMatcha.lua")
	if not (success and source) then
		success, source = pcall(httpget, "https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/DaHoodMatcha.lua")
	end
	local chunk = success and source and loadstring(source)
	if not chunk then
		return warn("[DaHood] Matcha detected, but DaHoodMatcha.lua could not be read or downloaded")
	end
	return chunk()
end

if not shared then return warn("No shared, no script.") end

-- Singleton: replace a previous instance.
if shared.DaHoodHub then
	pcall(shared.DaHoodHub.detach)
end

local DaHood = {}

-- Constants.
local PLACE_IDS = { 2788229376, 88976059384565 }
local UI_FILE = "V18UI.lua"
local UI_URL = "https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/V18UI.lua"
local TARGET_PARTS = { "Head", "UpperTorso", "HumanoidRootPart", "Closest" }
local ESP_FONT = 2

-- Services.
local playersService = game:GetService("Players")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")
local replicatedStorage = game:GetService("ReplicatedStorage")
local lightingService = game:GetService("Lighting")
local virtualUser = game:GetService("VirtualUser")
local teleportService = game:GetService("TeleportService")

-- State.
local localPlayer = playersService.LocalPlayer
local ui = nil
local window = nil
local mainEvent = nil
local gunHandler = nil
local connections = {}
local detaching = false
local drawings = {}
local espObjects = {}
local aimCircle = nil
local silentCircle = nil
local hitboxBackup = {}
local lightingBackup = nil
local noclipParts = {}
local flying = false
local lastStomp = 0
local lastReload = 0
local lastTrigger = 0
local lastInfo = 0
local stickyTarget = nil
local currentInfo = { name = "-", distance = 0, part = "" }
local chamObjects = {}
local chamFolder = nil
local neonBackup = {}
local lastNeon = 0
local rapidPatched = {}
local rapidMultiplier = 0
local crosshairLines = {}
local worldBackup = nil
local zoomBackup = nil
local spectating = false
local spectateTarget = nil
local lastSpectate = 0

-- The executor adds setupvalue / getupvalues to debug; the type checker does not know them.
local executorDebug = getgenv().debug

-- Hooks live in getgenv so a re-execute restores the first original instead of stacking a second hook.
local hookStore = getgenv().DaHoodHooks
if not hookStore then
	hookStore = { originalGetAim = nil, namecallInstalled = false }
	getgenv().DaHoodHooks = hookStore
end

-- Reads a UI flag; false / nil while the UI does not exist yet.
---@param name string
---@return any
local function flag(name)
	local entry = ui and ui.Flags[name]
	if entry then return entry.Value end
end

---@param name string
---@param default number
---@return number
local function numberFlag(name, default)
	local value = flag(name)
	return type(value) == "number" and value or default
end

---@param message string
local function log(message)
	warn("[DaHood] " .. message)
end

---@param failure string
local function onError(failure)
	warn("[DaHood] error: " .. tostring(failure))
	warn(debug.traceback())
end

-- Target selection ----------------------------------------------------------------------------------------------

---@return Model?
local function localCharacter()
	return localPlayer.Character
end

---@param character Model
---@return boolean
local function isKnocked(character)
	local effects = character:FindFirstChild("BodyEffects")
	local knocked = effects and effects:FindFirstChild("K.O")
	return knocked ~= nil and knocked.Value == true
end

---@param character Model
---@return boolean
local function isProtected(character)
	return character:FindFirstChildOfClass("ForceField") ~= nil
end

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.IgnoreWater = true

-- True when something solid sits between the camera and the part (the target's own character does not count).
---@param part BasePart
---@return boolean
local function isWalled(part)
	local camera = workspace.CurrentCamera
	local ignore = { part.Parent }
	if localCharacter() then table.insert(ignore, localCharacter()) end
	local ignored = workspace:FindFirstChild("Ignored")
	if ignored then table.insert(ignore, ignored) end
	wallParams.FilterDescendantsInstances = ignore

	local origin = camera.CFrame.Position
	return workspace:Raycast(origin, part.Position - origin, wallParams) ~= nil
end

-- Picks the part to aim at on a character according to the dropdown; "Closest" takes the part nearest the cursor.
---@param character Model
---@param choice string
---@param cursor Vector2
---@return BasePart?
local function pickPart(character, choice, cursor)
	if choice ~= "Closest" then
		return character:FindFirstChild(choice)
	end

	local camera = workspace.CurrentCamera
	local best, bestDistance = nil, math.huge
	for _, name in { "Head", "UpperTorso", "HumanoidRootPart" } do
		local part = character:FindFirstChild(name)
		if not part then continue end

		local screen = camera:WorldToViewportPoint(part.Position)
		local distance = (Vector2.new(screen.X, screen.Y) - cursor).Magnitude
		if distance < bestDistance then
			best, bestDistance = part, distance
		end
	end
	return best
end

-- Best target for the given settings: { player, part, position, distance }. Position includes prediction.
---@param settings table fov, partChoice, wallCheck, ignoreKnocked, ignoreProtected, maxDistance, prediction, sticky
---@return table?
local function findTarget(settings)
	local camera = workspace.CurrentCamera
	local mine = localCharacter()
	local root = mine and mine:FindFirstChild("HumanoidRootPart")
	if not (camera and root) then return nil end

	local cursor = userInputService:GetMouseLocation()
	local best, bestScore = nil, math.huge

	for _, player in playersService:GetPlayers() do
		if player == localPlayer then continue end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not (humanoid and humanoid.Health > 0) then continue end
		if settings.ignoreKnocked and isKnocked(character) then continue end
		if settings.ignoreProtected and isProtected(character) then continue end

		local part = pickPart(character, settings.partChoice, cursor)
		if not part then continue end

		local worldDistance = (part.Position - root.Position).Magnitude
		if settings.maxDistance > 0 and worldDistance > settings.maxDistance then continue end

		local screen, onScreen = camera:WorldToViewportPoint(part.Position)
		if not onScreen then continue end

		local distance = (Vector2.new(screen.X, screen.Y) - cursor).Magnitude
		-- The previous target gets a wider circle so the aim does not flick between two close players.
		local limit = (settings.sticky == player) and settings.fov * 1.4 or settings.fov
		if distance > limit then continue end
		if settings.wallCheck and isWalled(part) then continue end

		local score = (settings.sticky == player) and distance * 0.5 or distance
		if score < bestScore then
			best, bestScore = { player = player, part = part, distance = worldDistance }, score
		end
	end

	if not best then return nil end

	local position = best.part.Position
	if settings.prediction > 0 then
		position = position + best.part.AssemblyLinearVelocity * settings.prediction
	end
	best.position = position
	return best
end

---@return table
local function aimbotSettings()
	return {
		fov = numberFlag("aimFov", 160),
		partChoice = flag("aimPart") or "Head",
		wallCheck = flag("aimWall") == true,
		ignoreKnocked = flag("aimKnocked") ~= false,
		ignoreProtected = flag("aimProtected") ~= false,
		maxDistance = numberFlag("aimDistance", 0),
		prediction = numberFlag("aimPrediction", 0),
		sticky = stickyTarget,
	}
end

---@return table
local function silentSettings()
	return {
		fov = numberFlag("silentFov", 200),
		partChoice = flag("silentPart") or "Head",
		wallCheck = flag("silentWall") == true,
		ignoreKnocked = flag("silentKnocked") ~= false,
		ignoreProtected = flag("silentProtected") ~= false,
		maxDistance = numberFlag("silentDistance", 0),
		prediction = numberFlag("silentPrediction", 0),
		sticky = nil,
	}
end

-- Silent aim and bullet redirect ------------------------------------------------------------------------------------

-- Target for the shot being fired right now, or nil when silent aim should leave the shot alone.
---@return table?
local function shotTarget()
	if not flag("silentAim") then return nil end
	if math.random(1, 100) > numberFlag("silentChance", 100) then return nil end

	return findTarget(silentSettings())
end

-- Replaces GunHandler.getAim so every gun's shot direction points at the chosen target.
local function installSilentAim()
	setthreadidentity(2)
	local success, module = pcall(require, replicatedStorage:WaitForChild("Modules"):WaitForChild("GunHandler"))
	setthreadidentity(8)
	if not (success and type(module) == "table" and type(module.getAim) == "function") then
		log("GunHandler not found; silent aim unavailable")
		return
	end

	gunHandler = module
	-- Always wrap the true original, even after a re-execute.
	hookStore.originalGetAim = hookStore.originalGetAim or module.getAim
	local original = hookStore.originalGetAim

	module.getAim = function(origin, range)
		local target = shotTarget()
		if target and typeof(origin) == "Vector3" then
			local offset = target.position - origin
			if offset.Magnitude > 0 then
				return offset.Unit, offset.Magnitude
			end
		end

		return original(origin, range)
	end
end

local function restoreSilentAim()
	if gunHandler and hookStore.originalGetAim then
		gunHandler.getAim = hookStore.originalGetAim
	end
end

-- Rewrites the hit data of a ShootGun report to the silent-aim target (works through walls). One namecall hook per session.
local function installBulletRedirect()
	if hookStore.namecallInstalled then return end
	hookStore.namecallInstalled = true

	local originalNamecall
	originalNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		local state = shared.DaHoodHub
		if state and state.redirectEnabled and self == state.mainEvent and getnamecallmethod() == "FireServer" then
			local action = ...
			if action == "ShootGun" then
				local target = state.redirectTarget()
				if target then
					local arguments = table.pack(...)
					local muzzle = arguments[3]
					arguments[4] = target.position
					arguments[5] = target.part
					arguments[6] = typeof(muzzle) == "Vector3" and (muzzle - target.position).Unit or Vector3.yAxis
					return originalNamecall(self, table.unpack(arguments, 1, arguments.n))
				end
			end
		end

		return originalNamecall(self, ...)
	end))
end

-- Aimbot (camera), trigger bot, auto actions -------------------------------------------------------------------------

local function stepAimbot()
	if not flag("aimbot") then
		stickyTarget = nil
		-- Silent aim has no camera step; sample its target a few times a second for the Target card.
		if flag("silentAim") and os.clock() - lastInfo > 0.2 then
			lastInfo = os.clock()
			local target = findTarget(silentSettings())
			if target then
				currentInfo.name, currentInfo.distance, currentInfo.part = target.player.DisplayName, target.distance, target.part.Name
			else
				currentInfo.name = "-"
			end
		elseif not flag("silentAim") then
			currentInfo.name = "-"
		end
		return
	end

	local mode = flag("aimMode") or "Hold RMB"
	local active = mode == "Always" or (mode == "Hold RMB" and userInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
	if not active then
		stickyTarget = nil
		return
	end

	local target = findTarget(aimbotSettings())
	if not target then
		stickyTarget = nil
		currentInfo.name = "-"
		return
	end

	stickyTarget = target.player
	currentInfo.name, currentInfo.distance, currentInfo.part = target.player.DisplayName, target.distance, target.part.Name

	local camera = workspace.CurrentCamera
	local desired = CFrame.lookAt(camera.CFrame.Position, target.position)
	local smoothing = numberFlag("aimSmooth", 6)
	local alpha = smoothing <= 1 and 1 or math.clamp(1 / smoothing, 0.02, 1)
	camera.CFrame = camera.CFrame:Lerp(desired, alpha)
end

local function stepTriggerBot()
	if not flag("triggerBot") then return end
	if os.clock() - lastTrigger < numberFlag("triggerDelay", 0.08) then return end

	local mine = localCharacter()
	local tool = mine and mine:FindFirstChildOfClass("Tool")
	if not (tool and tool:FindFirstChild("Ammo")) then return end

	local camera = workspace.CurrentCamera
	local cursor = userInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(cursor.X, cursor.Y)
	wallParams.FilterDescendantsInstances = { mine, workspace:FindFirstChild("Ignored") or mine }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 500, wallParams)
	if not hit then return end

	local character = hit.Instance:FindFirstAncestorOfClass("Model")
	local owner = character and playersService:GetPlayerFromCharacter(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (owner and owner ~= localPlayer and humanoid and humanoid.Health > 0) then return end
	if isKnocked(character) or isProtected(character) then return end

	lastTrigger = os.clock()
	tool:Activate()
end

local function stepAutoActions()
	local mine = localCharacter()
	local root = mine and mine:FindFirstChild("HumanoidRootPart")
	if not (mine and root) then return end

	-- Auto stomp: any knocked player within reach.
	if flag("autoStomp") and mainEvent and os.clock() - lastStomp > 0.5 then
		local reach = numberFlag("stompRange", 8)
		for _, player in playersService:GetPlayers() do
			if player == localPlayer then continue end

			local character = player.Character
			local theirRoot = character and character:FindFirstChild("HumanoidRootPart")
			if theirRoot and isKnocked(character) and (theirRoot.Position - root.Position).Magnitude <= reach then
				lastStomp = os.clock()
				mainEvent:FireServer("Stomp")
				break
			end
		end
	end

	-- Auto reload: equipped gun is empty.
	if flag("autoReload") and mainEvent and os.clock() - lastReload > 1.2 then
		local tool = mine:FindFirstChildOfClass("Tool")
		local ammo = tool and tool:FindFirstChild("Ammo")
		local effects = mine:FindFirstChild("BodyEffects")
		local reloading = effects and effects:FindFirstChild("Reload")
		if ammo and ammo.Value == 0 and not (reloading and reloading.Value) then
			lastReload = os.clock()
			mainEvent:FireServer("Reload", tool)
		end
	end
end

-- Hitbox expander: client-side bigger root parts on everyone else.
local function stepHitboxes()
	local enabled = flag("hitbox") == true
	local size = numberFlag("hitboxSize", 8)

	for _, player in playersService:GetPlayers() do
		if player == localPlayer then continue end

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then continue end

		if enabled then
			if not hitboxBackup[root] then
				hitboxBackup[root] = { size = root.Size, transparency = root.Transparency, collide = root.CanCollide }
			end
			root.Size = Vector3.new(size, size, size)
			root.Transparency = 0.8
			root.CanCollide = false
		elseif hitboxBackup[root] then
			local saved = hitboxBackup[root]
			root.Size, root.Transparency, root.CanCollide = saved.size, saved.transparency, saved.collide
			hitboxBackup[root] = nil
		end
	end

	if not enabled then
		for root, saved in hitboxBackup do
			if root.Parent then root.Size, root.Transparency, root.CanCollide = saved.size, saved.transparency, saved.collide end
			hitboxBackup[root] = nil
		end
	end
end

-- Movement ------------------------------------------------------------------------------------------------------------

---@param deltaTime number
local function stepMovement(deltaTime)
	local mine = localCharacter()
	local root = mine and mine:FindFirstChild("HumanoidRootPart")
	local humanoid = mine and mine:FindFirstChildOfClass("Humanoid")
	if not (root and humanoid and humanoid.Health > 0) then return end

	local camera = workspace.CurrentCamera

	if flag("fly") then
		local look, right = camera.CFrame.LookVector, camera.CFrame.RightVector
		local direction = Vector3.zero
		if userInputService:IsKeyDown(Enum.KeyCode.W) then direction += look end
		if userInputService:IsKeyDown(Enum.KeyCode.S) then direction -= look end
		if userInputService:IsKeyDown(Enum.KeyCode.D) then direction += right end
		if userInputService:IsKeyDown(Enum.KeyCode.A) then direction -= right end
		if userInputService:IsKeyDown(Enum.KeyCode.Space) or userInputService:IsKeyDown(Enum.KeyCode.E) then direction += Vector3.yAxis end
		if userInputService:IsKeyDown(Enum.KeyCode.LeftControl) or userInputService:IsKeyDown(Enum.KeyCode.Q) then direction -= Vector3.yAxis end

		-- No BodyVelocity: the game reports those. Zero the velocity and move the root part directly.
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		if direction.Magnitude > 0 then
			local boost = userInputService:IsKeyDown(Enum.KeyCode.LeftShift) and numberFlag("flyBoost", 2) or 1
			-- A long frame must not turn a 10000 speed into a teleport across the map.
			root.CFrame = root.CFrame + direction.Unit * numberFlag("flySpeed", 150) * boost * math.min(deltaTime, 0.05)
		end
		flying = true
	elseif flying then
		flying = false
		root.AssemblyLinearVelocity = Vector3.zero
	end

	if flag("speed") and not flag("fly") then
		local move = humanoid.MoveDirection
		if move.Magnitude > 0 then
			local extra = math.max(numberFlag("speedValue", 40) - humanoid.WalkSpeed, 0)
			root.CFrame = root.CFrame + move.Unit * extra * deltaTime
		end
	end

	if flag("noclip") or flag("fly") then
		for _, part in mine:GetDescendants() do
			if part:IsA("BasePart") and part.CanCollide then
				part.CanCollide = false
				noclipParts[part] = true
			end
		end
	elseif next(noclipParts) then
		for part in noclipParts do
			if part.Parent then part.CanCollide = true end
			noclipParts[part] = nil
		end
	end

	if flag("bunnyHop") and humanoid.MoveDirection.Magnitude > 0 and humanoid.FloorMaterial ~= Enum.Material.Air then
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end

	if flag("fovChanger") then
		camera.FieldOfView = numberFlag("fovValue", 90)
	end
end

-- Visuals ---------------------------------------------------------------------------------------------------------------

local SKELETON = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}
local KNOCKED_COLOR = Color3.fromRGB(240, 96, 112)
local DEFAULT_COLOR = Color3.fromRGB(122, 152, 244)

---@param class string
---@param props table
---@return table?
local function newDrawing(class, props)
	local success, object = pcall(Drawing.new, class)
	if not success then return nil end

	for key, value in props do
		object[key] = value
	end
	table.insert(drawings, object)
	return object
end

-- Creates a drawing inside a per-player table the first time it is needed, so unused ESP parts cost nothing.
---@param objects table
---@param key string
---@param class string
---@param props table
---@return table?
local function slot(objects, key, class, props)
	local object = objects[key]
	if object then return object end

	object = newDrawing(class, props)
	objects[key] = object
	return object
end

---@param objects table
local function hideEsp(objects)
	for _, object in objects do
		object.Visible = false
	end
end

---@param player Player
local function removeEsp(player)
	local objects = espObjects[player]
	if objects then
		for _, object in objects do
			pcall(function() object:Remove() end)
		end
		espObjects[player] = nil
	end

	local cham = chamObjects[player]
	if cham then
		pcall(function() cham:Destroy() end)
		chamObjects[player] = nil
	end
end

---@param objects table
---@param x number
---@param y number
---@param width number
---@param height number
---@param color Color3
---@param visible boolean
local function drawCorners(objects, x, y, width, height, color, visible)
	if not visible then
		for index = 1, 8 do
			local line = objects["corner" .. index]
			if line then line.Visible = false end
		end
		return
	end

	local length = math.min(width, height) * 0.3
	local segments = {
		{ Vector2.new(x, y), Vector2.new(x + length, y) }, { Vector2.new(x, y), Vector2.new(x, y + length) },
		{ Vector2.new(x + width, y), Vector2.new(x + width - length, y) }, { Vector2.new(x + width, y), Vector2.new(x + width, y + length) },
		{ Vector2.new(x, y + height), Vector2.new(x + length, y + height) }, { Vector2.new(x, y + height), Vector2.new(x, y + height - length) },
		{ Vector2.new(x + width, y + height), Vector2.new(x + width - length, y + height) }, { Vector2.new(x + width, y + height), Vector2.new(x + width, y + height - length) },
	}
	for index, segment in segments do
		local line = slot(objects, "corner" .. index, "Line", { Thickness = 1.5, Visible = false })
		if line then
			line.Visible = true
			line.From, line.To, line.Color = segment[1], segment[2], color
		end
	end
end

---@param objects table
---@param character Model
---@param camera Camera
---@param color Color3
---@param visible boolean
local function drawSkeleton(objects, character, camera, color, visible)
	for index, pair in SKELETON do
		local existing = objects["bone" .. index]
		local first, second = character:FindFirstChild(pair[1]), character:FindFirstChild(pair[2])
		if not (visible and first and second) then
			if existing then existing.Visible = false end
			continue
		end

		local from = camera:WorldToViewportPoint(first.Position)
		local to = camera:WorldToViewportPoint(second.Position)
		if from.Z <= 0 or to.Z <= 0 then
			if existing then existing.Visible = false end
			continue
		end

		local line = existing or slot(objects, "bone" .. index, "Line", { Thickness = 1.3, Visible = false })
		if line then
			line.Visible = true
			line.From, line.To, line.Color = Vector2.new(from.X, from.Y), Vector2.new(to.X, to.Y), color
		end
	end
end

-- Arrow on a ring around the screen centre pointing at a player who is off screen.
---@param objects table
---@param camera Camera
---@param position Vector3
---@param color Color3
local function drawArrow(objects, camera, position, color)
	local relative = camera.CFrame:PointToObjectSpace(position)
	local angle = math.atan2(relative.X, -relative.Z)
	local viewport = camera.ViewportSize
	local center = viewport / 2
	local radius = math.min(viewport.X, viewport.Y) * 0.38
	local direction = Vector2.new(math.sin(angle), -math.cos(angle))
	local side = Vector2.new(-direction.Y, direction.X)
	local base = center + direction * radius

	local arrow = slot(objects, "arrow", "Triangle", { Filled = true, Thickness = 1, Visible = false })
	if arrow then
		arrow.Visible = true
		arrow.PointA = base + direction * 14
		arrow.PointB = base - direction * 6 + side * 9
		arrow.PointC = base - direction * 6 - side * 9
		arrow.Color = color
	end
end

local function stepEsp()
	local camera = workspace.CurrentCamera
	local enabled = flag("esp") == true
	local color = flag("espColor") or DEFAULT_COLOR
	local viewport = camera.ViewportSize
	local maxDistance = numberFlag("espDistance", 0)
	local cursor = userInputService:GetMouseLocation()
	local tracerFrom = flag("espTracerFrom") or "Bottom"
	local cornerStyle = flag("espBoxStyle") == "Corner"

	for _, player in playersService:GetPlayers() do
		if player == localPlayer then continue end

		local objects = espObjects[player]
		if not objects then
			objects = {}
			espObjects[player] = objects
		end

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local alive = root ~= nil and humanoid ~= nil and humanoid.Health > 0
		local within = alive and (maxDistance <= 0 or (camera.CFrame.Position - root.Position).Magnitude <= maxDistance)
		if not (enabled and within) then
			hideEsp(objects)
			continue
		end

		local knocked = isKnocked(character)
		local tint = knocked and KNOCKED_COLOR or color
		local screen, onScreen = camera:WorldToViewportPoint(root.Position)
		if not onScreen then
			hideEsp(objects)
			if flag("espArrows") then drawArrow(objects, camera, root.Position, tint) end
			continue
		end

		local top = camera:WorldToViewportPoint(root.Position + Vector3.new(0, 3.1, 0))
		local bottom = camera:WorldToViewportPoint(root.Position - Vector3.new(0, 3.4, 0))
		local height = math.abs(bottom.Y - top.Y)
		local width = height * 0.55
		local x, y = screen.X - width / 2, top.Y

		local showBox = flag("espBox") ~= false
		if showBox and not cornerStyle then
			local box = slot(objects, "box", "Square", { Thickness = 1, Filled = false, Visible = false })
			if box then
				box.Visible = true
				box.Position, box.Size, box.Color = Vector2.new(x, y), Vector2.new(width, height), tint
			end
		elseif objects.box then
			objects.box.Visible = false
		end
		drawCorners(objects, x, y, width, height, tint, showBox and cornerStyle)

		if flag("espName") ~= false then
			local name = slot(objects, "name", "Text", { Size = 13, Center = true, Outline = true, Font = ESP_FONT, Visible = false })
			if name then
				name.Visible = true
				name.Text = knocked and (player.DisplayName .. " [KO]") or player.DisplayName
				name.Position, name.Color = Vector2.new(screen.X, y - 16), Color3.new(1, 1, 1)
			end
		elseif objects.name then
			objects.name.Visible = false
		end

		if flag("espInfo") ~= false then
			local info = slot(objects, "info", "Text", { Size = 12, Center = true, Outline = true, Font = ESP_FONT, Visible = false })
			if info then
				info.Visible = true
				info.Text = string.format("%dm  %d HP", math.floor((camera.CFrame.Position - root.Position).Magnitude), math.floor(humanoid.Health))
				info.Position, info.Color = Vector2.new(screen.X, y + height + 2), Color3.fromRGB(210, 205, 200)
			end
		elseif objects.info then
			objects.info.Visible = false
		end

		if flag("espWeapon") then
			local tool = character:FindFirstChildOfClass("Tool")
			local weapon = slot(objects, "weapon", "Text", { Size = 12, Center = true, Outline = true, Font = ESP_FONT, Visible = false })
			if weapon then
				weapon.Visible = tool ~= nil
				weapon.Text = tool and tool.Name or ""
				weapon.Position, weapon.Color = Vector2.new(screen.X, y + height + 15), Color3.fromRGB(240, 190, 110)
			end
		elseif objects.weapon then
			objects.weapon.Visible = false
		end

		if flag("espHealth") ~= false then
			local bar = slot(objects, "healthBar", "Line", { Thickness = 2, Visible = false })
			if bar then
				local fraction = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
				bar.Visible = true
				bar.From, bar.To = Vector2.new(x - 4, y + height), Vector2.new(x - 4, y + height - height * fraction)
				bar.Color = Color3.fromRGB(255 * (1 - fraction), 255 * fraction, 80)
			end
		elseif objects.healthBar then
			objects.healthBar.Visible = false
		end

		local head = character:FindFirstChild("Head")
		if flag("espHeadDot") and head then
			local headScreen = camera:WorldToViewportPoint(head.Position)
			local dot = slot(objects, "headDot", "Circle", { Thickness = 1, NumSides = 20, Filled = false, Visible = false })
			if dot then
				dot.Visible = headScreen.Z > 0
				dot.Position, dot.Radius, dot.Color = Vector2.new(headScreen.X, headScreen.Y), math.max(2, height * 0.07), tint
			end
		elseif objects.headDot then
			objects.headDot.Visible = false
		end

		if flag("espLook") and head then
			local from = camera:WorldToViewportPoint(head.Position)
			local to = camera:WorldToViewportPoint(head.Position + head.CFrame.LookVector * 8)
			local look = slot(objects, "look", "Line", { Thickness = 1.5, Visible = false })
			if look then
				look.Visible = from.Z > 0 and to.Z > 0
				look.From, look.To, look.Color = Vector2.new(from.X, from.Y), Vector2.new(to.X, to.Y), Color3.fromRGB(255, 220, 120)
			end
		elseif objects.look then
			objects.look.Visible = false
		end

		drawSkeleton(objects, character, camera, tint, flag("espSkeleton") == true)

		if flag("espTracer") then
			local tracer = slot(objects, "tracer", "Line", { Thickness = 1, Visible = false })
			if tracer then
				tracer.Visible = true
				tracer.From = tracerFrom == "Center" and viewport / 2 or (tracerFrom == "Mouse" and cursor or Vector2.new(viewport.X / 2, viewport.Y))
				tracer.To, tracer.Color = Vector2.new(screen.X, y + height), tint
			end
		elseif objects.tracer then
			objects.tracer.Visible = false
		end

		if objects.arrow then objects.arrow.Visible = false end
	end
end

-- Engine chams: a Highlight per character (depth mode, fill and outline are all adjustable).
local function stepChams()
	local enabled = flag("chams") == true
	if enabled and not chamFolder then
		chamFolder = Instance.new("Folder")
		chamFolder.Name = "DaHoodChams"
		local parentOk = pcall(function() chamFolder.Parent = gethui() end)
		if not parentOk then chamFolder.Parent = game:GetService("CoreGui") end
	end

	local camera = workspace.CurrentCamera
	local maxDistance = numberFlag("espDistance", 0)
	for _, player in playersService:GetPlayers() do
		if player == localPlayer then continue end

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local cham = chamObjects[player]
		local show = enabled and root ~= nil and humanoid ~= nil and humanoid.Health > 0
			and (maxDistance <= 0 or (camera.CFrame.Position - root.Position).Magnitude <= maxDistance)

		if not show then
			if cham then cham.Enabled = false end
			continue
		end

		if not cham or not cham.Parent then
			cham = Instance.new("Highlight")
			cham.Parent = chamFolder
			chamObjects[player] = cham
		end

		cham.Adornee = character
		cham.Enabled = true
		cham.DepthMode = flag("chamsMode") == "Visible only" and Enum.HighlightDepthMode.Occluded or Enum.HighlightDepthMode.AlwaysOnTop
		cham.FillColor = isKnocked(character) and KNOCKED_COLOR or (flag("chamsFill") or DEFAULT_COLOR)
		cham.OutlineColor = flag("chamsOutline") or Color3.new(1, 1, 1)
		cham.FillTransparency = numberFlag("chamsFillAlpha", 0.5)
		cham.OutlineTransparency = numberFlag("chamsOutlineAlpha", 0)
	end
end

-- Neon chams: recolours the real body parts with the Neon material (client side), restored when switched off.
local function stepNeon()
	if os.clock() - lastNeon < 0.3 then return end
	lastNeon = os.clock()

	for part in neonBackup do
		if not part.Parent then neonBackup[part] = nil end
	end

	if flag("neonChams") then
		local color = flag("neonColor") or Color3.fromRGB(122, 152, 244)
		for _, player in playersService:GetPlayers() do
			if player == localPlayer or not player.Character then continue end

			for _, part in player.Character:GetDescendants() do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
					if not neonBackup[part] then neonBackup[part] = { material = part.Material, color = part.Color } end
					part.Material = Enum.Material.Neon
					part.Color = color
				end
			end
		end
	else
		for part, saved in neonBackup do
			if part.Parent then
				part.Material, part.Color = saved.material, saved.color
			end
			neonBackup[part] = nil
		end
	end
end

local function stepFovCircles()
	local cursor = userInputService:GetMouseLocation()

	if aimCircle then
		aimCircle.Visible = flag("aimbot") == true and flag("showFov") == true
		aimCircle.Position = cursor
		aimCircle.Radius = numberFlag("aimFov", 160)
		aimCircle.Color = flag("fovColor") or DEFAULT_COLOR
	end

	if silentCircle then
		silentCircle.Visible = flag("silentAim") == true and flag("showFov") == true
		silentCircle.Position = cursor
		silentCircle.Radius = numberFlag("silentFov", 200)
		silentCircle.Color = Color3.fromRGB(240, 170, 90)
	end
end

-- Custom crosshair at the cursor (the game aims at the mouse).
local function stepCrosshair()
	local enabled = flag("crosshair") == true
	if #crosshairLines == 0 then
		if not enabled then return end

		for index = 1, 4 do
			crosshairLines[index] = newDrawing("Line", { Thickness = 2, Visible = false })
		end
	end

	local center = userInputService:GetMouseLocation()
	local size, gap = numberFlag("crosshairSize", 8), numberFlag("crosshairGap", 4)
	local color = flag("crosshairColor") or Color3.new(1, 1, 1)
	local ends = {
		{ center + Vector2.new(-gap - size, 0), center + Vector2.new(-gap, 0) },
		{ center + Vector2.new(gap, 0), center + Vector2.new(gap + size, 0) },
		{ center + Vector2.new(0, -gap - size), center + Vector2.new(0, -gap) },
		{ center + Vector2.new(0, gap), center + Vector2.new(0, gap + size) },
	}
	for index, line in crosshairLines do
		line.Visible = enabled
		line.From, line.To, line.Color = ends[index][1], ends[index][2], color
	end
end

local function applyFullbright(enabled)
	if enabled then
		if not lightingBackup then
			lightingBackup = {
				Brightness = lightingService.Brightness,
				ClockTime = lightingService.ClockTime,
				GlobalShadows = lightingService.GlobalShadows,
				Ambient = lightingService.Ambient,
				FogEnd = lightingService.FogEnd,
			}
		end
		lightingService.Brightness = 2
		lightingService.ClockTime = 14
		lightingService.GlobalShadows = false
		lightingService.Ambient = Color3.fromRGB(190, 190, 190)
		lightingService.FogEnd = 1e6
	elseif lightingBackup then
		for property, value in lightingBackup do
			lightingService[property] = value
		end
		lightingBackup = nil
	end
end

local function restoreWorld()
	if not worldBackup then return end

	lightingService.FogEnd, lightingService.FogStart, lightingService.ClockTime = worldBackup.fogEnd, worldBackup.fogStart, worldBackup.clockTime
	local atmosphere = lightingService:FindFirstChildOfClass("Atmosphere")
	if atmosphere and worldBackup.density then
		atmosphere.Density, atmosphere.Haze = worldBackup.density, worldBackup.haze
	end
	worldBackup = nil
end

-- No fog, forced time of day and unlimited zoom; each one is undone as soon as it is switched off.
local function stepWorld()
	local fog, timeOn = flag("noFog") == true, flag("timeChanger") == true
	if fog or timeOn then
		if not worldBackup then
			local atmosphere = lightingService:FindFirstChildOfClass("Atmosphere")
			worldBackup = {
				fogEnd = lightingService.FogEnd, fogStart = lightingService.FogStart, clockTime = lightingService.ClockTime,
				density = atmosphere and atmosphere.Density, haze = atmosphere and atmosphere.Haze,
			}
		end

		if fog then
			lightingService.FogEnd, lightingService.FogStart = 1e6, 1e6
			local atmosphere = lightingService:FindFirstChildOfClass("Atmosphere")
			if atmosphere then atmosphere.Density, atmosphere.Haze = 0, 0 end
		end
		if timeOn then
			lightingService.ClockTime = numberFlag("timeValue", 14)
		else
			lightingService.ClockTime = worldBackup.clockTime
		end
	else
		restoreWorld()
	end

	if flag("unlimitedZoom") then
		if not zoomBackup then zoomBackup = localPlayer.CameraMaxZoomDistance end
		localPlayer.CameraMaxZoomDistance = 100000
	elseif zoomBackup then
		localPlayer.CameraMaxZoomDistance = zoomBackup
		zoomBackup = nil
	end
end

-- Spectate: the camera follows the player nearest the cursor until the toggle is switched off.
local function stepSpectate()
	local camera = workspace.CurrentCamera
	if flag("spectate") then
		if os.clock() - lastSpectate > 0.3 then
			lastSpectate = os.clock()
			local target = findTarget({ fov = 100000, partChoice = "HumanoidRootPart", wallCheck = false, ignoreKnocked = false, ignoreProtected = false, maxDistance = 0, prediction = 0, sticky = spectateTarget })
			spectateTarget = target and target.player or nil
		end

		local character = spectateTarget and spectateTarget.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
			spectating = true
		end
	elseif spectating then
		spectating = false
		spectateTarget = nil
		local mine = localCharacter()
		local humanoid = mine and mine:FindFirstChildOfClass("Humanoid")
		if humanoid then camera.CameraSubject = humanoid end
	end
end

-- Weapons ---------------------------------------------------------------------------------------------------------------

---@return Tool?
local function equippedGun()
	local mine = localCharacter()
	local tool = mine and mine:FindFirstChildOfClass("Tool")
	if tool and tool:FindFirstChild("Ammo") then return tool end
end

-- Rapid fire: every gun script copies its ShootingCooldown into an upvalue of the Activated handler and refuses to fire
-- inside that window. The upvalue is found by value and divided by the multiplier.
---@param tool Tool
---@param multiplier number
local function patchFireRate(tool, multiplier)
	local record = rapidPatched[tool]
	if record then
		pcall(executorDebug.setupvalue, record.fn, record.index, record.original / multiplier)
		return
	end

	local cooldown = tool:FindFirstChild("ShootingCooldown")
	if not cooldown then return end

	for _, connection in getconnections(tool.Activated) do
		local fn = connection.Function
		if fn and islclosure(fn) then
			local success, upvalues = pcall(executorDebug.getupvalues, fn)
			if not success then continue end

			for index, value in upvalues do
				if type(value) == "number" and math.abs(value - cooldown.Value) < 1e-4 then
					rapidPatched[tool] = { fn = fn, index = index, original = value }
					pcall(executorDebug.setupvalue, fn, index, value / multiplier)
					return
				end
			end
		end
	end
end

local function restoreFireRate()
	for tool, record in rapidPatched do
		pcall(executorDebug.setupvalue, record.fn, record.index, record.original)
		rapidPatched[tool] = nil
	end
	rapidMultiplier = 0
end

local function stepRapidFire()
	if not flag("rapidFire") then
		if next(rapidPatched) then restoreFireRate() end
		return
	end

	local tool = equippedGun()
	local multiplier = math.max(numberFlag("fireRate", 4), 1)
	if tool and (not rapidPatched[tool] or multiplier ~= rapidMultiplier) then
		patchFireRate(tool, multiplier)
		rapidMultiplier = multiplier
	end
end

-- Auto fire: holding the left mouse button keeps activating the equipped gun (semi-autos included).
local function stepAutoFire()
	if not flag("autoFire") then return end
	if (window and window:IsOpen()) or userInputService:GetFocusedTextBox() then return end
	if not userInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then return end

	local tool = equippedGun()
	if tool then tool:Activate() end
end

-- UI ----------------------------------------------------------------------------------------------------------------------

---@return table
local function loadLibrary()
	local success, library = pcall(function()
		local chunk = loadstring(readfile(UI_FILE))
		return chunk and chunk()
	end)
	if success and type(library) == "table" then return library end

	local response = request({ Url = UI_URL, Method = "GET" })
	local chunk = loadstring(response.Body)
	assert(chunk, "V18UI failed to compile")
	return chunk()
end

local function buildUi()
	ui = loadLibrary()
	window = ui:CreateWindow({
		Title = "Da Hood",
		Subtitle = "Combat  /  Movement  /  Visuals",
		ToggleKey = Enum.KeyCode.RightShift,
		-- Pressing "Unload Script" in Settings unloads the whole hub, not just the window.
		OnDestroy = function()
			if not detaching then DaHood.detach() end
		end,
	})

	-- A hub overlay should not blur the game while you play; Settings can turn it back on.
	ui.Flags.ui_blur.Set(false)

	-- Overview ----------------------------------------------------------------------------------------------------
	local overview = window:CreateTab("Overview", "layout-dashboard", "Your hub at a glance")
	overview:AddStatRow({
		{ Title = "Aimbot", Get = function()
			return flag("aimbot") and "ON" or "OFF", flag("aimbot") and 1 or 0.04, flag("aimMode") or ""
		end },
		{ Title = "Silent aim", Get = function()
			return flag("silentAim") and "ON" or "OFF", flag("silentAim") and numberFlag("silentChance", 100) / 100 or 0.04, string.format("%d%% hit", numberFlag("silentChance", 100))
		end },
		{ Title = "Target", Get = function()
			return currentInfo.name, currentInfo.name == "-" and 0 or math.clamp(1 - currentInfo.distance / 300, 0, 1), currentInfo.name == "-" and "" or string.format("%d studs", currentInfo.distance)
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
	overview:AddKeybind({ Text = "Panic key", Default = Enum.KeyCode.End, Flag = "keyPanic", Pressed = function()
		for name, entry in ui.Flags do
			if entry.Type == "Toggle" and string.sub(name, 1, 3) ~= "ui_" and entry.Value then entry.Set(false) end
		end
	end })

	-- Combat ------------------------------------------------------------------------------------------------------
	window:CreateCategory("Combat")
	local combat = window:CreateTab("Aimbot", "crosshair", "Camera aim assist")
	combat:AddSection("Aimbot")
	combat:AddToggle({ Text = "Aimbot", Flag = "aimbot", Key = Enum.KeyCode.Z })
	combat:AddDropdown({ Text = "Activation", Options = { "Hold RMB", "Always" }, Default = "Hold RMB", Flag = "aimMode" })
	combat:AddDropdown({ Text = "Target part", Options = TARGET_PARTS, Default = "Head", Flag = "aimPart" })
	combat:AddSlider({ Text = "FOV radius", Min = 20, Max = 600, Default = 160, Increment = 5, Flag = "aimFov" })
	combat:AddSlider({ Text = "Smoothing", Min = 1, Max = 30, Default = 6, Increment = 1, Flag = "aimSmooth" })
	combat:AddSlider({ Text = "Prediction", Min = 0, Max = 0.3, Default = 0, Increment = 0.01, Suffix = " s", Flag = "aimPrediction" })
	combat:AddSection("Filters")
	combat:AddToggle({ Text = "Wall check", Flag = "aimWall", NoList = true })
	combat:AddToggle({ Text = "Skip knocked players", Default = true, Flag = "aimKnocked", NoList = true })
	combat:AddToggle({ Text = "Skip spawn-protected", Default = true, Flag = "aimProtected", NoList = true })
	combat:AddSlider({ Text = "Max distance (0 = any)", Min = 0, Max = 1000, Default = 0, Increment = 10, Flag = "aimDistance" })
	combat:AddSection("Trigger bot")
	combat:AddToggle({ Text = "Trigger bot", Flag = "triggerBot" })
	combat:AddSlider({ Text = "Delay", Min = 0.02, Max = 0.5, Default = 0.08, Increment = 0.01, Suffix = " s", Flag = "triggerDelay" })

	local silent = window:CreateTab("Silent Aim", "target", "Redirects shots, not your camera")
	silent:AddSection("Silent aim")
	silent:AddToggle({ Text = "Silent aim", Flag = "silentAim" })
	silent:AddDropdown({ Text = "Target part", Options = TARGET_PARTS, Default = "Head", Flag = "silentPart" })
	silent:AddSlider({ Text = "FOV radius", Min = 20, Max = 800, Default = 200, Increment = 5, Flag = "silentFov" })
	silent:AddSlider({ Text = "Hit chance", Min = 1, Max = 100, Default = 100, Increment = 1, Suffix = "%", Flag = "silentChance" })
	silent:AddSlider({ Text = "Prediction", Min = 0, Max = 0.3, Default = 0, Increment = 0.01, Suffix = " s", Flag = "silentPrediction" })
	silent:AddSection("Bullet redirect")
	silent:AddToggle({ Text = "Bullet TP (hit through walls)", Flag = "bulletTp", Callback = function(on)
		DaHood.redirectEnabled = on
	end })
	silent:AddLabel("Rewrites the hit position and part of each shot to the silent-aim target. Needs Silent aim enabled.")
	silent:AddSection("Filters")
	silent:AddToggle({ Text = "Wall check", Flag = "silentWall", NoList = true })
	silent:AddToggle({ Text = "Skip knocked players", Default = true, Flag = "silentKnocked", NoList = true })
	silent:AddToggle({ Text = "Skip spawn-protected", Default = true, Flag = "silentProtected", NoList = true })
	silent:AddSlider({ Text = "Max distance (0 = any)", Min = 0, Max = 1000, Default = 0, Increment = 10, Flag = "silentDistance" })

	local weapons = window:CreateTab("Weapons", "swords", "Fire rate, stomp and reload")
	weapons:AddSection("Firing")
	weapons:AddToggle({ Text = "Rapid fire", Flag = "rapidFire" })
	weapons:AddSlider({ Text = "Fire rate multiplier", Min = 1, Max = 25, Default = 4, Increment = 1, Suffix = "x", Flag = "fireRate" })
	weapons:AddToggle({ Text = "Auto fire (hold left mouse)", Flag = "autoFire" })
	weapons:AddLabel("Rapid fire divides the gun's cooldown on your client; the server may still enforce its own limit.")
	weapons:AddSection("Auto actions")
	weapons:AddToggle({ Text = "Auto stomp", Flag = "autoStomp" })
	weapons:AddSlider({ Text = "Stomp range", Min = 3, Max = 14, Default = 8, Increment = 1, Flag = "stompRange" })
	weapons:AddToggle({ Text = "Auto reload", Flag = "autoReload" })
	weapons:AddSection("Hitbox")
	weapons:AddToggle({ Text = "Expand enemy hitboxes", Flag = "hitbox" })
	weapons:AddSlider({ Text = "Hitbox size", Min = 4, Max = 20, Default = 8, Increment = 1, Flag = "hitboxSize" })

	-- Player ------------------------------------------------------------------------------------------------------
	window:CreateCategory("Player")
	local movement = window:CreateTab("Movement", "wind", "Fly, speed and noclip")
	movement:AddSection("Fly")
	movement:AddToggle({ Text = "Fly (WASD, Space/E up, Ctrl/Q down)", Flag = "fly", Key = Enum.KeyCode.X })
	movement:AddSlider({ Text = "Fly speed", Min = 10, Max = 10000, Default = 150, Increment = 10, Flag = "flySpeed" })
	movement:AddSlider({ Text = "Shift boost", Min = 1, Max = 10, Default = 2, Increment = 0.5, Suffix = "x", Flag = "flyBoost" })
	movement:AddSection("Speed")
	movement:AddToggle({ Text = "Speed boost", Flag = "speed" })
	movement:AddSlider({ Text = "Speed", Min = 16, Max = 500, Default = 40, Increment = 2, Flag = "speedValue" })
	movement:AddSection("Other")
	movement:AddToggle({ Text = "Noclip", Flag = "noclip", Key = Enum.KeyCode.V })
	movement:AddToggle({ Text = "Infinite jump", Flag = "infiniteJump" })
	movement:AddToggle({ Text = "Bunny hop", Flag = "bunnyHop" })

	-- Visuals -----------------------------------------------------------------------------------------------------
	window:CreateCategory("Visuals")
	local visuals = window:CreateTab("ESP", "eye", "See players through walls")
	visuals:AddSection("Player ESP")
	visuals:AddToggle({ Text = "ESP", Flag = "esp" })
	visuals:AddDropdown({ Text = "Box style", Options = { "Box", "Corner" }, Default = "Box", Flag = "espBoxStyle" })
	visuals:AddToggle({ Text = "Boxes", Default = true, Flag = "espBox", NoList = true })
	visuals:AddToggle({ Text = "Names", Default = true, Flag = "espName", NoList = true })
	visuals:AddToggle({ Text = "Distance and health text", Default = true, Flag = "espInfo", NoList = true })
	visuals:AddToggle({ Text = "Health bar", Default = true, Flag = "espHealth", NoList = true })
	visuals:AddToggle({ Text = "Equipped weapon", Flag = "espWeapon" })
	visuals:AddToggle({ Text = "Skeleton", Flag = "espSkeleton" })
	visuals:AddToggle({ Text = "Head dot", Flag = "espHeadDot" })
	visuals:AddToggle({ Text = "Look direction line", Flag = "espLook" })
	visuals:AddToggle({ Text = "Off-screen arrows", Flag = "espArrows" })
	visuals:AddToggle({ Text = "Tracers", Flag = "espTracer" })
	visuals:AddDropdown({ Text = "Tracer origin", Options = { "Bottom", "Center", "Mouse" }, Default = "Bottom", Flag = "espTracerFrom" })
	visuals:AddSlider({ Text = "Max distance (0 = any)", Min = 0, Max = 2000, Default = 0, Increment = 25, Flag = "espDistance" })
	visuals:AddColor({ Text = "ESP color", Default = Color3.fromRGB(122, 152, 244), Flag = "espColor" })

	local chams = window:CreateTab("Chams", "shield", "Highlight and neon player models")
	chams:AddSection("Engine chams (Highlight)")
	chams:AddToggle({ Text = "Chams", Flag = "chams" })
	chams:AddDropdown({ Text = "Visibility", Options = { "Through walls", "Visible only" }, Default = "Through walls", Flag = "chamsMode" })
	chams:AddColor({ Text = "Fill color", Default = Color3.fromRGB(122, 152, 244), Flag = "chamsFill" })
	chams:AddColor({ Text = "Outline color", Default = Color3.new(1, 1, 1), Flag = "chamsOutline" })
	chams:AddSlider({ Text = "Fill transparency", Min = 0, Max = 1, Default = 0.5, Increment = 0.05, Flag = "chamsFillAlpha" })
	chams:AddSlider({ Text = "Outline transparency", Min = 0, Max = 1, Default = 0, Increment = 0.05, Flag = "chamsOutlineAlpha" })
	chams:AddSection("Neon chams (material)")
	chams:AddToggle({ Text = "Neon chams", Flag = "neonChams" })
	chams:AddColor({ Text = "Neon color", Default = Color3.fromRGB(122, 152, 244), Flag = "neonColor" })
	chams:AddLabel("Chams share the ESP max distance. Knocked players are tinted red.")

	local world = window:CreateTab("World", "rocket", "Camera, lighting and crosshair")
	world:AddSection("Aim helpers")
	world:AddToggle({ Text = "Show FOV circles", Default = true, Flag = "showFov", NoList = true })
	world:AddColor({ Text = "Aimbot circle color", Default = Color3.fromRGB(122, 152, 244), Flag = "fovColor" })
	world:AddToggle({ Text = "Crosshair", Flag = "crosshair" })
	world:AddSlider({ Text = "Crosshair size", Min = 2, Max = 30, Default = 8, Increment = 1, Flag = "crosshairSize" })
	world:AddSlider({ Text = "Crosshair gap", Min = 0, Max = 20, Default = 4, Increment = 1, Flag = "crosshairGap" })
	world:AddColor({ Text = "Crosshair color", Default = Color3.new(1, 1, 1), Flag = "crosshairColor" })
	world:AddSection("Lighting")
	world:AddToggle({ Text = "Fullbright", Flag = "fullbright", Callback = applyFullbright })
	world:AddToggle({ Text = "No fog", Flag = "noFog" })
	world:AddToggle({ Text = "Time of day", Flag = "timeChanger" })
	world:AddSlider({ Text = "Clock time", Min = 0, Max = 24, Default = 14, Increment = 0.5, Flag = "timeValue" })
	world:AddSection("Camera")
	world:AddToggle({ Text = "Camera FOV", Flag = "fovChanger" })
	world:AddSlider({ Text = "Camera FOV value", Min = 40, Max = 120, Default = 90, Increment = 1, Flag = "fovValue" })
	world:AddToggle({ Text = "Unlimited zoom", Flag = "unlimitedZoom" })
	world:AddToggle({ Text = "Spectate nearest to cursor", Flag = "spectate" })

	-- Misc --------------------------------------------------------------------------------------------------------
	window:CreateCategory("Misc")
	local misc = window:CreateTab("Misc", "sliders-horizontal", "Utilities")
	misc:AddSection("Session")
	misc:AddToggle({ Text = "Anti-AFK", Default = true, Flag = "antiAfk", NoList = true })
	misc:AddButton({ Text = "Rejoin server", Callback = function()
		teleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, localPlayer)
	end })
	misc:AddButton({ Text = "Copy server JobId", Callback = function()
		setclipboard(game.JobId)
		window:Notify({ Title = "Copied", Text = game.JobId })
	end })

	-- Live target card beside the window.
	window:AddWidget({ Title = "Target", Icon = "crosshair", Kind = "stat", Get = function()
		return currentInfo.name, currentInfo.name == "-" and 0 or math.clamp(1 - currentInfo.distance / 300, 0, 1), currentInfo.name == "-" and "none in range" or currentInfo.part
	end })
end

-- Lifecycle -------------------------------------------------------------------------------------------------------------

function DaHood.init()
	if not table.find(PLACE_IDS, game.PlaceId) then
		warn("[DaHood] wrong place, expected Da Hood")
		return
	end

	mainEvent = replicatedStorage:WaitForChild("MainEvent")
	DaHood.mainEvent = mainEvent
	DaHood.redirectEnabled = false
	DaHood.redirectTarget = function()
		if not flag("silentAim") then return nil end

		return findTarget(silentSettings())
	end

	buildUi()
	installSilentAim()
	installBulletRedirect()

	-- Drawing objects that do not belong to a player.
	aimCircle = newDrawing("Circle", { Thickness = 1.5, NumSides = 64, Filled = false, Visible = false, Transparency = 1 })
	silentCircle = newDrawing("Circle", { Thickness = 1.5, NumSides = 64, Filled = false, Visible = false, Transparency = 1 })

	table.insert(connections, runService.RenderStepped:Connect(function()
		xpcall(function()
			stepAimbot()
			stepEsp()
			stepFovCircles()
			stepCrosshair()
		end, onError)
	end))

	table.insert(connections, runService.Heartbeat:Connect(function(deltaTime)
		xpcall(function()
			stepMovement(deltaTime)
			stepTriggerBot()
			stepAutoActions()
			stepHitboxes()
			stepRapidFire()
			stepAutoFire()
			stepChams()
			stepNeon()
			stepWorld()
			stepSpectate()
		end, onError)
	end))

	table.insert(connections, userInputService.JumpRequest:Connect(function()
		if not flag("infiniteJump") then return end

		local character = localCharacter()
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end
	end))

	table.insert(connections, localPlayer.Idled:Connect(function()
		if not flag("antiAfk") then return end

		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.new())
	end))

	table.insert(connections, playersService.PlayerRemoving:Connect(removeEsp))

	window:Notify({ Title = "Da Hood", Text = "Loaded. RightShift toggles the menu.", Duration = 5 })
end

function DaHood.detach()
	if detaching then return end
	detaching = true
	DaHood.redirectEnabled = false

	for _, connection in connections do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(connections)

	restoreSilentAim()
	restoreFireRate()
	applyFullbright(false)
	restoreWorld()
	if zoomBackup then localPlayer.CameraMaxZoomDistance = zoomBackup end
	for part, saved in neonBackup do
		if part.Parent then part.Material, part.Color = saved.material, saved.color end
	end
	table.clear(neonBackup)
	if chamFolder then pcall(function() chamFolder:Destroy() end) end
	table.clear(chamObjects)
	if spectating then
		local mine = localCharacter()
		local humanoid = mine and mine:FindFirstChildOfClass("Humanoid")
		local camera = workspace.CurrentCamera
		if humanoid and camera then camera.CameraSubject = humanoid end
	end
	for root, saved in hitboxBackup do
		if root.Parent then root.Size, root.Transparency, root.CanCollide = saved.size, saved.transparency, saved.collide end
	end
	table.clear(hitboxBackup)
	for part in noclipParts do
		if part.Parent then part.CanCollide = true end
	end
	table.clear(noclipParts)

	for _, object in drawings do
		pcall(function() object:Remove() end)
	end
	table.clear(drawings)
	table.clear(espObjects)

	if ui then pcall(function() ui:Destroy() end) end
	if shared.DaHoodHub == DaHood then shared.DaHoodHub = nil end
end

shared.DaHoodHub = DaHood
xpcall(DaHood.init, onError)

return DaHood
