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
local WINDOW_WIDTH = 940
local WINDOW_HEIGHT = 610
local HEADER_HEIGHT = 86
local SIDEBAR_WIDTH = 200
local WIDGET_WIDTH = 188
local WIDGET_GAP = 14
local SEGMENTS = 22
local QUINT = Enum.EasingStyle.Quint
local BACK = Enum.EasingStyle.Back
local OUT = Enum.EasingDirection.Out
local IN = Enum.EasingDirection.In

-- Palette: warm near-black surfaces and one ivory, at several strengths. Text, accent and lines are all the same ivory.
local IVORY = Color3.fromRGB(236, 232, 222)
local COLORS = {
	bg = Color3.fromRGB(12, 12, 12),
	sidebar = Color3.fromRGB(12, 12, 12),
	card = Color3.fromRGB(22, 22, 21),
	row = IVORY,
	track = Color3.fromRGB(8, 8, 8),
	stroke = IVORY,
	text = IVORY,
	muted = Color3.fromRGB(152, 149, 139),
	accent = IVORY,
	accent2 = Color3.fromRGB(190, 186, 176),
	dark = Color3.fromRGB(12, 12, 12),
	good = Color3.fromRGB(160, 196, 160),
	bad = Color3.fromRGB(206, 118, 108),
}

-- Width a row has inside a card, used to measure wrapped text before the layout exists.
local ROW_WIDTH = 300

local BODY = Enum.Font.Gotham
local BOLD = Enum.Font.GothamMedium
local DISPLAY = Enum.Font.Garamond
local MONO = Enum.Font.Code

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
local function stroke(inst, transparency, thickness)
	return create("UIStroke", {
		Color = COLORS.stroke,
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

-- Rows -------------------------------------------------------------------------------------------------------

local Tab = {}
Tab.__index = Tab

-- The card rows are added to: the newest section, or a default card when none was started.
---@param tab table
---@return Frame
local function currentCard(tab)
	if not tab.card then tab:AddSection("") end
	return tab.card
end

-- A soft glass row inside the current card.
---@param tab table
---@param height number
---@param clickable boolean
---@return Instance, UIScale
local function newRow(tab, height, clickable, rest, hover)
	rest = rest or 0.95
	hover = hover or 0.9
	local card = currentCard(tab)
	tab.order = tab.order + 1
	tab.heights[tab.column] = tab.heights[tab.column] + height + 6

	local props = {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = COLORS.row,
		BackgroundTransparency = rest,
		BorderSizePixel = 0,
		LayoutOrder = tab.order,
	}
	if clickable then
		props.Text = ""
		props.AutoButtonColor = false
	end

	local row = create(clickable and "TextButton" or "Frame", props, card)
	corner(row, 4)
	local scale = create("UIScale", { Scale = 1 }, row)

	track(row.MouseEnter:Connect(function()
		tween(row, 0.2, { BackgroundTransparency = hover })
	end))
	track(row.MouseLeave:Connect(function()
		tween(row, 0.25, { BackgroundTransparency = rest })
	end))

	return row, scale
end

-- Starts a titled glass card in the shorter of the two columns; later rows land inside it.
---@param content string
function Tab:AddSection(content)
	local column = self.heights[1] <= self.heights[2] and 1 or 2
	self.column = column
	self.order = self.order + 1

	local card = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = COLORS.card,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = self.order,
	}, self.columns[column])
	corner(card, 6)
	stroke(card, 0.9)
	create("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 14) }, card)
	create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, card)

	self.card = card
	self.heights[column] = self.heights[column] + 40

	if content ~= "" then
		label(card, content, 21, COLORS.text, DISPLAY, { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 0, TextTruncate = Enum.TextTruncate.AtEnd })
	else
		self.heights[column] = self.heights[column] - 22
	end
end

---@param content string
---@return table
function Tab:AddLabel(content)
	local card = currentCard(self)
	self.order = self.order + 1
	self.heights[self.column] = self.heights[self.column] + 30

	local item = label(card, content, 12, COLORS.muted, BODY, {
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = self.order,
	})

	return {
		SetText = function(_, value)
			item.Text = value
		end,
	}
end

