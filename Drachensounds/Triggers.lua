-- Event detection. Midnight (12.x) hides most combat data behind "secret values",
-- so every detector here uses an API that is documented as non-secret, or guards
-- with issecretvalue(), or (Bloodlust) lets Blizzard play the sound itself.
local ADDON_NAME, ns = ...

local issecretvalue = issecretvalue or function() return false end

local frame = CreateFrame("Frame")
local handlers = {}     -- event -> { fn, ... }
local unitFilter = {}   -- event -> unit list it is registered for, false = all units
frame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event]) do fn(...) end
end)

-- Adds a handler for a WoW event; any number of handlers may share one event.
-- With units given, fn only sees events for those units (a shared event with
-- different filters is registered for all units and filtered per handler).
local function On(event, fn, ...)
	local units = ... and { ... }
	if units then
		local inner = fn
		fn = function(unit, ...) if tContains(units, unit) then inner(unit, ...) end end
	end
	if not handlers[event] then
		handlers[event] = {}
		unitFilter[event] = units or false
		if units then frame:RegisterUnitEvent(event, unpack(units)) else frame:RegisterEvent(event) end
	elseif unitFilter[event] and not (units and table.concat(units, ",") == table.concat(unitFilter[event], ",")) then
		unitFilter[event] = false
		frame:RegisterEvent(event)
	end
	tinsert(handlers[event], fn)
end

-- Detection for each trigger, keyed like ns.EVENTS. InitTriggers only installs the
-- detectors of triggers available on the running client.
local detectors = {}
local function Detector(key, setup)
	detectors[key] = setup
end

-- Returns true/false, or nil when the answer is hidden.
local function IsDead(unit)
	if not UnitExists(unit) then return false end
	local dead = UnitIsDeadOrGhost(unit)
	if issecretvalue(dead) then return nil end
	if dead then
		local feign = UnitIsFeignDeath(unit)
		if feign and not issecretvalue(feign) then return false end
	end
	return dead and true or false
end

local function IsMe(unit)
	local me = UnitIsUnit(unit, "player")
	return me and not issecretvalue(me)
end

-- Spec role where specializations exist (Midnight); the assigned group role otherwise
-- (Forever is Classic-based and may report no specialization).
local function PlayerIsTank()
	local getSpec = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
	local index = getSpec and getSpec()
	if index and index > 0 then
		local role = select(5, C_SpecializationInfo.GetSpecializationInfo(index))
		if role then return role == "TANK" end
	end
	local assigned = UnitGroupRolesAssigned("player")
	return not issecretvalue(assigned) and assigned == "TANK"
end

---------------------------------------------------------------------------
-- Player death / resurrection / boss kill
---------------------------------------------------------------------------

Detector("playerDeath", function()
	On("PLAYER_DEAD", function() ns:Fire("playerDeath") end)
end)

Detector("resurrect", function()
	On("RESURRECT_REQUEST", function() ns:Fire("resurrect") end)
end)

Detector("bossKill", function()
	On("ENCOUNTER_END", function(_, _, _, _, success)
		if not issecretvalue(success) and success == 1 then ns:Fire("bossKill") end
	end)
end)

---------------------------------------------------------------------------
-- Group member and pet deaths
-- UnitIsDeadOrGhost is not secret in 12.x; UNIT_DIED gives a GUID that is secret
-- in restricted content, so it is only used as a "rescan now" hint (and to catch
-- pets that despawn on death, when the GUID is readable).
---------------------------------------------------------------------------

local groupUnits, groupDead = {}, {}
local petGUID, petDead = nil, false

local function RebuildGroup()
	wipe(groupUnits)
	wipe(groupDead)
	local prefix, count = "party", GetNumSubgroupMembers()
	if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end
	for i = 1, count do
		local unit = prefix .. i
		if not IsMe(unit) then
			groupUnits[unit] = true
			groupDead[unit] = IsDead(unit) or false
		end
	end
end

local function CheckGroupUnit(unit)
	local dead = IsDead(unit)
	if dead == nil then return end
	if dead and not groupDead[unit] then
		ns:Debug("Tod erkannt: %s", unit)
		ns:Fire("groupDeath")
	end
	groupDead[unit] = dead
end

local function SeedPet()
	if UnitExists("pet") then
		local guid = UnitGUID("pet")
		petGUID = not issecretvalue(guid) and guid or nil
		petDead = IsDead("pet") or false
	else
		petGUID, petDead = nil, false
	end
