-- HussUI: "private edition" skin for the Huss Valley hub. Near-black surfaces, ivory type, serif headings, mono small caps and
-- one-pixel hairlines (the look of the Giorgio reference), with a film viewer for the start-up edits.
-- API: CreateWindow -> CreateCategory / CreateTab -> Add* (same shape as V18UI / GlassUI), plus Tab:AddWide / Tab:AddFilm.
--
--   local UI = loadstring(readfile("HussUI.lua"))()
--   local window = UI:CreateWindow({ Title = "Da Hood", Subtitle = "Workspace", ToggleKey = Enum.KeyCode.RightShift })
--   local tab = window:CreateTab("Combat", "crosshair")
--   tab:AddSection("Aimbot")
--   tab:AddToggle({ Text = "Enabled", Flag = "aimEnabled", Callback = function(on) end })
--   UI.Flags.aimEnabled.Value, UI:Destroy()

local HussUI = {}
HussUI.Flags = {}

-- Constants.
local GUI_NAME = "HussUI"
local INTRO_NAME = "HussUI_Intro"
local BLUR_NAME = "HussUI_Blur"
local ICON_FOLDER = "V18UI/icons/"
local WINDOW_WIDTH = 880
local WINDOW_HEIGHT = 556
local HEADER_HEIGHT = 90
local SIDEBAR_WIDTH = 204
local TAB_HEIGHT = 44
local PAGE_PADDING = 24
local ROW_HEIGHT = 52
local RADIUS = 6
-- Width of a row inside a page (window less sidebar, padding and the scroll bar).
local LIST_WIDTH = 626
local WIDGET_WIDTH = 188
local WIDGET_GAP = 14
local SEGMENTS = 22
local QUINT = Enum.EasingStyle.Quint
local BACK = Enum.EasingStyle.Back
local OUT = Enum.EasingDirection.Out
local IN = Enum.EasingDirection.In

-- Palette (the reference's): warm near-black surfaces and one ivory at several strengths.
local IVORY = Color3.fromRGB(236, 232, 222)
local COLORS = {
	bg = Color3.fromRGB(12, 12, 12),
	card = Color3.fromRGB(22, 22, 21),
	overlay = Color3.fromRGB(30, 30, 28),
	hover = Color3.fromRGB(42, 42, 39),
	track = Color3.fromRGB(8, 8, 8),
	line = Color3.fromRGB(69, 68, 63),
	lineStrong = Color3.fromRGB(107, 105, 97),
	row = IVORY,
	text = IVORY,
	dim = Color3.fromRGB(182, 179, 170),
	muted = Color3.fromRGB(152, 149, 139),
	faint = Color3.fromRGB(106, 105, 99),
	accent = IVORY,
	accent2 = Color3.fromRGB(190, 186, 176),
	ink = Color3.fromRGB(12, 12, 12),
	good = Color3.fromRGB(150, 196, 160),
	warn = Color3.fromRGB(232, 200, 120),
	bad = Color3.fromRGB(206, 118, 108),
}

local BODY = Enum.Font.Gotham
local BOLD = Enum.Font.GothamMedium
local STRONG = Enum.Font.GothamBold
local DISPLAY = Enum.Font.Garamond
local MONO = Enum.Font.Code
local MORPH_NAME = "HussUI_Morph"

-- Services.
local playersService = game:GetService("Players")
local runService = game:GetService("RunService")
local tweenService = game:GetService("TweenService")
local userInputService = game:GetService("UserInputService")
local lightingService = game:GetService("Lighting")
local coreGuiService = game:GetService("CoreGui")
local httpService = game:GetService("HttpService")
local statsService = game:GetService("Stats")
local textService = game:GetService("TextService")

local localPlayer = playersService.LocalPlayer

-- State. One window at a time; everything it owns hangs off `active` so Destroy leaves nothing behind.
local active = nil
local guiParent = nil
local iconCache = {}

---@return Instance
local function getGuiParent()
	if guiParent then return guiParent end

	local hasHui, hui = pcall(function()
		return gethui()
	end)
	if hasHui and typeof(hui) == "Instance" then
		guiParent = hui
		return guiParent
	end

	local hasCore = pcall(function()
		local probe = Instance.new("Folder")
		probe.Parent = coreGuiService
		probe:Destroy()
	end)
	guiParent = hasCore and coreGuiService or localPlayer:WaitForChild("PlayerGui")
	return guiParent
end

---@param className string
---@param props table
---@param parent Instance?
---@return Instance
local function create(className, props, parent)
	local inst = Instance.new(className)
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

---@param inst Instance
---@param duration number
---@param props table
---@param style Enum.EasingStyle?
---@param direction Enum.EasingDirection?
---@return Tween
local function tween(inst, duration, props, style, direction)
	local playing = tweenService:Create(inst, TweenInfo.new(duration, style or QUINT, direction or OUT), props)
	playing:Play()
	return playing
end

---@param connection RBXScriptConnection
---@return RBXScriptConnection
local function track(connection)
	table.insert(active.connections, connection)
	return connection
end

---@param inst Instance
---@param radius number
local function corner(inst, radius)
	create("UICorner", { CornerRadius = UDim.new(0, radius) }, inst)
end

---@param inst Instance
---@param transparency number
---@param thickness number?
---@return UIStroke
local function stroke(inst, transparency, thickness, color)
	return create("UIStroke", {
		Color = color or COLORS.line,
		Thickness = thickness or 1,
		Transparency = transparency,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
end

-- Flat fill: kept as a helper so call sites read the same, but there are no gradients in this skin.
---@param inst Instance
---@param first Color3
local function gradient(inst, first)
	inst.BackgroundColor3 = first
end

---@param parent Instance
---@param content string
---@param size number
---@param color Color3
---@param font Enum.Font?
---@param props table?
---@return TextLabel
local function label(parent, content, size, color, font, props)
	local item = create("TextLabel", {
		BackgroundTransparency = 1,
		Text = content,
		TextSize = size,
		TextColor3 = color,
		Font = font or BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, size + 4),
	}, parent)
	if props then
		for key, value in props do
			item[key] = value
		end
	end
	return item
end

-- Local Lucide PNG for a tab/widget icon, or "" when the file is not on disk.
---@param name string?
---@return string
local function icon(name)
	if not name then return "" end
	if iconCache[name] ~= nil then return iconCache[name] end

	local asset = ""
	pcall(function()
		local path = ICON_FOLDER .. name .. ".png"
		if isfile(path) then asset = getcustomasset(path) end
	end)

	iconCache[name] = asset
	return asset
end

---@param callback function?
---@param ... any
local function safeCall(callback, ...)
	if not callback then return end

	local success, err = pcall(callback, ...)
	if not success then warn("[HussUI] callback error: " .. tostring(err)) end
end

---@param value number
---@return string
local function formatNumber(value)
	local formatted = string.format("%.2f", value)
	formatted = formatted:gsub("0+$", "")
	formatted = formatted:gsub("%.$", "")
	return formatted
end

---@param color Color3
---@return string
local function toHex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

---@param hex string
---@return Color3?
local function fromHex(hex)
	local r, g, b = string.match(tostring(hex), "^#?(%x%x)(%x%x)(%x%x)$")
	if not r then return nil end

	return Color3.fromRGB(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

-- Removes leftovers from an earlier load before anything new exists.
local function sweepPrevious()
	for _, container in { getGuiParent(), coreGuiService } do
		pcall(function()
			for _, child in container:GetChildren() do
				if child.Name == GUI_NAME or child.Name == INTRO_NAME then child:Destroy() end
			end
		end)
	end

	for _, child in lightingService:GetChildren() do
		if child.Name == BLUR_NAME then child:Destroy() end
	end
end

-- Letter-spaced small caps, the way the reference sets its labels.
---@param content string
---@return string
local function spaced(content)
	local result = string.gsub(string.upper(content), ".", function(character)
		return character == " " and "  " or (character .. " ")
	end)
	return (string.gsub(result, "%s+$", ""))
end

-- Assets: interface sounds and animated line icons ------------------------------------------------------------------------
-- One small pack (assets/ui.pack + ui.json in the repo) is downloaded once and unpacked into the workspace. Everything that
-- uses an asset works without it; sounds and animated icons simply appear once the pack is on disk.

local ASSET_BASE = "https://raw.githubusercontent.com/StaticNeutron/monkey-hub/main/assets/"
local ASSET_FOLDER = "HussValley/assets"
local ASSET_MARKER = ASSET_FOLDER .. "/hv_ready_r2"
local assetIds = {}
local assetsState = "idle"

-- Animated icons: name -> frame count (120 fps, 14 x 14 cells of 72 px per page, 196 frames a page).
local ICONS = { ["grid-3"] = 73, account = 97, gauge = 253, compass = 133, cog = 121, ["document-list"] = 157 }
local TAB_ICONS = {
	Overview = "grid-3", Combat = "account", Movement = "gauge", Catcher = "account", Teleport = "compass",
	Servers = "document-list", Visuals = "grid-3", Edits = "document-list", Misc = "cog", Settings = "cog",
}
local ICON_RATE = 120
local ICON_CELLS = 196
local SFX_LEVEL = { hover = 0.2, click = 0.35, tab = 0.3, open = 0.35, close = 0.3, toggle_on = 0.4, toggle_off = 0.35, saved = 0.4 }

-- Downloads and unpacks the asset pack on its own thread (a blocking request on the main thread would stutter the game).
local function ensureAssets()
	if assetsState ~= "idle" then return end
	assetsState = "loading"

	task.spawn(function()
		pcall(setthreadidentity, 8)
		local success = pcall(function()
			if isfile(ASSET_MARKER) then return end

			local index = httpService:JSONDecode(request({ Url = ASSET_BASE .. "ui.json?t=" .. os.time(), Method = "GET" }).Body)
			local pack = request({ Url = ASSET_BASE .. "ui.pack", Method = "GET" })
			assert(pack.Success and #pack.Body == index.total, "asset pack incomplete")

			local built = ""
			for part in string.gmatch(ASSET_FOLDER, "[^/]+") do
				built = built == "" and part or (built .. "/" .. part)
				if not isfolder(built) then makefolder(built) end
			end

			local cursor = 0
			for _, file in index.files do
				writefile(ASSET_FOLDER .. "/hv_" .. string.gsub(file.name, "/", "_"), string.sub(pack.Body, cursor + 1, cursor + file.size))
				cursor += file.size
			end
			writefile(ASSET_MARKER, "1")
		end)

		local ready = success and pcall(isfile, ASSET_MARKER) and isfile(ASSET_MARKER)
		assetsState = ready and "ready" or "failed"
	end)
end

-- An asset as a content id, or nil while the pack is not on disk.
---@param name string
---@return string?
local function assetId(name)
	if assetsState ~= "ready" then return nil end
	if assetIds[name] ~= nil then return assetIds[name] or nil end

	local success, id = pcall(function()
		return getcustomasset(ASSET_FOLDER .. "/hv_" .. string.gsub(name, "/", "_"))
	end)
	assetIds[name] = (success and type(id) == "string" and id ~= "") and id or false
	return assetIds[name] or nil
end

-- A short interface sound (CC0 set from the reference). Quiet when sounds are off.
---@param name string
local function playSfx(name)
	if not active or not active.sounds then return end

	local enabled = HussUI.Flags.ui_sfx
	if enabled and not enabled.Value then return end

	local id = assetId("sounds/" .. name .. ".ogg")
	if not id then return end

	local level = HussUI.Flags.ui_sfxVolume and HussUI.Flags.ui_sfxVolume.Value or 55
	local sound = active.sounds[name]
	if not sound then
		sound = create("Sound", { Name = "Sfx_" .. name, SoundId = id }, active.gui)
		active.sounds[name] = sound
	end

	sound.Volume = (SFX_LEVEL[name] or 0.3) * level / 100 * 2
	sound.TimePosition = 0
	sound:Play()
end

-- One animated line icon. The still last frame shows at rest; play() runs it from the start.
---@param parent Instance
---@param name string
---@param size number
---@param position UDim2
---@return table
local function newIcon(parent, name, size, position)
	local image = create("ImageLabel", { Size = UDim2.fromOffset(size, size), Position = position, AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 1, ImageColor3 = COLORS.muted, ImageRectSize = Vector2.new(72, 72), Visible = false, ZIndex = 2 }, parent)
	local player = { image = image, name = name, count = ICONS[name], playing = false, clock = 0, shown = false }

	-- Shows one frame (0-based). False while its page is not available yet.
	function player:setFrame(frame)
		frame = math.clamp(math.floor(frame), 0, self.count - 1)
		local id = assetId(string.format("icons/%s-%02d.png", self.name, frame // ICON_CELLS + 1))
		if not id then return false end

		local cell = frame % ICON_CELLS
		image.Image = id
		image.ImageRectOffset = Vector2.new((cell % 14) * 72, (cell // 14) * 72)
		image.Visible = true
		return true
	end

	function player:play()
		self.playing, self.clock = true, 0
	end

	table.insert(active.icons, player)
	return player
end

-- Advances every playing icon, and reveals each one as soon as its page exists.
---@param deltaTime number
local function stepIcons(deltaTime)
	if not active or assetsState ~= "ready" then return end

	for _, player in active.icons do
		if not player.shown then
			-- Rest on the finished frame; the still glyph steps aside.
			if player:setFrame(player.count - 1) then
				player.shown = true
				if player.owner then player.owner.glyph.Visible = false end
			end
		elseif player.playing then
			player.clock += deltaTime
			local frame = math.floor(player.clock * ICON_RATE)
			if frame >= player.count - 1 then
				player.playing = false
				frame = player.count - 1
			end
			player:setFrame(frame)
		end
	end
end

---@param tab table
---@param opts table
---@param kind string
---@param apply function
---@return table
local function registerFlag(tab, opts, kind, apply)
	local entry = { Type = kind, Value = nil }
	entry.Set = function(value)
		apply(value, false)
	end

	if not opts.NoFlag then
		HussUI.Flags[opts.Flag or (tab.name .. "_" .. tostring(opts.Text))] = entry
	end

	return entry
end

---@param scale UIScale
local function squish(scale)
	scale.Scale = 0.985
	tween(scale, 0.2, { Scale = 1 }, QUINT)
end

-- Rows -------------------------------------------------------------------------------------------------------------------
-- One column of full-width rows (the reference's layout): a tracked section label, then 52 px raised rows with a hairline
-- edge. Long text wraps and the row grows to fit.

local Tab = {}
Tab.__index = Tab

-- Width of a row's text before the controls on its right, used to measure wrapped text before the layout exists.
local ROW_TEXT = LIST_WIDTH - 24

---@param content string
---@param width number
---@param size number?
---@param font Enum.Font?
---@return number
local function measure(content, width, size, font)
	return math.ceil(textService:GetTextSize(tostring(content), size or 13, font or BOLD, Vector2.new(width, 1000)).Y)
end

-- A raised row inside the tab's list.
---@param tab table
---@param height number
---@param clickable boolean
---@return Instance, UIScale
local function newRow(tab, height, clickable)
	tab.order = tab.order + 1

	local props = {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = COLORS.card,
		BorderSizePixel = 0,
		LayoutOrder = tab.order,
	}
	if clickable then
		props.Text = ""
		props.AutoButtonColor = false
	end

	local row = create(clickable and "TextButton" or "Frame", props, tab.list)
	corner(row, RADIUS)
	stroke(row, 0.5, 1, COLORS.line)
	local scale = create("UIScale", { Scale = 1 }, row)

	track(row.MouseEnter:Connect(function()
		tween(row, 0.2, { BackgroundColor3 = COLORS.overlay })
	end))
	track(row.MouseLeave:Connect(function()
		tween(row, 0.25, { BackgroundColor3 = COLORS.card })
	end))

	return row, scale
end

-- A tracked, tiny, upper-case label that starts a group of rows.
---@param content string
function Tab:AddSection(content)
	self.order = self.order + 1
	if content == "" then return end

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = self.order }, self.list)
	label(holder, spaced(content), 9, COLORS.faint, BOLD, { Position = UDim2.fromOffset(2, 13), Size = UDim2.new(1, -4, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd })
end

-- A paragraph: raised, padded, dim text.
---@param content string
---@return table
function Tab:AddLabel(content)
	self.order = self.order + 1

	local card = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = COLORS.card, BorderSizePixel = 0, LayoutOrder = self.order }, self.list)
	corner(card, RADIUS)
	stroke(card, 0.5, 1, COLORS.line)
	create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12) }, card)

	local item = label(card, content, 12, COLORS.dim, BODY, {
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	return {
		SetText = function(_, value)
			item.Text = value
		end,
	}
end

---@param opts table
function Tab:AddButton(opts)
	local row, scale = newRow(self, 38, true)
	label(row, opts.Text, 13, COLORS.text, STRONG, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	track(row.Activated:Connect(function()
		squish(scale)
		active.sfx("click")
		safeCall(opts.Callback)
	end))
end

-- Short label for a key on the bind chip.
---@param key Enum.KeyCode?
---@return string
local function keyLabel(key)
	if not key then return "-" end

	local short = {
		LeftControl = "LCtrl", RightControl = "RCtrl", LeftShift = "LShift", RightShift = "RShift", LeftAlt = "LAlt",
		RightAlt = "RAlt", Backspace = "Bksp", Return = "Enter", Insert = "Ins", Delete = "Del", PageUp = "PgUp",
		PageDown = "PgDn", Space = "Space", Backquote = "~", Minus = "-", Equals = "=", Zero = "0", One = "1", Two = "2",
		Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
	}
	return short[key.Name] or key.Name
end

-- A toggle row: a pill switch on the right. Every toggle gets a bind chip (click it, press a key; Esc / Backspace clears)
-- unless Bind = false, and is listed in the on-screen keybind list while enabled unless NoList = true.
---@param opts table
---@return table
function Tab:AddToggle(opts)
	local value = false
	local key = opts.Key
	local bindable = opts.Bind ~= false and not opts.NoFlag
	local reserved = bindable and 132 or 78
	local height = math.max(ROW_HEIGHT, measure(opts.Text, ROW_TEXT - reserved) + 22)
	local row, scale = newRow(self, height, true)
	label(row, opts.Text, 13, COLORS.text, BOLD, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -reserved, 1, 0),
		TextWrapped = true,
	})

	local rail = create("Frame", { Size = UDim2.fromOffset(38, 21), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), BackgroundColor3 = COLORS.hover, BorderSizePixel = 0, ZIndex = 2 }, row)
	corner(rail, 999)
	local railStroke = stroke(rail, 0.4, 1, COLORS.lineStrong)
	local fill = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.accent, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2 }, rail)
	corner(fill, 999)
	local knob = create("Frame", { Size = UDim2.fromOffset(15, 15), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), BackgroundColor3 = COLORS.dim, BorderSizePixel = 0, ZIndex = 3 }, rail)
	corner(knob, 999)

	local chip
	if bindable then
		chip = create("TextButton", {
			Text = "",
			AutoButtonColor = false,
			Font = MONO,
			TextSize = 10,
			TextColor3 = COLORS.muted,
			Size = UDim2.fromOffset(52, 22),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -62, 0.5, 0),
			BackgroundColor3 = COLORS.track,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, row)
		corner(chip, 5)
		stroke(chip, 0.55, 1, COLORS.line)
	end

	local function refreshList()
		if active.refreshKeyList then active.refreshKeyList() end
	end

	local entry
	local function apply(incoming, silent)
		local was = value
		value = incoming == true
		entry.Value = value
		tween(fill, 0.25, { BackgroundTransparency = value and 0 or 1 })
		tween(knob, 0.25, { Position = UDim2.new(0, value and 20 or 3, 0.5, 0), BackgroundColor3 = value and COLORS.ink or COLORS.dim }, QUINT)
		tween(railStroke, 0.25, { Transparency = value and 1 or 0.4 })

		if was ~= value then
			self.enabled = self.enabled + (value and 1 or -1)
			if self.refreshBadge then self.refreshBadge() end
			refreshList()
			if not silent then active.sfx(value and "toggle_on" or "toggle_off") end
		end
		if not silent then safeCall(opts.Callback, value) end
	end

	entry = registerFlag(self, opts, "Toggle", apply)
	apply(opts.Default == true, true)

	track(row.Activated:Connect(function()
		squish(scale)
		apply(not value, false)
	end))

	if not opts.NoList then
		table.insert(active.listed, {
			text = opts.Text,
			isOn = function() return value end,
			key = function() return key end,
		})
	end

	if bindable then
		local flagName = (opts.Flag or (self.name .. "_" .. tostring(opts.Text))) .. "_bind"
		local function applyKey(incoming)
			if incoming == "None" or incoming == "" then incoming = nil end
			if typeof(incoming) == "string" then incoming = Enum.KeyCode[incoming] end
			key = incoming
			HussUI.Flags[flagName].Value = key and key.Name or "None"
			chip.Text = keyLabel(key)
			chip.TextColor3 = key and COLORS.accent or COLORS.muted
			refreshList()
		end

		HussUI.Flags[flagName] = { Type = "Bind", Value = key and key.Name or "None", Set = applyKey }
		chip.Text = keyLabel(key)
		chip.TextColor3 = key and COLORS.accent or COLORS.muted

		track(chip.Activated:Connect(function()
			if active.capturing then return end

			active.capturing = true
			chip.Text = "..."

			local connection
			connection = userInputService.InputBegan:Connect(function(input)
				if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

				connection:Disconnect()
				active.capturing = false
				if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Backspace then
					applyKey(nil)
					return
				end

				applyKey(input.KeyCode)
			end)
			track(connection)
		end))

		-- Ignored while typing in a TextBox; not while "processed", since many games bind the same keys.
		track(userInputService.InputBegan:Connect(function(input)
			if active.capturing or not key or input.KeyCode ~= key or userInputService:GetFocusedTextBox() then return end

			squish(scale)
			apply(not value, false)
		end))
	end

	return entry