---@param opts table
function Tab:AddButton(opts)
	-- An outlined button: hairline border, ivory type; hovering fills it a little.
	local row, scale = newRow(self, 36, true, 0.96, 0.86)
	stroke(row, 0.6)
	label(row, opts.Text, 12, COLORS.text, BOLD, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	track(row.Activated:Connect(function()
		squish(scale)
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

-- A toggle row. Every toggle gets a bind chip (click it, press a key; Esc / Backspace clears) unless Bind = false, and
-- is listed in the on-screen keybind list while enabled unless NoList = true.
---@param opts table
---@return table
function Tab:AddToggle(opts)
	local value = false
	local key = opts.Key
	local bindable = opts.Bind ~= false and not opts.NoFlag
	-- Long text wraps onto more lines and the row grows to fit, so a sentence is never cut off.
	local reserved = bindable and 122 or 70
	local measured = textService:GetTextSize(tostring(opts.Text), 13, BODY, Vector2.new(ROW_WIDTH - reserved, 1000))
	local row, scale = newRow(self, math.max(36, math.ceil(measured.Y) + 16), true)
	label(row, opts.Text, 13, COLORS.text, BODY, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -reserved, 1, 0),
		TextWrapped = true,
	})

	local rail = create("Frame", { Size = UDim2.fromOffset(40, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), BackgroundColor3 = COLORS.track, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, row)
	corner(rail, 4)
	stroke(rail, 0.55)
	local fill = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.accent, BackgroundTransparency = 1, BorderSizePixel = 0 }, rail)
	corner(fill, 4)
	local knob = create("Frame", { Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), BackgroundColor3 = COLORS.muted, BorderSizePixel = 0 }, rail)
	corner(knob, 3)

	local chip
	if bindable then
		chip = create("TextButton", {
			Text = "",
			AutoButtonColor = false,
			Font = MONO,
			TextSize = 10,
			TextColor3 = COLORS.muted,
			Size = UDim2.fromOffset(50, 20),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -58, 0.5, 0),
			BackgroundColor3 = COLORS.track,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
		}, row)
		corner(chip, 3)
		stroke(chip, 0.7)
	end

	local function refreshList()
		if active.refreshKeyList then active.refreshKeyList() end
	end

	local entry
	local function apply(incoming, silent)
		local was = value
		value = incoming == true
		entry.Value = value
		tween(fill, 0.3, { BackgroundTransparency = value and 0 or 1 })
		tween(knob, 0.2, { Position = UDim2.new(0, value and 21 or 3, 0.5, 0), BackgroundColor3 = value and COLORS.dark or COLORS.muted }, QUINT)

		if was ~= value then
			self.enabled = self.enabled + (value and 1 or -1)
			if self.refreshBadge then self.refreshBadge() end
			refreshList()
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
			chip.TextColor3 = key and COLORS.accent2 or COLORS.muted
			refreshList()
		end

		HussUI.Flags[flagName] = { Type = "Bind", Value = key and key.Name or "None", Set = applyKey }
		chip.Text = keyLabel(key)
		chip.TextColor3 = key and COLORS.accent2 or COLORS.muted

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

	local row = newRow(self, 52, false)
	label(row, opts.Text, 13, COLORS.text, BODY, {
		Position = UDim2.fromOffset(12, 5),
		Size = UDim2.new(1, -90, 0, 18),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local readout = label(row, "", 12, COLORS.accent2, MONO, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 5),
		Size = UDim2.fromOffset(70, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local rail = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, -24, 0, 4), Position = UDim2.new(0, 12, 0, 34), BackgroundColor3 = COLORS.track, BackgroundTransparency = 0, BorderSizePixel = 0 }, row)
	corner(rail, 2)
	stroke(rail, 0.75)
	local fill = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0 }, rail)
	corner(fill, 2)
	local knob = create("Frame", { Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0, ZIndex = 3 }, rail)
	corner(knob, 2)

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

	track(rail.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			tween(knob, 0.15, { Size = UDim2.fromOffset(15, 15) }, QUINT)
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
			tween(knob, 0.15, { Size = UDim2.fromOffset(12, 12) }, QUINT)
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

	local row = newRow(self, 36, false)
	row.ClipsDescendants = true

	local header = create("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36) }, row)
	label(header, opts.Text, 13, COLORS.text, BODY, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -130, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local readout = label(header, "", 11, COLORS.accent2, MONO, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -32, 0, 0),
		Size = UDim2.fromOffset(100, 36),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	-- Gotham has no arrow glyph, so the chevron is two rotated bars.
	local chevron = create("Frame", { Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), BackgroundTransparency = 1 }, header)
	for _, arm in { { x = 4.5, rotation = 45 }, { x = 9.5, rotation = -45 } } do
		create("Frame", { Size = UDim2.fromOffset(8, 2), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(arm.x, 7), Rotation = arm.rotation, BorderSizePixel = 0, BackgroundColor3 = COLORS.muted }, chevron)
	end

	local list = create("Frame", { Size = UDim2.new(1, -12, 0, 0), Position = UDim2.fromOffset(6, 38), BackgroundTransparency = 1 }, row)
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	local entry
	local buttons = {}

	local function paint()
		for name, button in buttons do
			local selected = name == value
			tween(button, 0.2, { BackgroundTransparency = selected and 0.8 or 1 })
			button.Font = selected and BOLD or BODY
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
		tween(row, 0.35, { Size = UDim2.new(1, 0, 0, open and (36 + #options * 30 + 8) or 36) }, QUINT)
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
			corner(button, 6)
			buttons[name] = button

			track(button.Activated:Connect(function()
				apply(name, false)
				setOpen(false)
			end))
		end
	end

	entry = registerFlag(self, opts, "Dropdown", apply)
	build()
	apply(value, true)

	track(header.Activated:Connect(function()
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
	local row = newRow(self, 36, false)
	label(row, opts.Text, 13, COLORS.text, BODY, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -96, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local pill = create("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Font = MONO,
		TextSize = 11,
		TextColor3 = COLORS.accent2,
		Size = UDim2.fromOffset(72, 24),
		TextTruncate = Enum.TextTruncate.AtEnd,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		BackgroundColor3 = COLORS.track,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
	}, row)
	corner(pill, 3)
	stroke(pill, 0.65)

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
	local row = newRow(self, 36, false)
	label(row, opts.Text, 13, COLORS.text, BODY, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.4, 0, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local box = create("TextBox", {
		Text = "",
		PlaceholderText = opts.Placeholder or "",
		PlaceholderColor3 = COLORS.muted,
		TextColor3 = COLORS.text,
		Font = BODY,
		TextSize = 12,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0.55, -16, 0, 24),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		BackgroundColor3 = COLORS.track,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
	}, row)
	corner(box, 6)
	stroke(box, 0.8)
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

	local row = newRow(self, 36, false)
	row.ClipsDescendants = true

	local header = create("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36) }, row)
	label(header, opts.Text, 13, COLORS.text, BODY, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -70, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local swatch = create("Frame", { Size = UDim2.fromOffset(34, 18), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), BorderSizePixel = 0 }, header)
	corner(swatch, 6)
	stroke(swatch, 0.6)

	local grid = create("Frame", { Position = UDim2.fromOffset(10, 40), Size = UDim2.new(1, -20, 0, 64), BackgroundTransparency = 1 }, row)
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
		corner(chip, 6)
		stroke(chip, 0.7)
		track(chip.Activated:Connect(function()
			apply(fromHex(hex), false)
		end))
	end

	track(header.Activated:Connect(function()
		open = not open
		tween(row, 0.35, { Size = UDim2.new(1, 0, 0, open and 112 or 36) }, QUINT)
	end))

	return entry
end

-- A full-width row of stat cards: small title, value, one line of detail. Get returns valueText, alpha 0..1 (1 = on), subText.
---@param specs table
function Tab:AddStatRow(specs)
	self.order = self.order + 1

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 90), BackgroundTransparency = 1, LayoutOrder = self.order - 1000 }, self.list)
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, holder)

	local count = #specs
	for index, spec in specs do
		local card = create("Frame", {
			Size = UDim2.new(1 / count, -12 * (count - 1) / count, 1, 0),
			BackgroundColor3 = COLORS.card,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			LayoutOrder = index,
		}, holder)
		corner(card, 6)
		stroke(card, 0.9)

		local truncate = Enum.TextTruncate.AtEnd
		label(card, string.upper(spec.Title), 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(14, 11), Size = UDim2.new(1, -28, 0, 14), TextTruncate = truncate })
		local value = label(card, "", 29, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(14, 28), Size = UDim2.new(1, -28, 0, 34), TextTruncate = truncate })
		local sub = label(card, "", 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(14, 66), Size = UDim2.new(1, -28, 0, 14), TextTruncate = truncate })

		table.insert(active.statCards, { spec = spec, value = value, sub = sub, segments = {}, shown = -1 })
	end
end

-- A full-width block above the two columns (stat rows and the film viewer live here).
---@param height number
---@return Frame
function Tab:AddWide(height)
	self.order = self.order + 1

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = COLORS.card, BorderSizePixel = 0, ClipsDescendants = true, LayoutOrder = self.order - 1000 }, self.list)
	corner(holder, 6)
	stroke(holder, 0.9)
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
	local card = self:AddWide(404)

	local STAGE_W, STAGE_H = 218, 388
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

			local made, player = pcall(Edits.newPlayer, stageHost, edit, { volume = Edits.prefs.volume, name = "Film", ZIndex = 3 })
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
	local listTop = 172
	local listHolder = create("Frame", { Position = UDim2.fromOffset(rightX, listTop), Size = UDim2.new(1, -rightX - 16, 1, -listTop - 12), BackgroundTransparency = 1 }, card)
	create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, listHolder)
	local listNotice = label(listHolder, "LOADING THE EDIT LIBRARY", 10, COLORS.muted, MONO, { Size = UDim2.new(1, 0, 0, 20) })

	local function buildList()
		listNotice:Destroy()
		local thumbs = Edits.thumbs()
		for index, edit in Edits.manifest.edits do
			local row = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.96, BorderSizePixel = 0, LayoutOrder = index }, listHolder)
			corner(row, 4)
			local mark = create("Frame", { Size = UDim2.fromOffset(2, 22), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = COLORS.accent, BackgroundTransparency = 1, BorderSizePixel = 0 }, row)
			local cover = create("ImageLabel", { Position = UDim2.fromOffset(10, 4), Size = UDim2.fromOffset(20, 32), BackgroundColor3 = COLORS.track, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Crop, Image = thumbs or "", ImageRectOffset = Vector2.new((edit.thumb or 0) * 144, 0), ImageRectSize = Vector2.new(144, 256) }, row)
			corner(cover, 2)
			label(row, string.format("%02d", index), 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(40, 0), Size = UDim2.fromOffset(22, 40) })
			label(row, edit.title, 13, COLORS.text, BODY, { Position = UDim2.fromOffset(66, 5), Size = UDim2.new(1, -190, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
			label(row, string.upper(edit.subtitle or ""), 9, COLORS.muted, MONO, { Position = UDim2.fromOffset(66, 22), Size = UDim2.new(1, -190, 0, 12), TextTruncate = Enum.TextTruncate.AtEnd })
			local status = label(row, "", 10, COLORS.muted, MONO, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Size = UDim2.fromOffset(110, 40), TextXAlignment = Enum.TextXAlignment.Right })

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

-- Window -----------------------------------------------------------------------------------------------------

local Window = {}
Window.__index = Window

-- Letter-spaced small caps, the way the reference sets its labels.
---@param content string
---@return string
local function spaced(content)
	local result = string.gsub(string.upper(content), ".", function(character)
		return character == " " and "  " or (character .. " ")
	end)
	return (string.gsub(result, "%s+$", ""))
end

---@param name string
function Window:CreateCategory(name)
	self.order = self.order + 1
	label(self.tabList, spaced(name), 10, COLORS.muted, MONO, {
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = self.order,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Position = UDim2.fromOffset(10, 0),
	}).Name = "Category"
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
		tween(previous.hl, 0.25, { BackgroundTransparency = 1 })
		tween(previous.bar, 0.25, { BackgroundTransparency = 1, Size = UDim2.fromOffset(2, 6) })
		tween(previous.title, 0.25, { TextColor3 = COLORS.muted })
		tween(previous.glyph, 0.25, { ImageColor3 = COLORS.muted })
		task.delay(0.2, function()
			if window.current ~= previous and previous.group.Parent then previous.group.Visible = false end
		end)
	end

	tab.group.Visible = true
	tab.group.GroupTransparency = 1
	tab.group.Position = UDim2.fromOffset(0, 18)
	tab.scale.Scale = 0.985
	tween(tab.group, 0.5, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) })
	tween(tab.scale, 0.5, { Scale = 1 })
	tween(tab.hl, 0.2, { BackgroundTransparency = 0.94 })
	tween(tab.bar, 0.3, { BackgroundTransparency = 0, Size = UDim2.fromOffset(2, 20) })
	tween(tab.title, 0.25, { TextColor3 = COLORS.text })
	tween(tab.glyph, 0.25, { ImageColor3 = COLORS.text })

	-- The page heading fades in again for every tab, like the reference's masked transitions.
	window.pageTitle.Text = tab.name
	window.pageSub.Text = string.upper(tab.subtitle or "")
	window.pageTitle.TextTransparency = 1
	window.pageSub.TextTransparency = 1
	tween(window.pageTitle, 0.45, { TextTransparency = 0 })
	tween(window.pageSub, 0.45, { TextTransparency = 0 })
