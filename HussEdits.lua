-- HussEdits: the edit films for the Huss Valley hub.
-- Potassium's VideoFrame cannot load local video, so each edit is stored as a pack of JPEG atlas pages (several frames per
-- picture) plus an mp3. A pack is downloaded from GitHub once, unpacked into the executor workspace, and played back frame
-- by frame with the audio as the clock.
--
--   local Edits = loadstring(readfile("HussEdits.lua"))()
--   Edits.loadPrefs()
--   local manifest = Edits.getManifest()
--   Edits.install(manifest.edits[1], function(fraction) end)
--   local player = Edits.newPlayer(someFrame, manifest.edits[1], { onEnded = function() end })
--   player:play()
--   Edits.prelude({ parent = guiParent, edit = Edits.pickStart(), onDone = function() end })

local Edits = {}

-- Constants.
local BASE_URL = "https://raw.githubusercontent.com/StaticNeutron/monkey-hub/main/edits/"
local FOLDER = "HussValley/edits"
local PREFS_FILE = "HussValley/edits.json"
local CHUNK_BYTES = 1048576
local PREFETCH_PAGES = 4
local BLACK = Color3.fromRGB(3, 3, 3)
local IVORY = Color3.fromRGB(236, 232, 222)
local DIM = Color3.fromRGB(152, 149, 139)
local LINE = Color3.fromRGB(69, 68, 63)

-- Services.
local httpService = game:GetService("HttpService")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")
local tweenService = game:GetService("TweenService")

-- State.
Edits.prefs = { play = true, pick = "Random", volume = 0.8 }
Edits.manifest = nil
local installing = {}
local thumbAsset = nil

---@param name string
---@return boolean
local function has(name)
	local environment = getgenv and getgenv() or {}
	return type(environment[name]) == "function"
end

---@return boolean
function Edits.supported()
	for _, name in { "request", "writefile", "readfile", "isfile", "isfolder", "makefolder", "getcustomasset" } do
		if not has(name) then return false end
	end
	return true
end

local function ensureFolders(path)
	local built = ""
	for part in string.gmatch(path, "[^/]+") do
		built = built == "" and part or (built .. "/" .. part)
		if not isfolder(built) then makefolder(built) end
	end
end

---@param text string
---@return any
local function decode(text)
	local success, value = pcall(function()
		return httpService:JSONDecode(text)
	end)
	return success and value or nil
end

-- Preferences ---------------------------------------------------------------------------------------------------------

-- Read before any UI exists, so the start-up edit can be chosen right away.
function Edits.loadPrefs()
	local success, text = pcall(function()
		return isfile(PREFS_FILE) and readfile(PREFS_FILE) or nil
	end)
	local data = success and text and decode(text)
	if type(data) ~= "table" then return Edits.prefs end

	if type(data.play) == "boolean" then Edits.prefs.play = data.play end
	if type(data.pick) == "string" then Edits.prefs.pick = data.pick end
	if type(data.volume) == "number" then Edits.prefs.volume = math.clamp(data.volume, 0, 1) end
	return Edits.prefs
end

function Edits.savePrefs()
	pcall(function()
		ensureFolders("HussValley")
		writefile(PREFS_FILE, httpService:JSONEncode(Edits.prefs))
	end)
end

-- Library ---------------------------------------------------------------------------------------------------------------

---@param force boolean?
---@return table?, string?
function Edits.getManifest(force)
	if Edits.manifest and not force then return Edits.manifest end
	if not Edits.supported() then return nil, "this executor lacks file or HTTP functions" end

	pcall(ensureFolders, FOLDER)
	local cachePath = FOLDER .. "/manifest.json"

	local requested, response = pcall(request, { Url = BASE_URL .. "manifest.json?t=" .. os.time(), Method = "GET" })
	local data = requested and type(response) == "table" and response.Success and decode(response.Body)
	if type(data) == "table" and type(data.edits) == "table" then
		pcall(writefile, cachePath, response.Body)
		Edits.manifest = data
		return data
	end

	-- Offline: the copy from the last successful run.
	local readable, cached = pcall(function()
		return isfile(cachePath) and decode(readfile(cachePath)) or nil
	end)
	if readable and type(cached) == "table" and type(cached.edits) == "table" then
		Edits.manifest = cached
		return cached
	end
	return nil, "could not reach the edit library"
