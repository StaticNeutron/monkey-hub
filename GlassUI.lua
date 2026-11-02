-- GlassUI: "Glass Aurora" executor UI library.
-- Style taken from three UI-design reels (VidHelper): frosted translucent panels, a glowing animated border,
-- an equalizer-bar beat pulse with one highlighted bar, a stepper-line intro, blur-style tab transitions
-- and a dark/light theme sweep. Same API shape as ui.lua: CreateWindow -> CreateCategory/CreateTab -> Add*.
--
--   local UI = loadstring(readfile("glassui.lua"))()
--   local window = UI:CreateWindow({ Title = "My Hub", Subtitle = "game", ToggleKey = Enum.KeyCode.RightShift })
--   local tab = window:CreateTab("Combat")
--   tab:AddToggle({ Text = "Auto fight", Flag = "autoFight", Callback = function(on) end })
--   UI.Flags.autoFight.Value, UI:Destroy()

local GlassUI = {}
GlassUI.Flags = {}

-- Constants.
local GUI_NAME = "GlassUI"
local INTRO_NAME = "GlassUI_Intro"
local BLUR_NAME = "GlassUI_Blur"
local WINDOW_WIDTH = 700
local WINDOW_HEIGHT = 440
local BAR_COUNT = 9
-- Seconds per beat (about 100 BPM). [inferred from the clips' cut rhythm]
local BEAT = 0.6
local QUINT = Enum.EasingStyle.Quint
local BACK = Enum.EasingStyle.Back
local OUT = Enum.EasingDirection.Out
local IN = Enum.EasingDirection.In

-- Fixed brand colors (the same in both themes).
local BRAND = {
	teal = Color3.fromRGB(53, 214, 197),
	periwinkle = Color3.fromRGB(111, 141, 255),
	amber = Color3.fromRGB(255, 179, 107),
}

-- Per-theme tokens. Dark is sampled from the teal/bronze glass reels, light from the aqua sweep.
local THEMES = {
	dark = {
		bg = Color3.fromRGB(8, 22, 26),
		panel = Color3.fromRGB(16, 38, 42),
		raised = Color3.fromRGB(30, 62, 66),
		track = Color3.fromRGB(6, 18, 21),
		stroke = Color3.fromRGB(190, 240, 235),
		text = Color3.fromRGB(234, 244, 243),
		muted = Color3.fromRGB(143, 172, 173),
		accent = BRAND.teal,
		accent2 = BRAND.periwinkle,
	},
	-- Deliberately mid-toned: pale tokens wash out to white under a bright game color grade.
	light = {
		bg = Color3.fromRGB(150, 194, 200),
		panel = Color3.fromRGB(178, 212, 217),
		raised = Color3.fromRGB(214, 238, 241),
		track = Color3.fromRGB(104, 150, 158),
		stroke = Color3.fromRGB(10, 70, 78),
		text = Color3.fromRGB(4, 22, 26),
		muted = Color3.fromRGB(26, 62, 70),
		accent = Color3.fromRGB(0, 120, 112),
		accent2 = Color3.fromRGB(52, 78, 205),
	},
}

-- Services.
local playersService = game:GetService("Players")
local runService = game:GetService("RunService")
local tweenService = game:GetService("TweenService")
local userInputService = game:GetService("UserInputService")
local lightingService = game:GetService("Lighting")
local coreGuiService = game:GetService("CoreGui")

-- State. One window at a time; everything it owns is reachable from `active` so Destroy leaves nothing behind.
local active = nil
local guiParent = nil

-- Resolved once from the executor thread: gethui() can throw from engine-created threads.
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
	if hasCore then
		guiParent = coreGuiService
		return guiParent
	end

	guiParent = playersService.LocalPlayer:WaitForChild("PlayerGui")
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

-- Binds a property to a theme token so the theme sweep can retarget it.
---@param inst Instance
---@param prop string
---@param token string
local function bind(inst, prop, token)
	table.insert(active.themed, { inst = inst, prop = prop, token = token })
	inst[prop] = active.theme[token]
end

---@param name string
local function applyTheme(name)
	active.themeName = name
	active.theme = THEMES[name]

	for index = #active.themed, 1, -1 do
		local entry = active.themed[index]
		if not entry.inst:IsDescendantOf(active.gui) then
			table.remove(active.themed, index)
		else
			tween(entry.inst, 0.55, { [entry.prop] = active.theme[entry.token] })
		end
	end

	-- The selected tab's title is bound to "muted" but displays as "text"; keep it that way.
	local current = active.window and active.window.current
	if current then tween(current.title, 0.55, { TextColor3 = active.theme.text }) end
end

---@param inst Instance
---@param radius number
local function corner(inst, radius)
	create("UICorner", { CornerRadius = UDim.new(0, radius) }, inst)
end

---@param inst Instance
---@param token string
---@param thickness number
---@param transparency number
---@return UIStroke
local function stroke(inst, token, thickness, transparency)
	local line = create("UIStroke", {
		Thickness = thickness,
		Transparency = transparency,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
	bind(line, "Color", token)
	return line
end

---@param parent Instance
---@param content string
---@param size number
---@param token string
---@param font Enum.Font?
---@param props table?
---@return TextLabel
local function text(parent, content, size, token, font, props)
	local label = create("TextLabel", {
		BackgroundTransparency = 1,
		Text = content,
		TextSize = size,
		Font = font or Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, size + 4),
	}, parent)
	if props then
		for key, value in props do
			label[key] = value
		end
	end
	bind(label, "TextColor3", token)
	return label
end

---@param inst Instance
---@param colors table
---@param rotation number?
---@return UIGradient
local function gradient(inst, colors, rotation)
	local keypoints = {}
	for index, color in colors do
		table.insert(keypoints, ColorSequenceKeypoint.new((index - 1) / (#colors - 1), color))
	end

	return create("UIGradient", { Color = ColorSequence.new(keypoints), Rotation = rotation or 0 }, inst)
end

-- Walks the brand palette as a loop; used to shimmer the title without sliding a gradient off the text.
-- The light theme shimmers through darker versions of the brand colors so the title stays readable on pale glass.
local CYCLE = {
	dark = { BRAND.teal, BRAND.periwinkle, BRAND.amber },
	light = { Color3.fromRGB(0, 120, 112), Color3.fromRGB(52, 78, 205), Color3.fromRGB(176, 92, 16) },
}

---@param phase number
---@param palette table
---@return Color3
local function cycleColor(phase, palette)
	local scaled = (phase % 1) * #palette
	local index = math.floor(scaled)
	return palette[index % #palette + 1]:Lerp(palette[(index + 1) % #palette + 1], scaled - index)
end

---@param callback function?
---@param ... any
local function safeCall(callback, ...)
	if not callback then return end

	local success, err = pcall(callback, ...)
	if not success then warn("[GlassUI] callback error: " .. tostring(err)) end
end

---@param value number
---@return string
local function formatNumber(value)
	local formatted = string.format("%.2f", value)
	formatted = formatted:gsub("0+$", "")
	formatted = formatted:gsub("%.$", "")
	return formatted
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

-- Shared row look: translucent raised glass, hairline stroke, hover lift, click squish.
---@param tab table
---@param height number
---@param clickable boolean
---@param rest number? background transparency at rest (default 0.55)
---@param hover number? background transparency on hover (default 0.38)
---@return Instance, UIStroke, UIScale
local function newRow(tab, height, clickable, rest, hover)
	tab.order = tab.order + 1
	rest = rest or 0.55
	hover = hover or 0.38

	local props = {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = rest,
		BorderSizePixel = 0,
		LayoutOrder = tab.order,
	}
	if clickable then
		props.Text = ""
		props.AutoButtonColor = false
	end

	local row = create(clickable and "TextButton" or "Frame", props, tab.list)
	bind(row, "BackgroundColor3", "raised")
	corner(row, 10)
	local line = stroke(row, "stroke", 1, 0.8)
	local scale = create("UIScale", { Scale = 1 }, row)

	track(row.MouseEnter:Connect(function()
		tween(row, 0.2, { BackgroundTransparency = hover })
		tween(line, 0.2, { Transparency = 0.5 })
	end))
	track(row.MouseLeave:Connect(function()
		tween(row, 0.25, { BackgroundTransparency = rest })
		tween(line, 0.25, { Transparency = 0.8 })
	end))

	return row, line, scale
end

---@param scale UIScale
local function squish(scale)
	scale.Scale = 0.97
	tween(scale, 0.35, { Scale = 1 }, BACK)
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
		GlassUI.Flags[opts.Flag or (tab.name .. "_" .. tostring(opts.Text))] = entry
	end

	return entry
end

-- Tab components -------------------------------------------------------------------------------------------

local Tab = {}
Tab.__index = Tab

---@param content string
function Tab:AddSection(content)
	self.order = self.order + 1

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = self.order }, self.list)
	local dot = create("Frame", { Size = UDim2.fromOffset(6, 6), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 2, 0.5, 0), BorderSizePixel = 0 }, holder)
	corner(dot, 3)
	gradient(dot, { BRAND.teal, BRAND.periwinkle }, 45)
	text(holder, string.upper(content), 12, "muted", Enum.Font.GothamBold, {
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -16, 1, 0),
	})
end

---@param content string
---@return table
function Tab:AddLabel(content)
	self.order = self.order + 1

	local label = text(self.list, content, 13, "muted", Enum.Font.GothamMedium, {
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -4, 0, 0),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = self.order,
	})
	create("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2) }, label)

	return {
		SetText = function(_, value)
			label.Text = value
		end,
	}
end

---@param opts table
function Tab:AddButton(opts)
	local row, _, scale = newRow(self, 38, true, 0.15, 0.02)

	-- The gradient button keeps its own fill and a dark label in both themes, so it leaves the theme sweep.
	for index = #active.themed, 1, -1 do
		local entry = active.themed[index]
		if entry.inst == row and entry.prop == "BackgroundColor3" then table.remove(active.themed, index) end
	end
	row.BackgroundColor3 = Color3.new(1, 1, 1)
	gradient(row, { BRAND.teal, BRAND.periwinkle }, 0)
	create("TextLabel", {
		Text = opts.Text,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(6, 20, 24),
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	}, row)

	track(row.Activated:Connect(function()
		squish(scale)
		safeCall(opts.Callback)
	end))
end

---@param opts table
---@return table
function Tab:AddToggle(opts)
	local value = false
	local row, _, scale = newRow(self, 40, true)
	text(row, opts.Text, 14, "text", Enum.Font.GothamMedium, {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -80, 1, 0),
	})

	local track_ = create("Frame", { Size = UDim2.fromOffset(44, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), BorderSizePixel = 0 }, row)
	bind(track_, "BackgroundColor3", "track")
	corner(track_, 11)
	stroke(track_, "stroke", 1, 0.8)
	local fill = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0 }, track_)
	corner(fill, 11)
	gradient(fill, { BRAND.teal, BRAND.periwinkle }, 0)
	local knob = create("Frame", { Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, track_)
	corner(knob, 8)

	local entry
	local function apply(incoming, silent)
		value = incoming == true
		entry.Value = value
		tween(fill, 0.3, { BackgroundTransparency = value and 0 or 1 })
		tween(knob, 0.4, { Position = UDim2.new(0, value and 25 or 3, 0.5, 0) }, BACK)
		if not silent then safeCall(opts.Callback, value) end
	end

	entry = registerFlag(self, opts, "Toggle", apply)
	apply(opts.Default == true, true)

	track(row.Activated:Connect(function()
		squish(scale)
		apply(not value, false)
	end))

	return entry
end

---@param opts table
---@return table
function Tab:AddSlider(opts)
	local minimum = opts.Min or 0
	local maximum = opts.Max or 100
	local increment = opts.Increment or 1

	local row = newRow(self, 56, false)
	text(row, opts.Text, 14, "text", Enum.Font.GothamMedium, {
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(1, -90, 0, 20),
	})
	local readout = text(row, "", 13, "accent", Enum.Font.GothamBold, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 6),
		Size = UDim2.fromOffset(70, 20),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local rail = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, -28, 0, 8), Position = UDim2.new(0, 14, 0, 36), BorderSizePixel = 0 }, row)
	bind(rail, "BackgroundColor3", "track")
	corner(rail, 4)
	local fill = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, rail)
	corner(fill, 4)
	gradient(fill, { BRAND.teal, BRAND.periwinkle }, 0)
	local knob = create("Frame", { Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3 }, rail)
	corner(knob, 8)
	create("UIStroke", { Color = BRAND.teal, Thickness = 2, Transparency = 0.2 }, knob)

	local entry
	local function apply(incoming, silent)
		local snapped = math.floor((math.clamp(tonumber(incoming) or minimum, minimum, maximum) - minimum) / increment + 0.5) * increment + minimum
		snapped = math.clamp(snapped, minimum, maximum)
		entry.Value = snapped

		local alpha = (maximum - minimum) == 0 and 0 or (snapped - minimum) / (maximum - minimum)
		tween(fill, 0.12, { Size = UDim2.fromScale(alpha, 1) })
		tween(knob, 0.12, { Position = UDim2.fromScale(alpha, 0.5) })
		readout.Text = formatNumber(snapped)
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
			tween(knob, 0.2, { Size = UDim2.fromOffset(20, 20) }, BACK)
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
			tween(knob, 0.25, { Size = UDim2.fromOffset(16, 16) }, BACK)
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

	local row = newRow(self, 40, false)
	row.ClipsDescendants = true

	local header = create("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40) }, row)
	text(header, opts.Text, 14, "text", Enum.Font.GothamMedium, {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -160, 1, 0),
	})
	local readout = text(header, "", 13, "accent", Enum.Font.GothamBold, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -38, 0, 0),
		Size = UDim2.fromOffset(130, 40),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	-- Gotham has no arrow glyph, so the chevron is two rotated bars.
	local chevron = create("Frame", { Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), BackgroundTransparency = 1 }, header)
	for _, arm in { { x = 4.5, rotation = 45 }, { x = 9.5, rotation = -45 } } do
		local bar = create("Frame", { Size = UDim2.fromOffset(8, 2), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(arm.x, 7), Rotation = arm.rotation, BorderSizePixel = 0 }, chevron)
		bind(bar, "BackgroundColor3", "muted")
	end

	local list = create("Frame", { Size = UDim2.new(1, -16, 0, 0), Position = UDim2.fromOffset(8, 42), BackgroundTransparency = 1 }, row)
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	local entry
	local buttons = {}

	local function paint()
		for name, button in buttons do
			local selected = name == value
			tween(button, 0.2, { TextTransparency = 0, BackgroundTransparency = selected and 0.7 or 1 })
			button.Font = selected and Enum.Font.GothamBold or Enum.Font.GothamMedium
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
		tween(row, 0.4, { Size = UDim2.new(1, 0, 0, open and (40 + #options * 32 + 8) or 40) }, QUINT)
		tween(chevron, 0.35, { Rotation = open and 180 or 0 }, BACK)
	end

	local function build()
		for _, button in buttons do
			button:Destroy()
		end
		table.clear(buttons)

		for index, name in options do
			local button = create("TextButton", {
				Text = tostring(name),
				Font = Enum.Font.GothamMedium,
				TextSize = 13,
				AutoButtonColor = false,
				Size = UDim2.new(1, 0, 0, 30),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				LayoutOrder = index,
			}, list)
			bind(button, "TextColor3", "text")
			bind(button, "BackgroundColor3", "accent")
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
	local row = newRow(self, 40, false)
	text(row, opts.Text, 14, "text", Enum.Font.GothamMedium, {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -120, 1, 0),
	})

	local pill = create("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		Size = UDim2.fromOffset(88, 24),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		BorderSizePixel = 0,
	}, row)
	bind(pill, "BackgroundColor3", "track")
	bind(pill, "TextColor3", "accent")
	corner(pill, 12)
	stroke(pill, "stroke", 1, 0.75)

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
		tween(pill, 0.2, { Size = UDim2.fromOffset(96, 26) }, BACK)

		local connection
		connection = userInputService.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

			connection:Disconnect()
			active.capturing = false
			tween(pill, 0.25, { Size = UDim2.fromOffset(88, 24) }, BACK)
			if input.KeyCode == Enum.KeyCode.Escape then
				apply(key, true)
				return
			end

			apply(input.KeyCode, false)
		end)
		track(connection)
	end))

	track(userInputService.InputBegan:Connect(function(input, processed)
		if processed or active.capturing or not key or input.KeyCode ~= key then return end

		safeCall(opts.Pressed)
	end))

	return entry