end

local function PetDied()
	if petDead then return end
	petDead = true
	ns:Fire("petDeath")
end

local function CheckPet()
	if not UnitExists("pet") then return end
	local dead = IsDead("pet")
	if dead == nil then return end
	if dead then PetDied() else petDead = false end
end

Detector("groupDeath", function()
	local function OnUnitChanged(unit)
		if groupUnits[unit] then CheckGroupUnit(unit) end
	end
	On("UNIT_HEALTH", OnUnitChanged)
	On("UNIT_FLAGS", OnUnitChanged)
	On("UNIT_DIED", function()
		for unit in pairs(groupUnits) do CheckGroupUnit(unit) end
	end)
end)

Detector("petDeath", function()
	On("UNIT_HEALTH", CheckPet, "pet")
	On("UNIT_FLAGS", CheckPet, "pet")
	On("UNIT_DIED", function(guid)
		if petGUID and not issecretvalue(guid) and guid == petGUID then PetDied() end
		CheckPet()
	end)
	On("UNIT_PET", function()
		if UnitExists("pet") then
			SeedPet()
		else
			-- keep the old GUID briefly so a late UNIT_DIED for a despawning pet still matches
			C_Timer.After(1, function() if not UnitExists("pet") then SeedPet() end end)
		end
	end, "player")
	On("PLAYER_ENTERING_WORLD", SeedPet)
end)

---------------------------------------------------------------------------
-- Boss aggro
-- UnitThreatSituation("player", bossN) is readable for the player's own threat
-- (Plater relies on this). If it ever comes back secret we fall back to the
-- boss's target, when unit tokens may be compared.
---------------------------------------------------------------------------

local MAX_BOSSES = MAX_BOSS_FRAMES or 8
local bossAggro = {}

local function HasAggro(boss)
	local status = UnitThreatSituation("player", boss)
	if not issecretvalue(status) then
		return (status or 0) >= 2
	end
	local target = boss .. "target"
	if C_Secrets and C_Secrets.CanCompareUnitTokens and C_Secrets.CanCompareUnitTokens("player", target) then
		local isMe = UnitIsUnit(target, "player")
		if not issecretvalue(isMe) then return isMe and true or false end
	end
	return nil
end

local function CheckBosses()
	local muted = ns.db.events.bossAggro.ignoreAsTank and PlayerIsTank()
	for i = 1, MAX_BOSSES do
		local boss = "boss" .. i
		if UnitExists(boss) then
			local aggro = HasAggro(boss)
			if aggro ~= nil then
				if aggro and not bossAggro[boss] and not muted then
					ns:Debug("Aggro von %s", boss)
					ns:Fire("bossAggro")
				end
				bossAggro[boss] = aggro
			end
		else
			bossAggro[boss] = nil
		end
	end
end

local function OnThreatEvent(unit)
	if unit == "player" or (unit and unit:find("^boss")) then CheckBosses() end
end

Detector("bossAggro", function()
	On("UNIT_THREAT_SITUATION_UPDATE", OnThreatEvent)
	On("UNIT_THREAT_LIST_UPDATE", OnThreatEvent)
	On("UNIT_TARGET", OnThreatEvent)
	On("INSTANCE_ENCOUNTER_ENGAGE_UNIT", CheckBosses)
	On("PLAYER_REGEN_ENABLED", function() wipe(bossAggro) end)
	On("PLAYER_ENTERING_WORLD", function() wipe(bossAggro) end)
end)

---------------------------------------------------------------------------
-- Spells: cooldown-ready list, per-spell cast / ready mappings
-- SpellCooldownInfo.isActive and .isOnGCD are NeverSecret, so readiness works in
-- combat. isOnGCD is only trustworthy inside SPELL_UPDATE_COOLDOWN, so transitions
-- *onto* cooldown are only taken from events; a ticker (running only while some
-- tracked spell is on cooldown) catches the transition back to ready.
---------------------------------------------------------------------------

local readyTracked = {}   -- spellID -> { onCD = bool }
local castByID, castByName = {}, {}
local ticker

function ns:ResolveSpell(text)
	text = strtrim(text or "")
	if text == "" then return nil end
	local info = C_Spell.GetSpellInfo(tonumber(text) or text)
	if info then return info.spellID, info.name, info.iconID end
end

