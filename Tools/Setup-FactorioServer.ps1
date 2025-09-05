# Setup-FactorioServer.ps1 (Revised w/ diagnostics)
# Purpose: Set up a headless Factorio server workspace + mods on Windows
# - Uses a custom config.ini passed via -c 
# - Creates a save with a specific seed
# - Writes a Start-Server.bat
# - Adds robust logging/diagnostics for save creation (captures stdout/stderr)
#
# Usage (PowerShell as Admin is recommended only if your D: root is ACL-restricted):
#   PowerShell -ExecutionPolicy Bypass -File D:\Source\FactorioAI\Setup-FactorioServer.ps1

param(
  [string]$FactorioExe = "D:\\SteamLibrary\\steamapps\\common\\Factorio\\bin\\x64\\factorio.exe",
  [string]$DataDir     = "D:\\FactorioAI",
  [string]$SaveName    = "aiworld.zip",
  [string]$Seed        = "0627218724",
  [int]$GamePort       = 34197,
  [int]$RconPort       = 27015,
  [switch]$VerboseLogs
)

$ErrorActionPreference = 'Stop'

function Out-JsonFile($Path, $Object) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -Force -ItemType Directory -Path $dir | Out-Null }
  $json = $Object | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function New-RconPassword([int]$len=24) {
  -join ((48..57 + 65..90 + 97..122) | Get-Random -Count $len | ForEach-Object {[char]$_})
}

function Get-FactorioVersion([string]$exe) {
  if (-not (Test-Path $exe)) { throw "factorio.exe not found at $exe" }
  try { ((& $exe '--version' 2>&1) -join "`n").Trim() } catch { return '' }
}

function Run-Factorio([string]$exe, [string[]]$args, [string]$logPrefix) {
  $out = "$logPrefix`_stdout.log"
  $err = "$logPrefix`_stderr.log"
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($args -join ' ')
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdOut = $p.StandardOutput.ReadToEnd()
  $stdErr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  [IO.File]::WriteAllText($out, $stdOut)
  [IO.File]::WriteAllText($err, $stdErr)
  if ($VerboseLogs) {
    Write-Host "\n[Factorio stdout]" -ForegroundColor Cyan
    Write-Host $stdOut
    Write-Host "\n[Factorio stderr]" -ForegroundColor Yellow
    Write-Host $stdErr
  }
  return $p.ExitCode
}

# --- 1) Show version ---
$ver = Get-FactorioVersion $FactorioExe
Write-Host "Using: $FactorioExe"
Write-Host "Version: $ver"

# --- 2) Layout ---
$SavesDir  = Join-Path $DataDir "saves"
$ModsDir   = Join-Path $DataDir "mods"
$ConfigDir = Join-Path $DataDir "config"
$LogsDir   = Join-Path $DataDir "logs"
$ScriptOut = Join-Path $DataDir "script-output"
$null = New-Item -Force -ItemType Directory -Path $SavesDir,$ModsDir,$ConfigDir,$LogsDir,$ScriptOut