end

---@param opts table
---@return table
function Tab:AddSlider(opts)
	local minimum = opts.Min or 0
	local maximum = opts.Max or 100
	local increment = opts.Increment or 1

	local height = math.max(50, measure(opts.Text, ROW_TEXT - 170) + 26)
	local row = newRow(self, height, false)
	label(row, opts.Text, 13, COLORS.text, BOLD, {
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -170, 0, height - 16),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local readout = label(row, "", 11, COLORS.accent, MONO, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.fromOffset(80, 13),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local rail = create("TextButton", { Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(132, 4), Position = UDim2.new(1, -12, 1, -12), BackgroundColor3 = COLORS.hover, BorderSizePixel = 0, ZIndex = 2 }, row)
	corner(rail, 999)
	local fill = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0, ZIndex = 3 }, rail)
	corner(fill, 999)
	local knob = create("Frame", { Size = UDim2.fromOffset(11, 11), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = COLORS.text, BorderSizePixel = 0, ZIndex = 4 }, rail)
	corner(knob, 999)
	-- A taller invisible strip so the thin track is easy to grab.
	local hit = create("TextButton", { Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 20, 0, 22), BackgroundTransparency = 1, ZIndex = 5 }, rail)

	local entry
	local function apply(incoming, silent)
		local snapped = math.floor((math.clamp(tonumber(incoming) or minimum, minimum, maximum) - minimum) / increment + 0.5) * increment + minimum
		snapped = math.clamp(snapped, minimum, maximum)
		entry.Value = snapped

		local alpha = (maximum - minimum) == 0 and 0 or (snapped - minimum) / (maximum - minimum)
		tween(fill, 0.1, { Size = UDim2.fromScale(alpha, 1) })
		tween(knob, 0.1, { Position = UDim2.fromScale(alpha, 0.5) })
		readout.Text = formatNumber(snapped) .. (opts.Suffix or "")
		if not silent then safeCall(opts.Callback, snapped) end
	end

	entry = registerFlag(self, opts, "Slider", apply)
	apply(opts.Default or minimum, true)

	local dragging = false
	local function fromInput(position)
		local alpha = math.clamp((position.X - rail.AbsolutePosition.X) / math.max(rail.AbsoluteSize.X, 1), 0, 1)
		apply(minimum + (maximum - minimum) * alpha, false)
	end

	track(hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			tween(knob, 0.15, { Size = UDim2.fromOffset(14, 14) }, QUINT)
			fromInput(input.Position)
		end
	end))
	track(userInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			fromInput(input.Position)
		end
	end))
	track(userInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			tween(knob, 0.15, { Size = UDim2.fromOffset(11, 11) }, QUINT)
		end
	end))

	return entry
end

---@param opts table
---@return table
function Tab:AddDropdown(opts)
	local options = opts.Options or {}
	local value = opts.Default or options[1]
	local open = false

	local height = math.max(ROW_HEIGHT, measure(opts.Text, ROW_TEXT - 230) + 22)
	local row = newRow(self, height, false)
	row.ClipsDescendants = true

	local header = create("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, height) }, row)
	label(header, opts.Text, 13, COLORS.text, BOLD, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -230, 1, 0),
		TextWrapped = true,
	})
	local readout = label(header, "", 11, COLORS.accent, MONO, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -36, 0, 0),
		Size = UDim2.fromOffset(170, height),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	-- Gotham has no arrow glyph, so the chevron is two rotated bars.
	local chevron = create("Frame", { Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), BackgroundTransparency = 1 }, header)
	for _, arm in { { x = 4.5, rotation = 45 }, { x = 9.5, rotation = -45 } } do
		create("Frame", { Size = UDim2.fromOffset(8, 2), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(arm.x, 7), Rotation = arm.rotation, BorderSizePixel = 0, BackgroundColor3 = COLORS.muted }, chevron)
	end

	local list = create("Frame", { Size = UDim2.new(1, -12, 0, 0), Position = UDim2.fromOffset(6, height + 2), BackgroundTransparency = 1 }, row)
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	local entry
	local buttons = {}

	local function paint()
		for name, button in buttons do
			local selected = name == value
			tween(button, 0.2, { BackgroundTransparency = selected and 0.86 or 1 })
			button.Font = selected and STRONG or BODY
		end
	end

	local function apply(incoming, silent)
		if incoming == nil or not table.find(options, incoming) then return end

		value = incoming
		entry.Value = incoming
		readout.Text = tostring(incoming)
		paint()
		if not silent then safeCall(opts.Callback, incoming) end
	end

	local function setOpen(state)
		open = state
		tween(row, 0.35, { Size = UDim2.new(1, 0, 0, open and (height + #options * 30 + 10) or height) }, QUINT)
		tween(chevron, 0.3, { Rotation = open and 180 or 0 }, BACK)
	end

	local function build()
		for _, button in buttons do
			button:Destroy()
		end
		table.clear(buttons)

		for index, name in options do
			local button = create("TextButton", {
				Text = tostring(name),
				Font = BODY,
				TextSize = 12,
				TextColor3 = COLORS.text,
				AutoButtonColor = false,
				Size = UDim2.new(1, 0, 0, 28),
				BackgroundColor3 = COLORS.accent,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				LayoutOrder = index,
			}, list)
			corner(button, 5)
			buttons[name] = button

			track(button.Activated:Connect(function()
				apply(name, false)
				active.sfx("click")
				setOpen(false)
			end))
		end
	end

	entry = registerFlag(self, opts, "Dropdown", apply)
	build()
	apply(value, true)

	track(header.Activated:Connect(function()
		active.sfx("click")
		setOpen(not open)
	end))

	entry.SetOptions = function(newOptions)
		options = newOptions
		build()
		if not table.find(options, value) then value = options[1] end
		entry.Value = value
		readout.Text = tostring(value or "")
		paint()
	end

	return entry
end

---@param opts table
---@return table
function Tab:AddKeybind(opts)
	local key = opts.Default
	local height = math.max(ROW_HEIGHT, measure(opts.Text, ROW_TEXT - 110) + 22)
	local row = newRow(self, height, false)
	label(row, opts.Text, 13, COLORS.text, BOLD, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -110, 1, 0),
		TextWrapped = true,
	})

	local pill = create("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Font = MONO,
		TextSize = 11,
		TextColor3 = COLORS.accent,
		Size = UDim2.fromOffset(78, 26),
		TextTruncate = Enum.TextTruncate.AtEnd,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		BackgroundColor3 = COLORS.track,
		BorderSizePixel = 0,
	}, row)
	corner(pill, 5)
	stroke(pill, 0.55, 1, COLORS.line)

	local entry
	local function apply(incoming, silent)
		if typeof(incoming) == "string" then incoming = Enum.KeyCode[incoming] end
		key = incoming
		entry.Value = key
		pill.Text = key and keyLabel(key) or "None"
		if not silent then safeCall(opts.Callback, key) end
	end

	entry = registerFlag(self, opts, "Keybind", apply)
	apply(key, true)

	track(pill.Activated:Connect(function()
		if active.capturing then return end

		active.capturing = true
		pill.Text = "..."

		local connection
		connection = userInputService.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

			connection:Disconnect()
			active.capturing = false
			if input.KeyCode == Enum.KeyCode.Escape then
				apply(key, true)
				return
			end

			apply(input.KeyCode, false)
		end)
		track(connection)
	end))

	-- Ignored while typing in a TextBox; not while "processed", since many games bind the same keys.
	track(userInputService.InputBegan:Connect(function(input)
		if active.capturing or not key or input.KeyCode ~= key or userInputService:GetFocusedTextBox() then return end

		safeCall(opts.Pressed)
	end))

	return entry
end

