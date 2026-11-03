-- V18UI: smoked-glass dashboard UI for executor scripts.
-- Modeled on the "Glassy Dashboard V18" reel in VidHelper: a warm translucent window over a blurred scene, a left nav
-- with a workspace profile and an active glass pill, a serif greeting header, rounded stat cards with segmented
-- bars, titled glass cards in two columns, and floating widget cards (blue bar chart, stat cards) beside the window.
-- API: CreateWindow -> CreateCategory / CreateTab -> Add* (same shape as GlassUI / ui.lua).
--
--   local UI = loadstring(readfile("V18UI.lua"))()
--   local window = UI:CreateWindow({ Title = "Da Hood", Subtitle = "Workspace", ToggleKey = Enum.KeyCode.RightShift })
--   local tab = window:CreateTab("Combat", "crosshair")
--   tab:AddSection("Aimbot")
--   tab:AddToggle({ Text = "Enabled", Flag = "aimEnabled", Callback = function(on) end })
--   UI.Flags.aimEnabled.Value, UI:Destroy()

local V18UI = {}
V18UI.Flags = {}

-- Constants.
local GUI_NAME = "V18UI"
local INTRO_NAME = "V18UI_Intro"
local BLUR_NAME = "V18UI_Blur"
local ICON_FOLDER = "V18UI/icons/"
local WINDOW_WIDTH = 900
local WINDOW_HEIGHT = 540
local SIDEBAR_WIDTH = 196
local WIDGET_WIDTH = 188
local WIDGET_GAP = 14
local SEGMENTS = 22
local QUINT = Enum.EasingStyle.Quint
local BACK = Enum.EasingStyle.Back
local OUT = Enum.EasingDirection.Out
local IN = Enum.EasingDirection.In

-- Warm smoked-glass palette sampled from the V18 frames.
local COLORS = {
	bg = Color3.fromRGB(24, 19, 16),
	sidebar = Color3.fromRGB(30, 24, 21),
	card = Color3.fromRGB(28, 22, 19),
	row = Color3.fromRGB(255, 244, 232),
	track = Color3.fromRGB(18, 14, 12),
	stroke = Color3.fromRGB(255, 240, 224),
	text = Color3.fromRGB(248, 242, 236),
	muted = Color3.fromRGB(182, 170, 158),
	accent = Color3.fromRGB(70, 108, 226),
	accent2 = Color3.fromRGB(122, 152, 244),
	good = Color3.fromRGB(96, 214, 150),
	bad = Color3.fromRGB(240, 96, 112),
}

local SERIF = Enum.Font.Garamond
local BODY = Enum.Font.GothamMedium
local BOLD = Enum.Font.GothamBold

-- Services.
local playersService = game:GetService("Players")
local runService = game:GetService("RunService")
local tweenService = game:GetService("TweenService")
local userInputService = game:GetService("UserInputService")
local lightingService = game:GetService("Lighting")
local coreGuiService = game:GetService("CoreGui")
local httpService = game:GetService("HttpService")
local statsService = game:GetService("Stats")

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

---@param inst Instance
---@param first Color3
---@param second Color3
---@param rotation number?
---@return UIGradient
local function gradient(inst, first, second, rotation)
	return create("UIGradient", { Color = ColorSequence.new(first, second), Rotation = rotation or 0 }, inst)
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
	if not success then warn("[V18UI] callback error: " .. tostring(err)) end
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
		V18UI.Flags[opts.Flag or (tab.name .. "_" .. tostring(opts.Text))] = entry
	end

	return entry
end

