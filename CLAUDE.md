# Drachensounds — agent notes

WoW addon that plays custom mp3s on game events, for Midnight retail (12.1.5, Interface 120105) and WoW Forever (1.60.1, Interface 16001) from one codebase. Config UI via `/dsounds`.

## Clients (Midnight + Forever)

- Forever ("Camelot" internally, `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` = 18 → `ns.IS_FOREVER`) is Classic content on the Midnight engine. One TOC lists both interfaces (`## Interface: 120105, 16001`); no per-flavor TOC or code fork.
- Verified against wow-ui-source branch `forever` (1.60.1.70450): every documented API and event the addon uses, their secret-value flags and the secret predicates are identical to `live`. The UI templates resolve to the same Mainline variants (Forever adds a Camelot overlay). Re-run that diff when adding APIs: compare `Blizzard_APIDocumentationGenerated` entries between the `live` and `forever` branches.
- Content differences are handled at runtime, not by flavor checks: tank detection falls back from spec role to `UnitGroupRolesAssigned` (Forever may have no specializations). Bloodlust IDs that don't exist on a client simply never fire.
- Clients: `_retail_` (Midnight), `_classic_beta_` (Forever beta), `_forever_` (Forever live) under `C:\Program Files (x86)\World of Warcraft`. `deploy.ps1` mirrors into every installed one (`-Clients` to pick). Smoke test both flavors: `DS_FLAVOR=forever` simulates Forever.

## Layout

- `Drachensounds/` — the addon folder that gets deployed (TOC lists load order).
  - `Core.lua` — namespace, `ns.EVENTS` (the fixed event list: keys, German labels/tooltips, the hardcoded sound `files` per event, default throttles — the single source of truth for those), SavedVariables defaults/merge/migration, sound playback, slash command.
  - `Triggers.lua` — all event detection, spell tracking, Bloodlust aura-sound registration.
  - `Options.lua` — the config panel (plain frames, no libraries) + stub entry in Esc > Options > AddOns.
  - `Sounds.lua` — **generated** list of bundled sounds. Never edit by hand.
  - `sounds/*.mp3` — the bundled subset of the library, renamed after their event (origins below).
- `sound-library/` — the full sound collection (~800 mp3s), local only (git-ignored, never published). Only a picked subset is copied into the addon; never bundle the whole library.
- `sound-sources/` — full-length originals of sounds fetched from elsewhere (YouTube via yt-dlp), kept so clips can be re-cut by hand. Local only (git-ignored), never bundled.
- `tools/deploy.ps1` — add/remove bundled sounds (`-Add quelle=ziel` copies `sound-library/quelle.mp3` as `ziel.mp3`; `-Remove`), regenerate `Sounds.lua`, mirror the addon into `Interface\AddOns\Drachensounds` of every installed client (see Clients).
- `tests/smoke.lua` — offline test against a mocked WoW API: `"/c/Program Files (x86)/Lua/5.1/lua.exe" tests/smoke.lua` (run from repo root; once more with `DS_FLAVOR=forever`). Syntax check: `luac -p Drachensounds/*.lua` (same folder). Update the scenarios when trigger behaviour changes.

## Workflow

1. Edit, then run the smoke test.
2. `powershell -File tools/deploy.ps1` to deploy. In game, `/reload` picks up Lua changes; **newly added sound files need a full client restart**.
3. `/dsounds debug` prints a chat line whenever a trigger fires; `/dsounds status` dumps tracking state. Use these when the user reports something not firing.

Sound names are file base names without `.mp3`; the addon only knows sounds listed in `Sounds.lua`.

## Sound model