end

---@param window table
---@param name string
---@param iconName string?
---@param listParent Instance
---@param order number
---@return table
local function makeTab(window, name, iconName, listParent, order)
	local tab = setmetatable({ name = name, window = window, order = 0, enabled = 0, heights = { 0, 0 }, column = 1 }, Tab)

	local button = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = order }, listParent)
	tab.hl = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.row, BackgroundTransparency = 1, BorderSizePixel = 0 }, button)
	corner(tab.hl, 4)
	tab.bar = create("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(2, 6), BackgroundColor3 = COLORS.accent, BackgroundTransparency = 1, BorderSizePixel = 0 }, button)

	local glyphImage = icon(iconName)
	tab.glyph = create("ImageLabel", { Image = glyphImage, ImageColor3 = COLORS.muted, BackgroundTransparency = 1, Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 14, 0.5, 0), Visible = glyphImage ~= "" }, button)
	tab.title = label(button, name, 14, COLORS.muted, BODY, { Position = UDim2.fromOffset(glyphImage ~= "" and 40 or 16, 0), Size = UDim2.new(1, -(glyphImage ~= "" and 76 or 52), 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })

	-- Count of switched-on toggles, set in mono beside the tab name.
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
		ScrollBarImageColor3 = COLORS.muted,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, tab.group)
	create("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, tab.list)
	create("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingLeft = UDim.new(0, 2), PaddingBottom = UDim.new(0, 12), PaddingRight = UDim.new(0, 10) }, tab.list)

	-- Two columns of cards under any stat row.
	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 1 }, tab.list)
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
	tab.columns = {}
	for index = 1, 2 do
		tab.columns[index] = create("Frame", { Size = UDim2.new(0.5, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = index }, holder)
		create("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, tab.columns[index])
	end

	track(button.MouseEnter:Connect(function()
		if window.current ~= tab then tween(tab.hl, 0.2, { BackgroundTransparency = 0.96 }) end
	end))
	track(button.MouseLeave:Connect(function()
		if window.current ~= tab then tween(tab.hl, 0.25, { BackgroundTransparency = 1 }) end
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

	local tab = makeTab(self, name, iconName, self.tabList, self.order)
	tab.subtitle = subtitle
	if not self.current then selectTab(tab) end

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

-- A toast: mono edition line, serif title, dim body and a hairline that runs out with the timer.
---@param opts table
function Window:Notify(opts)
	local duration = opts.Duration or 4
	local kinds = { info = "NOTICE", ok = "COMPLETE", warn = "ATTENTION", bad = "UNAVAILABLE" }

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, active.toastHost)
	local card = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(340, 0), BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0, BorderSizePixel = 0, ClipsDescendants = true }, holder)
	corner(card, 8)
	stroke(card, 0.82)

	local inner = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, card)
	create("UIPadding", { PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 16), PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 18) }, inner)
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, inner)

	label(inner, "HUSS VALLEY  /  " .. (kinds[opts.Kind or "info"] or "NOTICE"), 9, COLORS.muted, MONO, { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 12) })
	label(inner, tostring(opts.Title or ""), 21, COLORS.text, DISPLAY, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 26), TextTruncate = Enum.TextTruncate.AtEnd })
	label(inner, tostring(opts.Text or ""), 12, COLORS.accent2, BODY, { LayoutOrder = 3, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })

	local timer = create("Frame", { Size = UDim2.new(1, -40, 0, 1), AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 20, 1, -8), BackgroundColor3 = COLORS.accent2, BackgroundTransparency = 0.3, BorderSizePixel = 0, ZIndex = 5 }, card)

	tween(card, 0.35, { Position = UDim2.fromOffset(0, 0) }, QUINT)
	tween(timer, duration, { Size = UDim2.new(0, 0, 0, 1) }, Enum.EasingStyle.Linear)

	task.delay(duration, function()
		if not holder.Parent then return end

		tween(card, 0.35, { Position = UDim2.fromOffset(340, 0) }, QUINT, IN)
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
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		LayoutOrder = #active.widgets + 1,
		ClipsDescendants = true,
	}, active.widgetHost)
	corner(card, 6)
	stroke(card, 0.9)

	local glyph = create("ImageLabel", { Image = icon(spec.Icon), ImageColor3 = COLORS.text, ImageTransparency = 0.2, BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(14, 13) }, card)
	label(card, string.upper(spec.Title), 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(spec.Icon and 34 or 14, 12), Size = UDim2.new(1, -48, 0, 16) })
	local value = label(card, "", 28, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(14, 32), Size = UDim2.new(1, -28, 0, 32), TextTruncate = Enum.TextTruncate.AtEnd })
	local sub = label(card, "", 10, COLORS.accent2, MONO, { Position = UDim2.fromOffset(14, 68), Size = UDim2.new(1, -28, 0, 14) })
	sub.TextColor3 = COLORS.muted
	if not spec.Icon then glyph.Visible = false end

	local widget = { spec = spec, value = value, sub = sub, kind = spec.Kind, history = {}, elapsed = 0 }

	if isBars then
		local chart = create("Frame", { Position = UDim2.new(0, 14, 1, -14), AnchorPoint = Vector2.new(0, 1), Size = UDim2.new(1, -28, 0, 82), BackgroundTransparency = 1 }, card)
		create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, chart)
		widget.bars = {}
		for index = 1, 9 do
			widget.history[index] = 0
			local bar = create("Frame", { Size = UDim2.new(1 / 9, -6 * 8 / 9, 0, 6), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.12, BorderSizePixel = 0, LayoutOrder = index }, chart)
			corner(bar, 6)
			widget.bars[index] = bar
		end
	else
		local bar = create("Frame", { Position = UDim2.new(0, 14, 1, -22), Size = UDim2.new(1, -28, 0, 10), BackgroundTransparency = 1 }, card)
		create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, bar)
		widget.segments = {}
		for segment = 1, SEGMENTS do
			widget.segments[segment] = create("Frame", { Size = UDim2.new(1 / SEGMENTS, -2 * (SEGMENTS - 1) / SEGMENTS, 1, 0), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.88, BorderSizePixel = 0, LayoutOrder = segment }, bar)
			corner(widget.segments[segment], 2)
		end
	end

	table.insert(active.widgets, widget)
