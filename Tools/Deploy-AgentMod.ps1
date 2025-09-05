<#  Deploy-AgentMod.ps1
    Packages agent_<version> from your source tree and deploys the ZIP to:
      - Server mods:  D:\FactorioAI\mods
      - Client mods:  %APPDATA%\Factorio\mods
    Also enables the mod in mod-list.json on both sides and removes any same-version folder copy.
    A copy of the ZIP and this script is placed in OneDrive\Source (if OneDrive is present).

    USAGE:
      PowerShell -ExecutionPolicy Bypass -File D:\Source\FactorioAI\Deploy-AgentMod.ps1 `
        -ModName agent -ModVersion 0.0.1
#>

param(
  [string]$ProjectRoot   = "D:\Source\FactorioAI",
  [string]$ModSourceRoot = "D:\Source\FactorioAI\mods",
  [string]$ServerModsDir = "D:\FactorioAI\mods",
  [string]$ClientModsDir = "$env:APPDATA\Factorio\mods",
  [string]$ModName       = "agent",
  [string]$ModVersion    = "0.0.1"
)

$ErrorActionPreference = 'Stop'

function Ensure-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -Force -ItemType Directory -Path $p | Out-Null } }
function Read-Json([string]$path) { if (Test-Path $path) { Get-Content -Raw $path | ConvertFrom-Json } else { $null } }
function Write-Json([string]$path, $obj, [int]$depth=20) {
  Ensure-Dir (Split-Path -Parent $path)
  $json = $obj | ConvertTo-Json -Depth $depth
  [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
}

# --- 1) Package the mod (zip root = files, not extra folder) ---
$modFolder = Join-Path $ModSourceRoot ("{0}_{1}" -f $ModName, $ModVersion)
if (-not (Test-Path $modFolder)) { throw "Mod folder not found: $modFolder" }
$zipName   = "{0}_{1}.zip" -f $ModName, $ModVersion
$modZip    = Join-Path $ProjectRoot $zipName
if (Test-Path $modZip) { Remove-Item -Force $modZip }
Compress-Archive -Path (Join-Path $modFolder "*") -DestinationPath $modZip
Write-Host "Packaged: $modZip"

# --- 2) Copy ZIP to server + client and remove same-version folder copies ---
foreach ($dst in @($ServerModsDir, $ClientModsDir)) {
  Ensure-Dir $dst
  $dstZip = Join-Path $dst $zipName
  Copy-Item -Force $modZip $dstZip
  $dupFolder = Join-Path $dst ("{0}_{1}" -f $ModName, $ModVersion)
  if (Test-Path $dupFolder) { Remove-Item -Recurse -Force $dupFolder }
  Write-Host "Deployed to: $dstZip"
}

# --- 3) Enable mod in mod-list.json on both sides ---
function Enable-ModInList([string]$modsDir, [string]$name) {
  $mlPath = Join-Path $modsDir "mod-list.json"
  $ml = Read-Json $mlPath
  if (-not $ml) { $ml = @{ mods = @(@{ name = "base"; enabled = $true }) } }
  if (-not $ml.mods) { $ml = @{ mods = @(@{ name = "base"; enabled = $true }) } }

  $entry = $ml.mods | Where-Object { $_.name -eq $name }
  if ($entry) { $entry.enabled = $true } else { $ml.mods += @{ name = $name; enabled = $true } }

  Write-Json $mlPath $ml
  Write-Host "Enabled '$name' in $mlPath"
}
Enable-ModInList -modsDir $ServerModsDir -name $ModName
Enable-ModInList -modsDir $ClientModsDir -name $ModName

Write-Host ""
Write-Host "Done."
Write-Host "  Mod zip:      $modZip"
Write-Host "  Server mods:  $ServerModsDir"
Write-Host "  Client mods:  $ClientModsDir"
