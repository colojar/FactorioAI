<#
  Start-Factorio-RTSP.ps1
  Streams the Factorio game window to an RTSP server as H.264.

  Requirements:
  - ffmpeg available in PATH, or at a common install path (see probe below).
    Quick install on Windows: winget install Gyan.FFmpeg

  Examples:
    # Dry-run to see the exact ffmpeg command without running it
    powershell -ExecutionPolicy Bypass -File .\Tools\Start-Factorio-RTSP.ps1 -DryRun

    # Stream with libx264 instead of NVENC
    powershell -ExecutionPolicy Bypass -File .\Tools\Start-Factorio-RTSP.ps1 -VideoCodec libx264
#>

param(
  [Parameter(Mandatory = $false)] [string] $WindowTitle = "Factorio",
  [Parameter(Mandatory = $false)] [int]    $Framerate   = 30,
  [Parameter(Mandatory = $false)] [string] $VideoBitrate = "8M",
  [Parameter(Mandatory = $false)] [string] $RtspUrl     = "rtsp://pai.tripnet.be:8554/factorio",
  [ValidateSet('h264_nvenc','libx264')] [string] $VideoCodec = 'h264_nvenc',
  [Parameter(Mandatory = $false)] [string] $FfmpegPath,
  [switch] $DryRun
)

# Locate ffmpeg (PowerShell 5.1 compatible)
$ffmpeg = $null
if ($FfmpegPath) {
  if (Test-Path $FfmpegPath) {
    $ffmpeg = (Resolve-Path $FfmpegPath).Path
  } else {
    Write-Error "Specified -FfmpegPath '$FfmpegPath' does not exist."; exit 1
  }
} else {
  $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($cmd) { $ffmpeg = $cmd.Source }
}
if (-not $ffmpeg) {
  $candidates = @(
    "C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe",
    "C:\\ffmpeg\\bin\\ffmpeg.exe",
    (Join-Path $PSScriptRoot "..\\ffmpeg.exe")
  )
  foreach ($p in $candidates) {
    if (Test-Path $p) { $ffmpeg = $p; break }
  }
}
if (-not $ffmpeg) {
  if ($DryRun) {
    # Allow DryRun to proceed so the user can see the command that would run
    $ffmpeg = 'ffmpeg'
  } else {
    Write-Error "ffmpeg not found. Install with: winget install Gyan.FFmpeg"; exit 1
  }
}

# Select codec settings
$codecArgs = if ($VideoCodec -eq 'h264_nvenc') {
  @('-c:v','h264_nvenc','-preset','p5','-tune','ll')
} else {
  @('-c:v','libx264','-preset','veryfast','-tune','zerolatency')
}

# Build ffmpeg arguments (ensure we don't nest arrays)
$args = @(
  '-loglevel','warning',
  '-f','gdigrab','-framerate',$Framerate,'-i',"title=$WindowTitle",
  '-vf','scale=1280:-2'
) + $codecArgs + @(
  '-pix_fmt','yuv420p',
  '-b:v',$VideoBitrate,'-maxrate',$VideoBitrate,'-bufsize','16M',
  '-f','rtsp','-rtsp_transport','tcp',$RtspUrl
)

Write-Host "Using ffmpeg at $ffmpeg"
Write-Host "Streaming window '$WindowTitle' at ${Framerate}fps to $RtspUrl with $VideoCodec ($VideoBitrate)."

if ($DryRun) {
  Write-Host ("Dry run: `"{0}`" {1}" -f $ffmpeg, ($args -join ' '))
  exit 0
}

& $ffmpeg @args

exit $LASTEXITCODE