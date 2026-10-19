<#
.SYNOPSIS
  Builds release\Drachensounds-<version>.zip from the Drachensounds/ addon folder.

.DESCRIPTION
  The version comes from "## Version:" in Drachensounds.toc. Before zipping it
  regenerates Sounds.lua and runs the smoke test for both clients; any failure
  aborts. The zip contains the Drachensounds folder at its root (what CurseForge
  and manual installs into Interface\AddOns expect) and uses "/" in entry names.

.EXAMPLE
  .\tools\release.ps1           # build the zip for the current version
  .\tools\release.ps1 -Force    # overwrite an existing zip of the same version
#>
param(
    [switch]$Force,
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)
$ErrorActionPreference = "Stop"

$repo  = Split-Path $PSScriptRoot -Parent
$addon = Join-Path $repo "Drachensounds"
$toc   = Join-Path $addon "Drachensounds.toc"

$version = (Select-String -Path $toc -Pattern '^## Version:\s*(\S+)').Matches.Groups[1].Value
if (-not $version) { throw "No '## Version:' line in $toc" }

$outDir = Join-Path $repo "release"
$zip = Join-Path $outDir "Drachensounds-$version.zip"
if ((Test-Path $zip) -and -not $Force) { throw "$zip already exists (bump the version or pass -Force)" }

# Keep the sound manifest in sync with sounds/ (no deploy).
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "deploy.ps1") -NoDeploy
if ($LASTEXITCODE) { throw "deploy.ps1 -NoDeploy failed" }

# Smoke test both clients.
Push-Location $repo
try {
    foreach ($flavor in "midnight", "forever") {
        $env:DS_FLAVOR = $flavor
        $result = & $Lua tests/smoke.lua | Select-Object -Last 1
        if ($LASTEXITCODE) { throw "smoke test failed ($flavor): $result" }
        Write-Host "tests ($flavor): $result"
    }
} finally {
    Remove-Item Env:DS_FLAVOR -ErrorAction SilentlyContinue
    Pop-Location
}

# Zip with forward-slash entry names (Compress-Archive on PowerShell 5.1 writes "\").
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force $outDir | Out-Null
if (Test-Path $zip) { Remove-Item $zip }
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem $addon -Recurse -File | Sort-Object FullName | ForEach-Object {
        $entry = "Drachensounds/" + $_.FullName.Substring($addon.Length + 1).Replace("\", "/")
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
}
Write-Host ("built {0} ({1:N0} KB)" -f $zip, ((Get-Item $zip).Length / 1KB))