local function OnRealCooldown(spellID, fromEvent)
	local info = C_Spell.GetSpellCooldown(spellID)
	if not info then return nil end
	if not info.isActive then return false end
	if fromEvent and info.isOnGCD then return false end
	local duration = info.duration
	if not issecretvalue(duration) and duration <= 1.5 then return false end
	return true
end

local function PlayCastSound(m)
	if not ns.db.enabled then return end
	if ns:Throttled(m, 0.5) then return end
	ns:Debug("Zauber gewirkt: %s (%s)", m.spell, tostring(m.sound))
	ns:PlaySound(m.sound)
end

local function SpellBecameReady(spellID)
	ns:Debug("Wieder bereit: %s", C_Spell.GetSpellName(spellID) or spellID)
	ns:Fire("cooldownReady")
end

local PollCooldowns

local function UpdateTicker()
	local anyOnCD = false
	for _, entry in pairs(readyTracked) do
		if entry.onCD then anyOnCD = true break end
	end
	if anyOnCD and not ticker then
		ticker = C_Timer.NewTicker(0.2, PollCooldowns)
	elseif not anyOnCD and ticker then
		ticker:Cancel()
		ticker = nil
	end
end

local function CheckCooldowns(fromEvent)
	for spellID, entry in pairs(readyTracked) do
		local onCD = OnRealCooldown(spellID, fromEvent)
		if onCD == true and fromEvent then
			entry.onCD = true
		elseif onCD == false and entry.onCD then
			entry.onCD = false
			SpellBecameReady(spellID)
		end
	end
	UpdateTicker()
end

function PollCooldowns() CheckCooldowns(false) end

local function AddCast(tbl, key, m)
	tbl[key] = tbl[key] or {}
	tinsert(tbl[key], m)
end

function ns:RebuildSpells()
	wipe(readyTracked)
	wipe(castByID)
	wipe(castByName)
	for _, m in ipairs(self.db.spells) do
		if m.enabled then
			local spellID, name = self:ResolveSpell(m.spell)
			if m.trigger == "cast" then
				if spellID then AddCast(castByID, spellID, m) end
				local key = (name or strtrim(m.spell or "")):lower()
				if key ~= "" and not tonumber(key) then AddCast(castByName, key, m) end
			elseif spellID and ns.EVENT_BY_KEY.cooldownReady then
				readyTracked[spellID] = { onCD = false }
			end
		end
	end
	-- seed silently so a rebuild never plays sounds
	for spellID, entry in pairs(readyTracked) do
		entry.onCD = OnRealCooldown(spellID, false) or false
	end
	UpdateTicker()
end

local rebuildPending
local function QueueRebuild()
	if rebuildPending then return end
	rebuildPending = true
	C_Timer.After(0.5, function()
		rebuildPending = false
		ns:RebuildSpells()
	end)
end

local function OnSpellCast(_, _, spellID)
	if issecretvalue(spellID) then return end
	local list = castByID[spellID]
	if not list then
		local name = C_Spell.GetSpellName(spellID)
		list = name and castByName[name:lower()]
	end
	if list then
		for _, m in ipairs(list) do PlayCastSound(m) end
	end
end

Detector("cooldownReady", function()
	On("SPELL_UPDATE_COOLDOWN", function() CheckCooldowns(true) end)
	On("SPELL_UPDATE_CHARGES", function() CheckCooldowns(true) end)
end)

-- The spell list itself (cast entries) is not a fixed trigger and runs on every client.
local function SetupSpellList()
	On("SPELLS_CHANGED", QueueRebuild)
	On("PLAYER_SPECIALIZATION_CHANGED", QueueRebuild, "player")
	On("TRAIT_CONFIG_UPDATED", QueueRebuild)
	On("UNIT_SPELLCAST_SUCCEEDED", OnSpellCast, "player")
end

---------------------------------------------------------------------------
-- Mage portals
-- Own casts: the spellID is readable, so a portal is any spell whose name contains
-- "Portal" (same word in the English and German clients), detected at cast start.
-- Other players' casts always carry a secret spellID (SecretWhenUnitSpellCastRestricted:
-- anyone but the player/pet). Heuristic instead: out of combat, a group mage finishes a
-- hidden ~10 s cast (portal, teleport or hearthstone) and is still visible shortly
-- after -> portal; teleports and hearthstones take the mage away. Fires when the
-- portal opens, not when the cast starts.
---------------------------------------------------------------------------