---@param opts table
---@return table
function Tab:AddInput(opts)
	local row = newRow(self, ROW_HEIGHT, false)
	label(row, opts.Text, 13, COLORS.text, BOLD, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.4, 0, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local box = create("TextBox", {
		Text = "",
		PlaceholderText = opts.Placeholder or "",
		PlaceholderColor3 = COLORS.faint,
		TextColor3 = COLORS.text,
		Font = MONO,
		TextSize = 11,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0.5, -16, 0, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		BackgroundColor3 = COLORS.track,
		BorderSizePixel = 0,
	}, row)
	corner(box, 5)
	stroke(box, 0.55, 1, COLORS.line)
	create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, box)

	local entry
	local function apply(incoming, silent)
		box.Text = tostring(incoming or "")
		entry.Value = box.Text
		if not silent then safeCall(opts.Callback, box.Text) end
	end

	entry = registerFlag(self, opts, "Input", apply)
	apply(opts.Default or "", true)

	track(box.FocusLost:Connect(function()
		entry.Value = box.Text
		safeCall(opts.Callback, box.Text)
	end))

	return entry
end

local PALETTE = {
	"#FF5F6D", "#FF9F5A", "#FFD166", "#7CE38B", "#4FD6C8", "#70A8FF",
	"#9B8CFF", "#E58CFF", "#FF8FB8", "#FFFFFF", "#B8B0A8", "#1A1614",
}

-- A swatch row that expands into a preset palette.
---@param opts table
---@return table
function Tab:AddColor(opts)
	local value = opts.Default or Color3.new(1, 1, 1)
	local open = false

	local row = newRow(self, ROW_HEIGHT, false)
	row.ClipsDescendants = true

	local header = create("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROW_HEIGHT) }, row)
	label(header, opts.Text, 13, COLORS.text, BOLD, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -80, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local swatch = create("Frame", { Size = UDim2.fromOffset(34, 18), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), BorderSizePixel = 0 }, header)
	corner(swatch, 5)
	stroke(swatch, 0.5, 1, COLORS.lineStrong)

	local grid = create("Frame", { Position = UDim2.fromOffset(12, ROW_HEIGHT), Size = UDim2.new(1, -24, 0, 64), BackgroundTransparency = 1 }, row)
	create("UIGridLayout", { CellSize = UDim2.fromOffset(30, 26), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, grid)

	local entry
	local function apply(incoming, silent)
		if typeof(incoming) == "string" then incoming = fromHex(incoming) end
		if typeof(incoming) ~= "Color3" then return end

		value = incoming
		entry.Value = value
		tween(swatch, 0.2, { BackgroundColor3 = value })
		if not silent then safeCall(opts.Callback, value) end
	end

	entry = registerFlag(self, opts, "Color", apply)
	apply(value, true)

	for index, hex in PALETTE do
		local chip = create("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = fromHex(hex), BorderSizePixel = 0, LayoutOrder = index }, grid)
		corner(chip, 5)
		stroke(chip, 0.6, 1, COLORS.lineStrong)
		track(chip.Activated:Connect(function()
			apply(fromHex(hex), false)
		end))
	end

	track(header.Activated:Connect(function()
		open = not open
		tween(row, 0.35, { Size = UDim2.new(1, 0, 0, open and ROW_HEIGHT + 76 or ROW_HEIGHT) }, QUINT)
	end))

	return entry
end

-- A full-width row of tiles: small tracked title, value, one line of detail. Get returns valueText, alpha 0..1 (1 = on), subText.
---@param specs table
function Tab:AddStatRow(specs)
	self.order = self.order + 1

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 68), BackgroundTransparency = 1, LayoutOrder = self.order }, self.list)
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, holder)

	local count = #specs
	for index, spec in specs do
		local card = create("Frame", {
			Size = UDim2.new(1 / count, -10 * (count - 1) / count, 1, 0),
			BackgroundColor3 = COLORS.card,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			LayoutOrder = index,
		}, holder)
		corner(card, RADIUS)
		stroke(card, 0.5, 1, COLORS.line)

		local truncate = Enum.TextTruncate.AtEnd
		label(card, string.upper(spec.Title), 10, COLORS.faint, BOLD, { Position = UDim2.fromOffset(12, 10), Size = UDim2.new(1, -24, 0, 12), TextTruncate = truncate })
		local value = label(card, "", 15, COLORS.accent, MONO, { Position = UDim2.fromOffset(12, 26), Size = UDim2.new(1, -24, 0, 18), TextTruncate = truncate })
		local sub = label(card, "", 9, COLORS.muted, MONO, { Position = UDim2.fromOffset(12, 47), Size = UDim2.new(1, -24, 0, 12), TextTruncate = truncate })

		table.insert(active.statCards, { spec = spec, value = value, sub = sub, segments = {}, shown = -1 })
	end
end

-- A full-width block above the two columns (stat rows and the film viewer live here).
---@param height number
---@return Frame
function Tab:AddWide(height)
	self.order = self.order + 1

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = COLORS.card, BorderSizePixel = 0, ClipsDescendants = true, LayoutOrder = self.order }, self.list)
	corner(holder, RADIUS)
	stroke(holder, 0.5, 1, COLORS.line)
	return holder
end

---@param tab table
---@return boolean
local function tabShown(tab)
	return active ~= nil and active.visible and tab.window.current == tab
end

---@param parent Instance
---@param content string
---@param size UDim2
---@param position UDim2
---@param callback function
---@return TextButton
local function outlineButton(parent, content, size, position, callback)
	local button = create("TextButton", {
		Text = content,
		Font = MONO,
		TextSize = 11,
		TextColor3 = COLORS.text,
		AutoButtonColor = false,
		BackgroundColor3 = COLORS.row,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = size,
		Position = position,
	}, parent)
	corner(button, 3)
	stroke(button, 0.62)
	track(button.MouseEnter:Connect(function()
		tween(button, 0.2, { BackgroundTransparency = 0.9 })
	end))
	track(button.MouseLeave:Connect(function()
		tween(button, 0.25, { BackgroundTransparency = 1 })
	end))
	track(button.Activated:Connect(callback))
	return button
end