end

---@param edit table
---@param name string
---@return string
local function localPath(edit, name)
	return string.format("%s/%s/hv_%s_r%d_%s", FOLDER, edit.id, edit.id, edit.rev or 1, name)
end

---@param edit table
---@return boolean
function Edits.isInstalled(edit)
	local success, present = pcall(isfile, localPath(edit, "ready"))
	return success and present == true
end

-- Finds an edit by id or by its display title.
---@param key string
---@return table?
function Edits.find(key)
	local manifest = Edits.manifest
	if not manifest then return nil end

	for _, edit in manifest.edits do
		if edit.id == key or edit.title == key then return edit end
	end
	return nil
end

-- The edit the start-up film should play (Random picks one that is already downloaded when there is one).
---@return table?
function Edits.pickStart()
	local manifest = Edits.manifest
	if not manifest or #manifest.edits == 0 then return nil end

	local chosen = Edits.prefs.pick ~= "Random" and Edits.find(Edits.prefs.pick) or nil
	if chosen then return chosen end

	local pool = {}
	for _, edit in manifest.edits do
		if Edits.isInstalled(edit) then table.insert(pool, edit) end
	end
	if #pool == 0 then pool = manifest.edits end
	return pool[math.random(1, #pool)]
end

-- Downloads and unpacks an edit. progress(fraction, text) is called as it goes. Returns true, or false and a reason.
---@param edit table
---@param progress function?
---@return boolean, string?
function Edits.install(edit, progress)
	if not Edits.supported() then return false, "this executor lacks file or HTTP functions" end
	progress = progress or function() end

	if Edits.isInstalled(edit) then
		progress(1, "ready")
		return true
	end

	-- A second caller waits for the download already running.
	if installing[edit.id] then
		while installing[edit.id] do task.wait(0.1) end
		return Edits.isInstalled(edit), "download failed"
	end
	installing[edit.id] = true

	local success, result, reason = pcall(function()
		ensureFolders(FOLDER .. "/" .. edit.id)

		local chunks, received = {}, 0
		local total = edit.packSize
		while received < total do
			local first, last = received, math.min(received + CHUNK_BYTES, total) - 1
			local response
			for _ = 1, 3 do
				local requested, reply = pcall(request, {
					Url = BASE_URL .. edit.id .. ".pack",
					Method = "GET",
					Headers = { Range = string.format("bytes=%d-%d", first, last) },
				})
				if requested and type(reply) == "table" and reply.Success and type(reply.Body) == "string" then
					response = reply
					break
				end
				task.wait(0.5)
			end
			if not response then return false, "download interrupted" end

			-- A server that ignores Range answers with the whole file at once.
			if response.StatusCode == 200 and #response.Body == total then
				chunks, received = { response.Body }, total
			else
				table.insert(chunks, response.Body)
				received += #response.Body
			end
			progress(math.min(received / total, 1) * 0.85, "downloading")
			task.wait()
		end

		local data = table.concat(chunks)
		if #data ~= total then return false, "download incomplete" end

		-- Audio first, then the pages in order. (crypt.hash is not used: Potassium hashes binary strings wrongly, so every
		-- page is checked for the JPEG start and end markers instead, which catches a cut or garbled download.)
		writefile(localPath(edit, "a.mp3"), string.sub(data, 1, edit.audioSize))
		local cursor = edit.audioSize
		for index, size in edit.pageSizes do
			local page = string.sub(data, cursor + 1, cursor + size)
			if string.byte(page, 1) ~= 0xFF or string.byte(page, 2) ~= 0xD8 or string.byte(page, #page - 1) ~= 0xFF or string.byte(page, #page) ~= 0xD9 then
				return false, "download damaged"
			end

			writefile(localPath(edit, string.format("p%04d.jpg", index)), page)
			cursor += size
			if index % 12 == 0 then
				progress(0.85 + 0.15 * index / #edit.pageSizes, "unpacking")
				task.wait()
			end
		end

		writefile(localPath(edit, "ready"), "1")
		progress(1, "ready")
		return true
	end)

	installing[edit.id] = nil
	if not success then return false, tostring(result) end
	return result, reason
end

-- Cover pictures for the list: one small atlas for every edit, downloaded on its own.
---@return string?
function Edits.thumbs()
	if thumbAsset then return thumbAsset end

	local manifest = Edits.manifest
	local info = manifest and manifest.thumbs
	if not info then return nil end

	local success, asset = pcall(function()
		local path = string.format("%s/hv_thumbs_r%d.jpg", FOLDER, info.rev or 1)
		if not isfile(path) then
			local response = request({ Url = BASE_URL .. info.file, Method = "GET" })
			if not (response and response.Success) then return nil end

			ensureFolders(FOLDER)
			writefile(path, response.Body)
		end
		return getcustomasset(path)
	end)
	if success and type(asset) == "string" and asset ~= "" then thumbAsset = asset end
	return thumbAsset
end

---@param seconds number
---@return string
function Edits.clock(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", seconds // 60, seconds % 60)
end

-- Player ----------------------------------------------------------------------------------------------------------------

local Player = {}
Player.__index = Player

-- A film inside `parent`. Frames come from atlas pages; the audio is the clock while it plays.
---@param parent Instance
---@param edit table
---@param opts table?
---@return table
function Edits.newPlayer(parent, edit, opts)
	opts = opts or {}

	local self = setmetatable({
		edit = edit,
		playing = false,
		ended = false,
		dead = false,
		loop = opts.loop == true,
		volume = opts.volume or Edits.prefs.volume,
		time = 0,
		shownPage = 0,
		buffering = false,
		onEnded = opts.onEnded,
		ids = {},
		labels = {},
	}, Player)

	self.perPage = edit.cols * edit.rows
	self.root = Instance.new("Frame")
	self.root.Name = opts.name or "HussFilm"
	self.root.Size = opts.Size or UDim2.fromScale(1, 1)
	self.root.Position = opts.Position or UDim2.fromScale(0, 0)
	self.root.AnchorPoint = opts.AnchorPoint or Vector2.zero
	self.root.BackgroundColor3 = BLACK
	self.root.BorderSizePixel = 0
	self.root.ClipsDescendants = true
	self.root.ZIndex = opts.ZIndex or 1
	self.root.Parent = parent

	-- Each tile is cropped by one pixel on every side so a neighbour never bleeds in through the filtering.
	self.view = Instance.new("ImageLabel")
	self.view.Name = "Picture"
	self.view.Size = UDim2.fromScale(1, 1)
	self.view.BackgroundTransparency = 1
	self.view.ScaleType = Enum.ScaleType.Crop
	self.view.ImageRectSize = Vector2.new(edit.tileW - 2, edit.tileH - 2)
	self.view.ZIndex = self.root.ZIndex
	self.view.Parent = self.root

	-- Pages about to be shown are loaded here first (nearly invisible, one pixel) so the swap never waits on a decode.
	self.decode = Instance.new("Frame")
	self.decode.Name = "Decode"
	self.decode.Size = UDim2.fromOffset(1, 1)
	self.decode.BackgroundTransparency = 1
	self.decode.ClipsDescendants = true
	self.decode.Parent = self.root

	local audioPath = localPath(edit, "a.mp3")
	local hasAudio = pcall(function()
		return isfile(audioPath)
	end) and isfile(audioPath)
	if hasAudio then
		local made, sound = pcall(function()
			local created = Instance.new("Sound")
			created.Name = "EditAudio"
			created.SoundId = getcustomasset(audioPath)
			created.Volume = self.volume
			created.Parent = self.root
			return created
		end)
		if made then self.sound = sound end
	end

	self.connection = runService.RenderStepped:Connect(function(deltaTime)
		self:step(deltaTime)
	end)

	self:prefetch(1)
	self:show(0)
	return self
end

---@param page number
---@return string?
function Player:idFor(page)
	if self.ids[page] then return self.ids[page] end

	local success, asset = pcall(getcustomasset, localPath(self.edit, string.format("p%04d.jpg", page)))
	if success and type(asset) == "string" and asset ~= "" then
		self.ids[page] = asset
		return asset
	end
	return nil
end

-- Keeps the next few pages loading (and drops the ones left behind).
---@param page number
function Player:prefetch(page)
	for index = page, math.min(page + PREFETCH_PAGES, self.edit.pages) do
		if not self.labels[index] then
			local id = self:idFor(index)
			if id then
				local label = Instance.new("ImageLabel")
				label.Size = UDim2.fromOffset(1, 1)
				label.BackgroundTransparency = 1
				label.ImageTransparency = 0.999999
				label.Image = id
				label.Parent = self.decode
				self.labels[index] = label
			end
		end
	end

	for index, label in self.labels do
		if index < page - 1 then
			label:Destroy()
			self.labels[index] = nil
		end
	end
end

---@param page number
---@return boolean
function Player:loaded(page)
	local label = self.labels[page]
	return label ~= nil and label.IsLoaded
end

-- Waits until the first pages are decoded (up to `timeout` seconds).
---@param timeout number?
---@return boolean
function Player:prepare(timeout)
	local deadline = os.clock() + (timeout or 4)
	while not self.dead and os.clock() < deadline do
		self:prefetch(1)
		if self:loaded(1) and (self.edit.pages < 2 or self:loaded(2)) then
			self:show(0)
			return true
		end
		task.wait(0.05)
	end
	return false
end

-- Puts one frame on screen. Returns false while its page is still loading.
---@param frame number
---@return boolean
function Player:show(frame)
	local page = frame // self.perPage + 1
	local slot = frame % self.perPage

	if page ~= self.shownPage then
		self:prefetch(page)
		if not self:loaded(page) then return false end

		self.view.Image = self.ids[page]
		self.shownPage = page
	end

	local column, row = slot % self.edit.cols, slot // self.edit.cols
	self.view.ImageRectOffset = Vector2.new(column * self.edit.tileW + 1, row * self.edit.tileH + 1)
	return true
end

---@param deltaTime number
function Player:step(deltaTime)
	if self.dead then return end

	local edit = self.edit
	if self.playing and not self.buffering then
		if self.sound and self.sound.IsPlaying then
			self.time = self.sound.TimePosition
		elseif not self.sound then
			self.time += deltaTime
		end
	end

	if self.playing and self.time >= edit.duration - 0.02 then
		if self.loop then
			self:seek(0)
		else
			self.playing, self.ended = false, true
			if self.sound then self.sound:Pause() end
			self.time = edit.duration
			if self.onEnded then task.spawn(self.onEnded, self) end
		end
		return
	end

	local frame = math.clamp(math.floor(self.time * edit.fps), 0, edit.frames - 1)
	local shown = self:show(frame)

	-- Hold the sound while a page decodes so picture and music stay together.
	if self.playing and self.sound then
		if not shown and not self.buffering then
			self.buffering = true
			self.sound:Pause()
		elseif shown and self.buffering then
			self.buffering = false
			self.sound:Resume()
		end
	end
end

function Player:play()
	if self.dead then return end

	if self.ended then self:seek(0) end
	self.playing, self.ended = true, false
	if self.sound then
		self.sound.Volume = self.volume
		self.sound:Play()
	end
end

function Player:pause()
	self.playing = false
	if self.sound then self.sound:Pause() end
end

---@param seconds number
function Player:seek(seconds)
	seconds = math.clamp(seconds, 0, self.edit.duration)
	self.time, self.ended = seconds, false
	if self.sound then self.sound.TimePosition = seconds end
end

---@param volume number
function Player:setVolume(volume)
	self.volume = math.clamp(volume, 0, 1)
	if self.sound then self.sound.Volume = self.volume end
end

function Player:destroy()
	if self.dead then return end

	self.dead = true
	if self.connection then self.connection:Disconnect() end
	if self.sound then pcall(function() self.sound:Stop() end) end
	self.root:Destroy()
end

-- Start-up film ---------------------------------------------------------------------------------------------------------

---@param value number
---@return number
local function ease(value)
	value = math.clamp(value, 0, 1)
	return 1 - (1 - value) ^ 3
end

---@param parent Instance
---@param text string
---@param size number
---@param font Enum.Font
---@param props table?
---@return TextLabel
local function text(parent, content, size, font, props)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = content
	label.TextSize = size
	label.Font = font
	label.TextColor3 = IVORY
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Size = UDim2.fromOffset(400, size + 6)
	if props then
		for key, value in props do
			label[key] = value
		end
	end
	label.Parent = parent
	return label
end

---@param parent Instance
---@param content string
---@param position UDim2
---@param callback function
---@return TextButton
local function hairlineButton(parent, content, position, callback)
	local button = Instance.new("TextButton")
	button.Text = content
	button.Font = Enum.Font.Code
	button.TextSize = 12
	button.TextColor3 = IVORY
	button.AutoButtonColor = false
	button.BackgroundColor3 = IVORY
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Size = UDim2.fromOffset(116, 32)
	button.Position = position
	button.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color = IVORY
	stroke.Transparency = 0.7
	stroke.Parent = button

	button.MouseEnter:Connect(function()
		tweenService:Create(button, TweenInfo.new(0.2), { BackgroundTransparency = 0.9 }):Play()
	end)
	button.MouseLeave:Connect(function()
		tweenService:Create(button, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	end)
	button.Activated:Connect(callback)
	return button
end

-- Black screen, the wordmark assembling in strips, then the chosen edit in a portrait frame. Space or the Skip button ends
-- it at once. Every failure path just closes it; onDone always runs exactly once.
---@param opts table  parent, edit, onDone, volume
---@return table
function Edits.prelude(opts)
	local handle = { done = false }
	local edit = opts.edit
	local volume = opts.volume or Edits.prefs.volume

	local gui = Instance.new("ScreenGui")
	gui.Name = "HussPrelude"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local parented = pcall(function() gui.Parent = opts.parent end)
	if not parented then
		gui:Destroy()
		handle.done = true
		if opts.onDone then task.spawn(opts.onDone) end
		return handle
	end

	local canvas = Instance.new("CanvasGroup")
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundColor3 = BLACK
	canvas.BorderSizePixel = 0
	canvas.Parent = gui

	local stage = Instance.new("Frame")
	stage.Name = "Choreography"
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromScale(0.5, 0.47)
	stage.Size = UDim2.fromOffset(700, 400)
	stage.BackgroundTransparency = 1
	stage.Parent = canvas

	-- The reference's opening: three tilted rings of line segments turning around a point of light, drifting particles, and
	-- eight rays. Everything collapses into the centre before the wordmark assembles.
	local orbitHost = Instance.new("Frame")
	orbitHost.AnchorPoint = Vector2.new(0.5, 0.5)
	orbitHost.Position = UDim2.fromScale(0.5, 0.5)
	orbitHost.Size = UDim2.fromOffset(300, 300)
	orbitHost.BackgroundTransparency = 1
	orbitHost.Parent = stage

	local function orbitPart(parent, size)
		local part = Instance.new("Frame")
		part.AnchorPoint = Vector2.new(0.5, 0.5)
		part.BackgroundColor3 = IVORY
		part.BorderSizePixel = 0
		part.Size = size or UDim2.fromOffset(2, 2)
		part.BackgroundTransparency = 1
		part.Parent = parent
		return part
	end

	local orbitLines = {}
	for ring = 1, 3 do
		orbitLines[ring] = {}
		for index = 1, 48 do
			orbitLines[ring][index] = orbitPart(orbitHost, UDim2.fromOffset(2, 1))
		end
	end

	local particles = {}
	for index = 1, 52 do
		local size = index % 3 == 0 and 2 or 1.3
		local particle = orbitPart(stage, UDim2.fromOffset(size, size))
		local rounding = Instance.new("UICorner")
		rounding.CornerRadius = UDim.new(1, 0)
		rounding.Parent = particle
		particles[index] = particle
	end

	local core = orbitPart(orbitHost, UDim2.fromOffset(4, 4))
	core.Position = UDim2.fromScale(0.5, 0.5)
	local coreRounding = Instance.new("UICorner")
	coreRounding.CornerRadius = UDim.new(1, 0)
	coreRounding.Parent = core

	local rays = {}
	for index = 1, 8 do
		local ray = orbitPart(orbitHost, UDim2.fromOffset(80, 1))
		ray.Position = UDim2.fromScale(0.5, 0.5)
		ray.Rotation = index * 22.5
		local fade = Instance.new("UIGradient")
		fade.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.1), NumberSequenceKeypoint.new(1, 1) })
		fade.Parent = ray
		rays[index] = ray
	end

	-- One point of a ring, tilted and turned in space, then squeezed in perspective.
	local function projected(theta, ring, time, shrink)
		local x, y = 132 * math.cos(theta), 132 * math.sin(theta)
		local tilt = 0.75 + ring * 0.42
		local z
		y, z = y * math.cos(tilt), y * math.sin(tilt)
		local rotation = time * 0.52 + ring * math.pi / 3
		x, y = x * math.cos(rotation) - y * math.sin(rotation), x * math.sin(rotation) + y * math.cos(rotation)
		local depth = 1 / (1 + z / 530)
		return Vector2.new(150 + x * depth * shrink, 150 + y * depth * shrink)
	end

	-- The wordmark is cut into horizontal strips that slide in one after another.
	local wordHeight, strips = 76, {}
	local wordHost = Instance.new("Frame")
	wordHost.AnchorPoint = Vector2.new(0.5, 0.5)
	wordHost.Position = UDim2.fromScale(0.5, 0.5)
	wordHost.Size = UDim2.fromOffset(640, wordHeight)
	wordHost.BackgroundTransparency = 1
	wordHost.Parent = stage
	for index = 1, 12 do
		local mask = Instance.new("Frame")
		mask.BackgroundTransparency = 1
		mask.ClipsDescendants = true
		mask.Size = UDim2.fromOffset(640, wordHeight / 12 + 0.4)
		mask.Parent = wordHost

		local word = text(mask, "HUSS VALLEY", 62, Enum.Font.Garamond, {
			Size = UDim2.fromOffset(640, wordHeight),
			Position = UDim2.fromOffset(0, -(index - 1) * wordHeight / 12),
			TextTransparency = 1,
		})
		strips[index] = { mask = mask, word = word }
	end

	local wordScale = Instance.new("UIScale")
	wordScale.Parent = wordHost
	local edition = text(wordHost, "P R I V A T E   E D I T I O N", 11, Enum.Font.Code, {
		Position = UDim2.new(0.5, -180, 1, 22),
		Size = UDim2.fromOffset(360, 18),
		TextTransparency = 1,
	})

	local footer = text(canvas, "PREPARING YOUR SETUP", 12, Enum.Font.Code, {
		Position = UDim2.new(0.5, -240, 1, -92),
		Size = UDim2.fromOffset(480, 20),
		TextColor3 = DIM,
	})
	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.new(0.5, 0, 1, -56)
	track.Size = UDim2.fromOffset(160, 1)
	track.BackgroundColor3 = LINE
	track.BorderSizePixel = 0
	track.Parent = canvas
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = IVORY
	fill.BorderSizePixel = 0
	fill.Parent = track

	-- Film stage (portrait). Hidden until the edit starts.
	local filmHost = Instance.new("Frame")
	filmHost.Name = "Film"
	filmHost.AnchorPoint = Vector2.new(0.5, 0.5)
	filmHost.BackgroundTransparency = 1
	filmHost.Visible = false
	filmHost.Parent = canvas
	local filmCaption = text(canvas, "", 11, Enum.Font.Code, { TextColor3 = DIM, Visible = false, Size = UDim2.fromOffset(420, 18) })

	local state = { phase = "intro", time = 0, filmTime = 0, muted = false, install = "pending", fraction = 0, outTime = 0 }
	local player = nil
	local connection, keyConnection

	local function finish()
		if handle.done then return end

		handle.done = true
		if connection then connection:Disconnect() end
		if keyConnection then keyConnection:Disconnect() end
		if player then player:destroy() end
		gui:Destroy()
		if opts.onDone then task.spawn(opts.onDone) end
	end
	handle.close = function()
		if state.phase ~= "out" then state.phase, state.outTime = "out", 0 end
	end

	hairlineButton(canvas, "Skip intro", UDim2.new(1, -146, 1, -72), handle.close)
	local muteButton
	muteButton = hairlineButton(canvas, "Sound on", UDim2.fromOffset(30, 30), function()
		state.muted = not state.muted
		muteButton.Text = state.muted and "Sound off" or "Sound on"
		if player then player:setVolume(state.muted and 0 or volume) end
	end)

	keyConnection = userInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Space and not userInputService:GetFocusedTextBox() then handle.close() end
	end)

	-- Download and prepare the edit on its own thread so the animation never waits on it.
	task.spawn(function()
		if not (edit and Edits.supported()) then
			state.install = "fail"
			return
		end

		local installed = Edits.install(edit, function(fraction)
			state.fraction = fraction
		end)
		if handle.done or not installed then
			state.install = "fail"
			return
		end

		local made, created = pcall(Edits.newPlayer, filmHost, edit, { volume = volume, name = "Edit" })
		if not made then
			state.install = "fail"
			return
		end

		player = created
		player.onEnded = handle.close
		player:prepare(5)
		state.install = "ok"
	end)

	connection = runService.RenderStepped:Connect(function(deltaTime)
		state.time += deltaTime
		local t = state.time
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)

		-- Wordmark assembly.
		local drawn = ease(t / 0.7)
		local orbitAlpha = ease(t / 0.55) * (1 - ease((t - 2.65) / 0.9))
		local shrink = 1 - ease((t - 2.7) / 1.0) * 0.96
		for ring, segments in orbitLines do
			for index, segment in segments do
				local first = projected((index - 1) / 48 * math.pi * 2, ring, t, shrink)
				local second = projected(index / 48 * math.pi * 2, ring, t, shrink)
				local delta = second - first
				segment.Position = UDim2.fromOffset((first.X + second.X) / 2, (first.Y + second.Y) / 2)
				segment.Size = UDim2.fromOffset(delta.Magnitude + 0.5, 1.15)
				segment.Rotation = math.deg(math.atan2(delta.Y, delta.X))
				segment.BackgroundTransparency = 1 - orbitAlpha * 0.64
			end
		end

		local morph = ease((t - 2.6) / 0.8)
		local particleFade = ease(t / 0.65) * (1 - ease((t - 4) / 0.4))
		for index, particle in particles do
			local phase = index * 2.399963 + t * 0.65
			local radius = 25 + math.sqrt(index / 52) * 69
			local x, y = math.cos(phase) * radius, math.sin(phase) * radius * 0.66
			local lineX = (index - 26.5) * 4.7
			local lineY = math.sin(index * 0.28 - t * 4) * 12 * math.sin(math.clamp((t - 3) / 1.2, 0, 1) * math.pi)
			particle.Position = UDim2.new(0.5, x + (lineX - x) * morph, 0.5, y + (lineY - y) * morph)
			particle.BackgroundTransparency = 1 - particleFade * (0.36 + (index % 4) * 0.15)
		end

		local glow = math.max(0, (1 - ease((t - 2.7) / 0.7)) * (0.65 + 0.15 * math.sin(t * 2)))
		core.BackgroundTransparency = 1 - glow
		for _, ray in rays do
			ray.BackgroundTransparency = 1 - glow * 0.26
		end
		for index, strip in strips do
			local progress = ease((t - 3.3 - (index - 1) * 0.035) / 0.65)
			strip.mask.Position = UDim2.fromOffset((index % 2 == 0 and 1 or -1) * (1 - progress) * 32, (index - 1) * wordHeight / 12)
			strip.word.TextTransparency = 1 - progress
		end
		edition.TextTransparency = 1 - ease((t - 4.7) / 0.6)

		local scale = math.min(1, (viewport.X - 40) / 700)
		stage.Size = UDim2.fromOffset(700 * scale, 400 * scale)

		-- Everything below the wordmark depends on how far the film has taken over the screen.
		local filmShown = state.phase == "film" and ease(state.filmTime / 1.2) or 0
		stage.Position = UDim2.fromScale(0.5, 0.47 - 0.37 * filmShown)
		wordScale.Scale = 1 - 0.45 * filmShown

		if state.phase == "intro" then
			if t < 2.6 then
				footer.Text = "PREPARING YOUR SETUP"
			elseif state.install == "pending" then
				footer.Text = string.format("FETCHING EDIT  %d%%", math.floor(state.fraction * 100))
			else
				footer.Text = "SHAPING YOUR SPACE"
			end
			fill.Size = UDim2.fromScale(math.clamp(math.max(state.fraction, t / 5), 0, 1), 1)

			if state.install == "fail" and t >= 4.6 then
				footer.Text = "EDIT UNAVAILABLE"
				state.phase, state.outTime = "out", 0
			elseif state.install == "ok" and t >= 4.8 then
				state.phase = "film"
				player:play()
			end
		elseif state.phase == "film" then
			state.filmTime += deltaTime
			local height = math.min(viewport.Y * 0.66, 720)
			local width = height * edit.tileW / edit.tileH
			filmHost.Visible = true
			filmHost.Size = UDim2.fromOffset(width, height)
			filmHost.Position = UDim2.new(0.5, 0, 0.5, viewport.Y * 0.06)
			filmCaption.Visible = true
			filmCaption.Position = UDim2.new(0.5, -210, 0.5, viewport.Y * 0.06 + height / 2 + 14)
			filmCaption.Text = string.format("%s   /   %s / %s", string.upper(edit.title), Edits.clock(player.time), Edits.clock(edit.duration))
			filmCaption.TextTransparency = 1 - filmShown
			player.view.ImageTransparency = 1 - filmShown
			footer.Text = "PRIVATE VIEWING  /  HUSS VALLEY"
			fill.Size = UDim2.fromScale(math.clamp(player.time / edit.duration, 0, 1), 1)
		elseif state.phase == "out" then
			state.outTime += deltaTime
			canvas.GroupTransparency = ease(state.outTime / 0.45)
			if state.outTime >= 0.5 then finish() end
		end
	end)

	return handle
end

return Edits
