-- Optional: switch off noisy game sounds in dungeons and raids, so the game has
-- fewer sounds to juggle and drops ours less often when it runs out of channels.
-- The values found on entering are kept in db.cvarBackup (SavedVariables), so they
-- are restored on leaving even after a /reload or crash inside an instance.
local _, ns = ...

-- Each option switches these CVars to "0" inside instances.
ns.INSTANCE_SOUND_OPTIONS = {
	{ key = "armorFoley", cvars = { "Sound_EnableArmorFoleySoundForSelf", "Sound_EnableArmorFoleySoundForOthers" },
	  label = "Rüstungsgeräusche ausschalten",
	  tooltip = "Rüstungsgeräusche von dir und anderen Spielern." },
	{ key = "pets", cvars = { "Sound_EnablePetSounds" },
	  label = "Begleitergeräusche ausschalten",
	  tooltip = "Geräusche von Begleitern und Tieren." },
}

local function GetCVar(name)
	return C_CVar.GetCVar(name)
end

-- An option is only offered when this client has all of its CVars.
function ns:InstanceSoundOptionAvailable(option)
	for _, cvar in ipairs(option.cvars) do
		if GetCVar(cvar) == nil then return false end
	end
	return true
end

local function InSoundReducedInstance()
	local inInstance, kind = IsInInstance()
	return inInstance and (kind == "party" or kind == "raid")
end

function ns:UpdateInstanceSounds()
	local backup = self.db.cvarBackup
	local inside = InSoundReducedInstance()
	for _, option in ipairs(ns.INSTANCE_SOUND_OPTIONS) do
		local mute = inside and self.db.instanceSounds[option.key] and self:InstanceSoundOptionAvailable(option)
		for _, cvar in ipairs(option.cvars) do
			local current = GetCVar(cvar)
			if current == nil then
				backup[cvar] = nil
			elseif mute then
				if backup[cvar] == nil then backup[cvar] = current end
				if current ~= "0" then C_CVar.SetCVar(cvar, "0") end
			elseif backup[cvar] ~= nil then
				-- only undo our own change: if the user switched it back on meanwhile, keep that
				if current == "0" then C_CVar.SetCVar(cvar, backup[cvar]) end
				backup[cvar] = nil
			end
		end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:SetScript("OnEvent", function()
	if ns.db then ns:UpdateInstanceSounds() end
end)
