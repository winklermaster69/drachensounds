local ADDON_NAME, ns = ...

ns.SOUND_DIR = "Interface\\AddOns\\" .. ADDON_NAME .. "\\sounds\\"
-- WoW Forever (Classic content on the Midnight engine) shares this code; see CLAUDE.md.
ns.IS_FOREVER = WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or 18)
ns.CLIENT = ns.IS_FOREVER and "forever" or "midnight"
ns.CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }
ns.CHANNEL_LABELS = {
	Master = "Meisterkanal",
	SFX = "Effekte",
	Music = "Musik",
	Ambience = "Umgebung",
	Dialog = "Dialog",
}

-- All fixed triggers, in display order. Each plays one of its hardcoded `files`;
-- triggers with several files let the user alternate or pick one (cfg.variant).
--   clients  = { "midnight" } / { "forever" }: only on that client (omit = everywhere)
--   defaults = extra per-trigger settings, merged into db.events[key]
-- Only triggers for the running client end up in ns.EVENTS (see SelectEvents);
-- detection lives in Triggers.lua, registered per trigger key.
ns.ALL_EVENTS = {
	{ key = "playerDeath", files = { "spielertod" }, throttle = 2,
	  label = "Eigener Tod",
	  tooltip = "Wenn du stirbst." },
	{ key = "petDeath", files = { "haustiertod_1", "haustiertod_2", "haustiertod_3" }, throttle = 2,
	  label = "Tod des Begleiters",
	  tooltip = "Wenn dein Begleiter (Tier, Dämon, Elementar …) stirbt." },
	{ key = "groupDeath", files = { "gruppentod" }, throttle = 2,
	  defaults = { throttle = 2 },  -- user-adjustable minimum seconds between group death sounds
	  label = "Tod eines Gruppenmitglieds",
	  tooltip = "Wenn ein anderes Gruppen- oder Schlachtzugsmitglied stirbt. Totstellen wird ignoriert." },
	{ key = "bossAggro", files = { "bossaggro" }, throttle = 3,
	  defaults = { ignoreAsTank = false },
	  label = "Aggro eines Bosses",
	  tooltip = "Wenn du die Aggro eines Bosses (Bossrahmen 1–8) bekommst." },
	{ key = "bossKill", files = { "bosssieg" }, throttle = 2,
	  label = "Boss besiegt",
	  tooltip = "Wenn ein Bosskampf erfolgreich endet." },
	{ key = "cooldownReady", files = { "abklingzeit_bereit" }, throttle = 1,
	  label = "Fähigkeit wieder bereit",
	  tooltip = "Wenn ein Zauber aus der Zauberliste mit „Wenn bereit“ seine Abklingzeit beendet." },
	{ key = "bloodlust", files = { "kampfrausch" }, throttle = 5,
	  label = "Kampfrausch / Heldentum",
	  tooltip = "Wenn du Kampfrausch, Heldentum, Zeitkrümmung oder Ähnliches erhältst." },
	{ key = "resurrect", files = { "wiederbelebung_1", "wiederbelebung_2", "wiederbelebung_3" }, throttle = 3,
	  label = "Wiederbelebung erhalten",
	  tooltip = "Wenn dir jemand eine Wiederbelebung anbietet." },
	{ key = "magePortal", files = { "portal" }, throttle = 5,
	  label = "Magier öffnet ein Portal",
	  tooltip = "Wenn du ein Portal wirkst, oder sobald ein Magier aus deiner Gruppe bzw. deinem Schlachtzug " ..
		"in deiner Nähe ein Portal öffnet." },
	{ key = "readyCheck", files = { "bereitschaftscheck" }, throttle = 2,
	  defaults = { mode = "allReady" },  -- "start" | "allReady" | "both"
	  label = "Bereitschaftscheck",
	  tooltip = "Wenn ein Bereitschaftscheck startet und/oder alle bereit sind (siehe Auswahl darunter)." },
}
-- Fills ns.EVENTS / ns.EVENT_BY_KEY with the triggers available on this client.
local function SelectEvents()
	ns.EVENTS, ns.EVENT_BY_KEY = {}, {}
	for _, def in ipairs(ns.ALL_EVENTS) do
		if not def.clients or tContains(def.clients, ns.CLIENT) then
			tinsert(ns.EVENTS, def)
			ns.EVENT_BY_KEY[def.key] = def
		end
	end
end

local DB_VERSION = 3

local function BuildDefaults()
	local events = {}
	for _, def in ipairs(ns.EVENTS) do
		local cfg = { enabled = true }
		if #def.files > 1 then cfg.variant = 0 end  -- 0 = alternate, n = always files[n]
		for k, v in pairs(def.defaults or {}) do cfg[k] = v end
		events[def.key] = cfg
	end
	return {
		version = DB_VERSION,
		enabled = true,
		debug = false,
		channel = "Master",
		events = events,
		spells = {},  -- { spell = "name or ID", trigger = "cast"|"ready", sound = "file" (cast only), enabled = true }
	}
end

-- Fills missing keys of dst from src (recursively), never overwriting user values.
local function ApplyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			-- list-like defaults (empty tables) are only created, never filled
			if next(v) ~= nil then ApplyDefaults(dst[k], v) end
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

-- Old bundled sound names -> current ones, for "cast" entries that saved a sound.
local RENAMED_SOUNDS = {
	-- v1 (library names)
	arschlocha = "spielertod", ambodenrumgruebbeln1 = "haustiertod_1", wiedumm = "gruppentod",
	dannsollerherkommen = "bossaggro", mikropimmel2 = "bosssieg", dakommtwiederwas = "abklingzeit_bereit",
	aufdieichbockhab = "kampfrausch",
	-- before the pet/resurrect variants (old "wiederbelebung" was the same audio as haustiertod_1)
	haustiertod = "haustiertod_1", wiederbelebung = "haustiertod_1",
}