-- The film viewer: a portrait stage, transport controls, a timeline and the list of edits. spec.Edits is the HussEdits module;
-- spec.OnUse(edit) is called by "Use at start". Returns { select, setVolume, pause }.
---@param spec table
---@return table
function Tab:AddFilm(spec)
	local Edits = spec.Edits
	local card = self:AddWide(372)

	local STAGE_W, STAGE_H = 196, 348
	local stageHost = create("Frame", { Position = UDim2.fromOffset(8, 8), Size = UDim2.fromOffset(STAGE_W, STAGE_H), BackgroundColor3 = Color3.fromRGB(4, 4, 4), BorderSizePixel = 0, ClipsDescendants = true }, card)
	corner(stageHost, 4)
	stroke(stageHost, 0.8)

	-- Idle picture: the cover of the selected edit, dimmed, with a prompt.
	local poster = create("ImageLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Crop, ImageTransparency = 0.45, ImageRectSize = Vector2.new(144, 256), ZIndex = 2 }, stageHost)
	local prompt = label(stageHost, "SELECT AN EDIT", 11, COLORS.text, MONO, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -20, 0, 20), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 4 })
	local stageButton = create("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 6, AutoButtonColor = false }, stageHost)

	local rightX = STAGE_W + 28
	local titleLabel = label(card, "Edits", 30, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(rightX, 12), Size = UDim2.new(1, -rightX - 16, 0, 38), TextTruncate = Enum.TextTruncate.AtEnd })
	local subLabel = label(card, "NO EDIT LOADED", 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(rightX, 52), Size = UDim2.new(1, -rightX - 16, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd })

	local function transportButton(content, width, x, callback)
		return outlineButton(card, content, UDim2.fromOffset(width, 30), UDim2.fromOffset(rightX + x, 80), callback)
	end

	local state = { edit = nil, player = nil, token = 0, rows = {}, loading = false }

	local function setPrompt(content, visible)
		prompt.Text = content
		prompt.Visible = visible
	end

	local function stop()
		if state.player then
			state.player:destroy()
			state.player = nil
		end
	end

	-- Loads (downloading when needed) and optionally starts an edit.
	local select
	local function indexOf(edit)
		for index, other in Edits.manifest.edits do
			if other == edit then return index end
		end
		return 1
	end

	local playButton
	local resetTimeline
	function select(edit, autoplay)
		if not edit or state.loading then return end

		state.token += 1
		local token = state.token
		stop()
		state.edit = edit
		if resetTimeline then resetTimeline(edit) end
		titleLabel.Text = edit.title
		subLabel.Text = string.format("EDIT %02d   /   %s   /   %s", indexOf(edit), string.upper(edit.subtitle or ""), Edits.clock(edit.duration))
		poster.Visible = true
		local thumbs = Edits.thumbs()
		if thumbs then
			poster.Image = thumbs
			poster.ImageRectOffset = Vector2.new((edit.thumb or 0) * 144, 0)
		end
		for _, entry in state.rows do
			entry.refresh()
		end

		state.loading = true
		setPrompt(Edits.isInstalled(edit) and "OPENING" or "FETCHING  0%", true)
		task.spawn(function()
			pcall(setthreadidentity, 8)
			local ok, reason = Edits.install(edit, function(fraction)
				if token == state.token then prompt.Text = string.format("FETCHING  %d%%", math.floor(fraction * 100)) end
			end)
			state.loading = false
			if token ~= state.token or not active then return end

			if not ok then
				setPrompt("COULD NOT LOAD  /  " .. string.upper(tostring(reason)), true)
				return
			end

			local made, player = pcall(Edits.newPlayer, stageHost, edit, { volume = math.min(Edits.prefs.volume, 1), name = "Film", ZIndex = 3, fit = true })
			if not made then
				setPrompt("COULD NOT PLAY", true)
				return
			end

			state.player = player
			player:prepare(5)
			poster.Visible = false
			setPrompt("", false)
			for _, entry in state.rows do
				entry.refresh()
			end
			if autoplay then player:play() end
		end)
	end

	local function toggle()
		local player = state.player
		if not player then
			if state.edit then select(state.edit, true) elseif Edits.manifest then select(Edits.manifest.edits[1], true) end
			return
		end

		if player.playing then player:pause() else player:play() end
	end

	local function step(offset)
		if not Edits.manifest then return end

		local count = #Edits.manifest.edits
		local index = state.edit and indexOf(state.edit) or 0
		select(Edits.manifest.edits[(index - 1 + offset) % count + 1], true)
	end

	track(stageButton.Activated:Connect(toggle))
	transportButton("PREV", 58, 0, function() step(-1) end)
	playButton = transportButton("PLAY", 78, 66, toggle)
	transportButton("NEXT", 58, 152, function() step(1) end)
	transportButton("USE AT START", 120, 218, function()
		if state.edit and spec.OnUse then spec.OnUse(state.edit) end
	end)

	-- Timeline.
	local clockLeft = label(card, "00:00", 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(rightX, 122), Size = UDim2.fromOffset(60, 14) })
	local clockRight = label(card, "00:00", 10, COLORS.muted, MONO, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 122), Size = UDim2.fromOffset(60, 14), TextXAlignment = Enum.TextXAlignment.Right })
	local timeline = create("TextButton", { Text = "", AutoButtonColor = false, Position = UDim2.fromOffset(rightX, 142), Size = UDim2.new(1, -rightX - 16, 0, 12), BackgroundTransparency = 1 }, card)
	local timelineRail = create("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.82, BorderSizePixel = 0 }, timeline)
	local timelineFill = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0 }, timelineRail)
	local timelineKnob = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0 }, timelineRail)
	corner(timelineKnob, 4)

	-- A freshly chosen edit starts from zero on the readout, not from the last one's clock.
	function resetTimeline(edit)
		timelineFill.Size = UDim2.fromScale(0, 1)
		timelineKnob.Position = UDim2.fromScale(0, 0.5)
		clockLeft.Text = "00:00"
		clockRight.Text = Edits.clock(edit.duration)
		playButton.Text = "PLAY"
	end

	local scrubbing = false
	local function scrubTo(position)
		local player = state.player
		if not player then return end

		local alpha = math.clamp((position.X - timeline.AbsolutePosition.X) / math.max(timeline.AbsoluteSize.X, 1), 0, 1)
		player:seek(alpha * state.edit.duration)
	end
	track(timeline.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			scrubbing = true
			scrubTo(input.Position)
		end
	end))
	track(userInputService.InputChanged:Connect(function(input)
		if scrubbing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then scrubTo(input.Position) end
	end))
	track(userInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then scrubbing = false end
	end))

	-- The list of edits.
	local listTop = 168
	local listHolder = create("ScrollingFrame", { Position = UDim2.fromOffset(rightX, listTop), Size = UDim2.new(1, -rightX - 16, 1, -listTop - 12), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = COLORS.lineStrong, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new() }, card)
	create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, listHolder)
	local listNotice = label(listHolder, "LOADING THE EDIT LIBRARY", 10, COLORS.muted, MONO, { Size = UDim2.new(1, 0, 0, 20) })

	local function buildList()
		listNotice:Destroy()
		local thumbs = Edits.thumbs()
		for index, edit in Edits.manifest.edits do
			local row = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.96, BorderSizePixel = 0, LayoutOrder = index }, listHolder)
			corner(row, 4)
			local mark = create("Frame", { Size = UDim2.fromOffset(2, 22), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = COLORS.accent, BackgroundTransparency = 1, BorderSizePixel = 0 }, row)
			local cover = create("ImageLabel", { Position = UDim2.fromOffset(10, 3), Size = UDim2.fromOffset(16, 28), BackgroundColor3 = COLORS.track, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Crop, Image = thumbs or "", ImageRectOffset = Vector2.new((edit.thumb or 0) * 144, 0), ImageRectSize = Vector2.new(144, 256) }, row)
			corner(cover, 2)
			label(row, string.format("%02d", index), 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(36, 0), Size = UDim2.fromOffset(22, 34) })
			label(row, edit.title, 13, COLORS.text, BODY, { Position = UDim2.fromOffset(62, 2), Size = UDim2.new(1, -190, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
			label(row, string.upper(edit.subtitle or ""), 9, COLORS.muted, MONO, { Position = UDim2.fromOffset(62, 18), Size = UDim2.new(1, -190, 0, 12), TextTruncate = Enum.TextTruncate.AtEnd })
			local status = label(row, "", 10, COLORS.muted, MONO, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Size = UDim2.fromOffset(110, 34), TextXAlignment = Enum.TextXAlignment.Right })

			local entry = {}
			function entry.refresh()
				local selected = state.edit == edit
				tween(row, 0.2, { BackgroundTransparency = selected and 0.9 or 0.96 })
				tween(mark, 0.2, { BackgroundTransparency = selected and 0 or 1 })
				if selected and state.player and state.player.playing then
					status.Text = "NOW PLAYING"
					status.TextColor3 = COLORS.text
				elseif Edits.isInstalled(edit) then
					status.Text = Edits.clock(edit.duration) .. "   READY"
					status.TextColor3 = COLORS.muted
				else
					status.Text = string.format("%.1f MB", edit.packSize / 1048576)
					status.TextColor3 = COLORS.muted
				end
			end
			entry.refresh()
			state.rows[index] = entry

			track(row.Activated:Connect(function()
				select(edit, true)
			end))
		end
	end

	-- Live readout, and pause whenever the page is not on screen (no music from a hidden menu).
	local lastPlaying = false
	track(runService.Heartbeat:Connect(function()
		local player = state.player
		if player and player.playing and not tabShown(self) then player:pause() end

		local playing = player ~= nil and player.playing
		if playing ~= lastPlaying then
			lastPlaying = playing
			playButton.Text = playing and "PAUSE" or (player and player.ended and "REPLAY" or "PLAY")
			for _, entry in state.rows do
				entry.refresh()
			end
		end
		if not tabShown(self) or not player then return end

		local duration = state.edit.duration
		local alpha = math.clamp(player.time / duration, 0, 1)
		timelineFill.Size = UDim2.fromScale(alpha, 1)
		timelineKnob.Position = UDim2.fromScale(alpha, 0.5)
		clockLeft.Text = Edits.clock(player.time)
		clockRight.Text = Edits.clock(duration)
		if player.ended and playButton.Text ~= "REPLAY" then playButton.Text = "REPLAY" end
	end))

	task.spawn(function()
		pcall(setthreadidentity, 8)
		local manifest, failure = Edits.getManifest()
		if not active then return end

		if not manifest then
			listNotice.Text = "OFFLINE  /  " .. string.upper(tostring(failure))
			return
		end

		buildList()
		local first = Edits.pickStart()
		if first then
			state.edit = first
			titleLabel.Text = first.title
			subLabel.Text = string.format("EDIT %02d   /   %s   /   %s", indexOf(first), string.upper(first.subtitle or ""), Edits.clock(first.duration))
			local thumbs = Edits.thumbs()
			if thumbs then
				poster.Image = thumbs
				poster.ImageRectOffset = Vector2.new((first.thumb or 0) * 144, 0)
			end
			setPrompt("PRESS PLAY", true)
			for _, entry in state.rows do
				entry.refresh()
			end
		end
	end)

	return {
		select = select,
		setVolume = function(volume)
			if state.player then state.player:setVolume(volume) end
		end,
		pause = function()
			if state.player then state.player:pause() end
		end,
		refresh = function()
			for _, entry in state.rows do
				entry.refresh()
			end
		end,
	}
end

-- Window -----------------------------------------------------------------------------------------------------------------

local Window = {}
Window.__index = Window

---@param name string
function Window:CreateCategory(name)
	self.order = self.order + 1
	label(self.navList, spaced(name), 9, COLORS.faint, BOLD, {
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = self.order,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Position = UDim2.fromOffset(10, 0),
	}).Name = "Category"
end

-- Whether a tab is on screen right now.
---@param tab table
---@return boolean
local function tabIsShown(tab)
	return active ~= nil and active.visible and tab.window.current == tab
end

-- Moves the sliding pill and edge bar to a tab. The tab's place is read from the layout, so any order of tabs works.
---@param window table
---@param tab table
---@param immediate boolean
local function movePill(window, tab, immediate)
	local factor = math.max(window.main.AbsoluteSize.X / WINDOW_WIDTH, 0.01)
	local offset = (tab.button.AbsolutePosition.Y - window.navList.AbsolutePosition.Y) / factor
	local pillPosition = UDim2.fromOffset(0, offset)
	-- The bar lives in the sidebar (the nav list would clip it), so the nav list's own offset and scroll are added here.
	local barPosition = UDim2.fromOffset(1, window.navHolder.Position.Y.Offset + offset - window.navHolder.CanvasPosition.Y + TAB_HEIGHT * 0.275)

	window.pill.Visible, window.pillBar.Visible = true, true
	if immediate then
		window.pill.Position, window.pillBar.Position = pillPosition, barPosition
	else
		tween(window.pill, 0.45, { Position = pillPosition })
		tween(window.pillBar, 0.45, { Position = barPosition })
	end
end

-- Page rows fade in one after another when a page opens (the reference's cascade). Every transparency a row draws is noted,
-- set to invisible, then brought back in turn: first row at once, then one every STEP seconds, capped so a long page does not
-- take long. A new cascade (or the window closing) puts everything back at once.
local CASCADE_STEP = 0.045
local CASCADE_CAP = 0.34
local CASCADE_ROWS = 12
local CASCADE_PROPERTIES = { "BackgroundTransparency", "TextTransparency", "ImageTransparency", "Transparency" }

---@param object Instance
---@param into table
local function noteDrawn(object, into)
	for _, property in CASCADE_PROPERTIES do
		local ok, value = pcall(function()
			return object[property]
		end)
		if ok and type(value) == "number" and value < 1 and (property ~= "Transparency" or object:IsA("UIStroke")) then
			table.insert(into, { object, property, value })
		end
	end
end

local function settleCascade()
	local running = active and active.cascade
	if not running then return end

	active.cascade = nil
	for _, part in running.parts do
		if part[1].Parent then
			pcall(function()
				part[1][part[2]] = part[3]
			end)
		end
	end
end

---@param tab table
local function cascadeIn(tab)
	if not active or HussUI.Flags.ui_animate and not HussUI.Flags.ui_animate.Value then return end

	settleCascade()

	local rows = {}
	for _, child in tab.list:GetChildren() do
		if child:IsA("GuiObject") then table.insert(rows, child) end
	end
	table.sort(rows, function(first, second)
		return first.LayoutOrder < second.LayoutOrder
	end)

	local running = { parts = {} }
	local groups = {}
	for index, row in rows do
		if index > CASCADE_ROWS then break end

		local group = {}
		noteDrawn(row, group)
		for _, descendant in row:GetDescendants() do
			noteDrawn(descendant, group)
		end
		groups[index] = group
		for _, part in group do
			table.insert(running.parts, part)
			part[1][part[2]] = 1
		end
	end
	active.cascade = running

	for index, group in groups do
		task.delay(math.min((index - 1) * CASCADE_STEP, CASCADE_CAP), function()
			if not active or active.cascade ~= running then return end

			for _, part in group do
				if part[1].Parent then tween(part[1], 0.3, { [part[2]] = part[3] }) end
			end
		end)
	end

	-- Whatever is left when it is over is put back exactly.
	task.delay(CASCADE_CAP + (CASCADE_ROWS * 0) + 0.45, function()
		if active and active.cascade == running then settleCascade() end
	end)
end

---@param tab table
local function selectTab(tab)
	local window = tab.window
	if window.current == tab then return end

	local previous = window.current
	window.current = tab

	if previous then
		previous.group.Visible = true
		tween(previous.group, 0.18, { GroupTransparency = 1 })
		tween(previous.title, 0.25, { TextColor3 = COLORS.muted })
		tween(previous.glyph, 0.25, { ImageColor3 = COLORS.muted })
		if previous.animated then tween(previous.animated.image, 0.25, { ImageColor3 = COLORS.muted }) end
		task.delay(0.2, function()
			if window.current ~= previous and previous.group.Parent then previous.group.Visible = false end
		end)
	end

	tab.group.Visible = true
	tab.group.GroupTransparency = 1
	tab.group.Position = UDim2.fromOffset(0, 24)
	tab.scale.Scale = 0.985
	tween(tab.group, 0.5, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) })
	tween(tab.scale, 0.5, { Scale = 1 })
	tween(tab.title, 0.25, { TextColor3 = COLORS.text })
	tween(tab.glyph, 0.25, { ImageColor3 = COLORS.text })
	if tab.animated then
		tween(tab.animated.image, 0.25, { ImageColor3 = COLORS.text })
		tab.animated:play()
	end
	movePill(window, tab, previous == nil)
	if previous then active.sfx("tab") end
	if previous or active.visible then task.defer(cascadeIn, tab) end

	-- The page heading fades in again for every tab.
	window.pageTitle.Text = tab.name
	window.pageSub.Text = tab.subtitle or ""
	window.pageTitle.TextTransparency = 1
	window.pageSub.TextTransparency = 1
	tween(window.pageTitle, 0.45, { TextTransparency = 0 })
	tween(window.pageSub, 0.45, { TextTransparency = 0 })
end

---@param window table
---@param name string
---@param iconName string?
---@param order number
---@return table
local function makeTab(window, name, iconName, order)
	local tab = setmetatable({ name = name, window = window, order = 0, enabled = 0 }, Tab)

	local button = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, TAB_HEIGHT), BackgroundColor3 = COLORS.row, BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = order }, window.navList)
	corner(button, RADIUS)
	tab.button = button

	local glyphImage = icon(iconName)
	tab.glyph = create("ImageLabel", { Image = glyphImage, ImageColor3 = COLORS.muted, BackgroundTransparency = 1, Size = UDim2.fromOffset(20, 20), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 14, 0.5, 0), Visible = glyphImage ~= "" }, button)
	tab.title = label(button, name, 14, COLORS.muted, BODY, { Position = UDim2.fromOffset(46, 0), Size = UDim2.new(1, -86, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })

	-- The animated line icon from the reference. It appears once the asset pack is on disk and replaces the still glyph.
	local animatedName = TAB_ICONS[name]
	if animatedName then
		tab.animated = newIcon(button, animatedName, 24, UDim2.new(0, 12, 0.5, 0))
		tab.animated.owner = tab
	end

	-- Count of switched-on toggles, set in mono at the right.
	local badge = create("TextLabel", { Text = "0", Font = MONO, TextSize = 10, TextColor3 = COLORS.accent2, BackgroundTransparency = 1, Visible = false, Size = UDim2.fromOffset(24, 16), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), TextXAlignment = Enum.TextXAlignment.Right }, button)
	tab.refreshBadge = function()
		badge.Visible = tab.enabled > 0
		badge.Text = string.format("%02d", tab.enabled)
	end

	tab.group = create("CanvasGroup", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1, Visible = false }, window.pages)
	tab.scale = create("UIScale", { Scale = 0.985 }, tab.group)
	tab.list = create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = COLORS.lineStrong,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, tab.group)
	create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, tab.list)
	create("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingLeft = UDim.new(0, 1), PaddingBottom = UDim.new(0, 14), PaddingRight = UDim.new(0, 12) }, tab.list)

	track(button.MouseEnter:Connect(function()
		if window.current ~= tab then tween(button, 0.2, { BackgroundTransparency = 0.95 }) end
		if tab.animated then tab.animated:play() end
		active.sfx("hover")
	end))
	track(button.MouseLeave:Connect(function()
		tween(button, 0.25, { BackgroundTransparency = 1 })
	end))
	track(button.Activated:Connect(function()
		selectTab(tab)
	end))

	table.insert(window.tabs, tab)
	return tab
end

-- The first user tab opens by itself; the built-in Settings tab never does.
---@param name string
---@param iconName string?
---@param subtitle string?
---@return table
function Window:CreateTab(name, iconName, subtitle)
	self.order = self.order + 1

	local tab = makeTab(self, name, iconName, self.order)
	tab.subtitle = subtitle

	-- Only the first tab opens by itself; the layout needs a frame before the pill can be placed.
	if not self.first then
		self.first = tab
		task.defer(function()
			if active and not self.current then selectTab(tab) end
		end)
	end

	return tab
end

-- Opens a tab by its name (the header's Edits button uses this).
---@param name string
function Window:SelectTab(name)
	for _, tab in self.tabs do
		if tab.name == name then
			selectTab(tab)
			return
		end
	end
end

-- A toast: tracked edition line, serif title, dim body, the monogram on the left and a hairline that runs out with the timer.
---@param opts table
function Window:Notify(opts)
	local duration = opts.Duration or 4
	local kinds = { info = "NOTICE", ok = "COMPLETE", warn = "ATTENTION", bad = "UNAVAILABLE" }

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, active.toastHost)
	local card = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(360, 0), BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0, BorderSizePixel = 0, ClipsDescendants = true }, holder)
	corner(card, 10)
	stroke(card, 0.45, 1, COLORS.line)

	label(card, "H", 35, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(20, 14), Size = UDim2.fromOffset(30, 40), TextXAlignment = Enum.TextXAlignment.Center })
	local inner = create("Frame", { Position = UDim2.fromOffset(64, 0), Size = UDim2.new(1, -64, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, card)
	create("UIPadding", { PaddingRight = UDim.new(0, 18), PaddingTop = UDim.new(0, 13), PaddingBottom = UDim.new(0, 20) }, inner)
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, inner)

	label(inner, "HUSS VALLEY  /  " .. (kinds[opts.Kind or "info"] or "NOTICE"), 9, COLORS.muted, MONO, { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 12) })
	label(inner, tostring(opts.Title or ""), 21, COLORS.text, DISPLAY, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 26), TextTruncate = Enum.TextTruncate.AtEnd })
	label(inner, tostring(opts.Text or ""), 12, COLORS.dim, BODY, { LayoutOrder = 3, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })

	local trackLine = create("Frame", { Size = UDim2.new(1, -40, 0, 1), AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 20, 1, -8), BackgroundColor3 = COLORS.line, BorderSizePixel = 0, ZIndex = 4 }, card)
	local timer = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.dim, BackgroundTransparency = 0.3, BorderSizePixel = 0, ZIndex = 5 }, trackLine)

	tween(card, 0.35, { Position = UDim2.fromOffset(0, 0) }, QUINT)
	tween(timer, duration, { Size = UDim2.new(0, 0, 1, 0) }, Enum.EasingStyle.Linear)
	active.sfx("saved")

	task.delay(duration, function()
		if not holder.Parent then return end

		tween(card, 0.35, { Position = UDim2.fromOffset(360, 0) }, QUINT, IN)
		task.delay(0.4, function()
			if holder.Parent then holder:Destroy() end
		end)
	end)
end

