-- Offline smoke test: loads the addon against a mocked WoW API and simulates events.
-- Usage (from repo root): lua tests/smoke.lua
-- Set DS_FLAVOR=forever to simulate the WoW Forever client (project ID 18, no specializations).
-- Secret values are modelled by the SECRET sentinel; doing math/comparisons on it errors,
-- like real secrets do for tainted code.

local ADDON = "Drachensounds"
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })

---------------------------------------------------------------------------
-- Mock world state
---------------------------------------------------------------------------
local now = 1000
local played = {}
local timers, tickers = {}, {}
local units = {}          -- token -> { dead, feign, guid, threat, target }
local cooldowns = {}      -- spellID -> SpellCooldownInfo
local spells = {          -- name/ID lookup for C_Spell.GetSpellInfo
	[45438] = "Ice Block", [133] = "Fireball", [2139] = "Counterspell",
	[10059] = "Portal: Sturmwind", [3561] = "Teleportieren: Sturmwind",
}
local readyStatus = {}    -- token -> "ready" | "notready" | "waiting"
local raid, subgroup = false, 0
local restricted = {}     -- AddOnRestrictionType -> bool
local auraSounds = {}
local nextAuraHandle = 1
local FOREVER = os.getenv("DS_FLAVOR") == "forever"
local specRole, groupRole = "DAMAGER", "NONE"

---------------------------------------------------------------------------
-- Generic widget mock: unknown methods are no-ops returning another widget
---------------------------------------------------------------------------
local eventFrames = {}
local Widget = {}
local function NewWidget(name)
	local w = setmetatable({ scripts = {}, events = {}, shown = true, name = name }, Widget)
	return w
end
Widget.__index = function(self, key)
	local method = rawget(Widget, key)
	if method then return method end
	if key == "Text" or key == "text" or key == "Inset" or key == "CloseButton" then
		local child = NewWidget()
		rawset(self, key, child)
		return child
	end
	if key:match("^%l") then return nil end -- plain fields, like on real frames
	return function() return NewWidget() end
end
function Widget:SetScript(name, fn) self.scripts[name] = fn end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:RegisterEvent(e) self.events[e] = true; eventFrames[self] = true end
function Widget:RegisterUnitEvent(e, ...) self.events[e] = { ... }; eventFrames[self] = true end
function Widget:UnregisterEvent(e) self.events[e] = nil end
function Widget:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
function Widget:Hide() self.shown = false end
function Widget:IsShown() return self.shown end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:GetName() return self.name end
function Widget:GetTop() return 500 end
function Widget:GetBottom() return 100 end
function Widget:GetChecked() return self.checked end
function Widget:SetChecked(v) self.checked = v end
function Widget:GetText() return self.textValue or "" end
function Widget:SetText(v) self.textValue = v end
function Widget:SetupMenu(fn) self.menuFn = fn; self:GenerateMenu() end
function Widget:GenerateMenu()
	if not self.menuFn then return end
	local root = NewWidget()
	self.radios = {}
	function root.CreateRadio(_, label, isSelected, onSelect)
		table.insert(self.radios, { label = label, isSelected = isSelected, onSelect = onSelect })
	end
	self.menuFn(self, root)
end