local function Migrate(db)
	if not db.events then
		db.version = DB_VERSION
		return
	end
	if (db.version or 1) < 2 then
		-- v1 (pre-release) had selectable event sounds and two separate spell lists
		db.spells = db.spells or {}
		for _, text in ipairs(db.cooldownSpells or {}) do
			tinsert(db.spells, { spell = text, trigger = "ready", enabled = true })
		end
		for _, m in ipairs(db.spellSounds or {}) do
			tinsert(db.spells, {
				spell = m.spell,
				trigger = m.trigger,
				sound = m.trigger == "cast" and m.sound or nil,
				enabled = m.enabled,
			})
		end
		db.cooldownSpells, db.spellSounds = nil, nil
		for _, cfg in pairs(db.events) do cfg.sound = nil end
	end
	if (db.version or 1) < 3 then
		-- v2 defaulted the ready check to "both"; the default is now "allReady"
		local readyCheck = db.events.readyCheck
		if readyCheck and readyCheck.mode == "both" then readyCheck.mode = "allReady" end
	end
	for _, m in ipairs(db.spells or {}) do
		if m.sound then m.sound = RENAMED_SOUNDS[m.sound] or m.sound end
	end
	db.version = DB_VERSION
end

---------------------------------------------------------------------------
-- Sounds
---------------------------------------------------------------------------

local soundSet = {}
for _, name in ipairs(ns.SOUNDS) do soundSet[name] = true end

function ns:HasSound(name)
	return name ~= nil and soundSet[name] == true
end

function ns:SoundPath(name)
	return ns.SOUND_DIR .. name .. ".mp3"
end

-- "abklingzeit_bereit" -> "Abklingzeit bereit"
function ns:SoundLabel(name)
	local label = name:gsub("_", " ")
	return label:sub(1, 1):upper() .. label:sub(2)
end

function ns:PlaySound(name)
	if not self:HasSound(name) then
		self:Debug("Sound „%s“ ist nicht enthalten", tostring(name))
		return
	end
	local willPlay = PlaySoundFile(self:SoundPath(name), self.db.channel)
	if not willPlay then
		self:Debug("„%s“ konnte nicht abgespielt werden (Kanal stumm?)", name)
	end
end

local rotation = {}

-- The file an event plays next: its picked variant, or the next one in rotation.
function ns:EventFile(key)
	local files, variant = ns.EVENT_BY_KEY[key].files, self.db.events[key].variant
	if #files == 1 then return files[1] end
	if variant and files[variant] then return files[variant] end
	rotation[key] = (rotation[key] or 0) % #files + 1
	return files[rotation[key]]
end

local lastPlayed = {}

-- Returns true if `key` fired less than `seconds` ago; otherwise records now.
function ns:Throttled(key, seconds)
	local now = GetTime()
	if lastPlayed[key] and now - lastPlayed[key] < seconds then return true end
	lastPlayed[key] = now
	return false
end

-- Plays the sound of a fixed event (see ns.EVENTS). Triggers not available on this
-- client have no def and stay silent.
function ns:Fire(key)
	local def, cfg = ns.EVENT_BY_KEY[key], self.db.events[key]
	if not (def and self.db.enabled and cfg and cfg.enabled) then return end
	if self:Throttled(key, cfg.throttle or def.throttle) then return end
	local file = self:EventFile(key)
	self:Debug("Ereignis: %s (%s)", def.label, file)
	self:PlaySound(file)
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

function ns:Print(fmt, ...)
	print("|cffd94a2bDrachensounds|r: " .. fmt:format(...))
end

function ns:Debug(fmt, ...)
	if self.db and self.db.debug then
		self:Print("|cff999999" .. fmt:format(...) .. "|r")
	end
end

---------------------------------------------------------------------------
-- Init & slash command
---------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
	if name ~= ADDON_NAME then return end
	self:UnregisterEvent("ADDON_LOADED")
	SelectEvents()
	DrachensoundsDB = DrachensoundsDB or {}
	Migrate(DrachensoundsDB)
	ApplyDefaults(DrachensoundsDB, BuildDefaults())
	ns.db = DrachensoundsDB
	ns:InitTriggers()
	ns:InitOptions()
end)

local SLASH_ALIASES = {
	an = "on", ein = "on", on = "on",
	aus = "off", off = "off",
	debug = "debug", fehlersuche = "debug",
	status = "status", zustand = "status",
}

SLASH_DRACHENSOUNDS1 = "/dsounds"
SLASH_DRACHENSOUNDS2 = "/drachensounds"
SlashCmdList.DRACHENSOUNDS = function(msg)
	msg = strtrim(msg or ""):lower()
	local cmd = SLASH_ALIASES[msg]
	if cmd == "on" or cmd == "off" then
		ns.db.enabled = (cmd == "on")
		ns:OnConfigChanged()
		ns:Print("Sounds %s.", ns.db.enabled and "aktiviert" or "deaktiviert")
	elseif cmd == "debug" then
		ns.db.debug = not ns.db.debug
		ns:Print("Debug-Ausgabe %s.", ns.db.debug and "an" or "aus")
	elseif cmd == "status" then
		ns:PrintStatus()
	elseif msg == "" then
		ns:ToggleOptions()
	else
		ns:Print("Befehle: /dsounds [an | aus | debug | status]")
	end
end