-- Floating widget card beside the window. Kind "bars": big value over a bar chart. Kind "stat": value + segmented bar.
-- Get returns valueText, number (chart sample or 0..1 fill), subText.
---@param spec table
function Window:AddWidget(spec)
	local isBars = spec.Kind == "bars"
	local card = create("Frame", {
		Size = UDim2.new(1, 0, 0, isBars and 196 or 112),
		BackgroundColor3 = COLORS.card,
		BorderSizePixel = 0,
		LayoutOrder = #active.widgets + 1,
		ClipsDescendants = true,
	}, active.widgetHost)
	corner(card, RADIUS)
	stroke(card, 0.5, 1, COLORS.line)

	local glyph = create("ImageLabel", { Image = icon(spec.Icon), ImageColor3 = COLORS.text, ImageTransparency = 0.2, BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(14, 13) }, card)
	label(card, string.upper(spec.Title), 10, COLORS.faint, BOLD, { Position = UDim2.fromOffset(spec.Icon and 34 or 14, 12), Size = UDim2.new(1, -48, 0, 16) })
	local value = label(card, "", 15, COLORS.accent, MONO, { Position = UDim2.fromOffset(14, 34), Size = UDim2.new(1, -28, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd })
	local sub = label(card, "", 9, COLORS.muted, MONO, { Position = UDim2.fromOffset(14, 62), Size = UDim2.new(1, -28, 0, 14) })
	if not spec.Icon then glyph.Visible = false end

	local widget = { spec = spec, value = value, sub = sub, kind = spec.Kind, history = {}, elapsed = 0 }

	if isBars then
		local chart = create("Frame", { Position = UDim2.new(0, 14, 1, -14), AnchorPoint = Vector2.new(0, 1), Size = UDim2.new(1, -28, 0, 82), BackgroundTransparency = 1 }, card)
		create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, chart)
		widget.bars = {}
		for index = 1, 9 do
			widget.history[index] = 0
			local bar = create("Frame", { Size = UDim2.new(1 / 9, -6 * 8 / 9, 0, 6), BackgroundColor3 = COLORS.accent, BackgroundTransparency = 0.12, BorderSizePixel = 0, LayoutOrder = index }, chart)
			corner(bar, 4)
			widget.bars[index] = bar
		end
	else
		local bar = create("Frame", { Position = UDim2.new(0, 14, 1, -22), Size = UDim2.new(1, -28, 0, 10), BackgroundTransparency = 1 }, card)
		create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, bar)
		widget.segments = {}
		for segment = 1, SEGMENTS do
			widget.segments[segment] = create("Frame", { Size = UDim2.new(1 / SEGMENTS, -2 * (SEGMENTS - 1) / SEGMENTS, 1, 0), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.9, BorderSizePixel = 0, LayoutOrder = segment }, bar)
			corner(widget.segments[segment], 2)
		end
	end

	table.insert(active.widgets, widget)
end

---@return boolean
function Window:IsOpen()
	return active ~= nil and active.visible
end

