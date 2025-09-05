<#  Setup-VideoStream.ps1  (fixed interpolation)
    Writes:
      - Tools\Start-Factorio-RTSP.ps1  (Windows: capture Factorio window with FFmpeg and PUSH via RTSP)
      - pi_rtsp_hailo.sh               (Pi: pull RTSP and run GStreamer + Hailo inference)
    Copies both to OneDrive\Source if present.

    USAGE:
      PowerShell -ExecutionPolicy Bypass -File D:\Source\FactorioAI\Setup-VideoStream.ps1 `
        -PiHost pai.tripnet.be -HefPath /home/pi/models/yolov5.hef
#>

param(
  [string]$ProjectRoot = "D:\Source\FactorioAI",
  [string]$PiHost      = "raspberrypi.local",
  [int]$RtspPort       = 8554,
  [string]$RtspName    = "factorio",
  [string]$WindowTitle = "Factorio",
  [int]$Framerate      = 30,
  [string]$Bitrate     = "8M",
  [ValidateSet('h264_nvenc','libx264')] [string]$Encoder = "h264_nvenc",
  [string]$HefPath     = "/home/pi/models/yolov5.hef"
)

$ErrorActionPreference = 'Stop'
function Ensure-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -Force -ItemType Directory -Path $p | Out-Null } }

# Build RTSP URL safely (avoid $Var:scope parsing)
$rtspUrl = "rtsp://{0}:{1}/{2}" -f $PiHost, $RtspPort, $RtspName

# --- 1) Write Windows capture (RTSP push) ---
$toolsDir = Join-Path $ProjectRoot "Tools"
Ensure-Dir $toolsDir
$capturePs1 = Join-Path $toolsDir "Start-Factorio-RTSP.ps1"

$cap = @"
<# Start-Factorio-RTSP.ps1
   Push the Factorio window as H.264 RTSP to $rtspUrl
   Requires ffmpeg in PATH. Quick install:
     winget install Gyan.FFmpeg
#>
param(
  [string]$WindowTitle = "$WindowTitle",
  [int]$Framerate = $Framerate,
  [string]$Bitrate = "$Bitrate",
  [string]$RtspUrl = "$rtspUrl",
  [ValidateSet('h264_nvenc','libx264')] [string]$Encoder = "$Encoder"
)

# Locate ffmpeg
$ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue)?.Source
if (-not $ffmpeg) {
  $candidates = @("C:\Program Files\ffmpeg\bin\ffmpeg.exe","C:\ffmpeg\bin\ffmpeg.exe","$PSScriptRoot\ffmpeg.exe")
  foreach ($c in $candidates) { if (Test-Path $c) { $ffmpeg = $c; break } }
}
if (-not $ffmpeg) { Write-Error "ffmpeg not found. Install: winget install Gyan.FFmpeg"; exit 1 }

$encArgs = if ($Encoder -eq "h264_nvenc") {
  @("-c:v","h264_nvenc","-preset","p5","-tune","ll")
} else {
  @("-c:v","libx264","-preset","veryfast","-tune","zerolatency")
}

# NOTE: This pushes to an RTSP server at `$RtspUrl` (e.g., MediaMTX on the Pi).
$argList = @(
  "-loglevel","warning",
  "-f","gdigrab","-framerate",$Framerate,"-i","title=$($WindowTitle)",
  "-vf","scale=1280:-2",
  $encArgs,
  "-pix_fmt","yuv420p",
  "-b:v",$Bitrate,"-maxrate",$Bitrate,"-bufsize","16M",
  "-f","rtsp","-rtsp_transport","tcp",$RtspUrl
)

Write-Host "Streaming Factorio window to $RtspUrl ..."
& $ffmpeg $argList
"@
[IO.File]::WriteAllText($capturePs1, $cap, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote: $capturePs1"

# --- 2) Write Pi-side RTSP+Hailo helper ---
$piScript = Join-Path $ProjectRoot "pi_rtsp_hailo.sh"
$pi = @"
#!/usr/bin/env bash
set -euo pipefail

RTSP_URL="$rtspUrl"
HEF_PATH="\${1:-$HefPath}"

if [ ! -f "$HefPath" ] && [ ! -f "\$HEF_PATH" ]; then
  echo "HEF not found. Pass path as first arg or set in script."; exit 2
fi
[ -f "\$HEF_PATH" ] || HEF_PATH="$HefPath"

# Requires: GStreamer with Hailo plugins (hailonet, hailooverlay, etc.)
# And an RTSP server receiving the push (e.g., mediamtx) on the Pi:
#   mediamtx &

GST_DEBUG=1 gst-launch-1.0 -v \
  rtspsrc location="\$RTSP_URL" protocols=tcp latency=100 ! \
    rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! videoscale ! \
    video/x-raw,format=RGB,width=1280,height=720 ! \
    hailonet hef-path="\$HEF_PATH" ! queue ! hailooverlay ! \
    videoconvert ! autovideosink sync=false

# Replace autovideosink with fakesink or appsink to go fully headless.
"@
[IO.File]::WriteAllText($piScript, $pi, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote: $piScript"

# --- 3) Copy both to OneDrive\Source (if available) ---
$oneDriveRoot = $env:OneDriveCommercial; if (-not $oneDriveRoot) { $oneDriveRoot = $env:OneDrive }
if (-not $oneDriveRoot) { $oneDriveRoot = Join-Path $env:UserProfile "OneDrive" }
if ($oneDriveRoot -and (Test-Path $oneDriveRoot)) {
  $odSrc = Join-Path $oneDriveRoot "Source"
  Ensure-Dir $odSrc
  Copy-Item -Force $capturePs1 $odSrc
  Copy-Item -Force $piScript $odSrc
  Copy-Item -Force $PSCommandPath $odSrc
  Write-Host "Copied to OneDrive: $odSrc"
} else {
  Write-Warning "OneDrive not detected; skipped OneDrive copy."
}

Write-Host ""
Write-Host "Done."
Write-Host "  Windows: $capturePs1    (run this to start streaming)"
Write-Host "  Pi:      $piScript      (scp to Pi; run with HEF path if different)"
Write-Host "  RTSP:    $rtspUrl"
