# Drachensounds

WoW addon (Midnight and WoW Forever) for a German audience that plays sounds on deaths, boss aggro/kills, Bloodlust, resurrections, mage portals, ready checks, cooldowns and spell casts. The addon itself is the `Drachensounds/` folder.

- Deploy to all installed WoW clients: `powershell -File tools/deploy.ps1`
- Bundle more sounds (for "on cast" entries): `powershell -File tools/deploy.ps1 -Add quelle=neuername,quelle2`, then restart WoW (needs a local `sound-library/` folder, not part of this repo)
- Build a release zip: `powershell -File tools/release.ps1` (writes `release/Drachensounds-<version>.zip`)
- In game: `/dsounds` opens the settings (`/dsounds debug` shows what fires)
- Test offline: `"C:\Program Files (x86)\Lua\5.1\lua.exe" tests/smoke.lua`