- The 8 fixed events play hardcoded files (`files` in `ns.EVENTS`); users can only enable/disable them. Events with several files (pet death, resurrection) have `cfg.variant`: 0 = alternate in rotation (default), n = always `files[n]` (`ns:EventFile`).
- Rate limiting: `ns:Fire` drops an event fired within `cfg.throttle or def.throttle` seconds of its last played sound. Group death exposes `cfg.throttle` in the UI (default 2 s) so wipes don't stack sounds.
- One spell list (`db.spells`): each entry is either `ready` (plays the `cooldownReady` event's file, gated by that event's checkbox) or `cast` (plays the entry's own `sound`, picked from all bundled sounds — the only sound picker in the addon).
- Origins of the bundled files in `sound-library/` (needed if a sound is ever re-picked):
  `spielertod`=arschlocha, `haustiertod_1/2/3`=ambodenrumgruebbeln1/2/3, `gruppentod`=wiedumm, `bossaggro`=dannsollerherkommen, `bosssieg`=mikropimmel2, `abklingzeit_bereit`=dakommtwiederwas, `kampfrausch`=aufdieichbockhab, `wiederbelebung_1`=nimmdiesescheissedaan, `wiederbelebung_2`=niemandunterkriegen, `wiederbelebung_3`=niemalsbesiegen.
  From `sound-sources/` (yt-dlp is `%USERPROFILE%\Downloads\yt-dlp.exe`; pass `--ffmpeg-location` and `-x`): `portal` = `portal-full.opus` (youtube.com/watch?v=C-qdCf-d-HI) 43.5–45 s, −4.6 dB, 15 ms fades; `bereitschaftscheck` = `readycheck-full.opus` (youtube.com/watch?v=lv-mD3qtalw) 12.4 s–end, 15 ms fade-in.
- Loudness: no bundled sound may be louder than `kampfrausch` (−11.8 LUFS integrated). Louder files get lowered with a plain gain change, e.g. `ffmpeg -i in.mp3 -af volume=-7.7dB -c:a libmp3lame -q:a 2 out.mp3`; measure with `-af ebur128 -f null -`. ffmpeg is at `%USERPROFILE%\Downloads\ffmpeg-9.0.2-essentials_build\bin` (not on PATH). Already applied: `haustiertod_1/2/3` were lowered to −11.8, and `wiederbelebung_1` to about −18 to match its siblings. Re-copying any of these from the library undoes it.
- Metadata: bundled files carry no tags (no ID3v1/v2, no Xing/LAME info header). Strip after every ffmpeg step with a stream copy: `ffmpeg -i in.mp3 -map 0:a -c:a copy -map_metadata -1 -id3v2_version 0 -write_id3v1 0 -write_xing 0 -fflags +bitexact -flags:a +bitexact out.mp3`. This adds ~30–50 ms of encoder padding (no gapless info left), which is inaudible here. LAME's version string remains in frame padding bits; that's accepted. Copies from `sound-library/` arrive tagged.
- `DrachensoundsDB.version` 3. `Migrate` in Core.lua converts the pre-release v1 layout (per-event `sound`, `cooldownSpells`, `spellSounds`), flips the old v2 ready-check default "both" to "allReady", and remaps renamed cast sounds via `RENAMED_SOUNDS` — add to that map whenever a bundled file is renamed or removed.

## Midnight restrictions (why detection works the way it does)

12.x makes most combat data "secret" for addon code (no math/comparison/branching on it; `issecretvalue(v)` tests it). COMBAT_LOG_EVENT_UNFILTERED is unavailable. Detection choices, verified against Blizzard's generated API docs (`Blizzard_APIDocumentationGenerated` in github.com/Gethe/wow-ui-source, branch `live`; flags like `NeverSecret`, `SecretWhen…`):

- Player death / resurrection / boss kill: `PLAYER_DEAD`, `RESURRECT_REQUEST`, `ENCOUNTER_END` (success == 1). Not restricted.
- Group / pet deaths: `UnitIsDeadOrGhost` is not secret → state-diffing on `UNIT_HEALTH`/`UNIT_FLAGS`. `UNIT_DIED(guid)` exists but its GUID is secret when unit identity is restricted, so it's only a rescan hint plus pet-GUID match for pets that despawn on death.
- Boss aggro: `UnitThreatSituation("player", bossN) >= 2` (player's own threat is readable; Plater relies on it). Fallback: `UnitIsUnit("bossNtarget", "player")` when `C_Secrets.CanCompareUnitTokens` allows.
- Cooldown ready: `C_Spell.GetSpellCooldown` → `isActive` and `isOnGCD` are `NeverSecret`; `startTime`/`duration` can be secret. `isOnGCD` is only reliable inside `SPELL_UPDATE_COOLDOWN`, so "went on cooldown" is taken from events only and a 0.2 s ticker (only while something is on cooldown) catches "ready again". Charge spells count as ready when the first charge returns.
- Mage portals: cast info (spellID, `UnitCastingInfo`) is **always** secret for anyone but the player/pet (`SecretWhenUnitSpellCastRestricted`), in or out of combat. Own casts: `UNIT_SPELLCAST_START` spell name containing "Portal" (enUS/deDE; teleports don't match). Group mages (`UnitClassBase == "MAGE"`): heuristic — out of combat, a hidden non-tradeskill cast lasting 6–11 s that succeeds, with the mage still `UnitIsVisible` 2 s later = portal (teleport/hearthstone remove the mage). So for others it fires when the portal opens, not at cast start.
- Ready check: `READY_CHECK` (start) and `READY_CHECK_CONFIRM` (not secret) + `GetReadyCheckStatus` over all connected members for "all ready"; any decline cancels the all-ready sound. `cfg.mode` = start / allReady (default) / both.
- Spell casts: `UNIT_SPELLCAST_SUCCEEDED` for `player` has a readable spellID; mappings match by resolved spellID, then by spell name (covers overrides).
- Bloodlust: auras are secret in combat, so `C_UnitAuras.AddAuraSound` registers the sound with the game on the Sated/Exhaustion-family debuffs (Blizzard plays it, cut at 5 s, throttle ≤ 5 s). Registration is refused during encounters and M+ combat → deferred until `ADDON_RESTRICTION_STATE_CHANGED` reports inactive. Lust debuff IDs live in `Triggers.lua`.

Installed addons worth grepping for current API usage: BigWigs (`BigWigs_Plugins/Sound.lua`, `Auras.lua`), Plater, NorthernSkyRaidTools, Decursive (`Dcr_12_1_Sounds.lua`). The user's M33kAuras is outdated — don't trust it.

## Conventions

- Audience is German only. Every user-facing string (UI, tooltips, chat, TOC notes) is German: plain, short, du-form, no filler or joke text (the user rejected an over-the-top bureaucratic version). Code, comments and docs stay English. Slash subcommands are German with English aliases (`SLASH_ALIASES` in Core.lua).
- Lua 5.1, tabs, no external libraries. Files are UTF-8 without BOM (umlauts are fine).
- SavedVariables `DrachensoundsDB` (account-wide). Defaults are merged on load (`ApplyDefaults` in Core.lua) — add new settings there rather than migrating by hand.
- Any setting change calls `ns:OnConfigChanged()` (rebuilds spell tracking + aura sounds).
