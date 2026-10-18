local ADDON_NAME, ns = ...

local ROW_HEIGHT = 28
local CONTENT_WIDTH = 640
local CONTROL_X = 290  -- column where per-event controls start
local TRIGGER_LABELS = { cast = "Beim Wirken", ready = "Wenn bereit" }
local THROTTLE_OPTIONS = { 0, 1, 2, 3, 5, 10 }
local READY_CHECK_MODES = { "start", "allReady", "both" }
local READY_CHECK_LABELS = { start = "Beim Start", allReady = "Wenn alle bereit", both = "Beides" }
local TEST_LABEL = "Anhören"

local panel

local function Changed()
	ns:OnConfigChanged()
end

---------------------------------------------------------------------------
-- Widget helpers
---------------------------------------------------------------------------

local function Label(parent, text, font)
	local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
	fs:SetText(text)
	fs:SetJustifyH("LEFT")
	return fs
end

local function Checkbox(parent, text, get, set, tooltip)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	local label = cb.Text or cb.text
	label:SetText(text or "")
	label:SetFontObject("GameFontHighlight")
	cb.get = get
	cb:SetScript("OnClick", function(self) set(self:GetChecked()) end)
	cb:SetScript("OnShow", function(self) self:SetChecked(self.get()) end)
	if tooltip then
		cb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(text, 1, 1, 1)
			GameTooltip:AddLine(tooltip, nil, nil, nil, true)
			GameTooltip:Show()
		end)
		cb:SetScript("OnLeave", GameTooltip_Hide)
	end
	cb:SetChecked(get())
	return cb
end

local function Button(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function EditBox(parent, width, onEnter)
	local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	eb:SetSize(width, 20)
	eb:SetAutoFocus(false)
	eb:SetScript("OnEnterPressed", function(self)
		onEnter(strtrim(self:GetText()))
		self:SetText("")
		self:ClearFocus()
	end)
	eb:SetScript("OnEscapePressed", eb.ClearFocus)
	return eb
end

-- Dropdown whose options come from list() and selection from get()/set().
local function Dropdown(parent, width, list, get, set, labelOf)
	local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
	dd:SetWidth(width)
	dd.get, dd.set = get, set
	dd:SetupMenu(function(self, root)
		local options = list()
		if #options > 15 then root:SetScrollMode(400) end
		for _, value in ipairs(options) do
			root:CreateRadio(labelOf and labelOf(value) or value,
				function() return self.get() == value end,
				function() self.set(value) end)
		end
	end)
	return dd
end

local function SoundDropdown(parent, get, set)
	return Dropdown(parent, 150, function() return ns.SOUNDS end, get, function(value)
		set(value)
		ns:PlaySound(value)
	end, function(value) return ns:SoundLabel(value) end)
end

local function TestButton(parent, getSound)
	return Button(parent, TEST_LABEL, 80, function() ns:PlaySound(getSound()) end)
end

local function SpellIcon(parent)
	local tex = parent:CreateTexture(nil, "ARTWORK")
	tex:SetSize(20, 20)
	tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	return tex
end

-- Writes icon + "Name (ID)" for a configured spell text, red when unresolved.
local function ShowSpell(icon, label, text)
	local spellID, name, iconID = ns:ResolveSpell(text)
	if spellID then
		icon:SetTexture(iconID)
		label:SetText(("%s |cff888888(%d)|r"):format(name, spellID))
	else
		icon:SetTexture(134400) -- question mark
		label:SetText(("|cffff5555%s|r |cff888888(nicht gefunden)|r"):format(text))
	end
end

local function Header(parent, text, anchor, yOffset)
	local fs = Label(parent, text, "GameFontNormalLarge")
	fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOffset or -18)
	return fs
end

local function Note(parent, text, anchor)
	local fs = Label(parent, text, "GameFontDisableSmall")
	fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
	fs:SetWidth(CONTENT_WIDTH - 20)
	fs:SetWordWrap(true)
	return fs
end

-- A sub-row under an event row (indented option).
local function SubRow(parent, anchor)
	local sub = CreateFrame("Frame", nil, parent)
	sub:SetSize(CONTENT_WIDTH, 26)
	sub:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
	return sub
end

---------------------------------------------------------------------------
-- Spell list (rebuilt on change, rows pooled)
---------------------------------------------------------------------------