end

-- Window ----------------------------------------------------------------------------------------------------

local Window = {}
Window.__index = Window

---@param name string
function Window:CreateCategory(name)
	self.order = self.order + 1

	local header = create("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = self.order }, self.tabList)
	local dot = create("Frame", { Size = UDim2.fromOffset(5, 5), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 2), BorderSizePixel = 0 }, header)
	corner(dot, 3)
	gradient(dot, { BRAND.teal, BRAND.amber }, 45)
	text(header, string.upper(name), 11, "muted", Enum.Font.GothamBold, {
		Position = UDim2.fromOffset(20, 2),
		Size = UDim2.new(1, -20, 1, 0),
	})
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
		tween(previous.bar, 0.3, { Size = UDim2.fromOffset(3, 0) })
		tween(previous.title, 0.25, { TextColor3 = active.theme.muted })
		task.delay(0.2, function()
			if window.current ~= previous and previous.group.Parent then previous.group.Visible = false end
		end)
	end

	-- Blur-style cross-fade from the reels: fade up, 0.97 -> 1 scale, 14 px slide.
	tab.group.Visible = true
	tab.group.GroupTransparency = 1
	tab.group.Position = UDim2.fromOffset(0, 14)
	tab.scale.Scale = 0.97
	tween(tab.group, 0.45, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) })
	tween(tab.scale, 0.45, { Scale = 1 })
	tween(tab.hl, 0.3, { BackgroundTransparency = 0.78 })
	tween(tab.bar, 0.4, { Size = UDim2.fromOffset(3, 18) }, BACK)
	tween(tab.title, 0.25, { TextColor3 = active.theme.text })