local PORTAL_MIN_CAST, PORTAL_MAX_CAST = 6, 11  -- seconds; base cast time is 10
local PORTAL_VISIBLE_CHECK = 2                   -- seconds after the cast succeeded
local hiddenCasts = {}                           -- unit -> GetTime() at cast start

local function IsMage(unit)
	local class = UnitClassBase(unit)
	return not issecretvalue(class) and class == "MAGE"
end

local function OnCastStart(unit, _, spellID)
	if not (unit == "player" or groupUnits[unit]) or not IsMage(unit) then return end
	if not issecretvalue(spellID) then
		local name = C_Spell.GetSpellName(spellID)
		if name and name:find("Portal", 1, true) then
			ns:Debug("Portal: %s (%s)", name, unit)
			ns:Fire("magePortal")
		end
		return
	end
	local isTradeskill = select(6, UnitCastingInfo(unit))  -- NeverSecret
	if isTradeskill == true or InCombatLockdown() then return end
	hiddenCasts[unit] = GetTime()
	ns:Debug("Verdeckter Zauber eines Magiers gestartet (%s)", unit)
end

local function OnHiddenCastSucceeded(unit)
	local started = hiddenCasts[unit]
	if not started then return end
	hiddenCasts[unit] = nil
	local elapsed = GetTime() - started
	if elapsed < PORTAL_MIN_CAST or elapsed > PORTAL_MAX_CAST then
		ns:Debug("Verdeckter Zauber (%s) dauerte %.1f s: kein Portal", unit, elapsed)
		return
	end
	C_Timer.After(PORTAL_VISIBLE_CHECK, function()
		local visible = UnitExists(unit) and UnitIsVisible(unit)
		if visible and not issecretvalue(visible) then
			ns:Debug("Portal erkannt (%s, %.1f s Zauberzeit)", unit, elapsed)
			ns:Fire("magePortal")
		else
			ns:Debug("Magier (%s) ist weg: Teleport oder Ruhestein", unit)
		end
	end)
end

local function OnCastEnded(unit)
	hiddenCasts[unit] = nil
end

Detector("magePortal", function()
	On("UNIT_SPELLCAST_START", OnCastStart)
	On("UNIT_SPELLCAST_SUCCEEDED", function(unit)
		if unit ~= "player" then OnHiddenCastSucceeded(unit) end
	end)
	On("UNIT_SPELLCAST_INTERRUPTED", OnCastEnded)
	On("UNIT_SPELLCAST_FAILED", OnCastEnded)
end)

---------------------------------------------------------------------------
-- Ready check: on start and/or once every connected member confirmed ready
---------------------------------------------------------------------------

local readyCheckRunning = false

local function ForEachGroupMember(fn)
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do fn("raid" .. i) end
	else
		fn("player")
		for i = 1, GetNumSubgroupMembers() do fn("party" .. i) end
	end
end

local function EveryoneReady()
	local allReady = true
	ForEachGroupMember(function(unit)
		if UnitExists(unit) and UnitIsConnected(unit) and GetReadyCheckStatus(unit) ~= "ready" then
			allReady = false
		end
	end)
	return allReady
end

local function ReadyCheckMode(mode)
	local cfgMode = ns.db.events.readyCheck.mode
	return cfgMode == mode or cfgMode == "both"
end

Detector("readyCheck", function()
	On("READY_CHECK", function()
		readyCheckRunning = true
		if ReadyCheckMode("start") then ns:Fire("readyCheck") end
	end)
	On("READY_CHECK_CONFIRM", function(_, isReady)
		if not readyCheckRunning or issecretvalue(isReady) then return end
		if not isReady then
			readyCheckRunning = false  -- someone declined: no "all ready" this time
		elseif EveryoneReady() then
			readyCheckRunning = false
			ns:Debug("Bereitschaftscheck: alle bereit")
			if ReadyCheckMode("allReady") then ns:Fire("readyCheck") end
		end
	end)
	On("READY_CHECK_FINISHED", function() readyCheckRunning = false end)
end)

---------------------------------------------------------------------------
-- Bloodlust / Heroism
-- Auras are secret in combat, so we register the sound with Blizzard via
-- C_UnitAuras.AddAuraSound on the exhaustion-type debuffs that every lust effect
-- applies. Registration is refused during encounters and in M+ combat, so it is
-- deferred until ADDON_RESTRICTION_STATE_CHANGED reports the restriction lifted.
-- Blizzard cuts these sounds off after 5 seconds.
---------------------------------------------------------------------------

