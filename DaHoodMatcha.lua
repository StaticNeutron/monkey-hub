-- Da Hood hub, Matcha edition (the Potassium edition is DaHoodHub.lua).
-- Matcha is an external LuaVM: no Instance, no hooks, no debug.setupvalue. Everything here is built from what Matcha does
-- have, verified live on place 2788229376:
--   * RegisterModel         native C++ player ESP (optional, on top of the Drawing ESP)
--   * Drawing               ESP boxes / skeleton / tracers / arrows / FOV circles / crosshair / HUD, pooled and reused
--   * WorldToScreen         render-callback only, so everything that projects runs in RenderStepped
--   * mousemoverel          aimbot (closed loop on the cursor) and flick shot
--   * mouse1click / keypress  trigger bot, auto fire, auto stomp (E), auto reload (R), anti-AFK
--   * getgc / setgc         WalkSpeed boost through the game's own speed table
--   * iskeypressed          hotkeys, fly input, panic key
--   * writefile / HttpService JSON   config save and load
--   * notify, GetPingValue, UI.AddTab   toasts, ping readout, native menu
-- Not possible on Matcha (no hooks, no hybrid FireServer): silent aim, bullet TP, rapid fire, chams, lighting, spectate.

-- Singleton: replace a previous instance.
if _G.DaHoodMatcha then
	pcall(_G.DaHoodMatcha.detach)
end

local DaHood = {}

-- Constants.
local PLACE_IDS = { [2788229376] = true, [88976059384565] = true }
local POOL_SIZE = 40
local COLLECT_INTERVAL = 0.25
local CONFIG_FILE = "DaHoodMatcha.json"
local ESP_FONT = 2
local TARGET_PARTS = { "Head", "UpperTorso", "HumanoidRootPart", "Closest" }
local DEFAULT_COLOR = Color3.fromRGB(122, 152, 244)
local KNOCKED_COLOR = Color3.fromRGB(240, 96, 112)
local WHITE = Color3.new(1, 1, 1)
local BOX_TOP = Vector3.new(0, 3.1, 0)
local BOX_BOTTOM = Vector3.new(0, 3.4, 0)
local INFO_COLOR = Color3.fromRGB(210, 205, 200)
local WEAPON_COLOR = Color3.fromRGB(240, 190, 110)
local LOOK_COLOR = Color3.fromRGB(255, 220, 120)
local FLICK_COLOR = Color3.fromRGB(240, 170, 90)
local HUD_COLOR = Color3.fromRGB(235, 232, 226)

-- Windows virtual-key codes.
local VK = {
	W = 0x57, A = 0x41, S = 0x53, D = 0x44, Q = 0x51, E = 0x45, R = 0x52, Z = 0x5A, X = 0x58, V = 0x56, C = 0x43, J = 0x4A, Y = 0x59, H = 0x48, G = 0x47,
	SPACE = 0x20, SHIFT = 0x10, CTRL = 0x11, END = 0x23, F15 = 0x7E,
}

-- Hotkeys polled with iskeypressed (Matcha does not raise InputBegan for every key).
local HOTKEYS = {
	aimbot = VK.Z, fly = VK.X, noclip = VK.V, flick = VK.C, panic = VK.END,
	hitbox = VK.J, timer = VK.Y, targetHover = VK.H, desync = VK.G,
}

-- Bone pairs for the skeleton.
local SKELETON = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}

-- Best-guess flag names for RegisterModel; Matcha accepts any table here, so wrong names simply draw nothing extra.
local NATIVE_FLAGS = { Box = true, Name = true, Health = true, Distance = true, Skeleton = true, Tool = true }

-- Every setting, with its default. The UI layer binds controls to these keys.
local DEFAULTS = {
	aimbot = false, aimMode = "Hold RMB", aimPart = "Head", aimFov = 160, aimSmooth = 6, aimPrediction = 0,
	aimWall = false, aimKnocked = true, aimProtected = true, aimDistance = 0,
	flick = false, flickPart = "Head", flickFov = 200, flickWall = false,
	triggerBot = false, triggerDelay = 0.08, triggerWall = true,
	autoFire = false, fireDelay = 0.06, autoStomp = false, stompRange = 8, autoReload = false,
	hitbox = false, hitboxPart = "HumanoidRootPart", hitboxSize = 8, hitboxHeight = 0, hitboxRange = 0, hitboxSkipKnocked = true,
	hitboxShow = false, hitboxType = "Old",
	timer = false, timerFire = true, timerMelee = true, timerMeleeRate = 0.12, timerMargin = 0.015, timerReload = true, timerStomp = true,
	godmode = false, godDryRun = true, godRadius = 5, godDistance = 12, godCooldown = 0.25, godLeash = 30, godMaxRange = 0, godReturn = false,
	fly = false, flySpeed = 150, flyBoost = 2, speed = false, speedValue = 40, noclip = false, infiniteJump = false,
	fovChanger = false, fovValue = 90,
	esp = true, espBox = true, espCorner = false, espName = true, espInfo = true, espHealth = true, espWeapon = false,
	espSkeleton = false, espHeadDot = false, espLook = false, espArrows = false, espTracer = false, espTracerFrom = "Bottom",
	espDistance = 0, espHeavyLimit = 6, espRate = 0, nativeEsp = false,
	showFov = true, crosshair = false, crosshairSize = 8, crosshairGap = 4, hud = true,
	-- Combat extras
	teamCheck = false, aimSticky = true, aimType = "Mouse", rageMethod = false, resolver = false, aimPredictMode = "Fixed", aimPredictPing = 1,
	flickDistance = 0, triggerHitboxMul = 1, triggerRelease = 10,
	-- Visual extras
	espTeamCheck = false, espVisibleCheck = false, espOutline = true, espTextBg = false, espGlow = false, espSelf = false,
	espSizing = "Static", espBoxFill = false, espBox3d = false, espNameMode = "Name", espHeadGlow = false, espAvatar = false,
	espArmorBar = false, espHealthBased = true, espHealthText = false, espHealthTextPos = "Above Name", espFlags = false,
	chams = false, chamsFilled = true, chamsAlpha = 0.5, chamsPulse = false, arrowSize = 14, arrowRadius = 38,
	radar = false, radarTeamCheck = false, radarSize = 110, radarRange = 150, radarX = 150, radarY = 260,
	-- World extras
	infAmmo = false, rapidFire = false, clickTp = false, waypointTween = false, waypointSpeed = 200, waypointShow = true, flyRate = 5,
	-- Character extras
	hitboxTeamCheck = false, jumpBoost = false, jumpPower = 50, timerMultiply = 1,
	targetHover = false, hoverMethod = "Closest To Mouse", hoverRadius = 25, hoverSpeed = 18.72, hoverHeight = 6, hoverCircle = true,
	desync = false, desyncUseTick = false, desyncInterval = 10, desyncReset = false, desyncShow = true,
	antiAfk = true,
}

-- Toggles the panic key and the "turn everything off" button switch back off.
local FEATURE_TOGGLES = {
	"aimbot", "flick", "triggerBot", "autoFire", "autoStomp", "autoReload", "hitbox", "fly", "speed", "noclip",
	"infiniteJump", "fovChanger", "nativeEsp", "crosshair", "timer", "godmode",
	"infAmmo", "rapidFire", "clickTp", "jumpBoost", "targetHover", "desync", "radar", "chams",
}

-- Services.
local playersService = game:GetService("Players")
local runService = RunService
local okHttp, httpService = pcall(function() return game:GetService("HttpService") end)

-- State.
local localPlayer = playersService.LocalPlayer
local localName = localPlayer.Name
local mouse = localPlayer:GetMouse()
local cfg = {}
local connections = {}
local detaching = false
local drawings = {}
local pool = {}
local poolShown = 0
local targets = {}
local me = { character = nil, root = nil, humanoid = nil, tool = nil, parts = {}, ammo = nil, reloading = nil }
local ignoredFolder = nil
local nativeHandles = {}
local hitboxApplied = {}
local noclipApplied = {}
local stickyName = nil
local lastTrigger = 0
local lastFire = 0
local lastStomp = 0
local lastReload = 0
local lastJump = 0
local lastAfk = 0
local lastFly = 0
local lastHitbox = 0
local lastNoclip = 0
local lastHud = 0
local flying = false
local flicking = false
local fpsValue = 60
local renderMs = 0
local collectMs = 0
local cursorX, cursorY = 0, 0
local lastEsp = 0
local recordCache = {}
local wasHolding = false
local hitboxWrites = 0
local godState = { lastCheck = 0, lastThreat = 0, lastDodge = 0, lastLog = 0, anchor = nil, flip = false, dodges = 0, threats = 0 }
local reclick
local MELEE_TOOLS = { Combat = true, ["[Knife]"] = true, ["[Bat]"] = true, ["[Pitchfork]"] = true, ["[StopSign]"] = true, ["[Shovel]"] = true, ["[Katana]"] = true }
local HITBOX_COLOR = Color3.fromRGB(255, 120, 90)
local HEAD_TOP = Vector3.new(0, 1.0, 0)
local FEET_BOTTOM = Vector3.new(0, 3.2, 0)
local BOX3D_HALF = Vector3.new(1.6, 3, 1)
local BOX3D_EDGES = {}
local GREEN = Color3.fromRGB(70, 255, 100)
local BLACK = Color3.new(0, 0, 0)
local VISIBLE_COLOR = Color3.fromRGB(170, 200, 255)
local HIDDEN_COLOR = Color3.fromRGB(255, 70, 70)
local ARMOR_COLOR = Color3.fromRGB(90, 160, 255)
local CHAMS_COLOR = Color3.fromRGB(122, 152, 244)
local RADAR_BACK = Color3.fromRGB(20, 22, 28)
local RAPID_COOLDOWN = 0.01
local FLY_GRAVITY_BIAS = 24