---@param scale UIScale
local function squish(scale)
	scale.Scale = 0.97
	tween(scale, 0.35, { Scale = 1 }, BACK)
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
local function newRow(tab, height, clickable)
	local card = currentCard(tab)
	tab.order = tab.order + 1
	tab.heights[tab.column] = tab.heights[tab.column] + height + 6

	local props = {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = COLORS.row,
		BackgroundTransparency = 0.93,
		BorderSizePixel = 0,
		LayoutOrder = tab.order,
	}
	if clickable then
		props.Text = ""
		props.AutoButtonColor = false
	end

	local row = create(clickable and "TextButton" or "Frame", props, card)
	corner(row, 10)
	local scale = create("UIScale", { Scale = 1 }, row)

	track(row.MouseEnter:Connect(function()
		tween(row, 0.2, { BackgroundTransparency = 0.86 })
	end))
	track(row.MouseLeave:Connect(function()
		tween(row, 0.25, { BackgroundTransparency = 0.93 })
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
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		LayoutOrder = self.order,
	}, self.columns[column])
	corner(card, 16)
	stroke(card, 0.88)
	create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12) }, card)
	create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, card)

	self.card = card
	self.heights[column] = self.heights[column] + 36

	if content ~= "" then
		label(card, content, 15, COLORS.text, BOLD, { Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 0 })
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
	local row, scale = newRow(self, 36, true)
	row.BackgroundColor3 = Color3.new(1, 1, 1)
	row.BackgroundTransparency = 0.05
	gradient(row, COLORS.accent, COLORS.accent2, 0)
	label(row, opts.Text, 13, Color3.fromRGB(14, 20, 40), BOLD, {
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
	local row, scale = newRow(self, 36, true)
	label(row, opts.Text, 13, COLORS.text, BODY, {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, bindable and -122 or -70, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local rail = create("Frame", { Size = UDim2.fromOffset(40, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), BackgroundColor3 = COLORS.track, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, row)
	corner(rail, 11)
	stroke(rail, 0.82)
	local fill = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0 }, rail)
	corner(fill, 11)
	gradient(fill, COLORS.accent, COLORS.accent2, 0)
	local knob = create("Frame", { Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, rail)
	corner(knob, 8)

	local chip
	if bindable then
		chip = create("TextButton", {
			Text = "",
			AutoButtonColor = false,
			Font = BOLD,
			TextSize = 10,
			TextColor3 = COLORS.muted,
			Size = UDim2.fromOffset(50, 20),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -58, 0.5, 0),
			BackgroundColor3 = COLORS.track,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
		}, row)
		corner(chip, 10)
		stroke(chip, 0.86)
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
		tween(knob, 0.4, { Position = UDim2.new(0, value and 21 or 3, 0.5, 0) }, BACK)

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
			V18UI.Flags[flagName].Value = key and key.Name or "None"
			chip.Text = keyLabel(key)
			chip.TextColor3 = key and COLORS.accent2 or COLORS.muted
			refreshList()
		end

		V18UI.Flags[flagName] = { Type = "Bind", Value = key and key.Name or "None", Set = applyKey }
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
	local readout = label(row, "", 13, COLORS.accent2, BOLD, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 5),
		Size = UDim2.fromOffset(70, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local rail = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, -24, 0, 6), Position = UDim2.new(0, 12, 0, 33), BackgroundColor3 = COLORS.track, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, row)
	corner(rail, 3)
	local fill = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, rail)
	corner(fill, 3)
	gradient(fill, COLORS.accent, COLORS.accent2, 0)
	local knob = create("Frame", { Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3 }, rail)
	corner(knob, 7)
	create("UIStroke", { Color = COLORS.accent, Thickness = 2, Transparency = 0.2 }, knob)

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
			tween(knob, 0.2, { Size = UDim2.fromOffset(18, 18) }, BACK)
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
			tween(knob, 0.25, { Size = UDim2.fromOffset(14, 14) }, BACK)
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
	local readout = label(header, "", 12, COLORS.accent2, BOLD, {
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
			corner(button, 8)
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
		Size = UDim2.new(1, -110, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local pill = create("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Font = BOLD,
		TextSize = 11,
		TextColor3 = COLORS.accent2,
		Size = UDim2.fromOffset(80, 24),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		BackgroundColor3 = COLORS.track,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
	}, row)
	corner(pill, 12)
	stroke(pill, 0.8)

	local entry
	local function apply(incoming, silent)
		if typeof(incoming) == "string" then incoming = Enum.KeyCode[incoming] end
		key = incoming
		entry.Value = key
		pill.Text = key and key.Name or "None"
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
	corner(box, 8)
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
		corner(chip, 7)
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

-- A full-width row of stat cards (big serif value, segmented bar). Get returns valueText, alpha 0..1, subText.
---@param specs table
function Tab:AddStatRow(specs)
	self.order = self.order + 1

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 96), BackgroundTransparency = 1, LayoutOrder = self.order - 1000 }, self.list)
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, holder)

	local count = #specs
	for index, spec in specs do
		local card = create("Frame", {
			Size = UDim2.new(1 / count, -12 * (count - 1) / count, 1, 0),
			BackgroundColor3 = COLORS.card,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			LayoutOrder = index,
		}, holder)
		corner(card, 16)
		stroke(card, 0.88)

		label(card, spec.Title, 12, COLORS.muted, BODY, { Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 16) })
		local value = label(card, "", 30, COLORS.text, SERIF, { Position = UDim2.fromOffset(14, 26), Size = UDim2.new(0.6, 0, 0, 34) })
		local sub = label(card, "", 11, COLORS.accent2, BODY, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 38), Size = UDim2.new(0.4, 0, 0, 14), TextXAlignment = Enum.TextXAlignment.Right })

		local bar = create("Frame", { Position = UDim2.new(0, 14, 1, -22), Size = UDim2.new(1, -28, 0, 10), BackgroundTransparency = 1 }, card)
		create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, bar)
		local segments = {}
		for segment = 1, SEGMENTS do
			segments[segment] = create("Frame", { Size = UDim2.new(1 / SEGMENTS, -2 * (SEGMENTS - 1) / SEGMENTS, 1, 0), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.88, BorderSizePixel = 0, LayoutOrder = segment }, bar)
			corner(segments[segment], 2)
		end

		table.insert(active.statCards, { spec = spec, value = value, sub = sub, segments = segments, shown = -1 })
	end