local LUST_DEBUFFS = {
	57723,  -- Exhaustion (Heroism)
	57724,  -- Sated (Bloodlust)
	80354,  -- Temporal Displacement (Time Warp)
	264689, -- Fatigued (Primal Rage)
	390435, -- Exhaustion (Fury of the Aspects)
	95809,  -- Insanity (drums)
	160455, -- Fatigued (Netherwinds)
}
local auraHandles = {}
local auraRefreshPending = false

local function AuraSoundsRestricted()
	local isActive = C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive
	if not isActive then return false end
	local T = Enum.AddOnRestrictionType
	return isActive(T.Encounter) or (isActive(T.Combat) and isActive(T.ChallengeMode))
end

function ns:RefreshAuraSounds()
	if not (C_UnitAuras and C_UnitAuras.AddAuraSound) then return end
	if AuraSoundsRestricted() then
		auraRefreshPending = true
		return
	end
	auraRefreshPending = false
	for _, handle in ipairs(auraHandles) do pcall(C_UnitAuras.RemoveAuraSound, handle) end
	wipe(auraHandles)

	local def = ns.EVENT_BY_KEY.bloodlust
	if not (def and self.db.enabled and self.db.events.bloodlust.enabled and self:HasSound(def.files[1])) then return end
	local file = def.files[1]
	local trigger = Enum.UnitAuraSoundTrigger and Enum.UnitAuraSoundTrigger.Added or 0
	for _, spellID in ipairs(LUST_DEBUFFS) do
		local ok, handle = pcall(C_UnitAuras.AddAuraSound, trigger, {
			unitToken = "player",
			spellID = spellID,
			soundFileName = self:SoundPath(file),
			outputChannel = self.db.channel,
			throttleSeconds = 5,
		})
		if ok and handle then
			tinsert(auraHandles, handle)
		else
			self:Debug("Kampfrausch-Sound für %d nicht registriert: %s", spellID, tostring(handle))
		end
	end
	if #auraHandles == 0 then auraRefreshPending = true end
	self:Debug("Kampfrausch-Sounds registriert: %d", #auraHandles)
end

Detector("bloodlust", function()
	On("ADDON_RESTRICTION_STATE_CHANGED", function(_, state)
		-- restriction checks always read "inactive" during this event, so retry just after it
		if auraRefreshPending and state == Enum.AddOnRestrictionState.Inactive then
			C_Timer.After(0.2, function() ns:RefreshAuraSounds() end)
		end
	end)
end)

---------------------------------------------------------------------------

function ns:OnConfigChanged()
	self:RebuildSpells()
	self:RefreshAuraSounds()
end

local function Count(tbl)
	local n = 0
	for _ in pairs(tbl) do n = n + 1 end
	return n
end

local function JaNein(v) return v and "ja" or "nein" end

function ns:PrintStatus()
	self:Print("Version %s (%s), aktiviert: %s, Kanal: %s", C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?",
		ns.IS_FOREVER and "Forever" or "Midnight", JaNein(self.db.enabled), ns.CHANNEL_LABELS[self.db.channel] or self.db.channel)
	self:Print("Kampfrausch-Sounds registriert: %d%s", #auraHandles,
		auraRefreshPending and " (ausstehend, gerade eingeschränkt)" or "")
	self:Print("Überwachte Abklingzeiten: %d, Zauber beim Wirken: %d per ID / %d per Name",
		Count(readyTracked), Count(castByID), Count(castByName))
	self:Print("Überwachte Gruppenmitglieder: %d, Begleiter erkannt: %s", Count(groupUnits), JaNein(petGUID ~= nil))
	self:Print("Auslöser in diesem Client: %d von %d", #ns.EVENTS, #ns.ALL_EVENTS)
end

function ns:InitTriggers()
	-- shared state used by several detectors
	On("GROUP_ROSTER_UPDATE", RebuildGroup)
	On("PLAYER_ENTERING_WORLD", RebuildGroup)
	for _, def in ipairs(ns.EVENTS) do
		if detectors[def.key] then detectors[def.key]() end
	end
	SetupSpellList()
	On("PLAYER_ENTERING_WORLD", function() ns:OnConfigChanged() end)
end