local function SpellRow(container, i)
	local row = CreateFrame("Frame", nil, container)
	row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
	row.enabled = Checkbox(row, nil,
		function() return row.entry and row.entry.enabled end,
		function(v) row.entry.enabled = v; Changed() end)
	row.enabled:SetPoint("LEFT", 0, 0)
	row.icon = SpellIcon(row)
	row.icon:SetPoint("LEFT", row.enabled, "RIGHT", 4, 0)
	row.label = Label(row, "")
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.label:SetWidth(150)
	row.label:SetWordWrap(false)
	row.trigger = Dropdown(row, 140, function() return { "cast", "ready" } end,
		function() return row.entry and row.entry.trigger end,
		function(v)
			row.entry.trigger = v
			if v == "cast" and not ns:HasSound(row.entry.sound) then row.entry.sound = ns.SOUNDS[1] end
			Changed()
			panel:RefreshLists()
		end,
		function(v) return TRIGGER_LABELS[v] end)
	row.trigger:SetPoint("LEFT", 210, 0)
	row.sound = SoundDropdown(row,
		function() return row.entry and row.entry.sound end,
		function(v) row.entry.sound = v; Changed() end)
	row.sound:SetPoint("LEFT", row.trigger, "RIGHT", 6, 0)
	row.fixedSound = Label(row, "Standard-Sound", "GameFontDisable")
	row.fixedSound:SetPoint("LEFT", row.sound, "LEFT", 4, 0)
	row.test = TestButton(row, function()
		if row.entry.trigger == "cast" then return row.entry.sound end
		return ns.EVENT_BY_KEY.cooldownReady.files[1]
	end)
	row.test:SetPoint("LEFT", row.sound, "RIGHT", 6, 0)
	row.remove = Button(row, "X", 26, function()
		tremove(ns.db.spells, row.index)
		Changed()
		panel:RefreshLists()
	end)
	row.remove:SetPoint("LEFT", row.test, "RIGHT", 4, 0)
	return row
end

local function FillRow(row, entry)
	row.entry = entry
	ShowSpell(row.icon, row.label, entry.spell)
	row.enabled:SetChecked(entry.enabled)
	row.trigger:GenerateMenu()
	local isCast = entry.trigger == "cast"
	row.sound:SetShown(isCast)
	row.fixedSound:SetShown(not isCast)
	if isCast then row.sound:GenerateMenu() end
end