-- Dock and minimise ------------------------------------------------------------------------------------------------------
-- The dock is a small pill that parks above the screen and slides to the top centre. Minimising does not shrink the window:
-- it is redrawn as a ring of dots that turns into a circle, folds into an infinity sign, spins down and flies into the pill,
-- which only fades in as the dots land (the reference's "genie"). Clicking the pill cancels anything still moving and
-- brings the window back with the opening animation.

local DOCK_WIDTH, DOCK_HEIGHT = 142, 36
local DOCK_IN_Y, DOCK_OUT_Y = 18, -60
local MORPH_SEGMENTS = 60
-- One long sweep with no bounce (a critically damped spring): it has settled by about 0.95 s.
local MORPH_OMEGA = 7.8
local MORPH_SECONDS = 1.07
-- The bloom around the morph is capped against the shorter screen side, and fainter the larger it gets.
local MORPH_GLOW_CAP = 0.62
local MORPH_GLOW_REF = 620

-- 0..1 with eased ends over a slice of the timeline.
---@param p number
---@param from number
---@param to number
---@return number
local function ramp(p, from, to)
	if to <= from then return p >= to and 1 or 0 end

	local t = math.clamp((p - from) / (to - from), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Where the dock sits: on screen at the top centre, or parked above it. Sizes follow the window's own scale.
---@param shown boolean
---@return UDim2
local function dockPosition(shown)
	return UDim2.new(0.5, 0, 0, (shown and DOCK_IN_Y or DOCK_OUT_Y) * active.dockScale.Scale)
end

-- Everything the dock draws, at its resting opacity times alpha (0 = gone, 1 = fully there).
---@param alpha number
local function setDockAlpha(alpha)
	active.dockAlpha = alpha
	active.dock.BackgroundTransparency = 1 - alpha
	active.dockStroke.Transparency = 1 - (1 - active.dockStrokeBase) * alpha
	active.dockLabel.TextTransparency = 1 - alpha
	active.dockMark.TextTransparency = 1 - alpha
end

---@param shown boolean
local function moveDock(shown)
	active.dockShown = shown
	tween(active.dock, 0.3, { Position = dockPosition(shown) })
end

-- Stops a morph that has not finished (restoring while it runs is an explicit "stop that").
local function cancelMorph()
	if not active then return end

	active.morphToken += 1
	active.morphBusy = false
	if active.morphConnection then
		active.morphConnection:Disconnect()
		active.morphConnection = nil
	end
	if active.morphGui then
		pcall(function() active.morphGui:Destroy() end)
		active.morphGui = nil
	end
end

-- The dock's own life: its halo breathes and the mark's halo drifts around the monogram (only while it is on screen).
---@param deltaTime number
local function stepDock(deltaTime)
	if not active or not active.dock then return end

	if not active.glowReady then
		local id = assetId("images/glow.png")
		if id then
			active.dockGlow.Image = id
			active.orbGlow.Image = id
			active.glowReady = true
		end
	end

	if not active.glowReady or not (active.dockShown or active.morphBusy) then return end

	active.dockTime += deltaTime
	local t = active.dockTime
	local hovered = active.dockHovered
	local pulse = 0.5 + 0.5 * math.cos(t * 2.1)
	local low, high = hovered and 0.52 or 0.74, hovered and 0.72 or 0.9
	active.dockGlow.ImageTransparency = 1 - (1 - (high - (high - low) * pulse)) * active.dockAlpha

	local angle = t * 0.75
	active.orbGlow.Position = UDim2.fromOffset(22 + math.cos(angle) * 2.6, 18 + math.sin(angle * 1.3) * 2.2)
	local second = 0.5 + 0.5 * math.cos(t * 1.55 + 1.1)
	active.orbGlow.ImageTransparency = 1 - (1 - ((hovered and 0.5 or 0.66) + 0.16 * second)) * active.dockAlpha
end

-- The morph itself: a ring of dots on screen, in raw screen pixels, over everything.
---@param onProgress function
---@param onDone function
local function runMorph(onProgress, onDone)
	local main = active.main
	local rect = { x = main.AbsolutePosition.X, y = main.AbsolutePosition.Y, w = main.AbsoluteSize.X, h = main.AbsoluteSize.Y }
	local token = active.morphToken
	if rect.w < 4 then
		onDone()
		return
	end

	local gui = create("ScreenGui", { Name = MORPH_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 1001 }, getGuiParent())
	active.morphGui = gui

	-- Where the gui's own origin is on screen (the inset can differ), measured once.
	local probe = create("Frame", { Size = UDim2.fromOffset(1, 1), BackgroundTransparency = 1 }, gui)
	runService.Heartbeat:Wait()
	if not active or active.morphToken ~= token or not gui.Parent then return end

	local origin = probe.AbsolutePosition
	probe:Destroy()

	local dock = active.dock
	local targetX = dock.AbsolutePosition.X + dock.AbsoluteSize.X / 2
	local targetY = dock.AbsolutePosition.Y + dock.AbsoluteSize.Y / 2

	local glowId = assetId("images/glow.png")
	local glow = glowId and create("ImageLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(rect.w, rect.h), BackgroundTransparency = 1, Image = glowId, ImageColor3 = COLORS.accent, ImageTransparency = 0.86, ZIndex = 1 }, gui)

	local dotSize = math.max(3, math.floor(rect.h / 150))
	local dots = {}
	for index = 1, MORPH_SEGMENTS do
		local dot = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(dotSize, dotSize), BackgroundColor3 = COLORS.text, BorderSizePixel = 0, ZIndex = 3 }, gui)
		corner(dot, 999)
		dots[index] = dot
	end

	local halfWidth, halfHeight = rect.w / 2, rect.h / 2
	local circleRadius = math.min(rect.w, rect.h) * 0.30
	local startX, startY = rect.x + halfWidth, rect.y + halfHeight

	local clock = 0
	local connection
	connection = runService.RenderStepped:Connect(function(deltaTime)
		if not gui.Parent then
			connection:Disconnect()
			return
		end

		clock += deltaTime
		local p = math.clamp(1 - (1 + MORPH_OMEGA * clock) * math.exp(-MORPH_OMEGA * clock), 0, 1)
		onProgress(p)

		local toCircle = ramp(p, 0, 0.42)
		local toInfinity = ramp(p, 0.3, 0.72)
		local away = ramp(p, 0.62, 1)
		local fade = ramp(p, 0.8, 1)

		local scale = 1 - 0.86 * away
		local centerX = startX + (targetX - startX) * away
		local centerY = startY + (targetY - startY) * away
		local rotation = p * 2.6
		local cosR, sinR = math.cos(rotation), math.sin(rotation)

		-- A superellipse: the exponent sweeps 8 (nearly the window's rectangle) down to 2 (a true ellipse).
		local exponent = 8 - 6 * toCircle

		for index, dot in dots do
			local t = (index - 1) / MORPH_SEGMENTS * math.pi * 2
			local cosT, sinT = math.cos(t), math.sin(t)

			local outlineX = halfWidth * (cosT >= 0 and 1 or -1) * math.abs(cosT) ^ (2 / exponent)
			local outlineY = halfHeight * (sinT >= 0 and 1 or -1) * math.abs(sinT) ^ (2 / exponent)

			-- A circle that folds into a figure eight: only Y changes, so it is one blend.
			local symbolX = circleRadius * cosT
			local symbolY = circleRadius * sinT * (1 + toInfinity * (cosT - 1))

			local x = (outlineX + (symbolX - outlineX) * toCircle) * scale
			local y = (outlineY + (symbolY - outlineY) * toCircle) * scale
			dot.Position = UDim2.fromOffset(centerX + x * cosR - y * sinR - origin.X, centerY + x * sinR + y * cosR - origin.Y)
			dot.BackgroundTransparency = fade

			-- A brighter head runs round the curve so the line reads as drawn.
			local head = ((index / MORPH_SEGMENTS) + p * 1.7) % 1
			local lit = head < 0.14 and (1 - head / 0.14) or 0
			local size = dotSize * (1 + lit * 1.25) * (0.5 + 0.5 * scale)
			dot.Size = UDim2.fromOffset(math.max(size, 1), math.max(size, 1))
		end

		if glow then
			local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
			local cap = math.min(viewport.X, viewport.Y) * MORPH_GLOW_CAP
			local glowWidth = math.min(rect.w * scale * 1.5, cap)
			local glowHeight = math.min(rect.h * scale * 1.5, cap)
			glow.Position = UDim2.fromOffset(centerX - origin.X, centerY - origin.Y)
			glow.Size = UDim2.fromOffset(glowWidth, glowHeight)

			-- Area times opacity is what the eye reads: the bigger the bloom, the fainter it is drawn.
			local opacity = (1 - (0.8 + 0.2 * fade)) * math.clamp(MORPH_GLOW_REF / math.max(math.sqrt(glowWidth * glowHeight), 1), 0.3, 1)
			glow.ImageTransparency = 1 - opacity
		end
	end)
	active.morphConnection = connection

	task.delay(MORPH_SECONDS, function()
		if not active or active.morphToken ~= token then return end

		connection:Disconnect()
		active.morphConnection = nil
		pcall(function() gui:Destroy() end)
		active.morphGui = nil
		onDone()
	end)
end

---@return boolean
function Window:IsOpen()
	return active ~= nil and active.visible
end

-- Opening: the panel fades in while growing from 95% with a slight spring, its shadow fades in and grows, the game behind
-- dims, the blur rises, and the page rows then fade in one by one.
function Window:Show()
	if active.visible then return end

	active.visible = true
	local blurWanted = HussUI.Flags.ui_blur == nil or HussUI.Flags.ui_blur.Value == true
	local dim = HussUI.Flags.ui_scrim == nil or HussUI.Flags.ui_scrim.Value == true

	settleCascade()
	active.root.Visible = true
	active.pop.Scale = 0.95
	active.main.GroupTransparency = 1
	tween(active.pop, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(active.main, 0.3, { GroupTransparency = 0 }, Enum.EasingStyle.Quad)
	for _, layer in active.shadows do
		layer.frame.BackgroundTransparency = 1
		layer.frame.Size = UDim2.new(0.97, layer.spread * 2, 0.97, layer.spread * 2)
		tween(layer.frame, 0.3, { BackgroundTransparency = layer.alpha }, Enum.EasingStyle.Quad)
		tween(layer.frame, 0.5, { Size = UDim2.new(1, layer.spread * 2, 1, layer.spread * 2) })
	end
	tween(active.scrim, 0.3, { BackgroundTransparency = dim and 0.55 or 1 }, Enum.EasingStyle.Quad)
	if blurWanted then tween(active.blur, 0.5, { Size = 12 }) end
	active.sfx("open")

	-- The pill is placed from the layout, which may not have run while the window was hidden.
	task.defer(function()
		local owner = active and active.window
		if not (owner and owner.current) then return end

		movePill(owner, owner.current, true)
		cascadeIn(owner.current)
	end)
end

-- Closing: fade and shrink away. keepDock leaves the dock alone (the morph is about to bring it in).
---@param keepDock boolean?
function Window:Hide(keepDock)
	if not active.visible then return end

	active.visible = false
	settleCascade()
	tween(active.pop, 0.2, { Scale = 0.97 }, QUINT, IN)
	tween(active.main, 0.2, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
	for _, layer in active.shadows do
		tween(layer.frame, 0.2, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
	end
	tween(active.scrim, 0.25, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
	tween(active.blur, 0.3, { Size = 0 })
	task.delay(0.3, function()
		if active and not active.visible and active.root.Parent then active.root.Visible = false end
	end)
	if not keepDock then moveDock(false) end
end

-- Minimise: the panel goes at once; what the eye follows is the morph, and the dock appears as it lands.
function Window:Minimise()
	if not active.visible or active.morphBusy then return end

	active.morphBusy = true
	active.morphToken += 1
	local token = active.morphToken

	-- The pill is placed first and revealed last, so the morph has a real target to fly to.
	active.dockShown = true
	active.dock.Position = dockPosition(true)
	setDockAlpha(0)

	task.spawn(runMorph, function(p)
		if active and active.morphToken == token then setDockAlpha(ramp(p, 0.78, 1)) end
	end, function()
		if active and active.morphToken == token then
			setDockAlpha(1)
			active.morphBusy = false
		end
	end)

	active.sfx("close")
	self:Hide(true)
end

-- Restore: anything still moving stops, the dock slides back out and the window opens.
function Window:Restore()
	cancelMorph()
	setDockAlpha(1)
	moveDock(false)
	self:Show()
end

-- Programmatic open/close (the hub uses this around its start-up film): plain show and hide, no dock.
---@param state boolean?
function Window:Toggle(state)
	if state == nil then state = not active.visible end

	if state then
		if not active.visible then self:Restore() end
	else
		self:Hide(false)
	end
end

-- What the menu key does: bring the window back, or minimise it to the dock (or just hide it when the dock is off).
function Window:Flip()
	if not active.visible then
		self:Restore()
	elseif HussUI.Flags.ui_dock == nil or HussUI.Flags.ui_dock.Value then
		self:Minimise()
	else
		self:Hide(false)
	end
end

-- The film window ------------------------------------------------------------------------------------------------------------
-- The reference's edit feature: the header button opens a floating film window (draggable by its title, resizable from the
-- corner) with a seek bar, pause / stop / next film, a volume slider and the clock. Every press of the header button moves on
-- to the next film. The stage takes the edit's own shape, portrait or landscape.

local FILM_MIN_WIDTH = 860
local FILM_STAGE_MAX_WIDTH = 1040
local FILM_STAGE_MAX_HEIGHT = 585
local FILM_HEADER = 50
local FILM_CONTROLS = 72
local FILM_FILL = Color3.fromRGB(224, 220, 207)

-- Closes the film window (and stops its sound), remembering where it was and how big.
---@param immediate boolean?
function Window:CloseFilm(immediate)
	local film = active and active.film
	if not film or film.closed then return end

	film.closed = true
	active.film = nil
	active.filmLayout = { position = film.root.Position, scale = film.scaler.Scale }
	for _, connection in film.connections do
		connection:Disconnect()
	end
	if film.player then film.player:destroy() end

	if immediate then
		film.gui:Destroy()
	else
		tween(film.root, 0.2, { GroupTransparency = 1 })
		task.delay(0.23, function()
			film.gui:Destroy()
		end)
	end
end

-- Opens the next film (step = 1) or the previous one (step = -1).
---@param step number?
function Window:OpenFilm(step)
	local Edits = active.edits
	if not (Edits and Edits.manifest and #Edits.manifest.edits > 0) then
		self:Notify({ Title = "Films unavailable", Text = "The edit library could not be reached.", Kind = "warn" })
		return
	end

	local edits = Edits.manifest.edits
	active.filmIndex = ((active.filmIndex or 0) + (step or 1) - 1) % #edits + 1
	local edit = edits[active.filmIndex]
	self:CloseFilm(true)

	local aspect = edit.tileW / edit.tileH
	local stageWidth = math.min(FILM_STAGE_MAX_HEIGHT * aspect, FILM_STAGE_MAX_WIDTH)
	local stageHeight = stageWidth / aspect
	local width = math.max(stageWidth, FILM_MIN_WIDTH)
	local height = FILM_HEADER + stageHeight + FILM_CONTROLS
	local bottom = FILM_HEADER + stageHeight

	local film = { closed = false, connections = {}, volume = math.clamp(Edits.prefs.volume, 0, 2) }
	active.film = film
	local function hold(connection)
		table.insert(film.connections, connection)
		return connection
	end

	local gui = create("ScreenGui", { Name = "HussUI_Film", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 1002 }, getGuiParent())
	film.gui = gui

	local function fitScale()
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
		local automatic = math.clamp(math.min(viewport.X / (WINDOW_WIDTH + 40), viewport.Y / (WINDOW_HEIGHT + 50)), 0.5, 1.6)
		return math.min(automatic, (viewport.X - 50) / width, (viewport.Y - 60) / height), viewport
	end

	local root = create("CanvasGroup", { Name = "FilmWindow", Size = UDim2.fromOffset(width, height), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(9, 9, 9), BorderSizePixel = 0, GroupTransparency = 1 }, gui)
	film.root = root
	corner(root, 7)
	stroke(root, 0.45, 1, COLORS.lineStrong)
	local initialScale = fitScale()
	film.scaler = create("UIScale", { Scale = initialScale }, root)
	if active.filmLayout then
		root.Position = active.filmLayout.position
		film.scaler.Scale = math.min(initialScale, active.filmLayout.scale)
	end

	label(root, string.format("HUSS VALLEY  /  FILM %02d  /  %s", active.filmIndex, string.upper(edit.title)), 14, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(24, 15), Size = UDim2.new(1, -140, 0, 26), TextTruncate = Enum.TextTruncate.AtEnd })

	-- Keeps the window fully on screen and within the sizes that fit.
	function film.setScale(value)
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
		local upper = math.min((viewport.X - 32) / width, (viewport.Y - 40) / height)
		film.scaler.Scale = math.clamp(value, math.min(0.5, upper), upper)

		local size = Vector2.new(width * film.scaler.Scale, height * film.scaler.Scale)
		local center = Vector2.new(root.Position.X.Scale * viewport.X + root.Position.X.Offset, root.Position.Y.Scale * viewport.Y + root.Position.Y.Offset)
		root.Position = UDim2.fromOffset(
			math.clamp(center.X, size.X / 2 + 8, math.max(size.X / 2 + 8, viewport.X - size.X / 2 - 8)),
			math.clamp(center.Y, size.Y / 2 + 8, math.max(size.Y / 2 + 8, viewport.Y - size.Y / 2 - 8))
		)
	end

	-- Dragging by the title strip.
	local grip = create("TextButton", { Name = "Drag", Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, -76, 0, FILM_HEADER) }, root)
	local drag
	hold(grip.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			drag = { input = input, touch = input.UserInputType == Enum.UserInputType.Touch, start = Vector2.new(input.Position.X, input.Position.Y), position = root.Position }
		end
	end))

	local stage = create("Frame", { Name = "Film", Position = UDim2.fromOffset((width - stageWidth) / 2, FILM_HEADER), Size = UDim2.fromOffset(stageWidth, stageHeight), BorderSizePixel = 0, BackgroundColor3 = Color3.new(0, 0, 0) }, root)
	local prompt = label(stage, "OPENING", 11, COLORS.text, MONO, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -20, 0, 20), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 5 })

	-- Buttons in the reference's flat style.
	local function filmButton(name, word, position, size, callback)
		local button = create("TextButton", { Name = name, Text = word, Position = position, Size = size, BackgroundColor3 = Color3.fromRGB(31, 31, 29), BorderSizePixel = 0, TextColor3 = Color3.fromRGB(235, 233, 226), TextSize = 12, Font = BODY, AutoButtonColor = false }, root)
		corner(button, 4)
		hold(button.MouseEnter:Connect(function()
			tween(button, 0.18, { BackgroundColor3 = Color3.fromRGB(48, 48, 44) })
			active.sfx("hover")
		end))
		hold(button.MouseLeave:Connect(function()
			tween(button, 0.18, { BackgroundColor3 = Color3.fromRGB(31, 31, 29) })
		end))
		hold(button.Activated:Connect(function()
			active.sfx("click")
			callback()
		end))
		return button
	end

	local pause = filmButton("Pause", "Pause", UDim2.fromOffset(24, bottom + 24), UDim2.fromOffset(80, 30), function()
		local player = film.player
		if not player then return end

		if player.playing then
			player:pause()
		else
			player:play()
		end
	end)
	filmButton("Stop", "Stop", UDim2.fromOffset(116, bottom + 24), UDim2.fromOffset(70, 30), function()
		if film.player then
			film.player:pause()
			film.player:seek(0)
		end
	end)
	filmButton("Next", "Next film", UDim2.fromOffset(198, bottom + 24), UDim2.fromOffset(100, 30), function()
		self:OpenFilm(1)
	end)
	filmButton("Close", "X", UDim2.new(1, -56, 0, 12), UDim2.fromOffset(32, 28), function()
		self:CloseFilm()
	end)

	-- Volume: 0 to 200%.
	label(root, "VOLUME", 10, COLORS.text, MONO, { Position = UDim2.fromOffset(330, bottom + 23), Size = UDim2.fromOffset(82, 30) })
	local volumeTrack = create("TextButton", { Name = "Volume", Text = "", Position = UDim2.fromOffset(416, bottom + 24), Size = UDim2.fromOffset(186, 30), BackgroundTransparency = 1, AutoButtonColor = false }, root)
	create("Frame", { Position = UDim2.new(0, 0, 0.5, -1), Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = Color3.fromRGB(58, 57, 51), BorderSizePixel = 0 }, volumeTrack)
	local volumeFill = create("Frame", { Position = UDim2.new(0, 0, 0.5, -1), Size = UDim2.fromOffset(0, 2), BackgroundColor3 = FILM_FILL, BorderSizePixel = 0 }, volumeTrack)
	local volumeKnob = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = FILM_FILL, BorderSizePixel = 0 }, volumeTrack)
	corner(volumeKnob, 4)
	local volumeValue = label(root, "", 12, COLORS.text, MONO, { Position = UDim2.fromOffset(618, bottom + 24), Size = UDim2.fromOffset(60, 30) })

	local saveToken = 0
	local function setVolume(value, persist)
		film.volume = math.clamp(tonumber(value) or 0.65, 0, 2)
		if film.player then film.player:setVolume(film.volume) end
		volumeFill.Size = UDim2.new(film.volume / 2, 0, 0, 2)
		volumeKnob.Position = UDim2.fromScale(film.volume / 2, 0.5)
		volumeValue.Text = string.format("%.0f%%", film.volume * 100)

		if persist then
			Edits.prefs.volume = film.volume
			saveToken += 1
			local token = saveToken
			task.delay(0.5, function()
				if token == saveToken then Edits.savePrefs() end
			end)
		end
	end
	film.setVolume = setVolume
	setVolume(film.volume, false)

	local volumeDrag
	local function volumeAt(x)
		setVolume((x - volumeTrack.AbsolutePosition.X) / math.max(1, volumeTrack.AbsoluteSize.X) * 2, true)
	end
	hold(volumeTrack.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			volumeDrag = input
			volumeAt(input.Position.X)
		end
	end))

	-- Resize: the corner mark scales the whole window.
	local resize = create("TextButton", { Name = "Resize", Text = "/", Position = UDim2.new(1, -25, 1, -25), Size = UDim2.fromOffset(24, 24), BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(235, 233, 226), TextSize = 20, Font = BODY, AutoButtonColor = false }, root)
	local resizing
	hold(resize.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			resizing = { input = input, start = Vector2.new(input.Position.X, input.Position.Y), scale = film.scaler.Scale }
		end
	end))

	hold(userInputService.InputChanged:Connect(function(input)
		if drag and (input == drag.input or (not drag.touch and input.UserInputType == Enum.UserInputType.MouseMovement)) then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - drag.start
			root.Position = drag.position + UDim2.fromOffset(delta.X, delta.Y)
		end
		if volumeDrag and (input == volumeDrag or (volumeDrag.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType == Enum.UserInputType.MouseMovement)) then
			volumeAt(input.Position.X)
		end
		if resizing and (input == resizing.input or (resizing.input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType == Enum.UserInputType.MouseMovement)) then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - resizing.start
			film.setScale(resizing.scale + 2 * (delta.X * width + delta.Y * height) / (width * width + height * height))
		end
	end))
	hold(userInputService.InputEnded:Connect(function(input)
		local released = input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
		if drag and (input == drag.input or (not drag.touch and released)) then drag = nil end
		if volumeDrag and (input == volumeDrag or (volumeDrag.UserInputType ~= Enum.UserInputType.Touch and released)) then volumeDrag = nil end
		if resizing and (input == resizing.input or (resizing.input.UserInputType ~= Enum.UserInputType.Touch and released)) then resizing = nil end
	end))
	hold(userInputService.WindowFocusReleased:Connect(function()
		drag, volumeDrag, resizing = nil, nil, nil
	end))
	film.setScale(film.scaler.Scale)

	-- Clock and seek bar.
	local clock = label(root, "", 12, COLORS.text, MONO, { Position = UDim2.new(1, -176, 0, bottom + 26), Size = UDim2.fromOffset(150, 25), TextXAlignment = Enum.TextXAlignment.Right })
	local seek = create("TextButton", { Name = "Seek", Text = "", Position = UDim2.fromOffset(24, bottom + 8), Size = UDim2.new(1, -48, 0, 4), BackgroundColor3 = Color3.fromRGB(49, 49, 45), BorderSizePixel = 0, AutoButtonColor = false }, root)
	local progress = create("Frame", { Name = "Progress", Size = UDim2.fromScale(0, 1), BackgroundColor3 = FILM_FILL, BorderSizePixel = 0 }, seek)
	hold(seek.Activated:Connect(function()
		if not film.player then return end

		local fraction = math.clamp((userInputService:GetMouseLocation().X - seek.AbsolutePosition.X) / seek.AbsoluteSize.X, 0, 1)
		film.player:seek(fraction * edit.duration)
	end))

	local accumulated = 0
	local lastViewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
	hold(runService.Heartbeat:Connect(function(deltaTime)
		accumulated += deltaTime
		if accumulated < 0.1 then return end
		accumulated = 0

		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
		if viewport ~= lastViewport then
			lastViewport = viewport
			film.setScale(film.scaler.Scale)
		end

		local player = film.player
		local at = player and player.time or 0
		clock.Text = string.format("%s / %s", Edits.clock(at), Edits.clock(edit.duration))
		progress.Size = UDim2.fromScale(math.clamp(at / edit.duration, 0, 1), 1)
		pause.Text = (player and player.playing) and "Pause" or "Play"
	end))

	active.sfx("open")
	tween(root, 0.3, { GroupTransparency = 0 })

	-- The edit is downloaded the first time, then it plays from disk.
	task.spawn(function()
		pcall(setthreadidentity, 8)
		local installed, reason = Edits.install(edit, function(fraction)
			if not film.closed then prompt.Text = string.format("FETCHING  %d%%", math.floor(fraction * 100)) end
		end)
		if film.closed then return end

		if not installed then
			prompt.Text = "COULD NOT LOAD  /  " .. string.upper(tostring(reason))
			return
		end

		local made, player = pcall(Edits.newPlayer, stage, edit, { volume = film.volume, name = "Edit", fit = true })
		if not made or film.closed then
			if made then player:destroy() end
			prompt.Text = "COULD NOT PLAY"
			return
		end

		film.player = player
		player:prepare(5)
		prompt.Visible = false
		player:play()
	end)
end