end

---@return boolean
function Window:IsOpen()
	return active ~= nil and active.visible
end

-- Opens or closes the window with a pop + fade and the background blur.
---@param state boolean?
function Window:Toggle(state)
	if state == nil then state = not active.visible end
	if state == active.visible then return end

	active.visible = state
	local blurWanted = HussUI.Flags.ui_blur == nil or HussUI.Flags.ui_blur.Value == true

	if state then
		active.root.Visible = true
		active.pop.Scale = 0.97
		tween(active.pop, 0.25, { Scale = 1 }, QUINT)
		active.cover.BackgroundTransparency = 0.2
		tween(active.cover, 0.45, { BackgroundTransparency = 1 })
		if blurWanted then tween(active.blur, 0.4, { Size = 12 }) end
	else
		tween(active.pop, 0.2, { Scale = 0.97 }, QUINT, IN)
		tween(active.cover, 0.25, { BackgroundTransparency = 0.2 })
		tween(active.blur, 0.3, { Size = 0 })
		task.delay(0.3, function()
			if active and not active.visible and active.root.Parent then active.root.Visible = false end
		end)
	end
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

-- Slow ivory shimmer for the wordmark: the colour sequence is cycled (sliding a gradient's offset would uncover the base colour).
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
	active = { connections = {}, visible = false, capturing = false, onDestroy = opts.OnDestroy, widgets = {}, statCards = {}, listed = {} }

	local showWidgets = opts.Widgets == true

	local gui = create("ScreenGui", { Name = GUI_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1000, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, getGuiParent())
	active.gui = gui
	active.blur = create("BlurEffect", { Name = BLUR_NAME, Size = 0 }, lightingService)

	local root = create("Frame", { Name = "Root", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT), BackgroundTransparency = 1, Visible = false }, gui)
	active.root = root
	local fit = create("UIScale", {}, root)
	local function refit()
		local camera = workspace.CurrentCamera
		if not camera then return end

		local viewport = camera.ViewportSize
		-- The main panel stays centered; leave room for the widget column on both sides so it never leaves the screen.
		local span = showWidgets and (WINDOW_WIDTH + 2 * (WIDGET_GAP + WIDGET_WIDTH)) or WINDOW_WIDTH
		fit.Scale = math.clamp(math.min(viewport.X / (span + 40), viewport.Y / (WINDOW_HEIGHT + 50)), 0.5, 1.15)
	end
	refit()
	if workspace.CurrentCamera then track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)) end

	local body = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, root)
	active.pop = create("UIScale", { Scale = 1 }, body)

	-- Main panel: one near-black plane with a hairline edge.
	local main = create("Frame", { Name = "Main", Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT), BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0, BorderSizePixel = 0, ClipsDescendants = true }, body)
	corner(main, 10)
	stroke(main, 0.84, 1)

	-- Pinstripe field behind everything (a suit-cloth nod to the reference), with a slow sheen crossing it.
	local stripes = create("Frame", { Name = "Pinstripe", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 0 }, main)
	for x = SIDEBAR_WIDTH + 12, WINDOW_WIDTH, 26 do
		create("Frame", { Position = UDim2.fromOffset(x, HEADER_HEIGHT), Size = UDim2.new(0, 1, 1, -HEADER_HEIGHT), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.975, BorderSizePixel = 0 }, stripes)
	end
	local sheen = create("Frame", { Position = UDim2.fromOffset(-300, HEADER_HEIGHT), Size = UDim2.new(0, 300, 1, -HEADER_HEIGHT), BackgroundColor3 = COLORS.row, BorderSizePixel = 0 }, stripes)
	create("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.955), NumberSequenceKeypoint.new(1, 1) }) }, sheen)
	tweenService:Create(sheen, TweenInfo.new(12, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1), { Position = UDim2.fromOffset(WINDOW_WIDTH, HEADER_HEIGHT) }):Play()

	-- Header: wordmark, edition line, the Edits shortcut, key hint, close. It is also the drag handle.
	local header = create("Frame", { Name = "Header", Size = UDim2.new(1, 0, 0, HEADER_HEIGHT), BackgroundTransparency = 1, Active = true }, main)
	local wordmark = label(header, string.upper(tostring(opts.Title or "Hub")), 38, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(28, 14), Size = UDim2.fromOffset(360, 44) })
	local shimmer = create("UIGradient", { Color = chromeSequence(0) }, wordmark)
	label(header, "PRIVATE EDITION  /  " .. string.upper(tostring(opts.Subtitle or "")), 9, COLORS.muted, MONO, { Position = UDim2.fromOffset(30, 60), Size = UDim2.fromOffset(520, 14), TextTruncate = Enum.TextTruncate.AtEnd })
	create("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.88, BorderSizePixel = 0 }, header)

	local close = create("TextButton", { Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -20, 0.5, 0), Size = UDim2.fromOffset(30, 30), BackgroundColor3 = COLORS.row, BackgroundTransparency = 1, BorderSizePixel = 0 }, header)
	corner(close, 4)
	stroke(close, 0.7)
	for _, rotation in { 45, -45 } do
		create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(12, 1), Rotation = rotation, BorderSizePixel = 0, BackgroundColor3 = COLORS.text }, close)
	end
	track(close.MouseEnter:Connect(function()
		tween(close, 0.2, { BackgroundColor3 = COLORS.bad, BackgroundTransparency = 0.5 })
	end))
	track(close.MouseLeave:Connect(function()
		tween(close, 0.25, { BackgroundColor3 = COLORS.row, BackgroundTransparency = 1 })
	end))
	track(close.Activated:Connect(function()
		window:Toggle(false)
	end))

	local hint = create("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -62, 0.5, 0), Size = UDim2.fromOffset(104, 30), BackgroundTransparency = 1 }, header)
	corner(hint, 4)
	stroke(hint, 0.8)
	window.keyHint = label(hint, string.upper(window.toggleKey.Name), 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -16, 1, 0), TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd })

	-- The film shortcut: serif word with an underline that draws in on hover.
	if opts.FilmTab then
		local films = create("TextButton", { Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -184, 0.5, 0), Size = UDim2.fromOffset(110, 34), BackgroundTransparency = 1 }, header)
		local word = label(films, opts.FilmLabel or "The edits", 22, COLORS.text, DISPLAY, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
		local underline = create("Frame", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromOffset(0, 1), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0 }, films)
		track(films.MouseEnter:Connect(function()
			tween(underline, 0.35, { Size = UDim2.new(1, -16, 0, 1) })
			tween(word, 0.3, { Position = UDim2.fromOffset(0, -2) })
		end))
		track(films.MouseLeave:Connect(function()
			tween(underline, 0.3, { Size = UDim2.fromOffset(0, 1) })
			tween(word, 0.3, { Position = UDim2.fromOffset(0, 0) })
		end))
		track(films.Activated:Connect(function()
			window:SelectTab(opts.FilmTab)
		end))
	end

	-- Sidebar: tabs, with a hairline on its right edge. The Settings tab is pinned to the bottom.
	local sidebar = create("Frame", { Position = UDim2.fromOffset(0, HEADER_HEIGHT + 1), Size = UDim2.new(0, SIDEBAR_WIDTH, 1, -(HEADER_HEIGHT + 1)), BackgroundTransparency = 1, ClipsDescendants = true }, main)
	create("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.9, BorderSizePixel = 0 }, sidebar)

	window.tabList = create("ScrollingFrame", { Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -21, 1, -70), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 0, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new() }, sidebar)
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, window.tabList)

	local footer = create("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 10, 1, -12), Size = UDim2.new(1, -21, 0, 40), BackgroundTransparency = 1 }, sidebar)
	create("UIListLayout", { VerticalAlignment = Enum.VerticalAlignment.Bottom }, footer)

	-- Page heading: serif title, mono subtitle.
	local pageLeft = SIDEBAR_WIDTH + 30
	window.pageTitle = label(main, "", 36, COLORS.text, DISPLAY, { Position = UDim2.fromOffset(pageLeft, HEADER_HEIGHT + 16), Size = UDim2.new(1, -(pageLeft + 24), 0, 42), TextTruncate = Enum.TextTruncate.AtEnd })
	window.pageSub = label(main, "", 10, COLORS.muted, MONO, { Position = UDim2.fromOffset(pageLeft + 2, HEADER_HEIGHT + 60), Size = UDim2.new(1, -(pageLeft + 24), 0, 14), TextTruncate = Enum.TextTruncate.AtEnd })

	-- Pages.
	window.pages = create("Frame", { Position = UDim2.fromOffset(pageLeft, HEADER_HEIGHT + 88), Size = UDim2.new(1, -(pageLeft + 18), 1, -(HEADER_HEIGHT + 100)), BackgroundTransparency = 1, ClipsDescendants = true }, main)

	-- Cover used for the open/close fade.
	active.cover = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.bg, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 30, Active = false }, main)
	corner(active.cover, 10)

	-- Floating widgets beside the window.
	active.widgetHost = create("Frame", { Position = UDim2.fromOffset(WINDOW_WIDTH + WIDGET_GAP, 0), Size = UDim2.fromOffset(WIDGET_WIDTH, WINDOW_HEIGHT), BackgroundTransparency = 1, Visible = showWidgets }, body)
	create("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, active.widgetHost)

	-- Toasts live on their own host so they survive the window being hidden.
	active.toastHost = create("Frame", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -20, 1, -20), Size = UDim2.fromOffset(320, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, gui)
	create("UIListLayout", { Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, active.toastHost)

	-- Keybind list: a small draggable panel that stays on screen while the menu is closed. It lists every enabled
	-- feature with its key (and the disabled ones too when "List disabled features too" is on).
	local listFrame = create("Frame", { Position = UDim2.new(0, 24, 0.38, 0), Size = UDim2.fromOffset(220, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0.06, BorderSizePixel = 0, Visible = false, Active = true, ClipsDescendants = true }, gui)
	corner(listFrame, 8)
	stroke(listFrame, 0.82)
	create("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12) }, listFrame)
	create("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, listFrame)
	local listTitle = label(listFrame, "KEYBINDS", 10, COLORS.muted, MONO, { Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 0, TextTruncate = Enum.TextTruncate.AtEnd })
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
			local dot = create("Frame", { Size = UDim2.fromOffset(5, 5), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = on and COLORS.accent or COLORS.muted, BackgroundTransparency = on and 0 or 0.6, BorderSizePixel = 0 }, holder)
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

		window:Toggle()
	end))

	-- Live refresh: stat cards, widgets and the wordmark shimmer.
	local fps = 60
	local statClock = 0
	local widgetClock = 0
	local shimmerClock = 0
	track(runService.Heartbeat:Connect(function(deltaTime)
		fps = fps + ((1 / math.max(deltaTime, 1e-3)) - fps) * math.min(1, deltaTime * 4)
		if not active.visible then return end

		shimmerClock = shimmerClock + deltaTime
		if shimmerClock >= 1 / 20 then
			shimmerClock = 0
			shimmer.Color = chromeSequence(os.clock() * 0.22)
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

	-- Built-in Settings tab, pinned to the sidebar footer so it is always last.
	local settings = makeTab(window, "Settings", "settings", footer, 1)
	settings.subtitle = "Interface, configs and session"
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
		Text = "Background blur",
		NoList = true,
		Bind = false,
		Default = false,
		Flag = "ui_blur",
		Callback = function(on)
			if active.visible then tween(active.blur, 0.3, { Size = on and 12 or 0 }) end
		end,
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

	active.window = window
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

	for _, instance in { owner.gui, owner.introGui, owner.blur } do
		if instance then pcall(function() instance:Destroy() end) end
	end

	table.clear(HussUI.Flags)
	if shared.__HussUI == HussUI then shared.__HussUI = nil end

	-- Lets the script that owns the window unload itself when the user presses Unload Script.
	if owner.onDestroy then safeCall(owner.onDestroy) end
end

return HussUI