-- Corners are indexed 0..7 by three bits (x, y, z); an edge joins two corners that differ in exactly one bit.
for first = 0, 7 do
	for second = first + 1, 7 do
		local difference = bit32.bxor(first, second)
		if difference == 1 or difference == 2 or difference == 4 then
			BOX3D_EDGES[#BOX3D_EDGES + 1] = { first + 1, second + 1 }
		end
	end
end

local selfRecord = nil
local avatarCache, avatarQueued, avatarQueue = {}, {}, {}
local radar = nil
local waypoints, waypointCounter, waypointDraws = {}, 0, {}
local tweenTarget, tweenLast = nil, 0
local hoverState = { angle = 0, lastPick = 0, lastWrite = 0, name = nil, record = nil, lines = {} }
local desyncState = { active = false, anchor = nil }
local desyncMarker = nil
local lastRapid = 0
local lastAmmo = 0
local cameraMemory = { address = nil, base = nil, failedAt = 0 }
local rapidBackup = {}
local clickTpWasDown, jumpBoostWasDown = false, false
local flyLast = nil
local sameTeam
local gunCooldown

-- Queues a headshot download; drawRecord shows it once avatarCache has the bytes (false marks a failed download).
---@param userId number
local function requestAvatar(userId)
	if avatarCache[userId] ~= nil or avatarQueued[userId] then return end

	avatarQueued[userId] = true
	avatarQueue[#avatarQueue + 1] = userId
end
local collectTick = 0
local fpsFrames = 0
local fpsSince = tick()
local drawingState = {}
local healthColors = {}
local cameraFovBackup = nil
local speedState = { applied = nil, base = 16, pendingSince = 0, pendingValue = nil, busy = false }
local keyWasDown = {}
local hudLines = {}
local hudHeader = nil
local aimCircle = nil
local flickCircle = nil
local crosshairLines = {}
local currentInfo = { name = "-", distance = 0, part = "" }
local uiTabs = {}

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.IgnoreWater = true

for key, value in pairs(DEFAULTS) do
	cfg[key] = value
end

-- Helpers ---------------------------------------------------------------------------------------------------------------

---@param message string
local function log(message)
	print("[DaHood] " .. message)
end

---@param failure string
local function onError(failure)
	warn("[DaHood] error: " .. tostring(failure))
end

---@param text string
---@param seconds number
local function toast(text, seconds)
	pcall(notify, "Da Hood", text, seconds or 3)
end

---@param key string
---@param default number
---@return number
local function numberSetting(key, default)
	local value = cfg[key]
	return type(value) == "number" and value or default
end

-- True only while Roblox has focus, so injected input never lands in another window.
---@return boolean
local function gameActive()
	return isrbxactive() == true
end

---@param keycode number
---@return boolean
local function keyDown(keycode)
	return iskeypressed(keycode) == true
end

-- Returns true once per physical press.
---@param name string
---@param keycode number
---@return boolean
local function keyPressedEdge(name, keycode)
	local down = keyDown(keycode)
	local was = keyWasDown[name]
	keyWasDown[name] = down
	return down and not was
end

-- Presses and releases a key without yielding the caller.
---@param keycode number
local function tapKey(keycode)
	task.spawn(function()
		keypress(keycode)
		task.wait(0.05)
		keyrelease(keycode)
	end)
end

-- Config ----------------------------------------------------------------------------------------------------------------

function DaHood.saveConfig()
	if not okHttp then return false end

	local success = pcall(function()
		writefile(CONFIG_FILE, httpService:JSONEncode(cfg))
	end)
	return success
end

function DaHood.loadConfig()
	if not okHttp then return false end

	local success, decoded = pcall(function()
		if not isfile(CONFIG_FILE) then return nil end
		return httpService:JSONDecode(readfile(CONFIG_FILE))
	end)
	if not (success and type(decoded) == "table") then return false end

	for key, default in pairs(DEFAULTS) do
		local saved = decoded[key]
		if saved ~= nil and type(saved) == type(default) then
			cfg[key] = saved
		end
	end
	return true
end

function DaHood.resetConfig()
	for key, value in pairs(DEFAULTS) do
		cfg[key] = value
	end
end

function DaHood.panic()
	for _, key in ipairs(FEATURE_TOGGLES) do
		cfg[key] = false
	end
	DaHood.syncUi()
	toast("All features disabled", 2)
end

-- Collector (slow loop: all tree lookups happen here, the renderer only reads) ---------------------------------------------

local function collectMe()
	local character = localPlayer.Character
	me.character = character
	me.root = character and character:FindFirstChild("HumanoidRootPart")
	me.humanoid = character and character:FindFirstChildOfClass("Humanoid")
	me.tool = character and character:FindFirstChildOfClass("Tool")
	me.ammo = me.tool and me.tool:FindFirstChild("Ammo")
	me.cooldownValue = me.ammo and me.tool:FindFirstChild("ShootingCooldown")
	me.maxAmmo = me.ammo and me.tool:FindFirstChild("MaxAmmo")
	local effects = character and character:FindFirstChild("BodyEffects")
	me.reloading = effects and effects:FindFirstChild("Reload")
	me.mouseValue = effects and effects:FindFirstChild("MousePos")
	local team = localPlayer.Team
	me.teamName = team and team.Name

	local parts = {}
	if character then
		for _, child in ipairs(character:GetChildren()) do
			local class = child.ClassName
			if class == "Part" or class == "MeshPart" then
				parts[#parts + 1] = child
			end
		end
	end
	me.parts = parts
end

-- Static references for one character (FindFirstChild costs ~0.4 ms each, so this runs once per character, not every tick).
---@param player table
---@param character table
---@param wantSkeleton boolean
---@return table?
local function buildRecord(player, character, wantSkeleton)
	local root = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not (root and head and humanoid) then return nil end

	local effects = character:FindFirstChild("BodyEffects")
	local record = {
		name = player.Name,
		address = character.Address,
		character = character,
		root = root,
		head = head,
		torso = character:FindFirstChild("UpperTorso") or root,
		humanoid = humanoid,
		knockedValue = effects and effects:FindFirstChild("K.O"),
		-- BodyEffects.MousePos is the world point that player is aiming at (the game replicates it for every player).
		mousePosValue = effects and effects:FindFirstChild("MousePos"),
		userId = player.UserId,
		armorValue = effects and effects:FindFirstChild("Armor"),
		armor = 0,
		health = 100, maxHealth = 100, knocked = false, protected = false, tool = nil, sortDistance = 0, rank = 999,
	}

	if wantSkeleton then
		-- Shared joints are projected once each: 15 parts instead of 28.
		local joints, indexOf, bones = {}, {}, {}
		local function joint(name)
			local index = indexOf[name]
			if index then return index end

			local part = character:FindFirstChild(name)
			if not part then return nil end

			index = #joints + 1
			joints[index] = part
			indexOf[name] = index
			return index
		end
		for _, pair in ipairs(SKELETON) do
			local first, second = joint(pair[1]), joint(pair[2])
			if first and second then bones[#bones + 1] = { first, second } end
		end
		record.joints, record.bones = joints, bones
	end

	return record
end

local function collectTargets()
	local wantSkeleton = cfg.espSkeleton == true or cfg.chams == true
	local out = {}
	local seen = {}
	local myPosition = me.root and me.root.Position
	collectTick = collectTick + 1
	-- ForceField and the held tool are looked up by class (slow), so they refresh once a second.
	local slowRefresh = collectTick % 4 == 0

	for _, player in ipairs(playersService:GetPlayers()) do
		local name = player.Name
		if name == localName then continue end

		local character = player.Character
		if not character then continue end

		local record = recordCache[name]
		if not record or record.address ~= character.Address or (wantSkeleton and not record.joints) then
			record = buildRecord(player, character, wantSkeleton)
			if not record then continue end

			record.fresh = true
			recordCache[name] = record
		end
		seen[name] = true

		-- Slow-changing values are refreshed here (4 Hz) instead of every frame: each memory read costs ~0.04 ms.
		local humanoid = record.humanoid
		record.health = humanoid.Health
		record.maxHealth = humanoid.MaxHealth
		local knockedValue = record.knockedValue
		record.knocked = knockedValue ~= nil and knockedValue.Value == true
		if slowRefresh or record.fresh then
			record.protected = character:FindFirstChildOfClass("ForceField") ~= nil
			local team = player.Team
			record.teamName = team and team.Name
			local tool = character:FindFirstChildOfClass("Tool")
			record.tool = tool
			record.ammoValue = tool and tool:FindFirstChild("Ammo")
			record.rangeValue = record.ammoValue and tool:FindFirstChild("Range")
			record.fresh = false
		end
		local armorNow = record.armorValue and record.armorValue.Value
		record.armor = type(armorNow) == "number" and armorNow or 0
		local position = record.root.Position
		record.sortDistance = myPosition and (position - myPosition).Magnitude or 0
		-- Resolver: velocity from where the player actually moved between collector ticks, not the (spoofable) physics velocity.
		if cfg.resolver then
			local previous = record.lastPosition
			local now = tick()
			if previous and now - record.lastTime > 0.05 then
				record.resolvedVelocity = (position - previous) / (now - record.lastTime)
			end
			record.lastPosition, record.lastTime = position, now
		end

		out[#out + 1] = record
	end

	for name in pairs(recordCache) do
		if not seen[name] then recordCache[name] = nil end
	end

	-- Nearest first: the heavy ESP parts (skeleton, look line, head dot) only run for the closest few.
	table.sort(out, function(a, b) return a.sortDistance < b.sortDistance end)
	for index, record in ipairs(out) do
		record.rank = index
	end

	-- Visible check for the nearest players only: one raycast each, four times a second.
	if cfg.espVisibleCheck then
		local camera = workspace.CurrentCamera
		local origin = camera and camera.CFrame.Position
		if origin then
			for index = 1, math.min(#out, 12) do
				local record = out[index]
				local ignore = { record.character }
				if me.character then ignore[#ignore + 1] = me.character end
				if ignoredFolder then ignore[#ignore + 1] = ignoredFolder end
				wallParams.FilterDescendantsInstances = ignore
				record.visible = workspace:Raycast(origin, record.head.Position - origin, wallParams) == nil
			end
		end
	end

	-- Self ESP: my own character gets a record too, but it is never part of the target list.
	if cfg.espSelf and me.character and me.root then
		if not selfRecord or selfRecord.address ~= me.character.Address or (wantSkeleton and not selfRecord.joints) then
			selfRecord = buildRecord(localPlayer, me.character, wantSkeleton)
			if selfRecord then selfRecord.rank = 1 end
		end
		if selfRecord then
			selfRecord.health = selfRecord.humanoid.Health
			selfRecord.maxHealth = selfRecord.humanoid.MaxHealth
			local value = selfRecord.knockedValue
			selfRecord.knocked = value ~= nil and value.Value == true
			selfRecord.tool, selfRecord.ammoValue = me.tool, me.ammo
			local armorValue = selfRecord.armorValue and selfRecord.armorValue.Value
			selfRecord.armor = type(armorValue) == "number" and armorValue or 0
		end
	else
		selfRecord = nil
	end

	targets = out
	ignoredFolder = workspace:FindFirstChild("Ignored")
end

---@param record table
---@return boolean
local function isKnocked(record)
	return record.knocked == true
end

-- Native ESP: one RegisterModel entry per character, re-registered on respawn --------------------------------------------

local function removeNative(name)
	local entry = nativeHandles[name]
	if entry then
		pcall(function() entry.handle:Remove() end)
		nativeHandles[name] = nil
	end
end

local function syncNative()
	if not cfg.nativeEsp then
		for name in pairs(nativeHandles) do
			removeNative(name)
		end
		return
	end

	local alive = {}
	for _, record in ipairs(targets) do
		alive[record.name] = true
		local entry = nativeHandles[record.name]
		local address = record.character.Address
		if entry and entry.address ~= address then
			removeNative(record.name)
			entry = nil
		end

		if not entry then
			local character, head, root, humanoid = record.character, record.head, record.root, record.humanoid
			local success, handle = pcall(RegisterModel, {
				entry = character,
				ShouldDraw = function() return cfg.nativeEsp == true and humanoid.Health > 0 end,
				GetHead = function() return head end,
				GetRoot = function() return root end,
				GetTool = function() return character:FindFirstChildOfClass("Tool") end,
				GetDisplayName = function() return record.name end,
				GetHealth = function() return humanoid.Health end,
				GetMaxHealth = function() return humanoid.MaxHealth end,
				Flags = NATIVE_FLAGS,
			})
			if success and handle then
				nativeHandles[record.name] = { handle = handle, address = address }
			end
		end
	end

	for name in pairs(nativeHandles) do
		if not alive[name] then removeNative(name) end
	end
end

-- Drawing helpers -------------------------------------------------------------------------------------------------------

---@param class string
---@param props table
---@return table?
local function newDrawing(class, props)
	local success, object = pcall(Drawing.new, class)
	if not success or not object then return nil end

	for key, value in pairs(props) do
		object[key] = value
	end
	drawings[#drawings + 1] = object
	drawingState[object] = {}
	return object
end

-- Creates a drawing inside a pool slot the first time an element is needed; the object is then reused forever.
---@param slotTable table
---@param key string
---@param class string
---@param props table
---@return table?
local function element(slotTable, key, class, props)
	local object = slotTable[key]
	if object then return object end

	object = newDrawing(class, props)
	slotTable[key] = object
	return object
end

-- Red to green in 5% steps; the Color3 objects are built once so the property cache can compare them by reference.
---@param fraction number
---@return table
local function healthColor(fraction)
	local step = math.floor(fraction * 20 + 0.5)
	local color = healthColors[step]
	if not color then
		local value = step / 20
		color = Color3.fromRGB(math.floor(255 * (1 - value)), math.floor(255 * value), 80)
		healthColors[step] = color
	end
	return color
end

---@param index number
---@return table
local function getSlot(index)
	local slotTable = pool[index]
	if not slotTable then
		slotTable = {}
		pool[index] = slotTable
	end
	return slotTable
end

-- Screen box around a root position (two projections): x, y, width, height, centerX; nil when either end is off screen.
---@param position table
---@return number?, number?, number?, number?, number?
local function screenBox(position)
	local top, topVisible = WorldToScreen(position + BOX_TOP)
	local bottom, bottomVisible = WorldToScreen(position - BOX_BOTTOM)
	if not (topVisible and bottomVisible) then return nil end

	local height = math.abs(bottom.Y - top.Y)
	local width = height * 0.55
	local centerX = (top.X + bottom.X) / 2
	return centerX - width / 2, top.Y, width, height, centerX
end

-- Targeting (render thread: uses WorldToScreen) ---------------------------------------------------------------------------

-- True when something solid sits between the camera and the part.
---@param camera table
---@param record table
---@param part table
---@return boolean
local function isWalled(camera, record, part)
	local ignore = { record.character }
	if me.character then ignore[#ignore + 1] = me.character end
	if ignoredFolder then ignore[#ignore + 1] = ignoredFolder end
	wallParams.FilterDescendantsInstances = ignore

	local origin = camera.CFrame.Position
	return workspace:Raycast(origin, part.Position - origin, wallParams) ~= nil
end

---@param record table
---@param choice string
---@param cursor table
---@return table?
local function pickPart(record, choice, cursor)
	if choice == "Head" then return record.head end
	if choice == "UpperTorso" then return record.torso end
	if choice == "HumanoidRootPart" then return record.root end

	local best, bestDistance = nil, math.huge
	for _, part in ipairs({ record.head, record.torso, record.root }) do
		local screen, visible = WorldToScreen(part.Position)
		if visible then
			local distance = math.sqrt((screen.X - cursor.X) ^ 2 + (screen.Y - cursor.Y) ^ 2)
			if distance < bestDistance then best, bestDistance = part, distance end
		end
	end
	return best
end

-- Best target inside the FOV circle: { record, part, screen, distance, position } or nil.
---@param camera table
---@param settings table fov, partChoice, wall, knocked, protected, maxDistance, prediction, sticky
---@return table?
local function findTarget(camera, settings)
	if not me.root then return nil end

	local cursor = Vector2.new(cursorX, cursorY)
	local myPosition = me.root.Position
	local candidates = {}

	for _, record in ipairs(targets) do
		if record.health <= 0 then continue end
		if settings.knocked and isKnocked(record) then continue end
		if settings.protected and record.protected then continue end
		if settings.team and sameTeam(record) then continue end

		local part = pickPart(record, settings.partChoice, cursor)
		if not part then continue end

		local partPosition = part.Position
		local worldDistance = (partPosition - myPosition).Magnitude
		if settings.maxDistance > 0 and worldDistance > settings.maxDistance then continue end

		local screen, visible = WorldToScreen(partPosition)
		if not visible then continue end

		local distance = math.sqrt((screen.X - cursor.X) ^ 2 + (screen.Y - cursor.Y) ^ 2)
		-- The previous target keeps a wider circle so the aim does not flick between two close players.
		local limit = (settings.sticky == record.name) and settings.fov * 1.4 or settings.fov
		if distance > limit then continue end

		local score = (settings.sticky == record.name) and distance * 0.5 or distance
		candidates[#candidates + 1] = { record = record, part = part, screen = screen, distance = worldDistance, score = score }
	end

	table.sort(candidates, function(a, b) return a.score < b.score end)

	-- Wall check only on the few best candidates: raycasts are the expensive part.
	for index = 1, math.min(#candidates, 3) do
		local candidate = candidates[index]
		if not (settings.wall and isWalled(camera, candidate.record, candidate.part)) then
			local position = candidate.part.Position
			if settings.prediction > 0 then
				local velocity = settings.resolver and candidate.record.resolvedVelocity or candidate.part.AssemblyLinearVelocity
				position = position + velocity * settings.prediction
			end
			candidate.position = position
			local screen, visible = WorldToScreen(position)
			if visible then
				candidate.screen = screen
				return candidate
			end
		end
	end
	return nil
end

-- Prediction time: a fixed value, or a multiple of the current ping.
---@return number
local function predictionSeconds()
	if cfg.aimPredictMode == "Ping" then
		return (GetPingValue() or 0) / 1000 * numberSetting("aimPredictPing", 1)
	end
	return numberSetting("aimPrediction", 0)
end

---@return table
local function aimbotSettings()
	return {
		fov = numberSetting("aimFov", 160), partChoice = cfg.aimPart or "Head", wall = cfg.aimWall == true,
		knocked = cfg.aimKnocked ~= false, protected = cfg.aimProtected ~= false,
		maxDistance = numberSetting("aimDistance", 0), prediction = predictionSeconds(), sticky = cfg.aimSticky ~= false and stickyName or nil,
		team = cfg.teamCheck == true, resolver = cfg.resolver == true,
	}
end

---@return table
local function flickSettings()
	return {
		fov = numberSetting("flickFov", 200), partChoice = cfg.flickPart or "Head", wall = cfg.flickWall == true,
		knocked = true, protected = true, maxDistance = numberSetting("flickDistance", 0), prediction = predictionSeconds(), sticky = nil,
		team = cfg.teamCheck == true, resolver = cfg.resolver == true,
	}
end

-- Memory aim: the camera's rotation matrix is written straight into the camera object's memory. The layout (nine floats, then the
-- position, at a fixed offset) is found by matching the live CFrame and verified before any write, so a changed engine layout
-- disables it instead of corrupting memory.
---@param camera table
---@return number?
local function cameraRotationBase(camera)
	local address = camera.Address
	if cameraMemory.address == address and cameraMemory.base then return cameraMemory.base end
	-- A failed search is not repeated every frame (it reads ~380 floats).
	if tick() - cameraMemory.failedAt < 5 then return nil end

	local frame = camera.CFrame
	local position = frame.Position
	local components = { frame:GetComponents() }
	for offset = 0x10, 0x600, 4 do
		local x = memory_read("float", address + offset)
		if type(x) == "number" and math.abs(x - position.X) < 0.02 then
			local y, z = memory_read("float", address + offset + 4), memory_read("float", address + offset + 8)
			if math.abs(y - position.Y) < 0.02 and math.abs(z - position.Z) < 0.02 then
				local base = offset - 36
				local matches = true
				for index = 1, 9 do
					if math.abs(memory_read("float", address + base + (index - 1) * 4) - components[3 + index]) > 0.005 then
						matches = false
						break
					end
				end
				if matches then
					cameraMemory.address, cameraMemory.base = address, base
					return base
				end
			end
		end
	end

	cameraMemory.failedAt = tick()
	return nil
end

---@param camera table
---@param desired table
---@return boolean
local function writeCameraRotation(camera, desired)
	local base = cameraRotationBase(camera)
	if not base then return false end

	local components = { desired:GetComponents() }
	local address = camera.Address
	for index = 1, 9 do
		memory_write("float", address + base + (index - 1) * 4, components[3 + index])
	end
	return true
end

-- Moves the cursor towards the target a fraction of the remaining distance each frame (closed loop, so a pixel-scale mismatch
-- only changes how fast it converges).
---@param camera table
local function stepAimbot(camera)
	if not cfg.aimbot then
		stickyName = nil
		currentInfo.name = "-"
		return
	end

	local mode = cfg.aimMode or "Hold RMB"
	local active = mode == "Always" or (mode == "Hold RMB" and ismouse2pressed())
	if not (active and gameActive()) then
		stickyName = nil
		return
	end

	local target = findTarget(camera, aimbotSettings())
	if not target then
		stickyName = nil
		currentInfo.name = "-"
		return
	end

	stickyName = target.record.name
	currentInfo.name, currentInfo.distance, currentInfo.part = target.record.name, target.distance, target.part.Name

	local smoothing = numberSetting("aimSmooth", 6)
	local alpha = smoothing <= 1 and 1 or math.clamp(1 / smoothing, 0.02, 1)
	-- Rage: no smoothing at all.
	if cfg.rageMethod then alpha = 1 end
	if cfg.aimType == "Memory" then
		local desired = CFrame.lookAt(camera.CFrame.Position, target.position)
		local frame = alpha >= 1 and desired or camera.CFrame:Lerp(desired, alpha)
		-- If the camera layout could not be verified this falls through to the Camera method below.
		if writeCameraRotation(camera, frame) then return end
	end
	if cfg.aimType ~= "Mouse" then
		-- Camera teleport: turn the camera onto the target (the game rewrites it every frame, so this snaps rather than drifts).
		local desired = CFrame.lookAt(camera.CFrame.Position, target.position)
		camera.CFrame = alpha >= 1 and desired or camera.CFrame:Lerp(desired, alpha)
		return
	end
	local deltaX, deltaY = (target.screen.X - cursorX) * alpha, (target.screen.Y - cursorY) * alpha
	-- mousemoverel takes integers; keep sub-pixel moves alive by rounding away from zero.
	deltaX = deltaX >= 0 and math.ceil(deltaX) or math.floor(deltaX)
	deltaY = deltaY >= 0 and math.ceil(deltaY) or math.floor(deltaY)
	if deltaX ~= 0 or deltaY ~= 0 then
		mousemoverel(deltaX, deltaY)
	end
end

-- Flick shot: snap the cursor onto the target, click, snap back. Experimental; a hotkey press runs it once.
---@param camera table
local function startFlick(camera)
	if flicking or not (cfg.flick and gameActive()) then return end

	local target = findTarget(camera, flickSettings())
	if not target then return end

	flicking = true
	local startX, startY = cursorX, cursorY
	local deltaX, deltaY = math.floor(target.screen.X - startX + 0.5), math.floor(target.screen.Y - startY + 0.5)

	task.spawn(function()
		mousemoverel(deltaX, deltaY)
		task.wait(0.04)
		mouse1click()
		task.wait(0.04)
		-- Return by what the cursor actually travelled, not by what was requested.
		mousemoverel(math.floor(startX - mouse.X + 0.5), math.floor(startY - mouse.Y + 0.5))
		flicking = false
	end)
end

-- Fires when the cursor sits inside an enemy's box and nothing blocks the view.
---@param camera table
local function stepTriggerBot(camera)
	if not cfg.triggerBot then return end
	if tick() - lastTrigger < numberSetting("triggerDelay", 0.08) then return end
	if not (gameActive() and me.tool and me.ammo) then return end

	local cx, cy = cursorX, cursorY
	for _, record in ipairs(targets) do
		if record.health <= 0 or isKnocked(record) or record.protected then continue end
		if cfg.teamCheck and sameTeam(record) then continue end

		-- Cheap reject first: one projection of the head; the full box only when the cursor is anywhere near.
		local rootPosition = record.root.Position
		local headScreen, headVisible = WorldToScreen(rootPosition)
		if not headVisible then continue end
		local near = math.abs(headScreen.X - cx) < 400 and math.abs(headScreen.Y - cy) < 400
		if not near then continue end

		local x, y, width, height = screenBox(rootPosition)
		local scale = numberSetting("triggerHitboxMul", 1)
		if x and scale ~= 1 then
			x, y, width, height = x - width * (scale - 1) / 2, y - height * (scale - 1) / 2, width * scale, height * scale
		end
		if x and cx >= x and cx <= x + width and cy >= y and cy <= y + height then
			if cfg.triggerWall and isWalled(camera, record, record.torso) then continue end

			lastTrigger = tick()
			-- Hold the button for "Release" milliseconds, like a quick human click.
			local releaseMs = numberSetting("triggerRelease", 10)
			if releaseMs > 0 then
				task.spawn(function()
					mouse1press()
					task.wait(releaseMs / 1000)
					mouse1release()
				end)
			else
				mouse1click()
			end
			return
		end
	end
end

-- Weapons and auto actions (heartbeat) ------------------------------------------------------------------------------------

local function stepAutoActions()
	if not (me.root and gameActive()) then return end
	local now = tick()
	local timerOn = cfg.timer == true
	local multiply = timerOn and math.max(numberSetting("timerMultiply", 1), 1) or 1
	local holding = ismouse1pressed()

	-- A fresh physical press already fired once; start the cadence clock from it.
	if holding and not wasHolding then lastFire = now end
	wasHolding = holding

	if holding and me.tool then
		local interval = nil
		if me.ammo then
			if timerOn and cfg.timerFire then
				-- Timer: click exactly when the gun's own ShootingCooldown has run out (plus a small margin), not on a human rhythm.
				local base = gunCooldown() or numberSetting("fireDelay", 0.06)
				interval = base + numberSetting("timerMargin", 0.015)
			elseif cfg.autoFire then
				interval = numberSetting("fireDelay", 0.06)
			end
		elseif timerOn and cfg.timerMelee and MELEE_TOOLS[me.tool.Name] then
			interval = numberSetting("timerMeleeRate", 0.12) / multiply
		end

		if interval and now - lastFire >= interval then
			lastFire = now
			reclick()
		end
	end

	-- Auto stomp: Da Hood stomps on E when a knocked player is in reach. The timer shortens the repeat gap.
	local stompGap = (timerOn and cfg.timerStomp) and 0.15 / multiply or 0.5
	if (cfg.autoStomp or (timerOn and cfg.timerStomp)) and now - lastStomp > stompGap then
		local reach = numberSetting("stompRange", 8)
		for _, record in ipairs(targets) do
			if isKnocked(record) and (record.root.Position - me.root.Position).Magnitude <= reach then
				lastStomp = now
				tapKey(VK.E)
				break
			end
		end
	end

	-- Auto reload: the equipped gun is empty and not already reloading. The timer shortens the guard.
	local reloadGap = (timerOn and cfg.timerReload) and math.max(0.35 / multiply, 0.1) or 1.2
	if (cfg.autoReload or (timerOn and cfg.timerReload)) and now - lastReload > reloadGap and me.ammo and me.ammo.Value == 0 then
		if not (me.reloading and me.reloading.Value) then
			lastReload = now
			tapKey(VK.R)
		end
	end
end

-- Hitbox expander ---------------------------------------------------------------------------------------------------------------

-- Parts the expander resizes on one player.
---@param record table
---@return table
local function hitboxParts(record)
	local choice = cfg.hitboxPart or "HumanoidRootPart"
	if choice == "Head" then return { record.head } end
	if choice == "UpperTorso" then return { record.torso } end
	if choice == "Head + Torso" then return { record.head, record.torso } end
	return { record.root }
end

-- Client-side bigger body parts on everyone else (Matcha writes game memory, so nothing replicates; the shooter's own raycast is
-- what sees the larger part). Every 0.4 s: restore parts that no longer qualify, apply new ones, and re-apply any the game reset.
local function stepHitboxes()
	local now = tick()
	if now - lastHitbox < 0.4 then return end
	lastHitbox = now

	local desired = {}
	if cfg.hitbox then
		local width = numberSetting("hitboxSize", 8)
		local height = numberSetting("hitboxHeight", 0)
		if height <= 0 or cfg.hitboxType == "Uniform" then height = width end
		local range = numberSetting("hitboxRange", 0)
		local skipKnocked = cfg.hitboxSkipKnocked ~= false

		for _, record in ipairs(targets) do
			record.hitW, record.hitH, record.hitPart = nil, nil, nil
			if record.health <= 0 then continue end
			if skipKnocked and isKnocked(record) then continue end
			if cfg.hitboxTeamCheck and sameTeam(record) then continue end
			if range > 0 and record.sortDistance > range then continue end

			for index, part in ipairs(hitboxParts(record)) do
				desired[part.Address] = { part = part, width = width, height = height }
				if index == 1 then
					record.hitW, record.hitH, record.hitPart = width, height, part
				end
			end
		end
	end

	for address, entry in pairs(hitboxApplied) do
		if not desired[address] then
			pcall(function()
				entry.part.Size = entry.size
				entry.part.CanCollide = entry.collide
			end)
			hitboxApplied[address] = nil
		end
	end

	for address, want in pairs(desired) do
		local part = want.part
		if not hitboxApplied[address] then
			-- The original size is captured before the first write so it can always be restored.
			hitboxApplied[address] = { part = part, size = part.Size, collide = part.CanCollide }
		end

		local current = part.Size
		if math.abs(current.X - want.width) > 0.01 or math.abs(current.Y - want.height) > 0.01 then
			part.Size = Vector3.new(want.width, want.height, want.width)
			part.CanCollide = false
			hitboxWrites = hitboxWrites + 1
		end
	end
end

-- Godmode: predictive bullet dodge ---------------------------------------------------------------------------------------------

-- Left button re-press while it is physically held: release then press, so the OS state ends "down" and ismouse1pressed keeps
-- reporting the hold (a plain click would end it).
function reclick()
	mouse1release()
	mouse1press()
end

-- A landing spot a short way along a direction: not through a wall, with floor underneath. Returns a Vector3 or nil.
---@param origin table
---@param direction table
---@param distance number
---@return table?
local function findSafeSpot(origin, direction, distance)
	local ignore = { me.character }
	if ignoredFolder then ignore[#ignore + 1] = ignoredFolder end
	wallParams.FilterDescendantsInstances = ignore

	local wall = workspace:Raycast(origin + Vector3.new(0, 1, 0), direction * distance, wallParams)
	local reach = wall and (wall.Distance - 1.5) or distance
	if reach < 4 then return nil end

	local spot = origin + direction * reach
	local down = Vector3.new(0, -14, 0)
	local floor = workspace:Raycast(spot + Vector3.new(0, 2, 0), down, wallParams)
	if not floor then return nil end

	-- Keep the same height above the ground I am standing on now.
	local ground = workspace:Raycast(origin, down, wallParams)
	local height = ground and math.clamp(origin.Y - ground.Position.Y, 2.5, 6) or 3
	return Vector3.new(spot.X, floor.Position.Y + height, spot.Z)
end

-- Guns in Da Hood are hitscan and the shooter's client reports the hit, so a bullet cannot be dodged after it is fired. What can be
-- done is to never stand on a loaded gun's aim line: each player's BodyEffects.MousePos is where they are aiming, so when a line
-- from their head through that point passes within a few studs of me (and the gun has ammo and range), I sidestep off the line.
local function stepDodge()
	if not (cfg.godmode and me.root and gameActive()) then return end

	local now = tick()
	if now - godState.lastCheck < 0.033 then return end
	godState.lastCheck = now

	local myPosition = me.root.Position
	if now - godState.lastThreat > 3 then godState.anchor = myPosition end

	local radius = numberSetting("godRadius", 5)
	local rangeCap = numberSetting("godMaxRange", 0)
	local threat = nil

	for _, record in ipairs(targets) do
		local ammo, aimValue = record.ammoValue, record.mousePosValue
		if not (ammo and aimValue) or record.health <= 0 or record.knocked then continue end

		local range = record.rangeValue and record.rangeValue.Value
		if type(range) ~= "number" or range <= 0 then range = 200 end
		if rangeCap > 0 then range = math.min(range, rangeCap) end
		-- sortDistance is from the 4 Hz collector, hence the margin.
		if record.sortDistance > range + 25 then continue end
		if ammo.Value <= 0 then continue end

		local aim = aimValue.Value
		if typeof(aim) ~= "Vector3" then continue end

		local origin = record.head.Position
		local toAim = aim - origin
		if toAim.Magnitude < 1 then continue end

		local direction = toAim.Unit
		local toMe = myPosition - origin
		local along = toMe:Dot(direction)
		if along < 0 or along > range + 10 then continue end

		-- Distance from me to the aim line; the allowance grows a little with range because the aim point jitters.
		local offAxis = (toMe - direction * along).Magnitude
		if offAxis <= radius + along * 0.015 then
			threat = { record = record, direction = direction, offAxis = offAxis }
			break
		end
	end

	if not threat then return end
	godState.lastThreat = now
	godState.threats = godState.threats + 1
	if now - godState.lastDodge < numberSetting("godCooldown", 0.25) then return end
	godState.lastDodge = now

	-- Sidestep perpendicular to the aim line, alternating sides; head back toward the anchor once the leash is exceeded.
	local side = Vector3.new(-threat.direction.Z, 0, threat.direction.X)
	if side.Magnitude < 0.1 then side = Vector3.new(1, 0, 0) end
	side = side.Unit
	godState.flip = not godState.flip
	local sign = godState.flip and 1 or -1
	local anchor = godState.anchor
	if anchor and (myPosition - anchor).Magnitude > numberSetting("godLeash", 30) then
		sign = ((anchor - myPosition):Dot(side) >= 0) and 1 or -1
	end

	local distance = numberSetting("godDistance", 12)
	local destination = findSafeSpot(myPosition, side * sign, distance) or findSafeSpot(myPosition, side * -sign, distance)
	if not destination then return end

	godState.dodges = godState.dodges + 1
	if cfg.godDryRun then
		if now - godState.lastLog > 1 then
			godState.lastLog = now
			log(string.format("dodge (dry run): %s is aiming at you, %.1f studs off their line", threat.record.name, threat.offAxis))
		end
		return
	end

	me.root.Position = destination
	if cfg.godReturn then
		task.delay(0.35, function()
			if me.root and not detaching then me.root.Position = myPosition end
		end)
	end
end

-- Movement (heartbeat) ----------------------------------------------------------------------------------------------------

-- WalkSpeed lives in a table inside the game, so it is changed through setgc (a full heap scan, hence debounced and run on its
-- own thread). The previous value is passed as the filter so only the matching number is touched.
local function stepSpeed()
	local want = cfg.speed and numberSetting("speedValue", 40) or speedState.base
	if speedState.busy or want == speedState.applied then
		speedState.pendingValue = nil
		return
	end
	if speedState.applied == nil and want == speedState.base then return end

	-- Let a dragged slider settle before paying for a scan.
	if speedState.pendingValue ~= want then
		speedState.pendingValue = want
		speedState.pendingSince = tick()
		return
	end
	if tick() - speedState.pendingSince < 0.6 then return end

	speedState.busy = true
	local previous = speedState.applied or speedState.base
	task.spawn(function()
		local success = pcall(setgc, "WalkSpeed", want, previous)
		if success then speedState.applied = want end
		speedState.busy = false
	end)
end

local function stepNoclip()
	local now = tick()
	if now - lastNoclip < 0.2 then return end
	lastNoclip = now

	if cfg.noclip or cfg.fly then
		for _, part in ipairs(me.parts) do
			local address = part.Address
			if not noclipApplied[address] then
				part.CanCollide = false
				noclipApplied[address] = part
			end
		end
	else
		for address, part in pairs(noclipApplied) do
			pcall(function() part.CanCollide = true end)
			noclipApplied[address] = nil
		end
	end
end

local function stepJump()
	if not (cfg.infiniteJump and me.root and gameActive()) then
		keyWasDown.jump = keyDown(VK.SPACE)
		return
	end

	if keyPressedEdge("jump", VK.SPACE) and tick() - lastJump > 0.12 then
		lastJump = tick()
		local velocity = me.root.AssemblyLinearVelocity
		me.root.AssemblyLinearVelocity = Vector3.new(velocity.X, 50, velocity.Z)
	end
end

---@param camera table
local function stepCameraFov(camera)
	if cfg.fovChanger then
		if not cameraFovBackup then cameraFovBackup = camera.FieldOfView end
		camera.FieldOfView = numberSetting("fovValue", 90)
	elseif cameraFovBackup then
		camera.FieldOfView = cameraFovBackup
		cameraFovBackup = nil
	end
end

local HOTKEY_TOGGLES = {
	{ "aimbot", "Aimbot" }, { "fly", "Fly" }, { "noclip", "Noclip" }, { "hitbox", "Hitbox expander" }, { "timer", "Timer" },
	{ "targetHover", "Target hover" }, { "desync", "Desync" },
}

local function stepHotkeys()
	if not gameActive() then return end

	for _, entry in ipairs(HOTKEY_TOGGLES) do
		local key = entry[1]
		if keyPressedEdge("hk" .. key, HOTKEYS[key]) then
			cfg[key] = not cfg[key]
			DaHood.syncUi()
			toast(entry[2] .. (cfg[key] and " ON" or " OFF"), 1.5)
		end
	end

	if keyPressedEdge("hkPanic", HOTKEYS.panic) then
		DaHood.panic()
	end
	if keyPressedEdge("hkFlick", HOTKEYS.flick) then
		DaHood.flickRequested = true
	end
end

local function stepAntiAfk()
	if not cfg.antiAfk then return end
	if tick() - lastAfk < 240 then return end

	lastAfk = tick()
	-- F15 is bound to nothing in Roblox or Da Hood; any input resets the idle timer.
	tapKey(VK.F15)
end

-- Rendering -------------------------------------------------------------------------------------------------------------------

-- Every Drawing setter crosses into the host process, so a property is only written when its value actually changed.
---@param object table
---@param prop string
---@param value any
local function put(object, prop, value)
	local state = drawingState[object]
	if state[prop] == value then return end

	state[prop] = value
	object[prop] = value
end

---@param object table
---@param prop string
---@param x number
---@param y number
local function putVec(object, prop, x, y)
	local state = drawingState[object]
	local last = state[prop]
	if last and last.X == x and last.Y == y then return end

	local value = Vector2.new(x, y)
	state[prop] = value
	object[prop] = value
end

---@param slotTable table
---@param x number
---@param y number
---@param width number
---@param height number
---@param color table
---@param visible boolean
local function drawCorners(slotTable, x, y, width, height, color, visible)
	if not visible then
		for index = 1, 8 do
			local line = slotTable["corner" .. index]
			if line then put(line, "Visible", false) end
		end
		return
	end

	local length = math.min(width, height) * 0.3
	local right, bottom = x + width, y + height
	local segments = {
		{ x, y, x + length, y }, { x, y, x, y + length },
		{ right, y, right - length, y }, { right, y, right, y + length },
		{ x, bottom, x + length, bottom }, { x, bottom, x, bottom - length },
		{ right, bottom, right - length, bottom }, { right, bottom, right, bottom - length },
	}
	for index, segment in ipairs(segments) do
		local line = element(slotTable, "corner" .. index, "Line", { Thickness = 1.5, Visible = false })
		if line then
			put(line, "Visible", true)
			putVec(line, "From", segment[1], segment[2])
			putVec(line, "To", segment[3], segment[4])
			put(line, "Color", color)
		end
	end
end

-- Arrow on a ring around the screen centre pointing at a player who is off screen.
---@param slotTable table
---@param camera table
---@param position table
---@param color table
local function drawArrow(slotTable, camera, position, color)
	local relative = camera.CFrame:PointToObjectSpace(position)
	local angle = math.atan2(relative.X, -relative.Z)
	local viewport = camera.ViewportSize
	local centerX, centerY = viewport.X / 2, viewport.Y / 2
	local radius = math.min(viewport.X, viewport.Y) * numberSetting("arrowRadius", 38) / 100
	local scale = numberSetting("arrowSize", 14) / 14
	local dirX, dirY = math.sin(angle), -math.cos(angle)
	local sideX, sideY = -dirY, dirX
	local baseX, baseY = centerX + dirX * radius, centerY + dirY * radius

	local arrow = element(slotTable, "arrow", "Triangle", { Filled = true, Thickness = 1, Visible = false })
	if arrow then
		put(arrow, "Visible", true)
		putVec(arrow, "PointA", baseX + dirX * 14 * scale, baseY + dirY * 14 * scale)
		putVec(arrow, "PointB", baseX - dirX * 6 * scale + sideX * 9 * scale, baseY - dirY * 6 * scale + sideY * 9 * scale)
		putVec(arrow, "PointC", baseX - dirX * 6 * scale - sideX * 9 * scale, baseY - dirY * 6 * scale - sideY * 9 * scale)
		put(arrow, "Color", color)
	end
end

-- Hides a slot once; later frames skip it until it is used again.
---@param slotTable table
local function parkSlot(slotTable)
	if slotTable.parked then return end

	slotTable.parked = true
	for key, object in pairs(slotTable) do
		if key ~= "parked" and key ~= "avatarUserId" then put(object, "Visible", false) end
	end
end

-- Small drawing helpers: create on first use, then only write what changed -------------------------------------------------

---@param slotTable table
---@param key string
local function hideKey(slotTable, key)
	local object = slotTable[key]
	if object then put(object, "Visible", false) end
end

---@param slotTable table
---@param key string
---@param x number
---@param y number
---@param width number
---@param height number
---@param color table
---@param thickness number
---@param filled boolean
---@param zIndex number
---@param alpha number?
local function setSquare(slotTable, key, x, y, width, height, color, thickness, filled, zIndex, alpha)
	local object = element(slotTable, key, "Square", { Visible = false })
	if not object then return end

	put(object, "Filled", filled)
	put(object, "Thickness", thickness)
	put(object, "ZIndex", zIndex)
	if alpha then put(object, "Transparency", alpha) end
	putVec(object, "Position", x, y)
	putVec(object, "Size", width, height)
	put(object, "Color", color)
	put(object, "Visible", true)
end

---@param slotTable table
---@param key string
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param color table
---@param thickness number
---@param alpha number?
local function setLine(slotTable, key, x1, y1, x2, y2, color, thickness, alpha)
	local object = element(slotTable, key, "Line", { Visible = false })
	if not object then return end

	put(object, "Thickness", thickness)
	if alpha then put(object, "Transparency", alpha) end
	putVec(object, "From", x1, y1)
	putVec(object, "To", x2, y2)
	put(object, "Color", color)
	put(object, "Visible", true)
end

---@param slotTable table
---@param key string
---@param text string
---@param x number
---@param y number
---@param color table
---@param size number
---@param center boolean
local function setText(slotTable, key, text, x, y, color, size, center)
	local object = element(slotTable, key, "Text", { Outline = true, Font = ESP_FONT, Visible = false })
	if not object then return end

	put(object, "Size", size)
	put(object, "Center", center)
	put(object, "Text", text)
	putVec(object, "Position", x, y)
	put(object, "Color", color)
	put(object, "Visible", true)
end

---@param slotTable table
---@param key string
---@param x number
---@param y number
---@param radius number
---@param color table
---@param filled boolean
---@param thickness number
---@param alpha number?
local function setCircle(slotTable, key, x, y, radius, color, filled, thickness, alpha)
	local object = element(slotTable, key, "Circle", { NumSides = 20, Visible = false })
	if not object then return end

	put(object, "Filled", filled)
	put(object, "Thickness", thickness)
	if alpha then put(object, "Transparency", alpha) end
	putVec(object, "Position", x, y)
	put(object, "Radius", radius)
	put(object, "Color", color)
	put(object, "Visible", true)
end

-- Box from the head and the feet (the "Bounding" sizing type): x, y, width, height, centerX or nil when off screen.
---@param record table
---@param rootPosition table
---@return number?, number?, number?, number?, number?
local function boundingBox(record, rootPosition)
	local top, topVisible = WorldToScreen(record.head.Position + HEAD_TOP)
	local bottom, bottomVisible = WorldToScreen(rootPosition - FEET_BOTTOM)
	if not (topVisible and bottomVisible) then return nil end

	local height = math.abs(bottom.Y - top.Y)
	local width = height * 0.55
	local centerX = (top.X + bottom.X) / 2
	return centerX - width / 2, top.Y, width, height, centerX
end

-- Oriented 3D box around the root part: 12 edges. Falls back to nothing when a corner is behind the camera.
---@param slotTable table
---@param record table
---@param color table
---@return boolean
local function draw3dBox(slotTable, record, color)
	local frame = record.root.CFrame
	local screenX, screenY = {}, {}
	local index = 0
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				index = index + 1
				local screen, visible = WorldToScreen(frame:PointToWorldSpace(Vector3.new(sx * BOX3D_HALF.X, sy * BOX3D_HALF.Y, sz * BOX3D_HALF.Z)))
				if not visible then return false end
				screenX[index], screenY[index] = screen.X, screen.Y
			end
		end
	end

	for edge, pair in ipairs(BOX3D_EDGES) do
		local first, second = pair[1], pair[2]
		setLine(slotTable, "edge" .. edge, screenX[first], screenY[first], screenX[second], screenY[second], color, 1)
	end
	return true
end

---@param slotTable table
local function hide3dBox(slotTable)
	for edge = 1, 12 do hideKey(slotTable, "edge" .. edge) end
end

-- Draws one player into a pool slot.
---@param slotTable table
---@param record table
---@param rootPosition table
---@param distance number
---@param camera table
---@param view table
local function drawRecord(slotTable, record, rootPosition, distance, camera, view)
	local knocked = record.knocked == true
	local tint
	if knocked then
		tint = KNOCKED_COLOR
	elseif cfg.espVisibleCheck then
		tint = record.visible and VISIBLE_COLOR or HIDDEN_COLOR
	else
		tint = DEFAULT_COLOR
	end

	local x, y, width, height, centerX
	if cfg.espSizing == "Bounding" then
		x, y, width, height, centerX = boundingBox(record, rootPosition)
	else
		x, y, width, height, centerX = screenBox(rootPosition)
	end

	if not x then
		parkSlot(slotTable)
		if cfg.espArrows then
			slotTable.parked = false
			drawArrow(slotTable, camera, rootPosition, tint)
		end
		return
	end
	slotTable.parked = false
	hideKey(slotTable, "arrow")

	local heavy = record.rank <= view.heavyLimit
	local outline = cfg.espOutline == true

	-- Box: 2D, corner or 3D, with optional outline, fill and glow.
	local boxOn = cfg.espBox == true
	local drew3d = false
	if boxOn and cfg.espBox3d and heavy then
		drew3d = draw3dBox(slotTable, record, tint)
	end
	if not drew3d then hide3dBox(slotTable) end

	if boxOn and not drew3d and not cfg.espCorner then
		if outline then setSquare(slotTable, "boxOutline", x, y, width, height, BLACK, 3, false, 1) else hideKey(slotTable, "boxOutline") end
		setSquare(slotTable, "box", x, y, width, height, tint, 1, false, 2)
	else
		hideKey(slotTable, "boxOutline")
		hideKey(slotTable, "box")
	end
	drawCorners(slotTable, x, y, width, height, tint, boxOn and not drew3d and cfg.espCorner == true)

	if boxOn and cfg.espBoxFill then
		setSquare(slotTable, "boxFill", x, y, width, height, tint, 1, true, 0, 0.25)
	else
		hideKey(slotTable, "boxFill")
	end
	if boxOn and cfg.espGlow then
		setSquare(slotTable, "boxGlow", x - 2, y - 2, width + 4, height + 4, tint, 5, false, 0, 0.3)
	else
		hideKey(slotTable, "boxGlow")
	end

	-- Name, with an optional background plate and an optional health readout above it.
	local labelY = y - 16
	if cfg.espName then
		local label = knocked and (record.name .. " [KO]") or record.name
		if cfg.espNameMode == "Name + Tool" and record.tool then label = label .. " [" .. record.tool.Name .. "]" end
		if cfg.espTextBg then
			local plate = #label * 7 + 8
			setSquare(slotTable, "nameBg", centerX - plate / 2, labelY - 1, plate, 15, BLACK, 1, true, 1, 0.5)
		else
			hideKey(slotTable, "nameBg")
		end
		setText(slotTable, "name", label, centerX, labelY, WHITE, 13, true)
	else
		hideKey(slotTable, "name")
		hideKey(slotTable, "nameBg")
	end

	if cfg.espHealthText then
		local text = string.format("%d HP", math.floor(record.health))
		local position = cfg.espHealthTextPos or "Above Name"
		if position == "Beside Bar" then
			setText(slotTable, "healthText", text, x - 6, y + height / 2 - 6, WHITE, 11, false)
		elseif position == "Below Box" then
			setText(slotTable, "healthText", text, centerX, y + height + 28, WHITE, 12, true)
		else
			setText(slotTable, "healthText", text, centerX, y - 30, WHITE, 12, true)
		end
	else
		hideKey(slotTable, "healthText")
	end

	if cfg.espInfo then
		setText(slotTable, "info", string.format("%dm  %d HP", math.floor(distance), math.floor(record.health)), centerX, y + height + 2, INFO_COLOR, 12, true)
	else
		hideKey(slotTable, "info")
	end

	if cfg.espWeapon and record.tool then
		setText(slotTable, "weapon", record.tool.Name, centerX, y + height + 15, WEAPON_COLOR, 12, true)
	else
		hideKey(slotTable, "weapon")
	end

	-- Health bar (colour follows health unless "Health based" is off) and armor bar.
	if cfg.espHealth then
		-- Quantised to 5% steps so the colour object only changes when the bar visibly moves.
		local fraction = math.floor(math.clamp(record.health / math.max(record.maxHealth, 1), 0, 1) * 20 + 0.5) / 20
		local color = cfg.espHealthBased == false and GREEN or healthColor(fraction)
		setLine(slotTable, "healthBar", x - 4, y + height, x - 4, y + height - height * fraction, color, 2)
	else
		hideKey(slotTable, "healthBar")
	end
	if cfg.espArmorBar and record.armor > 0 then
		local fraction = math.clamp(record.armor / 100, 0, 1)
		setLine(slotTable, "armorBar", x - 8, y + height, x - 8, y + height - height * fraction, ARMOR_COLOR, 2)
	else
		hideKey(slotTable, "armorBar")
	end

	-- Silhouette flags to the right of the box.
	if cfg.espFlags then
		local row = 0
		local function flagLine(text, color)
			row = row + 1
			setText(slotTable, "flag" .. row, text, x + width + 4, y + (row - 1) * 11, color, 10, false)
		end
		if knocked then flagLine("KO", KNOCKED_COLOR) end
		if record.protected then flagLine("SHIELD", WEAPON_COLOR) end
		if record.ammoValue then flagLine("ARMED", WHITE) end
		if record.armor > 0 then flagLine("ARMOR", ARMOR_COLOR) end
		for index = row + 1, 4 do hideKey(slotTable, "flag" .. index) end
	else
		for index = 1, 4 do hideKey(slotTable, "flag" .. index) end
	end

	-- Head dot, its glow, and the look line: only for the nearest players.
	local wantDot = cfg.espHeadDot and heavy
	local wantGlow = cfg.espHeadGlow and heavy
	if wantDot or wantGlow then
		local headScreen, headVisible = WorldToScreen(record.head.Position)
		local dotRadius = math.max(2, math.floor(height * 0.07))
		if headVisible and wantDot then
			setCircle(slotTable, "headDot", headScreen.X, headScreen.Y, dotRadius, tint, false, 1)
		else
			hideKey(slotTable, "headDot")
		end
		if headVisible and wantGlow then
			setCircle(slotTable, "headGlow", headScreen.X, headScreen.Y, dotRadius * 2, tint, true, 1, 0.3)
		else
			hideKey(slotTable, "headGlow")
		end
	else
		hideKey(slotTable, "headDot")
		hideKey(slotTable, "headGlow")
	end

	if cfg.espLook and heavy then
		local from, fromVisible = WorldToScreen(record.head.Position)
		local to, toVisible = WorldToScreen(record.head.Position + record.head.CFrame.LookVector * 8)
		if fromVisible and toVisible then
			setLine(slotTable, "look", from.X, from.Y, to.X, to.Y, LOOK_COLOR, 1.5)
		else
			hideKey(slotTable, "look")
		end
	else
		hideKey(slotTable, "look")
	end

	-- Skeleton and silhouette chams share one projection of the joints.
	local wantSkeleton = cfg.espSkeleton and heavy
	local wantChams = cfg.chams and heavy
	if (wantSkeleton or wantChams) and record.joints then
		local jointX, jointY, jointVisible = {}, {}, {}
		for index, part in ipairs(record.joints) do
			local screen, visible = WorldToScreen(part.Position)
			jointX[index], jointY[index], jointVisible[index] = screen.X, screen.Y, visible
		end

		local chamThickness = math.max(2, height * 0.09)
		local chamAlpha = numberSetting("chamsAlpha", 0.5)
		if cfg.chamsPulse then chamAlpha = 0.25 + 0.5 * math.abs(math.sin(tick() * 2)) end
		for index = 1, #SKELETON do
			local bone = record.bones[index]
			local ok = bone and jointVisible[bone[1]] and jointVisible[bone[2]]
			if ok and wantSkeleton then
				setLine(slotTable, "bone" .. index, jointX[bone[1]], jointY[bone[1]], jointX[bone[2]], jointY[bone[2]], tint, 1.3)
			else
				hideKey(slotTable, "bone" .. index)
			end
			if ok and wantChams then
				local thickness = cfg.chamsFilled == false and 1.5 or chamThickness
				setLine(slotTable, "cham" .. index, jointX[bone[1]], jointY[bone[1]], jointX[bone[2]], jointY[bone[2]], CHAMS_COLOR, thickness, chamAlpha)
			else
				hideKey(slotTable, "cham" .. index)
			end
		end
	else
		for index = 1, #SKELETON do
			hideKey(slotTable, "bone" .. index)
			hideKey(slotTable, "cham" .. index)
		end
	end

	if cfg.espTracer then
		local fromX, fromY = view.width / 2, view.height
		if view.tracerFrom == "Center" then
			fromY = view.height / 2
		elseif view.tracerFrom == "Mouse" then
			fromX, fromY = cursorX, cursorY
		elseif view.tracerFrom == "Top" then
			fromY = 0
		end
		setLine(slotTable, "tracer", fromX, fromY, centerX, y + height, tint, 1)
	else
		hideKey(slotTable, "tracer")
	end

	-- Hitbox expander outline.
	if cfg.hitbox and cfg.hitboxShow and record.hitW then
		local center = record.hitPart.Position
		local half = Vector3.new(0, record.hitH / 2, 0)
		local topPoint, topVisible = WorldToScreen(center + half)
		local bottomPoint, bottomVisible = WorldToScreen(center - half)
		if topVisible and bottomVisible then
			local boxHeight = math.abs(bottomPoint.Y - topPoint.Y)
			local boxWidth = boxHeight * record.hitW / record.hitH
			setSquare(slotTable, "hitbox", (topPoint.X + bottomPoint.X) / 2 - boxWidth / 2, topPoint.Y, boxWidth, boxHeight, HITBOX_COLOR, 1, false, 2)
		else
			hideKey(slotTable, "hitbox")
		end
	else
		hideKey(slotTable, "hitbox")
	end

	-- Profile picture above the name; the image bytes come from the avatar cache (fetched in the background).
	if cfg.espAvatar then
		local bytes = avatarCache[record.userId]
		if bytes == nil then
			requestAvatar(record.userId)
			hideKey(slotTable, "avatar")
		elseif bytes ~= false then
			local image = element(slotTable, "avatar", "Image", { Visible = false })
			if image then
				if slotTable.avatarUserId ~= record.userId then
					image.Data = bytes
					slotTable.avatarUserId = record.userId
				end
				putVec(image, "Size", 24, 24)
				putVec(image, "Position", centerX - 12, labelY - 28)
				put(image, "Visible", true)
			end
		end
	else
		hideKey(slotTable, "avatar")
	end
end

---@param camera table
local function stepEsp(camera)
	local shown = 0
	local viewport = camera.ViewportSize
	local view = {
		cameraPosition = camera.CFrame.Position,
		maxDistance = numberSetting("espDistance", 0),
		heavyLimit = numberSetting("espHeavyLimit", 6),
		tracerFrom = cfg.espTracerFrom or "Bottom",
		width = viewport.X, height = viewport.Y,
	}

	if cfg.esp then
		local function consider(record)
			if shown >= POOL_SIZE then return end
			if record.health <= 0 then return end
			if cfg.espTeamCheck and sameTeam(record) then return end

			-- The root position is read once per player per frame (each memory read costs ~0.04 ms).
			local rootPosition = record.root.Position
			local distance = (view.cameraPosition - rootPosition).Magnitude
			if view.maxDistance > 0 and distance > view.maxDistance then return end

			shown = shown + 1
			drawRecord(getSlot(shown), record, rootPosition, distance, camera, view)
		end

		for _, record in ipairs(targets) do
			consider(record)
		end
		if cfg.espSelf and selfRecord and selfRecord.health > 0 then
			consider(selfRecord)
		end
	end

	-- Slots used last frame but not this one.
	for index = shown + 1, poolShown do
		if pool[index] then parkSlot(pool[index]) end
	end
	poolShown = shown
end

local function stepOverlays()
	if aimCircle then
		put(aimCircle, "Visible", cfg.aimbot == true and cfg.showFov == true)
		putVec(aimCircle, "Position", cursorX, cursorY)
		put(aimCircle, "Radius", numberSetting("aimFov", 160))
		put(aimCircle, "Color", DEFAULT_COLOR)
	end
	if flickCircle then
		put(flickCircle, "Visible", cfg.flick == true and cfg.showFov == true)
		putVec(flickCircle, "Position", cursorX, cursorY)
		put(flickCircle, "Radius", numberSetting("flickFov", 200))
		put(flickCircle, "Color", FLICK_COLOR)
	end

	local enabled = cfg.crosshair == true
	if #crosshairLines == 0 then
		if not enabled then return end
		for index = 1, 4 do
			crosshairLines[index] = newDrawing("Line", { Thickness = 2, Visible = false })
		end
	end
	local size, gap = numberSetting("crosshairSize", 8), numberSetting("crosshairGap", 4)
	local ends = {
		{ cursorX - gap - size, cursorY, cursorX - gap, cursorY },
		{ cursorX + gap, cursorY, cursorX + gap + size, cursorY },
		{ cursorX, cursorY - gap - size, cursorX, cursorY - gap },
		{ cursorX, cursorY + gap, cursorX, cursorY + gap + size },
	}
	for index, line in ipairs(crosshairLines) do
		put(line, "Visible", enabled)
		putVec(line, "From", ends[index][1], ends[index][2])
		putVec(line, "To", ends[index][3], ends[index][4])
		put(line, "Color", WHITE)
	end
end

-- Watermark with ping and fps, plus the list of features that are on. Refreshed four times a second.
local function stepHud()
	if not hudHeader then
		hudHeader = newDrawing("Text", { Size = 14, Outline = true, Font = ESP_FONT, Visible = false })
		for index = 1, #FEATURE_TOGGLES do
			hudLines[index] = newDrawing("Text", { Size = 12, Outline = true, Font = ESP_FONT, Visible = false })
		end
	end

	local now = tick()
	if now - lastHud < 0.25 then return end
	lastHud = now

	if not cfg.hud then
		put(hudHeader, "Visible", false)
		for _, line in ipairs(hudLines) do put(line, "Visible", false) end
		return
	end

	put(hudHeader, "Visible", true)
	put(hudHeader, "Text", string.format("Da Hood  |  Matcha  |  %d ms  |  %d fps", math.floor(GetPingValue() or 0), math.floor(fpsValue)))
	putVec(hudHeader, "Position", 12, 10)
	put(hudHeader, "Color", HUD_COLOR)

	local row = 0
	for _, key in ipairs(FEATURE_TOGGLES) do
		if cfg[key] then
			row = row + 1
			local line = hudLines[row]
			put(line, "Visible", true)
			put(line, "Text", key)
			putVec(line, "Position", 12, 10 + 18 * row)
			put(line, "Color", DEFAULT_COLOR)
		end
	end
	for index = row + 1, #hudLines do
		put(hudLines[index], "Visible", false)
	end
end

-- Extras: radar, waypoints, target hovering, desync, rapid fire, click TP, jump boost ------------------------------------------

function sameTeam(record)
	return me.teamName ~= nil and record.teamName ~= nil and me.teamName == record.teamName
end

-- Background worker that downloads headshots one at a time (two HTTP calls each: the thumbnail JSON, then the PNG bytes).
local function avatarWorker()
	while not detaching do
		local userId = table.remove(avatarQueue, 1)
		if not userId then
			task.wait(0.3)
			continue
		end

		local success, bytes = pcall(function()
			local meta = httpget("https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=" .. userId .. "&size=48x48&format=Png")
			local decoded = httpService:JSONDecode(meta)
			return httpget(decoded.data[1].imageUrl)
		end)
		avatarCache[userId] = (success and type(bytes) == "string" and #bytes > 100) and bytes or false
		task.wait(0.4)
	end
end

-- Radar -------------------------------------------------------------------------------------------------------------------------

---@return table
local function ensureRadar()
	if radar then return radar end

	radar = { dots = {} }
	radar.background = newDrawing("Circle", { NumSides = 48, Filled = true, Thickness = 1, Visible = false, Color = RADAR_BACK })
	radar.border = newDrawing("Circle", { NumSides = 48, Filled = false, Thickness = 1.5, Visible = false, Color = HUD_COLOR })
	radar.me = newDrawing("Circle", { NumSides = 12, Filled = true, Thickness = 1, Visible = false, Color = WHITE })
	return radar
end

-- Top-down radar, rotated with the camera: forward is up.
---@param camera table
local function stepRadar(camera)
	if not cfg.radar then
		if radar then
			put(radar.background, "Visible", false)
			put(radar.border, "Visible", false)
			put(radar.me, "Visible", false)
			for _, dot in ipairs(radar.dots) do put(dot, "Visible", false) end
		end
		return
	end

	local state = ensureRadar()
	local size = numberSetting("radarSize", 110)
	local range = math.max(numberSetting("radarRange", 150), 10)
	local centerX, centerY = numberSetting("radarX", 150), numberSetting("radarY", 260)

	putVec(state.background, "Position", centerX, centerY)
	put(state.background, "Radius", size)
	put(state.background, "Visible", true)
	putVec(state.border, "Position", centerX, centerY)
	put(state.border, "Radius", size)
	put(state.border, "Visible", true)
	putVec(state.me, "Position", centerX, centerY)
	put(state.me, "Radius", 3)
	put(state.me, "Visible", true)

	local look, right = camera.CFrame.LookVector, camera.CFrame.RightVector
	local lookLength = math.sqrt(look.X * look.X + look.Z * look.Z)
	if lookLength < 0.01 then lookLength = 1 end
	local lookX, lookZ = look.X / lookLength, look.Z / lookLength
	local cameraPosition = camera.CFrame.Position

	local used = 0
	for _, record in ipairs(targets) do
		if record.health <= 0 then continue end
		if cfg.radarTeamCheck and sameTeam(record) then continue end

		local position = record.root.Position
		local dx, dz = position.X - cameraPosition.X, position.Z - cameraPosition.Z
		local sideways = dx * right.X + dz * right.Z
		local forward = dx * lookX + dz * lookZ
		local distance = math.sqrt(sideways * sideways + forward * forward)
		local scale = size / range
		local pointX, pointY = sideways * scale, forward * scale
		if distance > range then
			pointX, pointY = sideways / distance * size, forward / distance * size
		end

		used = used + 1
		local dot = state.dots[used]
		if not dot then
			dot = newDrawing("Circle", { NumSides = 12, Filled = true, Thickness = 1, Visible = false })
			state.dots[used] = dot
		end
		putVec(dot, "Position", centerX + pointX, centerY - pointY)
		put(dot, "Radius", 3)
		put(dot, "Color", record.knocked and KNOCKED_COLOR or DEFAULT_COLOR)
		put(dot, "Visible", true)
	end
	for index = used + 1, #state.dots do
		put(state.dots[index], "Visible", false)
	end
end

-- Waypoints ---------------------------------------------------------------------------------------------------------------------

---@param name string?
---@return string?
function DaHood.createWaypoint(name)
	if not me.root then return nil end

	if not name or name == "" then
		waypointCounter = waypointCounter + 1
		name = "WP" .. waypointCounter
	end
	waypoints[#waypoints + 1] = { name = name, position = me.root.Position }
	return name
end

---@param name string
function DaHood.removeWaypoint(name)
	for index, waypoint in ipairs(waypoints) do
		if waypoint.name == name then
			table.remove(waypoints, index)
			return true
		end
	end
	return false
end

---@return table
function DaHood.waypointNames()
	local names = {}
	for _, waypoint in ipairs(waypoints) do names[#names + 1] = waypoint.name end
	return names
end

-- Teleports to a waypoint, or starts a tween towards it when "Tween goto" is on.
---@param name string
function DaHood.gotoWaypoint(name)
	if not me.root then return end

	for _, waypoint in ipairs(waypoints) do
		if waypoint.name == name then
			if cfg.waypointTween then
				tweenTarget = waypoint.position
				tweenLast = tick()
			else
				me.root.Position = waypoint.position
			end
			return
		end
	end
end

-- Part writes cost ~25 ms each on Matcha, so the tween moves in steps about seven times a second.
local function stepWaypointTween()
	if not (tweenTarget and me.root) then return end

	local now = tick()
	if now - tweenLast < 0.14 then return end

	local step = numberSetting("waypointSpeed", 200) * (now - tweenLast)
	tweenLast = now
	local position = me.root.Position
	local offset = tweenTarget - position
	if offset.Magnitude <= step then
		me.root.Position = tweenTarget
		tweenTarget = nil
	else
		me.root.Position = position + offset.Unit * step
	end
end

---@param camera table
local function stepWaypointDraw(camera)
	local count = 0
	if cfg.waypointShow then
		local cameraPosition = camera.CFrame.Position
		for _, waypoint in ipairs(waypoints) do
			local screen, visible = WorldToScreen(waypoint.position)
			if visible then
				count = count + 1
				local entry = waypointDraws[count]
				if not entry then
					entry = {
						label = newDrawing("Text", { Size = 13, Center = true, Outline = true, Font = ESP_FONT, Visible = false }),
						marker = newDrawing("Circle", { NumSides = 16, Filled = false, Thickness = 1.5, Visible = false }),
					}
					waypointDraws[count] = entry
				end
				put(entry.label, "Text", string.format("%s  %dm", waypoint.name, math.floor((waypoint.position - cameraPosition).Magnitude)))
				putVec(entry.label, "Position", screen.X, screen.Y - 22)
				put(entry.label, "Color", WEAPON_COLOR)
				put(entry.label, "Visible", true)
				putVec(entry.marker, "Position", screen.X, screen.Y)
				put(entry.marker, "Radius", 7)
				put(entry.marker, "Color", WEAPON_COLOR)
				put(entry.marker, "Visible", true)
			end
		end
	end
	for index = count + 1, #waypointDraws do
		put(waypointDraws[index].label, "Visible", false)
		put(waypointDraws[index].marker, "Visible", false)
	end
end

-- Target hovering -----------------------------------------------------------------------------------------------------------------

---@param camera table
---@return table?
local function pickHoverTarget(camera)
	local method = cfg.hoverMethod or "Closest To Mouse"
	if method == "Closest To Mouse" then
		local target = findTarget(camera, {
			fov = 100000, partChoice = "HumanoidRootPart", wall = false, knocked = false, protected = false, maxDistance = 0,
			prediction = 0, sticky = hoverState.name, team = cfg.teamCheck == true,
		})
		return target and target.record
	end

	local best, bestValue = nil, math.huge
	for _, record in ipairs(targets) do
		if record.health <= 0 or record.knocked then continue end
		if cfg.teamCheck and sameTeam(record) then continue end

		local value = method == "Lowest Health" and record.health or record.sortDistance
		if value < bestValue then best, bestValue = record, value end
	end
	return best
end

-- Orbits my character around the chosen target. Each position write stalls ~25 ms, so it hops about six times a second.
---@param camera table
local function stepHover(camera)
	if not (cfg.targetHover and me.root) then
		hoverState.name, hoverState.record = nil, nil
		for _, line in ipairs(hoverState.lines) do put(line, "Visible", false) end
		return
	end

	local now = tick()
	if now - hoverState.lastPick > 0.25 then
		hoverState.lastPick = now
		local record = pickHoverTarget(camera)
		hoverState.record, hoverState.name = record, record and record.name
	end

	local record = hoverState.record
	if not (record and record.health > 0) then
		for _, line in ipairs(hoverState.lines) do put(line, "Visible", false) end
		return
	end

	local center = record.root.Position
	local radius = math.max(numberSetting("hoverRadius", 25), 2)

	if now - hoverState.lastWrite >= 0.17 then
		local elapsed = now - hoverState.lastWrite
		hoverState.lastWrite = now
		-- speed is studs per second along the circle, so the angle advances by speed / radius.
		hoverState.angle = hoverState.angle + numberSetting("hoverSpeed", 18.72) / radius * math.min(elapsed, 0.5)
		local destination = center + Vector3.new(math.cos(hoverState.angle) * radius, numberSetting("hoverHeight", 6), math.sin(hoverState.angle) * radius)
		me.root.Position = destination
	end

	-- Ring on the ground around the target.
	local segments = 24
	local previousX, previousY, previousVisible = nil, nil, false
	for index = 0, segments do
		local angle = index / segments * math.pi * 2
		local screen, visible = WorldToScreen(center + Vector3.new(math.cos(angle) * radius, -3, math.sin(angle) * radius))
		if index > 0 then
			local line = hoverState.lines[index]
			if not line then
				line = newDrawing("Line", { Thickness = 1.5, Visible = false, Color = HITBOX_COLOR })
				hoverState.lines[index] = line
			end
			local show = cfg.hoverCircle and visible and previousVisible
			if show then
				putVec(line, "From", previousX, previousY)
				putVec(line, "To", screen.X, screen.Y)
			end
			put(line, "Visible", show == true)
		end
		previousX, previousY, previousVisible = screen.X, screen.Y, visible
	end
end

-- Desync -------------------------------------------------------------------------------------------------------------------------

-- Lowering the physics sender rate makes the server see my position far less often than I move. getfflag does not read real
-- values on Matcha, so the effect cannot be confirmed from here.
---@param on boolean
local function applyDesync(on)
	pcall(setfflag, "DFIntS2PhysicsSenderRate", on and "1" or "15")
	desyncState.active = on
end

local function stepDesync()
	local want = cfg.desync == true
	if want and cfg.desyncUseTick then
		-- Interval mode: desynced and normal take turns, one slot every desyncInterval tenths of a second.
		local slot = math.floor(tick() / (math.max(numberSetting("desyncInterval", 10), 1) * 0.1))
		want = slot % 2 == 0
	end

	if want == desyncState.active then return end
	if want then
		desyncState.anchor = me.root and me.root.Position
	elseif cfg.desyncReset and desyncState.anchor and me.root and not cfg.desync then
		me.root.Position = desyncState.anchor
	end
	applyDesync(want)
end

-- Marks where the server last saw me while desynced.
---@param camera table
local function stepDesyncDraw(camera)
	local show = cfg.desync and cfg.desyncShow and desyncState.active and desyncState.anchor
	if not show then
		if desyncMarker then
			put(desyncMarker.circle, "Visible", false)
			put(desyncMarker.label, "Visible", false)
		end
		return
	end

	if not desyncMarker then
		desyncMarker = {
			circle = newDrawing("Circle", { NumSides = 20, Filled = false, Thickness = 2, Visible = false, Color = KNOCKED_COLOR }),
			label = newDrawing("Text", { Size = 13, Center = true, Outline = true, Font = ESP_FONT, Visible = false, Color = KNOCKED_COLOR }),
		}
	end
	local screen, visible = WorldToScreen(desyncState.anchor)
	putVec(desyncMarker.circle, "Position", screen.X, screen.Y)
	put(desyncMarker.circle, "Radius", 10)
	put(desyncMarker.circle, "Visible", visible)
	put(desyncMarker.label, "Text", "server")
	putVec(desyncMarker.label, "Position", screen.X, screen.Y - 26)
	put(desyncMarker.label, "Visible", visible)
end

-- Infinite ammo: the equipped gun's Ammo IntValue is topped up to its MaxAmmo on this client. The server keeps its own count, so this
-- only helps where the client script is what refuses to fire on an empty magazine.
local function stepInfAmmo()
	if not (cfg.infAmmo and me.ammo) then return end

	local now = tick()
	if now - lastAmmo < 0.1 then return end
	lastAmmo = now

	local maximum = me.maxAmmo and me.maxAmmo.Value
	if type(maximum) ~= "number" or maximum <= 0 then return end
	if me.ammo.Value < maximum then me.ammo.Value = maximum end
end

-- Rapid fire, click TP, jump boost ----------------------------------------------------------------------------------------------

-- The equipped gun's ShootingCooldown NumberValue is lowered on this client; the game's server keeps its own copy, so this only
-- helps if the gun script reads the value live.
local function stepRapidFire()
	local now = tick()
	if now - lastRapid < 0.25 then return end
	lastRapid = now

	if cfg.rapidFire and me.cooldownValue then
		local object = me.cooldownValue
		local address = object.Address
		if not rapidBackup[address] then
			rapidBackup[address] = { object = object, value = object.Value }
		end
		if object.Value ~= RAPID_COOLDOWN then object.Value = RAPID_COOLDOWN end
	elseif not cfg.rapidFire then
		for address, entry in pairs(rapidBackup) do
			pcall(function() entry.object.Value = entry.value end)
			rapidBackup[address] = nil
		end
	end
end

-- The gun's real cooldown, even while rapid fire has lowered the value.
---@return number?
function gunCooldown()
	local object = me.cooldownValue
	if not object then return nil end

	local backup = rapidBackup[object.Address]
	local value = backup and backup.value or object.Value
	return type(value) == "number" and value > 0 and value or nil
end

-- Hold Ctrl and click: teleport to where my mouse points (BodyEffects.MousePos is that world point).
local function stepClickTp()
	local down = cfg.clickTp == true and gameActive() and keyDown(VK.CTRL) and ismouse1pressed()
	if down and not clickTpWasDown and me.root and me.mouseValue then
		local target = me.mouseValue.Value
		if typeof(target) == "Vector3" then
			me.root.Position = target + Vector3.new(0, 3.5, 0)
		end
	end
	clickTpWasDown = down
end

-- Jump with a chosen power, only when standing on something.
local function stepJumpBoost()
	local down = keyDown(VK.SPACE)
	local pressed = down and not jumpBoostWasDown
	jumpBoostWasDown = down
	if not (pressed and cfg.jumpBoost and me.root and me.character and gameActive()) then return end

	local now = tick()
	if now - lastJump < 0.25 then return end

	wallParams.FilterDescendantsInstances = { me.character }
	if workspace:Raycast(me.root.Position, Vector3.new(0, -5, 0), wallParams) then
		lastJump = now
		local velocity = me.root.AssemblyLinearVelocity
		me.root.AssemblyLinearVelocity = Vector3.new(velocity.X, numberSetting("jumpPower", 50), velocity.Z)
	end
end

-- Fly: a velocity write costs ~20 ms on Matcha, so velocity is only re-asserted a few times a second (and straight away when the
-- direction changes). Gravity pulls between writes, so the target is biased upwards to centre the drift.
---@param camera table
local function stepFly(camera)
	if not me.root then return end

	if not cfg.fly then
		if flying then
			flying = false
			flyLast = nil
			me.root.AssemblyLinearVelocity = Vector3.zero
		end
		return
	end
	flying = true

	local direction = Vector3.zero
	local vertical = false
	if gameActive() then
		local look, right = camera.CFrame.LookVector, camera.CFrame.RightVector
		if keyDown(VK.W) then direction = direction + look end
		if keyDown(VK.S) then direction = direction - look end
		if keyDown(VK.D) then direction = direction + right end
		if keyDown(VK.A) then direction = direction - right end
		if keyDown(VK.SPACE) or keyDown(VK.E) then direction = direction + Vector3.new(0, 1, 0) vertical = true end
		if keyDown(VK.CTRL) or keyDown(VK.Q) then direction = direction - Vector3.new(0, 1, 0) vertical = true end
	end

	local speed = numberSetting("flySpeed", 150)
	local desired = Vector3.zero
	if direction.Magnitude > 0 then
		local boost = keyDown(VK.SHIFT) and numberSetting("flyBoost", 2) or 1
		desired = direction.Unit * speed * boost
	end
	if not vertical then
		desired = desired + Vector3.new(0, FLY_GRAVITY_BIAS, 0)
	end

	local now = tick()
	local interval = 1 / math.max(numberSetting("flyRate", 5), 1)
	local changed = flyLast == nil or (desired - flyLast).Magnitude > math.max(speed * 0.25, 10)
	if now - lastFly < (changed and 0.08 or interval) then return end

	lastFly = now
	flyLast = desired
	me.root.AssemblyLinearVelocity = desired
end

-- UI --------------------------------------------------------------------------------------------------------------------------

-- Declarative control list; the UI layer turns it into Matcha tabs. Each control is bound to a cfg key.
DaHood.controls = {
	{ tab = "DH Aimbot", items = {
		{ type = "toggle", key = "aimbot", text = "Aimbot (Z)" },
		{ type = "dropdown", key = "aimMode", text = "Activation", options = { "Hold RMB", "Always" } },
		{ type = "dropdown", key = "aimPart", text = "Target part", options = TARGET_PARTS },
		{ type = "slider", key = "aimFov", text = "FOV radius", min = 20, max = 600, step = 5 },
		{ type = "slider", key = "aimSmooth", text = "Smoothing", min = 1, max = 30, step = 1 },
		{ type = "slider", key = "aimPrediction", text = "Prediction", min = 0, max = 0.3, step = 0.01 },
		{ type = "toggle", key = "aimWall", text = "Wall check" },
		{ type = "toggle", key = "aimKnocked", text = "Skip knocked players" },
		{ type = "toggle", key = "aimProtected", text = "Skip spawn-protected" },
		{ type = "slider", key = "aimDistance", text = "Max distance (0 = any)", min = 0, max = 1000, step = 10 },
		{ type = "toggle", key = "flick", text = "Flick shot (C)" },
		{ type = "dropdown", key = "flickPart", text = "Flick part", options = TARGET_PARTS },
		{ type = "slider", key = "flickFov", text = "Flick FOV", min = 20, max = 800, step = 5 },
		{ type = "toggle", key = "triggerBot", text = "Trigger bot" },
		{ type = "slider", key = "triggerDelay", text = "Trigger delay", min = 0.02, max = 0.5, step = 0.01 },
		{ type = "toggle", key = "triggerWall", text = "Trigger wall check" },
	} },
	{ tab = "DH Weapons", items = {
		{ type = "toggle", key = "autoFire", text = "Auto fire (hold LMB)" },
		{ type = "slider", key = "fireDelay", text = "Auto fire delay", min = 0.02, max = 0.3, step = 0.01 },
		{ type = "toggle", key = "autoStomp", text = "Auto stomp" },
		{ type = "slider", key = "stompRange", text = "Stomp range", min = 3, max = 14, step = 1 },
		{ type = "toggle", key = "autoReload", text = "Auto reload" },
	} },
	{ tab = "DH Custom", items = {
		{ type = "toggle", key = "hitbox", text = "Hitbox expander" },
		{ type = "dropdown", key = "hitboxPart", text = "Hitbox part", options = { "HumanoidRootPart", "Head", "UpperTorso", "Head + Torso" } },
		{ type = "slider", key = "hitboxSize", text = "Hitbox width", min = 2, max = 40, step = 1 },
		{ type = "slider", key = "hitboxHeight", text = "Hitbox height (0 = same as width)", min = 0, max = 60, step = 1 },
		{ type = "slider", key = "hitboxRange", text = "Hitbox range (0 = any)", min = 0, max = 600, step = 10 },
		{ type = "toggle", key = "hitboxSkipKnocked", text = "Skip knocked players" },
		{ type = "toggle", key = "hitboxShow", text = "Draw hitbox outline" },
		{ type = "toggle", key = "timer", text = "Timer manipulator (master)" },
		{ type = "toggle", key = "timerFire", text = "Gun: click on exact cooldown" },
		{ type = "slider", key = "timerMargin", text = "Cooldown margin", min = 0, max = 0.1, step = 0.005 },
		{ type = "toggle", key = "timerMelee", text = "Melee: repeat M1 while held" },
		{ type = "slider", key = "timerMeleeRate", text = "Melee repeat gap", min = 0.05, max = 0.5, step = 0.01 },
		{ type = "toggle", key = "timerReload", text = "Fast reload" },
		{ type = "toggle", key = "timerStomp", text = "Fast stomp" },
		{ type = "toggle", key = "godmode", text = "Godmode (dodge aim lines)" },
		{ type = "toggle", key = "godDryRun", text = "Godmode dry run (log only, no teleport)" },
		{ type = "slider", key = "godRadius", text = "Danger radius around aim line", min = 2, max = 15, step = 0.5 },
		{ type = "slider", key = "godDistance", text = "Sidestep distance", min = 6, max = 40, step = 1 },
		{ type = "slider", key = "godCooldown", text = "Min time between dodges", min = 0.1, max = 1, step = 0.05 },
		{ type = "slider", key = "godLeash", text = "Max drift from start", min = 10, max = 120, step = 5 },
		{ type = "slider", key = "godMaxRange", text = "Ignore guns farther than (0 = gun range)", min = 0, max = 400, step = 10 },
		{ type = "toggle", key = "godReturn", text = "Blink back after dodging" },
	} },
	{ tab = "DH Movement", items = {
		{ type = "toggle", key = "fly", text = "Fly (X)" },
		{ type = "slider", key = "flySpeed", text = "Fly speed", min = 10, max = 1000, step = 10 },
		{ type = "slider", key = "flyBoost", text = "Shift boost", min = 1, max = 10, step = 0.5 },
		{ type = "toggle", key = "speed", text = "Speed boost (gc)" },
		{ type = "slider", key = "speedValue", text = "Speed", min = 16, max = 200, step = 2 },
		{ type = "toggle", key = "noclip", text = "Noclip (V)" },
		{ type = "toggle", key = "infiniteJump", text = "Infinite jump" },
		{ type = "toggle", key = "fovChanger", text = "Camera FOV" },
		{ type = "slider", key = "fovValue", text = "FOV value", min = 40, max = 120, step = 1 },
	} },
	{ tab = "DH Visuals", items = {
		{ type = "toggle", key = "esp", text = "ESP" },
		{ type = "toggle", key = "espBox", text = "Boxes" },
		{ type = "toggle", key = "espCorner", text = "Corner boxes" },
		{ type = "toggle", key = "espName", text = "Names" },
		{ type = "toggle", key = "espInfo", text = "Distance and health" },
		{ type = "toggle", key = "espHealth", text = "Health bar" },
		{ type = "toggle", key = "espWeapon", text = "Equipped weapon" },
		{ type = "toggle", key = "espSkeleton", text = "Skeleton" },
		{ type = "toggle", key = "espHeadDot", text = "Head dot" },
		{ type = "toggle", key = "espLook", text = "Look direction" },
		{ type = "toggle", key = "espArrows", text = "Off-screen arrows" },
		{ type = "toggle", key = "espTracer", text = "Tracers" },
		{ type = "dropdown", key = "espTracerFrom", text = "Tracer origin", options = { "Bottom", "Center", "Mouse" } },
		{ type = "slider", key = "espDistance", text = "Max distance (0 = any)", min = 0, max = 2000, step = 25 },
		{ type = "slider", key = "espHeavyLimit", text = "Skeleton / dot / look: nearest N", min = 0, max = 30, step = 1 },
		{ type = "slider", key = "espRate", text = "ESP refresh cap Hz (0 = every frame)", min = 0, max = 240, step = 5 },
		{ type = "toggle", key = "nativeEsp", text = "Native Matcha ESP (RegisterModel)" },
		{ type = "toggle", key = "showFov", text = "Show FOV circles" },
		{ type = "toggle", key = "crosshair", text = "Crosshair" },
		{ type = "slider", key = "crosshairSize", text = "Crosshair size", min = 2, max = 30, step = 1 },
		{ type = "slider", key = "crosshairGap", text = "Crosshair gap", min = 0, max = 20, step = 1 },
		{ type = "toggle", key = "hud", text = "HUD (ping, fps, active features)" },
	} },
	{ tab = "DH Misc", items = {
		{ type = "toggle", key = "antiAfk", text = "Anti-AFK" },
		{ type = "button", text = "Save config", action = "save" },
		{ type = "button", text = "Load config", action = "load" },
		{ type = "button", text = "Reset to defaults", action = "reset" },
		{ type = "button", text = "Turn every feature off (End)", action = "panic" },
		{ type = "button", text = "Copy server JobId", action = "jobid" },
	} },
}

---@param action string
function DaHood.runAction(action)
	if action == "save" then
		toast(DaHood.saveConfig() and "Config saved" or "Config save failed", 2)
	elseif action == "load" then
		toast(DaHood.loadConfig() and "Config loaded" or "No config found", 2)
		DaHood.syncUi()
	elseif action == "reset" then
		DaHood.resetConfig()
		DaHood.syncUi()
		toast("Defaults restored", 2)
	elseif action == "panic" then
		DaHood.panic()
	elseif action == "jobid" then
		pcall(setclipboard, game.JobId)
		toast("JobId copied", 2)
	end
end

-- Pushes cfg values into the UI controls (after a hotkey, config load or reset). Filled in by the UI layer.
function DaHood.syncUi() end

-- UI layer placeholder (replaced once the UI.AddTab callback API is known).
function DaHood.buildUi() end

function DaHood.destroyUi() end

-- Lifecycle -------------------------------------------------------------------------------------------------------------------

function DaHood.init()
	if not PLACE_IDS[game.PlaceId] then
		warn("[DaHood] wrong place, expected Da Hood")
		return
	end

	DaHood.loadConfig()
	collectMe()
	collectTargets()

	aimCircle = newDrawing("Circle", { Thickness = 1.5, NumSides = 64, Filled = false, Visible = false, Transparency = 1 })
	flickCircle = newDrawing("Circle", { Thickness = 1.5, NumSides = 64, Filled = false, Visible = false, Transparency = 1 })

	task.spawn(avatarWorker)

	-- Collector: the only place that walks the tree.
	task.spawn(function()
		while not detaching do
			local started = os.clock()
			pcall(collectMe)
			pcall(collectTargets)
			pcall(syncNative)
			collectMs = collectMs * 0.7 + (os.clock() - started) * 1000 * 0.3
			task.wait(COLLECT_INTERVAL)
		end
	end)

	-- Renderer: WorldToScreen only works inside this callback.
	connections[#connections + 1] = runService.RenderStepped:Connect(function()
		if detaching then return end

		xpcall(function()
			-- Frames counted over half-second windows: steadier than averaging per-frame deltas.
			fpsFrames = fpsFrames + 1
			local now = tick()
			if now - fpsSince >= 0.5 then
				fpsValue = fpsFrames / (now - fpsSince)
				fpsFrames, fpsSince = 0, now
			end

			local camera = workspace.CurrentCamera
			if not camera then return end

			local started = os.clock()
			cursorX, cursorY = mouse.X, mouse.Y
			stepAimbot(camera)
			if DaHood.flickRequested then
				DaHood.flickRequested = false
				startFlick(camera)
			end
			stepTriggerBot(camera)
			-- Optional cap on how often the ESP redraws (0 = every frame).
			local espRate = numberSetting("espRate", 0)
			if espRate <= 0 or started - lastEsp >= 1 / espRate then
				lastEsp = started
				stepEsp(camera)
			end
			stepOverlays()
			stepRadar(camera)
			stepWaypointDraw(camera)
			stepHover(camera)
			stepDesyncDraw(camera)
			stepHud()
			renderMs = renderMs * 0.9 + (os.clock() - started) * 1000 * 0.1
		end, onError)
	end)

	connections[#connections + 1] = runService.Heartbeat:Connect(function()
		if detaching then return end

		xpcall(function()
			local camera = workspace.CurrentCamera
			stepHotkeys()
			stepAutoActions()
			stepHitboxes()
			stepDodge()
			stepSpeed()
			stepNoclip()
			stepJump()
			stepJumpBoost()
			stepRapidFire()
			stepInfAmmo()
			stepClickTp()
			stepWaypointTween()
			stepDesync()
			stepAntiAfk()
			if camera then
				stepFly(camera)
				stepCameraFov(camera)
			end
		end, onError)
	end)

	DaHood.buildUi()
	toast("Loaded. Z aimbot, X fly, V noclip, C flick, End panic.", 5)
	log("loaded")
end

function DaHood.detach()
	if detaching then return end
	detaching = true

	for _, connection in ipairs(connections) do
		pcall(function() connection:Disconnect() end)
	end
	connections = {}

	for name in pairs(nativeHandles) do
		removeNative(name)
	end

	-- Undo every client-side change.
	for address, entry in pairs(hitboxApplied) do
		pcall(function()
			entry.part.Size = entry.size
			entry.part.CanCollide = entry.collide
		end)
		hitboxApplied[address] = nil
	end
	for address, part in pairs(noclipApplied) do
		pcall(function() part.CanCollide = true end)
		noclipApplied[address] = nil
	end
	if cameraFovBackup then
		pcall(function() workspace.CurrentCamera.FieldOfView = cameraFovBackup end)
	end
	if speedState.applied then
		pcall(setgc, "WalkSpeed", speedState.base, speedState.applied)
	end
	if flying and me.root then
		pcall(function() me.root.AssemblyLinearVelocity = Vector3.zero end)
	end
	for address, entry in pairs(rapidBackup) do
		pcall(function() entry.object.Value = entry.value end)
		rapidBackup[address] = nil
	end
	if desyncState.active then applyDesync(false) end
	tweenTarget = nil

	for _, object in ipairs(drawings) do
		pcall(function() object:Remove() end)
	end
	drawings = {}
	pool = {}

	DaHood.destroyUi()
	if _G.DaHoodMatcha == DaHood then _G.DaHoodMatcha = nil end
end

-- Snapshot of internal state for live diagnostics.
---@return table
function DaHood.debugState()
	return {
		targets = #targets, shown = poolShown, drawings = #drawings, hasRoot = me.root ~= nil, hasTool = me.tool ~= nil,
		fps = math.floor(fpsValue), renderMs = math.floor(renderMs * 100) / 100, collectMs = math.floor(collectMs * 10) / 10, native = (function() local n = 0 for _ in pairs(nativeHandles) do n = n + 1 end return n end)(),
		info = currentInfo.name, speedApplied = speedState.applied,
		hitboxParts = (function() local n = 0 for _ in pairs(hitboxApplied) do n = n + 1 end return n end)(), hitboxWrites = hitboxWrites,
		dodges = godState.dodges, threats = godState.threats,
	}
end

DaHood.cfg = cfg
_G.DaHoodMatcha = DaHood
xpcall(DaHood.init, onError)

return DaHood