-- Config manager shown in the built-in Settings tab (named JSON files under <Title>/configs).
---@param window table
---@param settings table
---@param folder string
local function buildConfigs(window, settings, folder)
	local supported = true
	for _, name in { "makefolder", "isfolder", "writefile", "readfile", "listfiles", "delfile", "isfile" } do
		if type(getfenv()[name]) ~= "function" and type(getgenv and getgenv()[name]) ~= "function" then supported = false end
	end

	settings:AddSection("Configs")
	if not supported then
		settings:AddLabel("Configs are not supported by this executor.")
		return
	end

	local root = folder .. "/configs"
	local function ensure()
		if not isfolder(folder) then makefolder(folder) end
		if not isfolder(root) then makefolder(root) end
	end

	local function names()
		local found = {}
		pcall(function()
			ensure()
			for _, path in listfiles(root) do
				local name = string.match(string.gsub(path, "\\", "/"), "([^/]+)%.json$")
				if name then table.insert(found, name) end
			end
		end)
		table.sort(found)
		return found
	end

	local nameInput = settings:AddInput({ Text = "Config name", Placeholder = "default", Flag = "cfg_name" })
	local list = names()
	local picker = settings:AddDropdown({ Text = "Saved configs", Options = #list > 0 and list or { "(none)" }, Flag = "cfg_pick" })

	local function refresh(select)
		local fresh = names()
		picker.SetOptions(#fresh > 0 and fresh or { "(none)" })
		if select then picker.Set(select) end
	end

	local function currentName()
		local typed = string.gsub(nameInput.Value or "", "[^%w_%- ]", "")
		if typed ~= "" then return typed end
		return picker.Value ~= "(none)" and picker.Value or "default"
	end

	settings:AddButton({ Text = "Save config", Callback = function()
		local data = {}
		for flag, entry in HussUI.Flags do
			if string.sub(flag, 1, 4) == "cfg_" or string.sub(flag, 1, 3) == "ui_" then continue end

			local value = entry.Value
			if typeof(value) == "EnumItem" then value = value.Name end
			if typeof(value) == "Color3" then value = toHex(value) end
			if type(value) == "boolean" or type(value) == "number" or type(value) == "string" then data[flag] = value end
		end

		local ok, failure = pcall(function()
			ensure()
			writefile(root .. "/" .. currentName() .. ".json", httpService:JSONEncode(data))
		end)
		window:Notify({ Title = ok and "Config saved" or "Could not save", Text = ok and currentName() or tostring(failure) })
		if ok then refresh(currentName()) end
	end })

	settings:AddButton({ Text = "Load config", Callback = function()
		local name = currentName()
		local ok, data = pcall(function()
			local path = root .. "/" .. name .. ".json"
			return isfile(path) and httpService:JSONDecode(readfile(path)) or nil
		end)
		if not ok or type(data) ~= "table" then
			window:Notify({ Title = "No config", Text = name .. " has nothing saved yet" })
			return
		end

		local applied = 0
		for flag, value in data do
			local entry = HussUI.Flags[flag]
			if entry and pcall(entry.Set, value) then applied += 1 end
		end
		window:Notify({ Title = "Config loaded", Text = string.format("%s (%d settings)", name, applied) })
	end })

	settings:AddButton({ Text = "Delete config", Callback = function()
		local name = currentName()
		pcall(function()
			if isfile(root .. "/" .. name .. ".json") then delfile(root .. "/" .. name .. ".json") end
		end)
		window:Notify({ Title = "Config deleted", Text = name })
		refresh()
	end })
end

-- Slow ivory shimmer for the serif title text: the colour sequence is cycled (sliding a gradient's offset would uncover the
-- base colour).
---@param phase number
---@return ColorSequence
local function chromeSequence(phase)
	local points = {}
	for index = 0, 8 do
		local position = index / 8
		local light = 0.5 + 0.5 * math.sin((position * 2 + phase) * math.pi)
		points[#points + 1] = ColorSequenceKeypoint.new(position, Color3.fromRGB(170, 166, 156):Lerp(Color3.fromRGB(255, 252, 244), light))
	end
	return ColorSequence.new(points)
end

---@param opts table
---@return table
function HussUI:CreateWindow(opts)
	opts = opts or {}

	if shared.__HussUI then pcall(function() shared.__HussUI:Destroy() end) end
	sweepPrevious()
	shared.__HussUI = HussUI

	local window = setmetatable({ tabs = {}, order = 0, toggleKey = opts.ToggleKey or Enum.KeyCode.RightShift }, Window)
	active = { edits = opts.Edits, connections = {}, visible = false, capturing = false, onDestroy = opts.OnDestroy, widgets = {}, statCards = {}, listed = {}, icons = {}, sounds = {}, sfx = playSfx, scaleMultiplier = 1 }

	local showWidgets = opts.Widgets == true

	local gui = create("ScreenGui", { Name = GUI_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1000, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, getGuiParent())
	active.gui = gui
	active.window = window
	active.blur = create("BlurEffect", { Name = BLUR_NAME, Size = 0 }, lightingService)
	ensureAssets()

	-- Dims the game behind the window while it is open (clicks pass straight through it).
	active.scrim = create("Frame", { Name = "Scrim", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 0, Active = false }, gui)

	local root = create("Frame", { Name = "Root", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT), BackgroundTransparency = 1, Visible = false }, gui)
	active.root = root
	local fit = create("UIScale", {}, root)
	local function refit()
		local camera = workspace.CurrentCamera
		if not camera then return end

		local viewport = camera.ViewportSize
		-- Fits the screen the way the reference does (up to 1.6x), times the user's own size setting.
		local span = showWidgets and (WINDOW_WIDTH + 2 * (WIDGET_GAP + WIDGET_WIDTH)) or WINDOW_WIDTH
		local automatic = math.clamp(math.min(viewport.X / (span + 40), viewport.Y / (WINDOW_HEIGHT + 50)), 0.5, 1.6)
		fit.Scale = math.clamp(automatic * active.scaleMultiplier, 0.4, 2)

		-- The dock keeps the window's own proportions and stays where it should (shown or parked) when the size changes.
		if active.dockScale then
			active.dockScale.Scale = math.clamp(fit.Scale, 0.8, 1.6)
			active.dock.Position = dockPosition(active.dockShown or active.morphBusy)
		end
	end
	active.refit = refit
	refit()
	if workspace.CurrentCamera then track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)) end

	local body = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, root)
	active.pop = create("UIScale", { Scale = 1 }, body)

	-- Drop shadow: two soft layers behind the panel.
	active.shadows = {}
	for _, layer in { { spread = 10, alpha = 0.86 }, { spread = 26, alpha = 0.93 } } do
		local shadow = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 8), Size = UDim2.new(1, layer.spread * 2, 1, layer.spread * 2), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = layer.alpha, BorderSizePixel = 0, ZIndex = 0 }, body)
		corner(shadow, 12 + layer.spread)
		table.insert(active.shadows, { frame = shadow, spread = layer.spread, alpha = layer.alpha })
	end

	-- Main panel: one near-black plane with a hairline edge.
	local main = create("CanvasGroup", { Name = "Main", Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT), BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0, BorderSizePixel = 0, GroupTransparency = 1 }, body)
	active.main = main
	corner(main, 12)
	stroke(main, 0.3, 1, COLORS.lineStrong)
	window.main = main

	-- Light bleeding from the top edge.
	local wash = create("Frame", { Size = UDim2.new(1, 0, 0, 260), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0 }, main)
	create("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.94), NumberSequenceKeypoint.new(1, 1) }), Rotation = 90 }, wash)

	-- Pinstripe field (a suit-cloth nod to the reference's striped film background) with a slow sheen crossing it.
	local stripes = create("Frame", { Name = "Pinstripe", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, main)
	for x = SIDEBAR_WIDTH + 14, WINDOW_WIDTH, 24 do
		create("Frame", { Position = UDim2.fromOffset(x, HEADER_HEIGHT), Size = UDim2.new(0, 1, 1, -HEADER_HEIGHT), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.975, BorderSizePixel = 0 }, stripes)
	end
	local sheen = create("Frame", { Position = UDim2.fromOffset(-300, HEADER_HEIGHT), Size = UDim2.new(0, 300, 1, -HEADER_HEIGHT), BackgroundColor3 = COLORS.row, BorderSizePixel = 0 }, stripes)
	create("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.955), NumberSequenceKeypoint.new(1, 1) }) }, sheen)
	tweenService:Create(sheen, TweenInfo.new(12, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1), { Position = UDim2.fromOffset(WINDOW_WIDTH, HEADER_HEIGHT) }):Play()

	-- Header: wordmark, edition line, the film shortcut, key hint, ping, minimise, close. It is also the drag handle.
	local header = create("Frame", { Name = "Header", Size = UDim2.new(1, 0, 0, HEADER_HEIGHT), BackgroundTransparency = 1, Active = true }, main)
	local wordmark = label(header, string.upper(tostring(opts.Title or "Hub")), 34, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(28, 18), Size = UDim2.fromOffset(340, 40) })
	local shimmer = create("UIGradient", { Color = chromeSequence(0) }, wordmark)
	label(header, "PRIVATE EDITION  /  " .. string.upper(tostring(opts.Subtitle or "")), 9, COLORS.faint, MONO, { Position = UDim2.fromOffset(30, 59), Size = UDim2.fromOffset(380, 12), TextTruncate = Enum.TextTruncate.AtEnd })
	create("Frame", { Position = UDim2.fromOffset(0, HEADER_HEIGHT), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = COLORS.line, BackgroundTransparency = 0.35, BorderSizePixel = 0 }, main)

	-- 30 px chrome buttons at the right edge.
	local function chromeButton(offset, draw, callback)
		local button = create("TextButton", { Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, offset, 0.5, 0), Size = UDim2.fromOffset(30, 30), BackgroundColor3 = COLORS.hover, BackgroundTransparency = 1, BorderSizePixel = 0 }, header)
		corner(button, 9)
		draw(button)
		track(button.MouseEnter:Connect(function()
			tween(button, 0.2, { BackgroundTransparency = 0.2 })
		end))
		track(button.MouseLeave:Connect(function()
			tween(button, 0.25, { BackgroundTransparency = 1 })
		end))
		track(button.Activated:Connect(callback))
	end
	chromeButton(-16, function(button)
		for _, rotation in { 45, -45 } do
			create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 1), Rotation = rotation, BorderSizePixel = 0, BackgroundColor3 = COLORS.muted }, button)
		end
	end, function()
		window:Hide(false)
	end)
	chromeButton(-50, function(button)
		create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(13, 1), BorderSizePixel = 0, BackgroundColor3 = COLORS.muted }, button)
	end, function()
		window:Minimise()
	end)

	-- Ping pill: a status dot and the live round-trip time.
	local pill = create("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -88, 0.5, 0), Size = UDim2.fromOffset(88, 28), BackgroundColor3 = COLORS.card, BorderSizePixel = 0 }, header)
	corner(pill, 999)
	stroke(pill, 0.3, 1, COLORS.line)
	local pingDot = create("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 11, 0.5, 0), Size = UDim2.fromOffset(6, 6), BackgroundColor3 = COLORS.good, BorderSizePixel = 0 }, pill)
	corner(pingDot, 999)
	local pingLabel = label(pill, "-- ms", 10, COLORS.dim, MONO, { Position = UDim2.fromOffset(23, 0), Size = UDim2.new(1, -28, 1, 0) })
	window.pingLabel = pingLabel

	window.keyHint = label(header, string.upper(window.toggleKey.Name), 10, COLORS.faint, MONO, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -190, 0.5, 0), Size = UDim2.fromOffset(80, 14), TextXAlignment = Enum.TextXAlignment.Right })

	-- The film shortcut: serif words with a shimmer and an underline that draws in on hover (the reference's "Giorgio Armani?").
	local filmShimmer
	if opts.FilmTab or opts.Edits then
		local films = create("TextButton", { Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(0, 0), Position = UDim2.new(1, -455, 0.5, -17), Size = UDim2.fromOffset(182, 34), BackgroundTransparency = 1 }, header)
		local word = label(films, opts.FilmLabel or "The edits", 21, COLORS.text, DISPLAY, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
		filmShimmer = create("UIGradient", { Color = chromeSequence(0) }, word)
		local underline = create("Frame", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromOffset(0, 1), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0 }, films)
		track(films.MouseEnter:Connect(function()
			tween(underline, 0.35, { Size = UDim2.new(1, -18, 0, 1) })
			tween(films, 0.3, { Position = UDim2.new(1, -455, 0.5, -19) })
		end))
		track(films.MouseLeave:Connect(function()
			tween(underline, 0.3, { Size = UDim2.fromOffset(0, 1) })
			tween(films, 0.3, { Position = UDim2.new(1, -455, 0.5, -17) })
		end))
		track(films.Activated:Connect(function()
			active.sfx("click")
			if active.edits then
				window:OpenFilm(1)
			elseif opts.FilmTab then
				window:SelectTab(opts.FilmTab)
			end
		end))
	end

	-- Sidebar: translucent black over the surface, a seam that fades down its right edge, the nav list, the footer.
	local sidebar = create("Frame", { Position = UDim2.fromOffset(0, HEADER_HEIGHT + 1), Size = UDim2.new(0, SIDEBAR_WIDTH, 1, -(HEADER_HEIGHT + 1)), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.42, BorderSizePixel = 0, ClipsDescendants = true }, main)
	local seam = create("Frame", { Position = UDim2.new(1, -1, 0, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0 }, sidebar)
	create("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(0.55, 0.9), NumberSequenceKeypoint.new(1, 1) }), Rotation = 90 }, seam)

	local navHolder = create("ScrollingFrame", { Position = UDim2.fromOffset(12, 14), Size = UDim2.new(1, -24, 1, -84), BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 2, ScrollBarImageColor3 = COLORS.lineStrong, ScrollBarImageTransparency = 0.4, ElasticBehavior = Enum.ElasticBehavior.Never }, sidebar)

	-- The pill and the edge bar slide between tabs.
	window.pill = create("Frame", { Size = UDim2.new(1, 0, 0, TAB_HEIGHT), BackgroundColor3 = COLORS.accent, BackgroundTransparency = 0.82, BorderSizePixel = 0, Visible = false }, navHolder)
	corner(window.pill, RADIUS)
	create("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }) }, window.pill)
	window.navHolder = navHolder
	window.pillBar = create("Frame", { Size = UDim2.fromOffset(3, TAB_HEIGHT * 0.45), Position = UDim2.fromOffset(1, 0), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0, Visible = false, ZIndex = 3 }, sidebar)
	corner(window.pillBar, 999)

	window.navList = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, navHolder)
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, window.navList)

	-- Footer: hairline, your avatar, your name and a state line.
	local footer = create("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -14), Size = UDim2.new(1, -24, 0, 42), BackgroundTransparency = 1 }, sidebar)
	create("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = COLORS.line, BackgroundTransparency = 0.4, BorderSizePixel = 0 }, footer)
	local avatar = create("ImageLabel", { Position = UDim2.fromOffset(0, 13), Size = UDim2.fromOffset(28, 28), BackgroundColor3 = COLORS.card, BorderSizePixel = 0, Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", localPlayer.UserId) }, footer)
	corner(avatar, 5)
	stroke(avatar, 0.45, 1, COLORS.lineStrong)
	label(footer, localPlayer.Name, 11, COLORS.dim, BOLD, { Position = UDim2.fromOffset(36, 13), Size = UDim2.new(1, -38, 0, 13), TextTruncate = Enum.TextTruncate.AtEnd })
	window.footState = label(footer, "connected", 10, COLORS.faint, MONO, { Position = UDim2.fromOffset(36, 27), Size = UDim2.new(1, -38, 0, 12), TextTruncate = Enum.TextTruncate.AtEnd })

	-- Content: page heading (serif title, dim subtitle) and the pages.
	local contentLeft = SIDEBAR_WIDTH + 1 + PAGE_PADDING
	window.pageTitle = label(main, "", 34, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(contentLeft, HEADER_HEIGHT + 25), Size = UDim2.new(1, -(contentLeft + PAGE_PADDING), 0, 36), TextTruncate = Enum.TextTruncate.AtEnd })
	window.pageSub = label(main, "", 12, COLORS.dim, BODY, { Position = UDim2.fromOffset(contentLeft + 1, HEADER_HEIGHT + 64), Size = UDim2.new(1, -(contentLeft + PAGE_PADDING), 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
	window.pages = create("Frame", { Position = UDim2.fromOffset(contentLeft, HEADER_HEIGHT + 96), Size = UDim2.new(1, -(contentLeft + PAGE_PADDING - 12), 1, -(HEADER_HEIGHT + 96 + 10)), BackgroundTransparency = 1, ClipsDescendants = true }, main)

	-- Cover used for the open/close fade.

	-- Floating widgets beside the window.
	active.widgetHost = create("Frame", { Position = UDim2.fromOffset(WINDOW_WIDTH + WIDGET_GAP, 0), Size = UDim2.fromOffset(WIDGET_WIDTH, WINDOW_HEIGHT), BackgroundTransparency = 1, Visible = showWidgets }, body)
	create("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, active.widgetHost)

	-- Toasts live on their own host so they survive the window being hidden.
	active.toastHost = create("Frame", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -20, 1, -20), Size = UDim2.fromOffset(340, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, gui)
	create("UIListLayout", { Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, active.toastHost)

	-- Dock: the pill the window minimises into, parked above the screen until it is needed. Its halo breathes, the monogram has
	-- a halo of its own, hovering lights the edge and swells the glow, clicking brings the window back.
	local dock = create("TextButton", { Name = "Dock", Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(DOCK_WIDTH, DOCK_HEIGHT), BackgroundColor3 = COLORS.overlay, BorderSizePixel = 0 }, gui)
	active.dock = dock
	active.dockScale = create("UIScale", { Scale = 1 }, dock)
	corner(dock, 999)
	active.dockStroke = stroke(dock, 0.3, 1, COLORS.lineStrong)
	active.dockStrokeBase = 0.3
	active.dockAlpha, active.dockTime, active.dockShown, active.dockHovered = 1, 0, false, false
	active.morphToken, active.morphBusy = 0, false
	active.dockGlow = create("ImageLabel", { Name = "DockGlow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 74, 1, 58), BackgroundTransparency = 1, ImageColor3 = COLORS.accent, ImageTransparency = 1, ZIndex = 0 }, dock)
	active.orbGlow = create("ImageLabel", { Name = "OrbGlow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(22, 18), Size = UDim2.fromOffset(46, 46), BackgroundTransparency = 1, ImageColor3 = COLORS.accent, ImageTransparency = 1, ZIndex = 1 }, dock)
	active.dockMark = label(dock, "H", 20, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(10, 6), Size = UDim2.fromOffset(24, 24), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 2 })
	active.dockLabel = label(dock, string.upper(tostring(opts.Title or "Hub")), 12, COLORS.dim, STRONG, { Position = UDim2.fromOffset(38, 0), Size = UDim2.new(1, -48, 1, 0), ZIndex = 2, TextTruncate = Enum.TextTruncate.AtEnd })
	track(dock.MouseEnter:Connect(function()
		active.dockHovered, active.dockStrokeBase = true, 0.05
		tween(active.dockStroke, 0.18, { Color = COLORS.accent, Transparency = 1 - 0.95 * active.dockAlpha })
		tween(active.dockLabel, 0.18, { TextColor3 = COLORS.text })
		tween(active.dockGlow, 0.3, { Size = UDim2.new(1, 104, 1, 80) })
	end))
	track(dock.MouseLeave:Connect(function()
		active.dockHovered, active.dockStrokeBase = false, 0.3
		tween(active.dockStroke, 0.18, { Color = COLORS.lineStrong, Transparency = 1 - 0.7 * active.dockAlpha })
		tween(active.dockLabel, 0.18, { TextColor3 = COLORS.dim })
		tween(active.dockGlow, 0.3, { Size = UDim2.new(1, 74, 1, 58) })
	end))
	track(dock.Activated:Connect(function()
		window:Restore()
	end))
	dock.Position = dockPosition(false)

	-- Keybind list: a small draggable panel that stays on screen while the menu is closed. It lists every enabled
	-- feature with its key (and the disabled ones too when "List disabled features too" is on).
	local listFrame = create("Frame", { Position = UDim2.new(0, 24, 0.38, 0), Size = UDim2.fromOffset(220, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0.06, BorderSizePixel = 0, Visible = false, Active = true, ClipsDescendants = true }, gui)
	corner(listFrame, 10)
	stroke(listFrame, 0.45, 1, COLORS.line)
	create("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12) }, listFrame)
	create("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, listFrame)
	local listTitle = label(listFrame, "KEYBINDS", 9, COLORS.faint, MONO, { Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 0, TextTruncate = Enum.TextTruncate.AtEnd })
	local listRows = {}

	active.refreshKeyList = function()
		for _, item in listRows do
			item:Destroy()
		end
		table.clear(listRows)

		local showAll = HussUI.Flags.ui_keylistAll ~= nil and HussUI.Flags.ui_keylistAll.Value == true
		local shown = 0
		for index, info in active.listed do
			local on = info.isOn()
			if not on and not showAll then continue end

			shown += 1
			local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = index }, listFrame)
			create("Frame", { Size = UDim2.fromOffset(5, 5), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = on and COLORS.accent or COLORS.muted, BackgroundTransparency = on and 0 or 0.6, BorderSizePixel = 0 }, holder)
			label(holder, info.text, 12, on and COLORS.text or COLORS.muted, BODY, { Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -66, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
			label(holder, keyLabel(info.key()), 10, COLORS.accent2, MONO, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(50, 20), TextXAlignment = Enum.TextXAlignment.Right })
			table.insert(listRows, holder)
		end

		if shown == 0 then
			table.insert(listRows, label(listFrame, "Nothing enabled", 12, COLORS.muted, BODY, { Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 1 }))
		end
		listTitle.Text = showAll and "KEYBINDS" or string.format("ACTIVE  /  %02d", shown)
	end
	active.keyListFrame = listFrame

	local listDragging = false
	local listDragStart = Vector2.zero
	local listStart = listFrame.Position
	track(listFrame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			listDragging = true
			listDragStart = Vector2.new(input.Position.X, input.Position.Y)
			listStart = listFrame.Position
		end
	end))
	track(userInputService.InputChanged:Connect(function(input)
		if listDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - listDragStart
			listFrame.Position = UDim2.new(listStart.X.Scale, listStart.X.Offset + delta.X, listStart.Y.Scale, listStart.Y.Offset + delta.Y)
		end
	end))
	track(userInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then listDragging = false end
	end))

	-- Dragging by the header.
	local dragging = false
	local dragStart = Vector2.zero
	local startPosition = root.Position
	track(header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			startPosition = root.Position
		end
	end))
	track(userInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStart
			root.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
		end
	end))
	track(userInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))

	-- Menu key.
	track(userInputService.InputBegan:Connect(function(input)
		if active.capturing or input.KeyCode ~= window.toggleKey or userInputService:GetFocusedTextBox() then return end

		window:Flip()
	end))

	-- Live refresh: stat cards, widgets, ping, shimmer and the animated icons.
	local fps = 60
	local statClock = 0
	local widgetClock = 0
	local shimmerClock = 0
	local pingClock = 2
	track(runService.Heartbeat:Connect(function(deltaTime)
		fps = fps + ((1 / math.max(deltaTime, 1e-3)) - fps) * math.min(1, deltaTime * 4)
		stepIcons(deltaTime)
		stepDock(deltaTime)
		if not active.visible then return end

		shimmerClock = shimmerClock + deltaTime
		if shimmerClock >= 1 / 20 then
			shimmerClock = 0
			local phase = os.clock() * 0.22
			shimmer.Color = chromeSequence(phase)
			if filmShimmer then filmShimmer.Color = chromeSequence(phase + 0.5) end
		end

		pingClock = pingClock + deltaTime
		if pingClock >= 2 then
			pingClock = 0
			local ping = -1
			pcall(function()
				ping = statsService.Network.ServerStatsItem["Data Ping"]:GetValue()
			end)
			pingLabel.Text = ping >= 0 and string.format("%d ms", math.floor(ping + 0.5)) or "offline"
			tween(pingDot, 0.3, { BackgroundColor3 = (ping < 0 and COLORS.faint) or (ping < 120 and COLORS.good) or (ping < 260 and COLORS.warn) or COLORS.bad })
		end

		statClock = statClock + deltaTime
		if statClock >= 0.25 then
			statClock = 0
			for _, card in active.statCards do
				local ok, valueText, alpha, subText = pcall(card.spec.Get)
				if not ok then continue end

				card.value.Text = tostring(valueText or "")
				card.sub.Text = string.upper(tostring(subText or ""))
				card.value.TextColor3 = (tonumber(alpha) or 0) > 0.5 and COLORS.accent or COLORS.muted
			end
		end

		widgetClock = widgetClock + deltaTime
		if widgetClock >= 0.5 then
			widgetClock = 0
			for _, widget in active.widgets do
				local ok, valueText, number, subText = pcall(widget.spec.Get)
				if not ok then continue end

				widget.value.Text = tostring(valueText or "")
				widget.sub.Text = string.upper(tostring(subText or ""))

				if widget.kind == "bars" then
					table.remove(widget.history, 1)
					table.insert(widget.history, tonumber(number) or 0)
					local peak = 1
					for _, sample in widget.history do
						peak = math.max(peak, sample)
					end
					for index, bar in widget.bars do
						local last = index == #widget.bars
						tween(bar, 0.45, { Size = UDim2.new(bar.Size.X.Scale, bar.Size.X.Offset, 0, 6 + math.floor(widget.history[index] / peak * 70)), BackgroundTransparency = last and 0 or 0.5 })
					end
				else
					local lit = math.floor(math.clamp(tonumber(number) or 0, 0, 1) * SEGMENTS + 0.5)
					for index, segment in widget.segments do
						local on = index <= lit
						tween(segment, 0.3, { BackgroundColor3 = on and COLORS.accent or COLORS.row, BackgroundTransparency = on and 0.1 or 0.9 })
					end
				end
			end
		end
	end))

	-- Built-in Settings tab, last in the nav under its own "System" heading.
	window.order = window.order + 0
	label(window.navList, spaced("System"), 9, COLORS.faint, BOLD, { Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 999998, TextYAlignment = Enum.TextYAlignment.Bottom, Position = UDim2.fromOffset(10, 0) }).Name = "Category"
	local settings = makeTab(window, "Settings", "settings", 999999)
	settings.subtitle = "Interface, sound, configs and session"
	settings:AddSection("Interface")
	settings:AddKeybind({
		Text = "Toggle UI",
		Default = window.toggleKey,
		Flag = "ui_toggleKey",
		Callback = function(key)
			if key then
				window.toggleKey = key
				window.keyHint.Text = string.upper(key.Name)
			end
		end,
	})
	settings:AddToggle({
		Text = "Keybind list",
		Default = true,
		Flag = "ui_keylist",
		NoList = true,
		Key = Enum.KeyCode.Insert,
		Callback = function(on)
			active.keyListFrame.Visible = on
			if on then active.refreshKeyList() end
		end,
	})
	settings:AddToggle({
		Text = "List disabled features too",
		Default = false,
		Flag = "ui_keylistAll",
		NoList = true,
		Bind = false,
		Callback = function()
			active.refreshKeyList()
		end,
	})
	settings:AddToggle({
		Text = "Minimise to the button at the top: the menu key shrinks the window into it (off: the menu key just hides the window)",
		Default = true,
		Flag = "ui_dock",
		NoList = true,
		Bind = false,
	})
	settings:AddSlider({
		Text = "Interface size (100% fits your screen the way the reference does)",
		Min = 60,
		Max = 140,
		Default = 100,
		Increment = 5,
		Suffix = "%",
		Flag = "ui_scale",
		Callback = function(value)
			active.scaleMultiplier = value / 100
			active.refit()
		end,
	})
	settings:AddToggle({
		Text = "Opening animation: the page rows fade in one by one when a page opens",
		Default = true,
		Flag = "ui_animate",
		NoList = true,
		Bind = false,
	})
	settings:AddToggle({
		Text = "Dim the game behind the window while it is open",
		Default = true,
		Flag = "ui_scrim",
		NoList = true,
		Bind = false,
		Callback = function(on)
			if active.visible then tween(active.scrim, 0.3, { BackgroundTransparency = on and 0.55 or 1 }) end
		end,
	})
	settings:AddToggle({
		Text = "Background blur",
		NoList = true,
		Bind = false,
		Default = false,
		Flag = "ui_blur",
		Callback = function(on)
			if active.visible then tween(active.blur, 0.3, { Size = on and 12 or 0 }) end
		end,
	})
	settings:AddSection("Sound")
	settings:AddToggle({
		Text = "Interface sounds",
		Default = true,
		Flag = "ui_sfx",
		NoList = true,
		Bind = false,
	})
	settings:AddSlider({
		Text = "Interface sound volume",
		Min = 0,
		Max = 100,
		Default = 55,
		Increment = 5,
		Suffix = "%",
		Flag = "ui_sfxVolume",
	})
	settings:AddSection("Session")
	settings:AddButton({
		Text = "Unload Script",
		Callback = function()
			task.defer(function()
				HussUI:Destroy()
			end)
		end,
	})
	buildConfigs(window, settings, (string.gsub(tostring(opts.Title or "HussUI"), "%s+", "")))

	window.Settings = settings

	-- The keybind list defaults to on; the initial toggle state does not run its callback, so show it here.
	active.keyListFrame.Visible = true
	active.refreshKeyList()

	-- Default widgets: frame rate chart, ping and player count.
	if showWidgets and opts.Widgets ~= false and not opts.NoDefaultWidgets then
		window:AddWidget({ Title = "Frame rate", Icon = "gauge", Kind = "bars", Get = function()
			return string.format("%d FPS", math.floor(fps + 0.5)), fps, string.format("target %d", 60)
		end })
		window:AddWidget({ Title = "Ping", Icon = "zap", Kind = "stat", Get = function()
			local ping = 0
			pcall(function()
				ping = statsService.Network.ServerStatsItem["Data Ping"]:GetValue()
			end)
			return string.format("%d ms", math.floor(ping + 0.5)), 1 - math.clamp(ping / 300, 0, 1), ping < 80 and "excellent" or ping < 160 and "fair" or "high"
		end })
	end

	-- StartHidden lets the caller keep the window closed (for example behind the start-up film) and open it later.
	if not opts.StartHidden then
		task.defer(function()
			window:Toggle(true)
		end)
	end

	return window
end

function HussUI:Destroy()
	local owner = active
	if not owner then return end

	active = nil
	for _, connection in owner.connections do
		pcall(function() connection:Disconnect() end)
	end

	for _, instance in { owner.gui, owner.introGui, owner.blur, owner.morphGui, owner.film and owner.film.gui } do
		if instance then pcall(function() instance:Destroy() end) end
	end

	table.clear(HussUI.Flags)
	if shared.__HussUI == HussUI then shared.__HussUI = nil end

	-- Lets the script that owns the window unload itself when the user presses Unload Script.
	if owner.onDestroy then safeCall(owner.onDestroy) end
end

return HussUI