---------------------------------------------------------------------------
-- Globals the addon uses
---------------------------------------------------------------------------
_G.issecretvalue = function(v) return v == SECRET end
_G.GetTime = function() return now end
_G.CreateFrame = function(_, name) local w = NewWidget(name); if name then _G[name] = w end; return w end
_G.UIParent = NewWidget()
_G.UISpecialFrames = {}
_G.GameTooltip = NewWidget()
_G.GameTooltip_Hide = function() end
_G.ButtonFrameTemplate_HidePortrait = function() end
_G.ButtonFrameTemplate_HideButtonBar = function() end
_G.HideUIPanel = function() end
_G.SlashCmdList = {}
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.tinsert, _G.tremove = table.insert, table.remove
_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
_G.print = function(...) io.write("  [chat] ", table.concat({ ... }, " "), "\n") end
_G.MAX_BOSS_FRAMES = 8
_G.WOW_PROJECT_ID = FOREVER and 18 or 1
_G.C_AddOns = { GetAddOnMetadata = function() return "test" end }
_G.UnitGroupRolesAssigned = function() return groupRole end
_G.Settings = {
	RegisterCanvasLayoutCategory = function() return {} end,
	RegisterAddOnCategory = function() end,
}
_G.Enum = {
	AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2 },
	AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
	UnitAuraSoundTrigger = { Added = 0 },
}
_G.PlaySoundFile = function(path, channel)
	table.insert(played, path:match("([^\\]+)%.mp3$"))
	return true, 1
end
_G.C_Timer = {
	After = function(_, fn) table.insert(timers, fn) end,
	NewTicker = function(_, fn)
		local t = { fn = fn }
		function t.Cancel() t.cancelled = true end
		table.insert(tickers, t)
		return t
	end,
}
_G.UnitExists = function(u) return units[u] ~= nil end
_G.UnitIsDeadOrGhost = function(u) return units[u] and units[u].dead or false end
_G.UnitIsFeignDeath = function(u) return units[u] and units[u].feign or false end
_G.UnitClassBase = function(u) return units[u] and units[u].class end
_G.UnitIsVisible = function(u) return units[u] ~= nil and not units[u].away end
_G.UnitCastingInfo = function(u) return SECRET, SECRET, SECRET, SECRET, SECRET, units[u] and units[u].crafting or false end
local inCombat = false
_G.InCombatLockdown = function() return inCombat end
_G.UnitIsConnected = function(u) return units[u] ~= nil and not units[u].offline end
_G.GetReadyCheckStatus = function(u) return readyStatus[u] end
_G.UnitGUID = function(u) return units[u] and units[u].guid end
_G.UnitIsUnit = function(a, b)
	if b == "player" and a:match("target$") then
		local boss = units[a:gsub("target$", "")]
		return boss and boss.target == "player" or false
	end
	return a == b