end

-- Window -----------------------------------------------------------------------------------------------------

local Window = {}
Window.__index = Window

---@param name string
function Window:CreateCategory(name)
	self.order = self.order + 1
	label(self.tabList, string.upper(name), 10, COLORS.muted, BOLD, {
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = self.order,
		TextTransparency = 0.2,
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
		tween(previous.title, 0.25, { TextColor3 = COLORS.muted })
		tween(previous.glyph, 0.25, { ImageColor3 = COLORS.muted })
		task.delay(0.2, function()
			if window.current ~= previous and previous.group.Parent then previous.group.Visible = false end
		end)
	end

	tab.group.Visible = true
	tab.group.GroupTransparency = 1
	tab.group.Position = UDim2.fromOffset(0, 14)
	tab.scale.Scale = 0.98
	tween(tab.group, 0.45, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) })
	tween(tab.scale, 0.45, { Scale = 1 })
	tween(tab.hl, 0.3, { BackgroundTransparency = 0.86 })
	tween(tab.title, 0.25, { TextColor3 = COLORS.text })
	tween(tab.glyph, 0.25, { ImageColor3 = COLORS.text })

	window.pageTitle.Text = tab.name
	window.pageSub.Text = tab.subtitle or ""
end

---@param window table
---@param name string
---@param iconName string?
---@param listParent Instance
---@param order number
---@return table
local function makeTab(window, name, iconName, listParent, order)
	local tab = setmetatable({ name = name, window = window, order = 0, enabled = 0, heights = { 0, 0 }, column = 1 }, Tab)

	local button = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, LayoutOrder = order }, listParent)
	tab.hl = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.row, BackgroundTransparency = 1, BorderSizePixel = 0 }, button)
	corner(tab.hl, 10)
	tab.glyph = create("ImageLabel", { Image = icon(iconName), ImageColor3 = COLORS.muted, BackgroundTransparency = 1, Size = UDim2.fromOffset(18, 18), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0) }, button)
	tab.title = label(button, name, 13, COLORS.muted, BODY, { Position = UDim2.fromOffset(40, 0), Size = UDim2.new(1, -76, 1, 0) })

	-- Count of switched-on toggles, shown as a blue badge like the inbox badge in the reel.
	local badge = create("TextLabel", { Text = "0", Font = BOLD, TextSize = 10, TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0, Visible = false, Size = UDim2.fromOffset(20, 16), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0) }, button)
	corner(badge, 8)
	tab.refreshBadge = function()
		badge.Visible = tab.enabled > 0
		badge.Text = tostring(tab.enabled)
	end

	tab.group = create("CanvasGroup", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1, Visible = false }, window.pages)
	tab.scale = create("UIScale", { Scale = 0.98 }, tab.group)
	tab.list = create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = COLORS.muted,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, tab.group)
	create("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, tab.list)
	create("UIPadding", { PaddingBottom = UDim.new(0, 10), PaddingRight = UDim.new(0, 8) }, tab.list)

	-- Two columns of cards under any stat row.
	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 1 }, tab.list)
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
	tab.columns = {}
	for index = 1, 2 do
		tab.columns[index] = create("Frame", { Size = UDim2.new(0.5, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = index }, holder)
		create("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, tab.columns[index])
	end

	track(button.MouseEnter:Connect(function()
		if window.current ~= tab then tween(tab.hl, 0.2, { BackgroundTransparency = 0.94 }) end
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

---@param opts table
function Window:Notify(opts)
	local duration = opts.Duration or 4

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, active.toastHost)
	local card = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(320, 0), BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0.12, BorderSizePixel = 0, ClipsDescendants = true }, holder)
	corner(card, 14)
	stroke(card, 0.8)

	local inner = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, card)
	create("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 14) }, inner)
	create("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, inner)

	local accent = create("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0 }, card)
	gradient(accent, COLORS.accent2, COLORS.accent, 90)

	label(inner, tostring(opts.Title or ""), 14, COLORS.text, BOLD, { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 18) })
	label(inner, tostring(opts.Text or ""), 12, COLORS.muted, BODY, { LayoutOrder = 2, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })

	local timer = create("Frame", { Size = UDim2.new(1, 0, 0, 3), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 5 }, card)
	gradient(timer, COLORS.accent, COLORS.accent2, 0)

	tween(card, 0.5, { Position = UDim2.fromOffset(0, 0) }, BACK)
	tween(timer, duration, { Size = UDim2.new(0, 0, 0, 3) }, Enum.EasingStyle.Linear)

	task.delay(duration, function()
		if not holder.Parent then return end

		tween(card, 0.35, { Position = UDim2.fromOffset(320, 0) }, QUINT, IN)
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
		BackgroundColor3 = isBars and Color3.fromRGB(96, 124, 224) or COLORS.bg,
		BackgroundTransparency = isBars and 0.08 or 0.3,
		BorderSizePixel = 0,
		LayoutOrder = #active.widgets + 1,
		ClipsDescendants = true,
	}, active.widgetHost)
	corner(card, 18)
	stroke(card, isBars and 0.6 or 0.85)
	if isBars then gradient(card, Color3.fromRGB(124, 154, 250), Color3.fromRGB(58, 80, 168), 90) end

	local glyph = create("ImageLabel", { Image = icon(spec.Icon), ImageColor3 = COLORS.text, ImageTransparency = 0.2, BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(14, 13) }, card)
	label(card, spec.Title, 12, COLORS.text, BODY, { Position = UDim2.fromOffset(spec.Icon and 34 or 14, 10), Size = UDim2.new(1, -48, 0, 20), TextTransparency = 0.15 })
	local value = label(card, "", 30, COLORS.text, SERIF, { Position = UDim2.fromOffset(14, 32), Size = UDim2.new(1, -28, 0, 34) })
	local sub = label(card, "", 11, COLORS.accent2, BODY, { Position = UDim2.fromOffset(14, 66), Size = UDim2.new(1, -28, 0, 14) })
	if isBars then sub.TextColor3 = Color3.fromRGB(214, 226, 255) end
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
	local blurWanted = V18UI.Flags.ui_blur == nil or V18UI.Flags.ui_blur.Value == true

	if state then
		active.root.Visible = true
		active.pop.Scale = 0.92
		tween(active.pop, 0.55, { Scale = 1 }, BACK)
		active.cover.BackgroundTransparency = 0.2
		tween(active.cover, 0.45, { BackgroundTransparency = 1 })
		if blurWanted then tween(active.blur, 0.6, { Size = 16 }) end
	else
		tween(active.pop, 0.28, { Scale = 0.94 }, QUINT, IN)
		tween(active.cover, 0.25, { BackgroundTransparency = 0.2 })
		tween(active.blur, 0.3, { Size = 0 })
		task.delay(0.3, function()
			if active and not active.visible and active.root.Parent then active.root.Visible = false end
		end)
	end
end

-- Short intro: dim, serif title blooms over a drawn line, then the window opens.
---@param window table
---@param opts table
local function playIntro(window, opts)
	local owner = active
	local introGui = create("ScreenGui", { Name = INTRO_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1001, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, getGuiParent())
	owner.introGui = introGui

	local dim = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(12, 9, 8), BackgroundTransparency = 1, BorderSizePixel = 0 }, introGui)
	local title = create("TextLabel", { Text = tostring(opts.Title or "V18"), Font = SERIF, TextSize = 64, TextColor3 = COLORS.text, TextTransparency = 1, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.47), Size = UDim2.fromOffset(600, 80) }, introGui)
	local line = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.54), Size = UDim2.fromOffset(0, 2), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, introGui)
	gradient(line, COLORS.accent, COLORS.accent2, 0)
	local sub = create("TextLabel", { Text = tostring(opts.Subtitle or ""), Font = BODY, TextSize = 14, TextColor3 = COLORS.muted, TextTransparency = 1, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.58), Size = UDim2.fromOffset(600, 20) }, introGui)

	local skipped = false
	table.insert(owner.connections, userInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.Space then skipped = true end
	end))

	local function pause(seconds)
		local deadline = os.clock() + seconds
		while os.clock() < deadline and not skipped and active == owner do
			task.wait(0.02)
		end
	end

	task.spawn(function()
		tween(dim, 0.4, { BackgroundTransparency = 0.35 })
		tween(title, 0.7, { TextTransparency = 0 })
		tween(line, 0.9, { Size = UDim2.fromOffset(320, 2) }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		tween(sub, 0.7, { TextTransparency = 0.1 })
		pause(1.5)
		if active ~= owner then return end

		tween(dim, 0.45, { BackgroundTransparency = 1 })
		tween(title, 0.35, { TextTransparency = 1 })
		tween(sub, 0.35, { TextTransparency = 1 })
		tween(line, 0.35, { Size = UDim2.fromOffset(0, 2) })
		window:Toggle(true)
		task.delay(0.55, function()
			if introGui.Parent then introGui:Destroy() end
		end)
	end)

	-- Watchdog: the window always opens, even if the intro thread dies.
	task.delay(6, function()
		if active == owner and not owner.visible then
			window:Toggle(true)
			if introGui.Parent then introGui:Destroy() end
		end
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
		for flag, entry in V18UI.Flags do
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
			local entry = V18UI.Flags[flag]
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

---@param opts table
---@return table
function V18UI:CreateWindow(opts)
	opts = opts or {}

	if shared.__V18UI then pcall(function() shared.__V18UI:Destroy() end) end
	sweepPrevious()
	shared.__V18UI = V18UI

	local window = setmetatable({ tabs = {}, order = 0, toggleKey = opts.ToggleKey or Enum.KeyCode.RightShift }, Window)
	active = { connections = {}, visible = false, capturing = false, onDestroy = opts.OnDestroy, widgets = {}, statCards = {}, listed = {} }

	local showWidgets = opts.Widgets ~= false

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

	-- Main glass panel.
	local main = create("Frame", { Name = "Main", Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT), BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0.2, BorderSizePixel = 0, ClipsDescendants = true }, body)
	corner(main, 24)
	stroke(main, 0.78, 1.4)
	local sheen = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Active = false }, main)
	create("UIGradient", { Rotation = 35, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(0.5, 0.97), NumberSequenceKeypoint.new(1, 0.99) }) }, sheen)

	-- Sidebar with the workspace profile.
	local sidebar = create("Frame", { Position = UDim2.fromOffset(14, 14), Size = UDim2.new(0, SIDEBAR_WIDTH, 1, -28), BackgroundColor3 = COLORS.sidebar, BackgroundTransparency = 0.45, BorderSizePixel = 0 }, main)
	corner(sidebar, 18)
	stroke(sidebar, 0.9)

	local avatar = create("ImageLabel", { Position = UDim2.fromOffset(14, 14), Size = UDim2.fromOffset(38, 38), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.85, Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", localPlayer.UserId), BorderSizePixel = 0 }, sidebar)
	corner(avatar, 19)
	label(sidebar, string.format("%s's Workspace", localPlayer.DisplayName), 12, COLORS.text, BOLD, { Position = UDim2.fromOffset(60, 14), Size = UDim2.new(1, -70, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd })
	label(sidebar, tostring(opts.Subtitle or "Workspace"), 11, COLORS.muted, BODY, { Position = UDim2.fromOffset(60, 33), Size = UDim2.new(1, -70, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })

	window.tabList = create("ScrollingFrame", { Position = UDim2.fromOffset(8, 66), Size = UDim2.new(1, -16, 1, -132), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 0, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new() }, sidebar)
	create("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, window.tabList)

	local footer = create("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 8, 1, -10), Size = UDim2.new(1, -16, 0, 40), BackgroundTransparency = 1 }, sidebar)
	create("UIListLayout", { VerticalAlignment = Enum.VerticalAlignment.Bottom }, footer)

	-- Header: serif page title, subtitle, key hint, close.
	local header = create("Frame", { Position = UDim2.fromOffset(SIDEBAR_WIDTH + 36, 14), Size = UDim2.new(1, -(SIDEBAR_WIDTH + 54), 0, 64), BackgroundTransparency = 1, Active = true }, main)
	window.pageTitle = label(header, "", 32, COLORS.text, SERIF, { Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, -180, 0, 36) })
	window.pageSub = label(header, "", 12, COLORS.muted, BODY, { Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, -180, 0, 16) })

	local close = create("TextButton", { Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 8), Size = UDim2.fromOffset(30, 30), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.9, BorderSizePixel = 0 }, header)
	corner(close, 15)
	stroke(close, 0.85)
	for _, rotation in { 45, -45 } do
		create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(12, 2), Rotation = rotation, BorderSizePixel = 0, BackgroundColor3 = COLORS.text }, close)
	end
	track(close.MouseEnter:Connect(function()
		tween(close, 0.2, { BackgroundColor3 = COLORS.bad, BackgroundTransparency = 0.3 })
	end))
	track(close.MouseLeave:Connect(function()
		tween(close, 0.25, { BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.9 })
	end))
	track(close.Activated:Connect(function()
		window:Toggle(false)
	end))

	local hint = create("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -40, 0, 8), Size = UDim2.fromOffset(128, 30), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.9, BorderSizePixel = 0 }, header)
	corner(hint, 15)
	stroke(hint, 0.85)
	create("ImageLabel", { Image = icon("search"), ImageColor3 = COLORS.muted, BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(10, 8) }, hint)
	window.keyHint = label(hint, window.toggleKey.Name, 11, COLORS.muted, BODY, { Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -36, 1, 0) })

	-- Pages.
	window.pages = create("Frame", { Position = UDim2.fromOffset(SIDEBAR_WIDTH + 36, 86), Size = UDim2.new(1, -(SIDEBAR_WIDTH + 54), 1, -100), BackgroundTransparency = 1, ClipsDescendants = true }, main)

	-- Cover used for the open/close fade.
	active.cover = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.bg, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 30, Active = false }, main)
	corner(active.cover, 24)

	-- Floating widgets beside the window.
	active.widgetHost = create("Frame", { Position = UDim2.fromOffset(WINDOW_WIDTH + WIDGET_GAP, 0), Size = UDim2.fromOffset(WIDGET_WIDTH, WINDOW_HEIGHT), BackgroundTransparency = 1, Visible = showWidgets }, body)
	create("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, active.widgetHost)

	-- Toasts live on their own host so they survive the window being hidden.
	active.toastHost = create("Frame", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -20, 1, -20), Size = UDim2.fromOffset(300, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, gui)
	create("UIListLayout", { Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, active.toastHost)

	-- Keybind list: a small draggable glass panel that stays on screen while the menu is closed. It lists every enabled
	-- feature with its key (and the disabled ones too when "List disabled features too" is on).
	local listFrame = create("Frame", { Position = UDim2.new(0, 24, 0.38, 0), Size = UDim2.fromOffset(212, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = COLORS.bg, BackgroundTransparency = 0.2, BorderSizePixel = 0, Visible = false, Active = true }, gui)
	corner(listFrame, 16)
	stroke(listFrame, 0.82)
	create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10) }, listFrame)
	create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, listFrame)
	local listTitle = label(listFrame, "Keybinds", 16, COLORS.text, SERIF, { Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 0 })
	local listRows = {}

	active.refreshKeyList = function()
		for _, item in listRows do
			item:Destroy()
		end
		table.clear(listRows)

		local showAll = V18UI.Flags.ui_keylistAll ~= nil and V18UI.Flags.ui_keylistAll.Value == true
		local shown = 0
		for index, info in active.listed do
			local on = info.isOn()
			if not on and not showAll then continue end

			shown += 1
			local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = index }, listFrame)
			local dot = create("Frame", { Size = UDim2.fromOffset(6, 6), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = on and COLORS.good or COLORS.muted, BackgroundTransparency = on and 0 or 0.5, BorderSizePixel = 0 }, holder)
			corner(dot, 3)
			label(holder, info.text, 12, on and COLORS.text or COLORS.muted, BODY, { Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -66, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
			label(holder, keyLabel(info.key()), 11, COLORS.accent2, BOLD, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(50, 20), TextXAlignment = Enum.TextXAlignment.Right })
			table.insert(listRows, holder)
		end

		if shown == 0 then
			table.insert(listRows, label(listFrame, "Nothing enabled", 12, COLORS.muted, BODY, { Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 1 }))
		end
		listTitle.Text = showAll and "Keybinds" or string.format("Active  (%d)", shown)
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

	-- Live refresh: stat cards and widgets.
	local fps = 60
	local statClock = 0
	local widgetClock = 0
	track(runService.Heartbeat:Connect(function(deltaTime)
		fps = fps + ((1 / math.max(deltaTime, 1e-3)) - fps) * math.min(1, deltaTime * 4)
		if not active.visible then return end

		statClock = statClock + deltaTime
		if statClock >= 0.25 then
			statClock = 0
			for _, card in active.statCards do
				local ok, valueText, alpha, subText = pcall(card.spec.Get)
				if not ok then continue end

				card.value.Text = tostring(valueText or "")
				card.sub.Text = tostring(subText or "")
				local lit = math.floor(math.clamp(tonumber(alpha) or 0, 0, 1) * SEGMENTS + 0.5)
				if lit ~= card.shown then
					card.shown = lit
					for index, segment in card.segments do
						local on = index <= lit
						tween(segment, 0.25, { BackgroundColor3 = on and COLORS.accent or COLORS.row, BackgroundTransparency = on and 0.05 or 0.88 })
					end
				end
			end
		end

		widgetClock = widgetClock + deltaTime
		if widgetClock >= 0.5 then
			widgetClock = 0
			for _, widget in active.widgets do
				local ok, valueText, number, subText = pcall(widget.spec.Get)
				if not ok then continue end

				widget.value.Text = tostring(valueText or "")
				widget.sub.Text = tostring(subText or "")

				if widget.kind == "bars" then
					table.remove(widget.history, 1)
					table.insert(widget.history, tonumber(number) or 0)
					local peak = 1
					for _, sample in widget.history do
						peak = math.max(peak, sample)
					end
					for index, bar in widget.bars do
						local last = index == #widget.bars
						tween(bar, 0.45, { Size = UDim2.new(bar.Size.X.Scale, bar.Size.X.Offset, 0, 6 + math.floor(widget.history[index] / peak * 70)), BackgroundTransparency = last and 0 or 0.35 })
					end
				else
					local lit = math.floor(math.clamp(tonumber(number) or 0, 0, 1) * SEGMENTS + 0.5)
					for index, segment in widget.segments do
						local on = index <= lit
						tween(segment, 0.3, { BackgroundColor3 = on and COLORS.accent2 or COLORS.row, BackgroundTransparency = on and 0.1 or 0.88 })
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
				window.keyHint.Text = key.Name
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
		Default = true,
		Flag = "ui_blur",
		Callback = function(on)
			if active.visible then tween(active.blur, 0.4, { Size = on and 16 or 0 }) end
		end,
	})
	settings:AddToggle({
		Text = "Widgets",
		NoList = true,
		Bind = false,
		Default = showWidgets,
		Flag = "ui_widgets",
		Callback = function(on)
			active.widgetHost.Visible = on
		end,
	})
	settings:AddSection("Session")
	settings:AddButton({
		Text = "Unload Script",
		Callback = function()
			task.defer(function()
				V18UI:Destroy()
			end)
		end,
	})
	buildConfigs(window, settings, (string.gsub(tostring(opts.Title or "V18UI"), "%s+", "")))

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

	if opts.Intro == false then
		task.defer(function()
			window:Toggle(true)
		end)
	else
		playIntro(window, opts)
	end

	return window
end

function V18UI:Destroy()
	local owner = active
	if not owner then return end

	active = nil
	for _, connection in owner.connections do
		pcall(function() connection:Disconnect() end)
	end

	for _, instance in { owner.gui, owner.introGui, owner.blur } do
		if instance then pcall(function() instance:Destroy() end) end
	end

	table.clear(V18UI.Flags)
	if shared.__V18UI == V18UI then shared.__V18UI = nil end

	-- Lets the script that owns the window unload itself when the user presses Unload Script.
	if owner.onDestroy then safeCall(owner.onDestroy) end
end

return V18UI