# --- 3) config.ini: set write-data/read-data ---
$configIniPath = Join-Path $ConfigDir "config.ini"
$config = @"
[path]
read-data=__PATH__executable__/../../data
write-data=$($DataDir -replace '\\','/')
"@
[IO.File]::WriteAllText($configIniPath, $config, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $configIniPath"

# --- 4) server-settings.json ---
$RconPassword = New-RconPassword
$ServerSettings = @{
  name = "FactorioAI"
  description = "AI playground server"
  tags = @("ai","dev")
  max_players = 16
  visibility = @{ public = $false; lan = $true }
  username = ""
  password = ""
  game_password = ""
  require_user_verification = $true
  max_upload_in_kilobytes_per_second = 0
  max_upload_slots = 5
  afk_autokick_interval = 0
  allow_commands = "admins-only"
  autosave_interval = 10
  autosave_slots = 3
  auto_pause = $false
  only_admins_can_pause_the_game = $true
  non_blocking_saving = $true
}
$ServerSettingsPath = Join-Path $ConfigDir "server-settings.json"
Out-JsonFile $ServerSettingsPath $ServerSettings
Write-Host "Wrote $ServerSettingsPath"

# --- 5) Create save with seed (w/ diagnostics + fallback) ---
$SavePath = Join-Path $SavesDir $SaveName
$SeedInt = try { [int]$Seed } catch { 0 }

if (-not (Test-Path $SavePath)) {
  Write-Host "Creating save at $SavePath (seed=$SeedInt) ..."
  $args = @('-c', '"' + $configIniPath + '"', '--mod-directory', '"' + $ModsDir + '"', '--create', '"' + $SavePath + '"', '--map-gen-seed', $SeedInt)
  $exit = Run-Factorio -exe $FactorioExe -args $args -logPrefix (Join-Path $LogsDir 'create')
  if ($exit -ne 0 -or -not (Test-Path $SavePath)) {
    Write-Warning "Create via custom config failed (exit=$exit). Attempting fallback create to TEMP using default paths…"
    $tmp = Join-Path $env:TEMP "aiworld_tmp.zip"
    if (Test-Path $tmp) { Remove-Item -Force $tmp }
    $exit2 = Run-Factorio -exe $FactorioExe -args @('--create', '"' + $tmp + '"', '--map-gen-seed', $SeedInt) -logPrefix (Join-Path $LogsDir 'create_fallback')
    if ($exit2 -eq 0 -and (Test-Path $tmp)) {
      Move-Item -Force $tmp $SavePath
      Write-Host "Created save via fallback and moved to $SavePath"
    } else {
      Write-Error "Failed to create save. See logs under $LogsDir (create_stdout/stderr.log and create_fallback_*)."
      throw "Create failed."
    }
  } else {
    Write-Host "Created save: $SavePath"
  }
} else {
  Write-Host "Save already exists: $SavePath"
}

# --- 6) Mods (optional auto-download; requires Mod Portal creds) ---
function Get-ModPortalCreds() {
  $u = $env:FACTORIO_USERNAME; $t = $env:FACTORIO_TOKEN
  if ($u -and $t) { return @{ username=$u; token=$t } }
  $playerData = Join-Path $env:APPDATA "Factorio\\player-data.json"
  if (Test-Path $playerData) {
    $pd = Get-Content -Raw $playerData | ConvertFrom-Json
    if ($pd."service-username" -and $pd."service-token") {
      return @{ username=$pd."service-username"; token=$pd."service-token" }
    }
  }
  return $null
}

function Get-ModRelease($ModName, $PreferMajor = "2.") {
  $api = "https://mods.factorio.com/api/mods/$ModName/full"
  $full = Invoke-RestMethod -UseBasicParsing -Method GET -Uri $api
  if (-not $full.releases) { throw "No releases for $ModName" }
  $rel = $full.releases |
    Sort-Object { [version]($_.version) } -Descending |
    Where-Object { $_.info_json.factorio_version -like "$PreferMajor*" } |
    Select-Object -First 1
  if (-not $rel) { $rel = $full.releases | Sort-Object { [version]($_.version) } -Descending | Select-Object -First 1 }
  return @{
    file_name    = $rel.file_name
    download_url = "https://mods.factorio.com$($rel.download_url)"
    version      = $rel.version
  }
}

function Download-Mod($ModName, $ModsDir, $Creds) {
  if (-not (Test-Path $ModsDir)) { New-Item -Force -ItemType Directory -Path $ModsDir | Out-Null }
  $rel = Get-ModRelease -ModName $ModName
  $dest = Join-Path $ModsDir $rel.file_name
  if (Test-Path $dest) { Write-Host "Already present: $($rel.file_name)"; return $dest }
  $url = if ($Creds) { "$($rel.download_url)?username=$($Creds.username)&token=$($Creds.token)" } else { $rel.download_url }
  try {
    Write-Host "Downloading $ModName $($rel.version) ..."
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
    Write-Host "Downloaded: $dest"
  } catch {
    Write-Warning "Auto-download failed for $ModName. Provide FACTORIO_USERNAME/FACTORIO_TOKEN or download manually to $ModsDir."
    throw
  }
  return $dest
}

$ModNames = @("even-distribution","GhostScanner4","squeak-through-2")
$modList = @{ mods = @(@{name="base";enabled=$true}) + ($ModNames | ForEach-Object { @{ name = $_; enabled = $true } }) }
$ModListPath = Join-Path $ModsDir "mod-list.json"
Out-JsonFile $ModListPath $modList
Write-Host "Wrote $ModListPath"

$creds = Get-ModPortalCreds
if ($creds) {
  foreach ($m in $ModNames) { Download-Mod -ModName $m -ModsDir $ModsDir -Creds $creds }
} else {
  Write-Warning "Mod Portal credentials not found; skipping auto-download."
}

# --- 7) Start-Server.bat ---
$bat = @"
@echo off
set FAC="`"$FactorioExe`""
set CFG="`"$configIniPath`""
set SAVE="`"$SavePath`""
set SETTINGS="`"$ServerSettingsPath`""
set MODDIR="`"$ModsDir`""

REM Game UDP $GamePort ; RCON TCP $RconPort
"%FAC%" -c %CFG% --mod-directory %MODDIR% ^
  --start-server %SAVE% --server-settings %SETTINGS% ^
  --port $GamePort --rcon-port $RconPort --rcon-password "$RconPassword"

pause
"@
$batPath = Join-Path $DataDir "Start-Server.bat"
[IO.File]::WriteAllText($batPath, $bat, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $batPath"

# --- 8) Summary ---
Write-Host ""
Write-Host "Workspace   : $DataDir"
Write-Host "Save        : $SavePath"
Write-Host "Server port : $GamePort (UDP)"
Write-Host "RCON        : $RconPort"
Write-Host "Mods        : $($ModNames -join ', ')"
Write-Host "Logs        : $LogsDir"
Write-Host "Next        : Double-click $batPath to start the server; join 127.0.0.1:$GamePort"