local function FillList(container, data)
	for i, entry in ipairs(data) do
		local row = container.rows[i] or SpellRow(container, i)
		container.rows[i] = row
		row.index = i
		FillRow(row, entry)
		row:Show()
	end
	for i = #data + 1, #container.rows do container.rows[i]:Hide() end
	container:SetHeight(math.max(1, #data * ROW_HEIGHT))
end

---------------------------------------------------------------------------
-- Event rows
---------------------------------------------------------------------------

local function VariantDropdown(parent, def, cfg)
	local values = { 0 }
	for i = 1, #def.files do values[#values + 1] = i end
	return Dropdown(parent, 150, function() return values end,
		function() return cfg.variant end,
		function(v)
			cfg.variant = v
			if v > 0 then ns:PlaySound(def.files[v]) end
		end,
		function(v) return v == 0 and "Abwechselnd" or ("Variante " .. v) end)
end

local function ThrottleDropdown(parent, cfg)
	return Dropdown(parent, 150, function() return THROTTLE_OPTIONS end,
		function() return cfg.throttle end,
		function(v) cfg.throttle = v end,
		function(v)
			if v == 0 then return "Keiner" end
			return v == 1 and "1 Sekunde" or (v .. " Sekunden")
		end)
end

local function EventRow(parent, anchor, def, first)
	local cfg = ns.db.events[def.key]
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, first and -6 or 0)
	Checkbox(row, def.label, function() return cfg.enabled end,
		function(v) cfg.enabled = v; Changed() end, def.tooltip):SetPoint("LEFT")
	if #def.files > 1 then
		VariantDropdown(row, def, cfg):SetPoint("LEFT", CONTROL_X, 0)
	end
	TestButton(row, function() return ns:EventFile(def.key) end):SetPoint("LEFT", CONTROL_X + 160, 0)

	if def.key == "bossAggro" then
		local sub = SubRow(parent, row)
		Checkbox(sub, "Nicht als Tank", function() return cfg.ignoreAsTank end,
			function(v) cfg.ignoreAsTank = v end):SetPoint("LEFT", 24, 0)
		return sub
	elseif def.key == "groupDeath" then
		local sub = SubRow(parent, row)
		Label(sub, "Mindestabstand zwischen Sounds"):SetPoint("LEFT", 52, 0)
		ThrottleDropdown(sub, cfg):SetPoint("LEFT", CONTROL_X, 0)
		return sub
	elseif def.key == "readyCheck" then
		local sub = SubRow(parent, row)
		Label(sub, "Auslösen"):SetPoint("LEFT", 52, 0)
		Dropdown(sub, 150, function() return READY_CHECK_MODES end,
			function() return cfg.mode end,
			function(v) cfg.mode = v end,
			function(v) return READY_CHECK_LABELS[v] end):SetPoint("LEFT", CONTROL_X, 0)
		return sub
	end
	return row
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function BuildPanel()
	local f = CreateFrame("Frame", "DrachensoundsOptionsFrame", UIParent, "ButtonFrameTemplate")
	ButtonFrameTemplate_HidePortrait(f)
	ButtonFrameTemplate_HideButtonBar(f)
	f:SetTitle("Drachensounds")
	f:SetSize(CONTENT_WIDTH + 70, 660)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	tinsert(UISpecialFrames, f:GetName())
	f:Hide()

	local scroll = CreateFrame("ScrollFrame", nil, f.Inset, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -28, 8)
	local c = CreateFrame("Frame", nil, scroll)
	c:SetSize(CONTENT_WIDTH, 100)
	scroll:SetScrollChild(c)

	-- General ---------------------------------------------------------------
	local enabled = Checkbox(c, "Sounds aktiviert", function() return ns.db.enabled end,
		function(v) ns.db.enabled = v; Changed() end)
	enabled:SetPoint("TOPLEFT", 0, 0)

	local channelLabel = Label(c, "Kanal")
	channelLabel:SetPoint("LEFT", enabled, "LEFT", 170, 0)
	local channel = Dropdown(c, 170, function() return ns.CHANNELS end,
		function() return ns.db.channel end,
		function(v) ns.db.channel = v; Changed() end,
		function(v) return ns.CHANNEL_LABELS[v] end)
	channel:SetPoint("LEFT", channelLabel, "RIGHT", 8, 0)

	local debug = Checkbox(c, "Debug-Ausgabe", function() return ns.db.debug end,
		function(v) ns.db.debug = v end, "Schreibt jeden ausgelösten Sound in den Chat.")
	debug:SetPoint("LEFT", channel, "RIGHT", 20, 0)

	-- Events ----------------------------------------------------------------
	local anchor = Header(c, "Ereignisse", enabled)
	for i, def in ipairs(ns.EVENTS) do
		anchor = EventRow(c, anchor, def, i == 1)
	end
	local lustNote = Note(c, "Kampfrausch wird über den Erschöpfungs-Debuff erkannt und vom Spiel selbst abgespielt " ..
		"(höchstens 5 Sekunden lang). Änderungen daran greifen erst nach einem Bosskampf bzw. nach dem Kampf in Mythisch+.",
		anchor)

	-- Spell list ------------------------------------------------------------------
	local spellHeader = Header(c, "Zauberliste", lustNote, -22)
	local spellNote = Note(c, "Zauber per Name oder ID eintragen. „Wenn bereit“ spielt den Sound von „Fähigkeit wieder " ..
		"bereit“, „Beim Wirken“ einen eigenen Sound. Namen werden nur für erlernte Zauber erkannt.", spellHeader)
	local input = EditBox(c, 240, function(text)
		if text == "" then return end
		tinsert(ns.db.spells, { spell = text, trigger = "ready", enabled = true })
		Changed()
		f:RefreshLists()
	end)
	input:SetPoint("TOPLEFT", spellNote, "BOTTOMLEFT", 6, -8)
	Button(c, "Hinzufügen", 110, function()
		input:GetScript("OnEnterPressed")(input)
	end):SetPoint("LEFT", input, "RIGHT", 8, 0)
	local list = CreateFrame("Frame", nil, c)
	list:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -6, -6)
	list:SetSize(CONTENT_WIDTH, 1)
	list.rows = {}

	function f:RefreshLists()
		FillList(list, ns.db.spells)
		-- size the scroll child to its content once the new layout is resolved
		C_Timer.After(0, function()
			local bottom, topY = list:GetBottom(), c:GetTop()
			if bottom and topY then c:SetHeight(topY - bottom + 20) end
		end)
	end

	f:SetScript("OnShow", function(self) self:RefreshLists() end)
	return f
end

function ns:ToggleOptions()
	panel = panel or BuildPanel()
	panel:SetShown(not panel:IsShown())
end

-- Entry in Esc > Options > AddOns that opens the real panel.
function ns:InitOptions()
	if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
	local stub = CreateFrame("Frame")
	local title = Label(stub, "Drachensounds", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	local open = Button(stub, "Einstellungen öffnen (/dsounds)", 240, function()
		if SettingsPanel then HideUIPanel(SettingsPanel) end
		panel = panel or BuildPanel()
		panel:Show()
	end)
	open:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
	local category = Settings.RegisterCanvasLayoutCategory(stub, "Drachensounds")
	Settings.RegisterAddOnCategory(category)
end