end
_G.UnitThreatSituation = function(_, mob) return units[mob] and units[mob].threat end
_G.IsInRaid = function() return raid end
_G.GetNumGroupMembers = function() return raid and 5 or subgroup + 1 end
_G.GetNumSubgroupMembers = function() return subgroup end
_G.C_Secrets = { CanCompareUnitTokens = function() return true end }
_G.C_SpecializationInfo = {
	GetSpecialization = function() return FOREVER and 0 or 1 end,
	GetSpecializationInfo = function() return 1, "Spec", "", 0, specRole end,
}
_G.C_RestrictedActions = { IsAddOnRestrictionActive = function(t) return restricted[t] or false end }
_G.C_UnitAuras = {
	AddAuraSound = function(trigger, info)
		assert(info.unitToken and info.spellID and info.soundFileName and info.outputChannel)
		if restricted[1] then error("restricted") end
		local h = nextAuraHandle
		nextAuraHandle = h + 1
		auraSounds[h] = info
		return h
	end,
	RemoveAuraSound = function(h) auraSounds[h] = nil end,
}
_G.C_Spell = {
	GetSpellInfo = function(idOrName)
		for id, name in pairs(spells) do
			if id == idOrName or name:lower() == tostring(idOrName):lower() then
				return { spellID = id, name = name, iconID = 1 }
			end
		end
	end,
	GetSpellName = function(id) return spells[id] end,
	GetSpellCooldown = function(id)
		return cooldowns[id] or { isActive = false, isEnabled = true, startTime = 0, duration = 0 }
	end,
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Fire(event, ...)
	for f in pairs(eventFrames) do
		local reg = f.events[event]
		if reg then
			local unit = ...
			if reg == true or (type(reg) == "table" and (reg[1] == unit or reg[2] == unit)) then
				f.scripts.OnEvent(f, event, ...)
			end
		end
	end
end
local function FlushTimers()
	while #timers > 0 do table.remove(timers, 1)() end
end
local function Tick()
	for _, t in ipairs(tickers) do if not t.cancelled then t.fn() end end
end
local function Advance(seconds) now = now + seconds end

local failures, checks = 0, 0
local function Expect(name, expected)
	checks = checks + 1
	local got = table.concat(played, ",")
	local want = table.concat(expected, ",")
	if got == want then
		io.write("ok   ", name, "\n")
	else
		failures = failures + 1
		io.write(("FAIL %s: expected [%s] got [%s]\n"):format(name, want, got))
	end
	played = {}
	Advance(10) -- clear throttles between scenarios
end
local function Check(name, cond)
	checks = checks + 1
	if cond then
		io.write("ok   ", name, "\n")
	else
		failures = failures + 1
		io.write("FAIL ", name, "\n")
	end
end

---------------------------------------------------------------------------
-- Load addon (TOC order)
---------------------------------------------------------------------------
local ns = {}
for line in io.lines(ADDON .. "/" .. ADDON .. ".toc") do
	if line:match("%.lua$") then
		local chunk = assert(loadfile(ADDON .. "/" .. line))
		chunk(ADDON, ns)
	end
end
units.player = { guid = "Player-1" }
-- a v1 (pre-release) SavedVariables table, to exercise the migration
DrachensoundsDB = {
	enabled = true, channel = "Master",
	events = {
		playerDeath = { enabled = false, sound = "arschlocha" },
		readyCheck = { enabled = true, mode = "both" },  -- the old default, flipped by the v3 migration
	},
	cooldownSpells = { "Ice Block" },
	spellSounds = {
		{ spell = "Fireball", trigger = "cast", sound = "wiedumm", enabled = true },
		{ spell = "Frostbolt", trigger = "cast", sound = "ambodenrumgruebbeln1", enabled = true },
	},
}
Fire("ADDON_LOADED", ADDON)
Fire("PLAYER_ENTERING_WORLD")
FlushTimers()

---------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------
local db = DrachensoundsDB
Check("migration: version bumped, old lists gone", db.version == 3 and db.cooldownSpells == nil and db.spellSounds == nil)
Check("migration: spells merged, sounds renamed", #db.spells == 3 and db.spells[1].trigger == "ready"
	and db.spells[2].trigger == "cast" and db.spells[2].sound == "gruppentod"
	and db.spells[3].sound == "haustiertod_1")
Check("migration: event choices kept, sounds dropped", db.events.playerDeath.enabled == false
	and db.events.playerDeath.sound == nil and db.events.groupDeath.enabled == true)
db.events.playerDeath.enabled = true
Check("every event sound is bundled", (function()
	for _, def in ipairs(ns.EVENTS) do
		for _, file in ipairs(def.files) do
			if not ns:HasSound(file) then return false end
		end
	end
	return true
end)())
Check("defaults: alternate variants, 2 s group death limit",
	db.events.petDeath.variant == 0 and db.events.resurrect.variant == 0 and db.events.groupDeath.throttle == 2)
Check("bloodlust aura sounds registered", (function()
	local n = 0
	for _, info in pairs(auraSounds) do
		n = n + 1
		if not info.soundFileName:find("kampfrausch") then return false end
	end
	return n == 7
end)())

Fire("PLAYER_DEAD");                  Expect("player death", { "spielertod" })
Fire("RESURRECT_REQUEST", "Someone"); Expect("resurrect", { "wiederbelebung_1" })
Fire("RESURRECT_REQUEST", "Someone"); Expect("resurrect alternates", { "wiederbelebung_2" })
Fire("RESURRECT_REQUEST", "Someone"); Expect("resurrect alternates again", { "wiederbelebung_3" })
Fire("RESURRECT_REQUEST", "Someone"); Expect("resurrect rotation wraps", { "wiederbelebung_1" })
db.events.resurrect.variant = 2
Fire("RESURRECT_REQUEST", "Someone"); Expect("resurrect picked variant", { "wiederbelebung_2" })
Fire("RESURRECT_REQUEST", "Someone"); Expect("picked variant stays", { "wiederbelebung_2" })
db.events.resurrect.variant = 0
Fire("ENCOUNTER_END", 1, "Boss", 16, 20, 1, {}); Expect("boss kill", { "bosssieg" })
Fire("ENCOUNTER_END", 1, "Boss", 16, 20, 0, {}); Expect("boss wipe is silent", {})
Fire("ENCOUNTER_END", 1, "Boss", 16, 20, SECRET, {}); Expect("secret success is ignored", {})
db.events.bossKill.enabled = false
Fire("ENCOUNTER_END", 1, "Boss", 16, 20, 1, {}); Expect("disabled event is silent", {})
db.events.bossKill.enabled = true

-- group deaths
subgroup = 2
units.party1 = { guid = "P1" }
units.party2 = { guid = "P2" }
Fire("GROUP_ROSTER_UPDATE")
units.party1.dead = true
Fire("UNIT_HEALTH", "party1");  Expect("party member death", { "gruppentod" })
Fire("UNIT_HEALTH", "party1");  Expect("no repeat while still dead", {})
units.party2.dead, units.party2.feign = true, true
Fire("UNIT_FLAGS", "party2");   Expect("feign death ignored", {})
units.party2.feign = false
Fire("UNIT_DIED", SECRET);      Expect("UNIT_DIED (secret guid) triggers rescan", { "gruppentod" })
units.party1.dead = false
Fire("UNIT_HEALTH", "party1")
units.party1.dead = true
Fire("UNIT_HEALTH", "nameplate1"); Expect("unrelated units ignored", {})
Fire("UNIT_HEALTH", "party1");  Expect("death after resurrect fires again", { "gruppentod" })
-- rate limit: a wipe must not stack sounds
subgroup = 4
units.party1, units.party2 = { guid = "P1" }, { guid = "P2" }
units.party3, units.party4 = { guid = "P3" }, { guid = "P4" }
Fire("GROUP_ROSTER_UPDATE")
for i = 1, 3 do
	units["party" .. i].dead = true
	Fire("UNIT_HEALTH", "party" .. i)
	Advance(0.5)
end
Expect("wipe: one sound within 2 s", { "gruppentod" })
units.party4.dead = true
Fire("UNIT_HEALTH", "party4");  Expect("next death after the limit plays", { "gruppentod" })
db.events.groupDeath.throttle = 0
for i = 1, 4 do units["party" .. i].dead = false; Fire("UNIT_HEALTH", "party" .. i) end
for i = 1, 2 do units["party" .. i].dead = true; Fire("UNIT_HEALTH", "party" .. i) end
Expect("limit 0 plays every death", { "gruppentod", "gruppentod" })
db.events.groupDeath.throttle = 2

-- pet
units.pet = { guid = "Pet-1" }
Fire("UNIT_PET", "player")
units.pet.dead = true
Fire("UNIT_HEALTH", "pet");     Expect("pet death", { "haustiertod_1" })
units.pet = { guid = "Pet-2" }
Fire("UNIT_PET", "player")
units.pet = nil
Fire("UNIT_PET", "player")
Fire("UNIT_DIED", "Pet-2");     Expect("despawned pet death via UNIT_DIED guid", { "haustiertod_2" })
FlushTimers()

-- boss aggro
units.boss1 = { threat = 0 }
Fire("INSTANCE_ENCOUNTER_ENGAGE_UNIT"); Expect("no aggro yet", {})
units.boss1.threat = 3
Fire("UNIT_THREAT_LIST_UPDATE", "boss1"); Expect("boss aggro", { "bossaggro" })
Fire("UNIT_THREAT_LIST_UPDATE", "boss1"); Expect("aggro held: silent", {})
units.boss1.threat, units.boss1.target = SECRET, "player"
Fire("PLAYER_REGEN_ENABLED")
Fire("UNIT_TARGET", "boss1");   Expect("secret threat falls back to boss target", { "bossaggro" })
Fire("PLAYER_REGEN_ENABLED")
db.events.bossAggro.ignoreAsTank, specRole, groupRole = true, "TANK", "TANK"
Fire("UNIT_TARGET", "boss1");   Expect("tank muted", {})
Fire("PLAYER_REGEN_ENABLED")
groupRole = "DAMAGER"  -- spec role wins where specs exist; Forever only has the group role
Fire("UNIT_TARGET", "boss1");   Expect("tank detection source", FOREVER and { "bossaggro" } or {})
specRole, groupRole = "DAMAGER", "NONE"
units.boss1 = nil

-- spell list: "ready" entries play the fixed cooldown sound, "cast" entries their own sound
db.spells = {
	{ spell = "Ice Block", trigger = "ready", enabled = true },
	{ spell = "Fireball", trigger = "cast", sound = "gruppentod", enabled = true },
	{ spell = "2139", trigger = "ready", enabled = true },
}
ns:OnConfigChanged()
cooldowns[45438] = { isActive = true, isOnGCD = true, duration = SECRET }
Fire("SPELL_UPDATE_COOLDOWN");  Check("GCD alone is not a cooldown", #tickers == 0 or tickers[#tickers].cancelled)
cooldowns[45438] = { isActive = true, isOnGCD = false, duration = SECRET }
Fire("SPELL_UPDATE_COOLDOWN", 45438)
Check("ticker runs while on cooldown", tickers[#tickers] and not tickers[#tickers].cancelled)
Tick();                         Expect("still on cooldown: silent", {})
cooldowns[45438] = nil
Tick();                         Expect("ready entry plays cooldown sound", { "abklingzeit_bereit" })
Check("ticker stops when nothing is on cooldown", tickers[#tickers].cancelled)
cooldowns[2139] = { isActive = true, isOnGCD = false, duration = 24 }
Fire("SPELL_UPDATE_COOLDOWN", 2139)
cooldowns[2139] = { isActive = true, isOnGCD = true, duration = 1.5 }
Fire("SPELL_UPDATE_COOLDOWN");  Expect("ready by ID (ended during GCD)", { "abklingzeit_bereit" })
db.events.cooldownReady.enabled = false
cooldowns[2139] = { isActive = true, isOnGCD = false, duration = 24 }
Fire("SPELL_UPDATE_COOLDOWN", 2139)
cooldowns[2139] = nil
Tick();                         Expect("ready entries follow the event switch", {})
db.events.cooldownReady.enabled = true
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 133); Expect("cast entry plays its own sound", { "gruppentod" })
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-2", SECRET); Expect("secret spellID ignored", {})
db.enabled = false
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3", 133)
Fire("PLAYER_DEAD");            Expect("master switch off", {})
db.enabled = true

-- bloodlust registration under restriction
restricted[1] = true
db.events.bloodlust.enabled = false
ns:OnConfigChanged()
Check("aura sounds untouched while restricted", next(auraSounds) ~= nil)
restricted[1] = false
Fire("ADDON_RESTRICTION_STATE_CHANGED", 1, 0)
FlushTimers()
Check("bloodlust unregistered after encounter", next(auraSounds) == nil)
db.events.bloodlust.enabled = true
ns:OnConfigChanged()

-- mage portals (party1..4 exist from the group death scenarios)
units.party1.class, units.party2.class = "MAGE", "WARRIOR"
Fire("UNIT_SPELLCAST_START", "party1", "Cast-P1", 10059); Expect("mage portal", { "portal" })
Fire("UNIT_SPELLCAST_START", "party1", "Cast-P2", 3561);  Expect("teleport is not a portal", {})
Fire("UNIT_SPELLCAST_START", "party2", "Cast-P3", 10059); Expect("non-mage ignored", {})
-- other players' casts are always secret: judged by cast time + still being there
local function HiddenCast(unit, seconds, outcome)
	Fire("UNIT_SPELLCAST_START", unit, SECRET, SECRET)
	Advance(seconds)
	Fire(outcome or "UNIT_SPELLCAST_SUCCEEDED", unit, SECRET, SECRET)
end
HiddenCast("party1", 10);        Expect("hidden cast: nothing until the visibility check", {})
FlushTimers();                   Expect("hidden 10 s cast, mage still here: portal", { "portal" })
HiddenCast("party1", 10); units.party1.away = true
FlushTimers();                   Expect("mage vanished (teleport/hearthstone): silent", {})
units.party1.away = nil
HiddenCast("party1", 2.5); FlushTimers(); Expect("short hidden cast: silent", {})
HiddenCast("party1", 10, "UNIT_SPELLCAST_INTERRUPTED"); FlushTimers(); Expect("interrupted: silent", {})
units.party1.crafting = true
HiddenCast("party1", 10); FlushTimers(); Expect("tradeskill cast: silent", {})
units.party1.crafting = nil
inCombat = true
HiddenCast("party1", 10); FlushTimers(); Expect("in combat: silent", {})
inCombat = false
HiddenCast("party2", 10); FlushTimers(); Expect("hidden cast by a non-mage: silent", {})
Fire("UNIT_SPELLCAST_START", "nameplate3", "Cast-P5", 10059); Expect("non-group units ignored", {})
units.player.class = "MAGE"
Fire("UNIT_SPELLCAST_START", "player", "Cast-P6", 10059); Expect("own portal", { "portal" })

-- ready check (party: player + party1..4; party4 offline and ignored)
local function Confirm(unit, ready)
	readyStatus[unit] = ready and "ready" or "notready"
	Fire("READY_CHECK_CONFIRM", unit, ready)
end
local function StartReadyCheck()
	for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do readyStatus[u] = "waiting" end
	Fire("READY_CHECK", "Someone", 35)
end
units.party4.offline = true
Check("migration: old ready check default becomes allReady", db.events.readyCheck.mode == "allReady")
db.events.readyCheck.mode = "both"
StartReadyCheck();               Advance(5)
Confirm("player", true); Confirm("party1", true); Confirm("party2", true)
Expect("start sound, nobody missing yet", { "bereitschaftscheck" })
Confirm("party3", true);         Expect("all ready (offline ignored)", { "bereitschaftscheck" })
db.events.readyCheck.mode = "allReady"
StartReadyCheck();               Expect("allReady mode: silent start", {})
Confirm("player", true); Confirm("party1", false); Confirm("party2", true); Confirm("party3", true)
Expect("someone declined: no all-ready sound", {})
db.events.readyCheck.mode = "start"
StartReadyCheck()
for _, u in ipairs({ "player", "party1", "party2", "party3" }) do Confirm(u, true) end
Expect("start mode: only the start sound", { "bereitschaftscheck" })
Fire("READY_CHECK_FINISHED", false)

-- options panel builds and lists render
SlashCmdList.DRACHENSOUNDS("")
FlushTimers()
local panel = _G.DrachensoundsOptionsFrame
Check("options panel shown", panel and panel:IsShown())
Check("client flavor detected", ns.IS_FOREVER == FOREVER)
table.insert(db.spells, { spell = "Unknown Spell", trigger = "ready", enabled = false })
panel:RefreshLists()
FlushTimers()
SlashCmdList.DRACHENSOUNDS("status")
SlashCmdList.DRACHENSOUNDS("aus")
Check("slash aus", db.enabled == false)
SlashCmdList.DRACHENSOUNDS("on")
Check("english alias on", db.enabled == true)
SlashCmdList.DRACHENSOUNDS("quatsch")

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