end

---@param window table
---@param name string
---@param listParent Instance
---@param order number
---@return table
local function makeTab(window, name, listParent, order)
	local tab = setmetatable({ name = name, window = window, order = 0 }, Tab)

	local button = create("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, LayoutOrder = order }, listParent)
	tab.hl = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0 }, button)
	corner(tab.hl, 10)
	gradient(tab.hl, { BRAND.teal, BRAND.periwinkle }, 0)
	tab.bar = create("Frame", { Size = UDim2.fromOffset(3, 0), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), BackgroundColor3 = BRAND.teal, BorderSizePixel = 0 }, button)
	corner(tab.bar, 2)
	tab.title = text(button, name, 14, "muted", Enum.Font.GothamBold, {
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -20, 1, 0),
	})

	tab.group = create("CanvasGroup", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1, Visible = false }, window.pages)
	tab.scale = create("UIScale", { Scale = 0.97 }, tab.group)
	tab.list = create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = BRAND.teal,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, tab.group)
	create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, tab.list)
	create("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, tab.list)

	track(button.MouseEnter:Connect(function()
		if window.current ~= tab then tween(tab.hl, 0.2, { BackgroundTransparency = 0.92 }) end
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
---@return table
function Window:CreateTab(name)
	self.order = self.order + 1

	local tab = makeTab(self, name, self.tabList, self.order)
	if not self.current then selectTab(tab) end

	return tab
end

---@param opts table
function Window:Notify(opts)
	local theme = active.theme
	local duration = opts.Duration or 4

	local holder = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, active.toastHost)
	local card = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(320, 0),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = 0.02,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, holder)
	corner(card, 12)
	create("UIStroke", { Color = theme.stroke, Transparency = 0.8, Thickness = 1 }, card)

	-- Text lives in an inner frame so its layout does not move the timer line.
	local inner = create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, card)
	create("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 14) }, inner)
	create("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, inner)

	local accent = create("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = BRAND.teal, BorderSizePixel = 0 }, card)
	gradient(accent, { BRAND.teal, BRAND.periwinkle }, 90)

	create("TextLabel", { Text = tostring(opts.Title or ""), Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = theme.text, BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 1 }, inner)
	create("TextLabel", { Text = tostring(opts.Text or ""), Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = theme.muted, BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = 2 }, inner)

	-- Stepper-style timer line along the bottom edge.
	local timer = create("Frame", { Size = UDim2.new(1, 0, 0, 3), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 5 }, card)
	gradient(timer, { BRAND.teal, BRAND.periwinkle, BRAND.amber }, 0)

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

-- Opens or closes the window with a pop + fade, and the optional background blur.
---@param state boolean?
function Window:Toggle(state)
	if state == nil then state = not active.visible end
	if state == active.visible then return end

	active.visible = state
	local blurWanted = GlassUI.Flags.ui_blur == nil or GlassUI.Flags.ui_blur.Value == true

	if state then
		active.root.Visible = true
		active.pop.Scale = 0.9
		active.cover.BackgroundTransparency = 0
		tween(active.pop, 0.55, { Scale = 1 }, BACK)
		tween(active.cover, 0.45, { BackgroundTransparency = 1 })
		if blurWanted then tween(active.blur, 0.6, { Size = 12 }) end
	else
		tween(active.pop, 0.28, { Scale = 0.92 }, QUINT, IN)
		tween(active.cover, 0.25, { BackgroundTransparency = 0 })
		tween(active.blur, 0.3, { Size = 0 })
		task.delay(0.3, function()
			if not active.visible and active.root.Parent then active.root.Visible = false end
		end)
	end
end

-- Stepper-line intro: bars rise, the line draws and its nodes pop, title blooms, then the window opens.
---@param window table
---@param opts table
local function playIntro(window, opts)
	local owner = active
	local introGui = create("ScreenGui", { Name = INTRO_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1001, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, getGuiParent())
	owner.introGui = introGui

	local dim = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(2, 8, 10), BackgroundTransparency = 1, BorderSizePixel = 0 }, introGui)
	local card = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(420, 240), BackgroundTransparency = 1 }, introGui)
	local cardScale = create("UIScale", { Scale = 1.15 }, card)

	local barHolder = create("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(BAR_COUNT * 18, 72), BackgroundTransparency = 1 }, card)
	local bars = {}
	for index = 1, BAR_COUNT do
		local bar = create("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromOffset((index - 1) * 18, 72), Size = UDim2.fromOffset(12, 4), BackgroundColor3 = index == 5 and BRAND.periwinkle or BRAND.teal, BorderSizePixel = 0 }, barHolder)
		corner(bar, 6)
		bars[index] = bar
	end

	local title = create("TextLabel", { Text = tostring(opts.Title or "GlassUI"), Font = Enum.Font.GothamBold, TextSize = 40, TextColor3 = Color3.new(1, 1, 1), TextTransparency = 1, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 92), Size = UDim2.fromOffset(420, 50) }, card)
	gradient(title, { BRAND.teal, BRAND.periwinkle, BRAND.amber }, 0)

	local line = create("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 170), Size = UDim2.fromOffset(300, 2), BackgroundTransparency = 1 }, card)
	local drawn = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, line)
	gradient(drawn, { BRAND.teal, BRAND.periwinkle }, 0)
	local nodes = {}
	for index = 1, 3 do
		local node = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new((index - 1) / 2, 0, 0.5, 0), Size = UDim2.fromOffset(0, 0), BackgroundColor3 = index == 3 and BRAND.amber or BRAND.teal, BorderSizePixel = 0 }, line)
		corner(node, 8)
		nodes[index] = node
	end

	local sub = create("TextLabel", { Text = tostring(opts.Subtitle or ""), Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = Color3.fromRGB(143, 172, 173), TextTransparency = 1, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 192), Size = UDim2.fromOffset(420, 20) }, card)

	local skipped = false
	local skipConnection = userInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.Space then skipped = true end
	end)
	table.insert(owner.connections, skipConnection)

	local function pause(seconds)
		local deadline = os.clock() + seconds
		while os.clock() < deadline and not skipped and active == owner do
			task.wait(0.02)
		end
	end

	local function finish()
		if active ~= owner then return end

		tween(card, 0.4, { Position = UDim2.fromScale(0.5, 0.46) })
		tween(cardScale, 0.4, { Scale = 0.9 })
		tween(dim, 0.45, { BackgroundTransparency = 1 })
		tween(title, 0.35, { TextTransparency = 1 })
		tween(sub, 0.35, { TextTransparency = 1 })
		for _, bar in bars do
			tween(bar, 0.3, { BackgroundTransparency = 1 })
		end
		for _, node in nodes do
			tween(node, 0.3, { BackgroundTransparency = 1 })
		end
		tween(drawn, 0.3, { BackgroundTransparency = 1 })

		window:Toggle(true)
		task.delay(0.55, function()
			if introGui.Parent then introGui:Destroy() end
		end)
	end

	task.spawn(function()
		tween(dim, 0.4, { BackgroundTransparency = 0.45 })
		tween(cardScale, 0.7, { Scale = 1 })
		tween(title, 0.6, { TextTransparency = 0 })

		-- Equalizer rise, one bar at a time.
		for index, bar in bars do
			tween(bar, 0.5, { Size = UDim2.fromOffset(12, 14 + ((index * 37) % 52)) }, BACK)
			task.wait(0.04)
		end

		-- Stepper line draws; each node pops as the line reaches it.
		tween(drawn, 0.9, { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		for index, node in nodes do
			task.delay((index - 1) * 0.45, function()
				tween(node, 0.4, { Size = UDim2.fromOffset(14, 14) }, BACK)
			end)
		end
		tween(sub, 0.6, { TextTransparency = 0 })

		pause(1.5)
		finish()
	end)

	-- Watchdog: the window always opens, even if the intro thread dies.
	task.delay(6, function()
		if active == owner and not owner.visible then
			window:Toggle(true)
			if introGui.Parent then introGui:Destroy() end
		end
	end)
end

---@param opts table
---@return table
function GlassUI:CreateWindow(opts)
	opts = opts or {}

	if shared.__GlassUI then pcall(function() shared.__GlassUI:Destroy() end) end
	sweepPrevious()
	shared.__GlassUI = GlassUI

	local window = setmetatable({ tabs = {}, order = 0, toggleKey = opts.ToggleKey or Enum.KeyCode.RightShift }, Window)
	active = { connections = {}, themed = {}, themeName = "dark", theme = THEMES.dark, visible = false, capturing = false }

	local gui = create("ScreenGui", { Name = GUI_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1000, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, getGuiParent())
	active.gui = gui
	active.blur = create("BlurEffect", { Name = BLUR_NAME, Size = 0 }, lightingService)

	-- Fit to the screen, then pop in/out through a second scale one level down.
	local root = create("Frame", { Name = "Root", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT), BackgroundTransparency = 1, Visible = false }, gui)
	active.root = root
	local fit = create("UIScale", {}, root)
	local function refit()
		local camera = workspace.CurrentCamera
		if not camera then return end

		local viewport = camera.ViewportSize
		fit.Scale = math.clamp(math.min(viewport.X / (WINDOW_WIDTH + 60), viewport.Y / (WINDOW_HEIGHT + 60)), 0.55, 1.2)
	end
	refit()
	if workspace.CurrentCamera then track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)) end

	local body = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, root)
	active.pop = create("UIScale", { Scale = 1 }, body)

	-- Soft layered glow behind the glass; it pulses on the beat.
	local glows = {}
	for index = 1, 3 do
		local pad = index * 14
		local glow = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, pad, 1, pad), BackgroundColor3 = index == 2 and BRAND.periwinkle or BRAND.teal, BackgroundTransparency = 0.88 + index * 0.03, BorderSizePixel = 0, ZIndex = 0 }, body)
		corner(glow, 16 + pad / 2)
		glows[index] = { frame = glow, base = 0.88 + index * 0.03 }
	end

	local main = create("Frame", { Name = "Main", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.08, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 1 }, body)
	bind(main, "BackgroundColor3", "bg")
	corner(main, 16)

	-- Animated rainbow-ish border: the gradient on the stroke rotates every frame.
	local border = create("UIStroke", { Thickness = 1.8, Color = Color3.new(1, 1, 1), Transparency = 0.15, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, main)
	local borderGradient = gradient(border, { BRAND.teal, BRAND.periwinkle, BRAND.amber, BRAND.teal }, 0)

	-- Glass sheen from the top-left.
	local sheen = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 2, Active = false }, main)
	create("UIGradient", { Rotation = 45, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(0.45, 0.965), NumberSequenceKeypoint.new(1, 1) }) }, sheen)

	-- Header: title, subtitle, equalizer, close.
	local header = create("Frame", { Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1, ZIndex = 3, Active = true }, main)
	local title = create("TextLabel", { Text = tostring(opts.Title or "GlassUI"), Font = Enum.Font.GothamBold, TextSize = 22, TextColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(22, 9), Size = UDim2.fromOffset(320, 26), ZIndex = 4 }, header)
	local titleGradient = gradient(title, { BRAND.teal, BRAND.periwinkle, BRAND.amber }, 0)
	local subtitle = text(header, tostring(opts.Subtitle or ""), 12, "muted", Enum.Font.GothamMedium, { Position = UDim2.fromOffset(22, 35), Size = UDim2.fromOffset(320, 16), ZIndex = 4 })
	subtitle.TextTransparency = 0.1

	local eq = create("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -62, 0.5, 0), Size = UDim2.fromOffset(BAR_COUNT * 7 - 3, 30), BackgroundTransparency = 1, ZIndex = 4 }, header)
	local bars = {}
	for index = 1, BAR_COUNT do
		local bar = create("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromOffset((index - 1) * 7, 30), Size = UDim2.fromOffset(4, 6), BackgroundColor3 = BRAND.teal, BorderSizePixel = 0, ZIndex = 4 }, eq)
		corner(bar, 2)
		bars[index] = { frame = bar, level = 0.2, target = 0.2, hot = false }
	end

	local close = create("TextButton", { Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -18, 0.5, 0), Size = UDim2.fromOffset(26, 26), BackgroundTransparency = 0.6, BorderSizePixel = 0, ZIndex = 5 }, header)
	bind(close, "BackgroundColor3", "raised")
	corner(close, 13)
	for _, rotation in { 45, -45 } do
		local arm = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(11, 2), Rotation = rotation, BorderSizePixel = 0, ZIndex = 6 }, close)
		bind(arm, "BackgroundColor3", "text")
	end
	track(close.MouseEnter:Connect(function()
		tween(close, 0.2, { BackgroundColor3 = Color3.fromRGB(235, 87, 110), BackgroundTransparency = 0.2 })
	end))
	track(close.MouseLeave:Connect(function()
		tween(close, 0.25, { BackgroundColor3 = active.theme.raised, BackgroundTransparency = 0.6 })
	end))
	track(close.Activated:Connect(function()
		window:Toggle(false)
	end))

	-- Sidebar.
	local sidebar = create("Frame", { Position = UDim2.fromOffset(14, 66), Size = UDim2.new(0, 170, 1, -80), BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 3 }, main)
	bind(sidebar, "BackgroundColor3", "panel")
	corner(sidebar, 14)
	stroke(sidebar, "stroke", 1, 0.9)

	window.tabList = create("ScrollingFrame", { Position = UDim2.fromOffset(6, 8), Size = UDim2.new(1, -12, 1, -64), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 0, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ZIndex = 3 }, sidebar)
	create("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, window.tabList)
	local footer = create("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 6, 1, -8), Size = UDim2.new(1, -12, 0, 40), BackgroundTransparency = 1, ZIndex = 3 }, sidebar)
	create("UIListLayout", { VerticalAlignment = Enum.VerticalAlignment.Bottom }, footer)

	-- Content.
	local content = create("Frame", { Position = UDim2.fromOffset(196, 66), Size = UDim2.new(1, -210, 1, -80), BackgroundTransparency = 1, ZIndex = 3 }, main)
	window.pages = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ClipsDescendants = true }, content)

	-- Cover used for the open/close fade.
	active.cover = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 30, Active = false }, main)
	bind(active.cover, "BackgroundColor3", "bg")
	corner(active.cover, 16)

	-- Toasts live on their own host so they survive the window being hidden.
	active.toastHost = create("Frame", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -20, 1, -20), Size = UDim2.fromOffset(300, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, gui)
	create("UIListLayout", { Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, active.toastHost)

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

	-- Idle beat pulse: equalizer, border rotation, glow, title shimmer.
	local elapsed = 0
	local lastBeat = -1
	local hot = 1
	track(runService.Heartbeat:Connect(function(deltaTime)
		if not active.visible then return end

		elapsed = elapsed + deltaTime
		local beat = math.floor(elapsed / BEAT)
		local phase = (elapsed % BEAT) / BEAT
		local pulse = math.exp(-phase * 5)

		if beat ~= lastBeat then
			lastBeat = beat
			hot = beat % BAR_COUNT + 1
			for index, bar in bars do
				bar.target = 0.15 + math.abs(math.sin(beat * 1.7 + index * 2.3)) * 0.85
				bar.frame.BackgroundColor3 = index == hot and BRAND.periwinkle or BRAND.teal
				if index == hot then bar.target = 1 end
			end
		end

		for _, bar in bars do
			bar.level = bar.level + (bar.target - bar.level) * math.min(1, deltaTime * 14)
			bar.frame.Size = UDim2.fromOffset(4, 4 + math.floor(bar.level * 26))
		end

		borderGradient.Rotation = (elapsed * 55) % 360
		local drift = elapsed * 0.1
		local palette = CYCLE[active.themeName]
		titleGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, cycleColor(drift, palette)),
			ColorSequenceKeypoint.new(0.5, cycleColor(drift + 0.17, palette)),
			ColorSequenceKeypoint.new(1, cycleColor(drift + 0.33, palette)),
		})
		border.Transparency = 0.25 - pulse * 0.2
		for _, glow in glows do
			glow.frame.BackgroundTransparency = glow.base - pulse * 0.05
		end
	end))

	-- Built-in Settings tab, pinned to the sidebar footer so it is always last.
	local settings = makeTab(window, "Settings", footer, 1)
	settings:AddSection("Interface")
	settings:AddKeybind({
		Text = "Toggle UI",
		Default = window.toggleKey,
		Flag = "ui_toggleKey",
		Callback = function(key)
			if key then window.toggleKey = key end
		end,
	})
	settings:AddToggle({
		Text = "Light theme",
		Default = false,
		Flag = "ui_light",
		Callback = function(on)
			applyTheme(on and "light" or "dark")
		end,
	})
	settings:AddToggle({
		Text = "Background blur",
		Default = true,
		Flag = "ui_blur",
		Callback = function(on)
			if active.visible then tween(active.blur, 0.4, { Size = on and 12 or 0 }) end
		end,
	})
	settings:AddSection("Session")
	settings:AddButton({
		Text = "Unload UI",
		Callback = function()
			task.defer(function()
				GlassUI:Destroy()
			end)
		end,
	})

	active.window = window

	if opts.Intro == false then
		task.defer(function()
			window:Toggle(true)
		end)
	else
		playIntro(window, opts)
	end

	return window
end

function GlassUI:Destroy()
	local owner = active
	if not owner then return end

	active = nil
	for _, connection in owner.connections do
		pcall(function() connection:Disconnect() end)
	end

	for _, instance in { owner.gui, owner.introGui, owner.blur } do
		if instance then pcall(function() instance:Destroy() end) end
	end

	table.clear(GlassUI.Flags)
	if shared.__GlassUI == GlassUI then shared.__GlassUI = nil end
end

return GlassUI
