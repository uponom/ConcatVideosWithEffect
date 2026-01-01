<#
.SYNOPSIS
  Concatenate 2 videos with a video transition (xfade) and audio crossfade (acrossfade),
  re-encoding the result with encoding parameters closely matching the first input file.

.REQUIREMENTS
  - ffmpeg and ffprobe must be available in PATH.

.USAGE
  .\Join-2VideosWithTransition.ps1 -Input1 .\a.mp4 -Input2 .\b.mp4 -Output .\out.mp4 `
    -Transition slideleft -TransitionDuration 1.0 -TransitionOffset 5.0

.NOTES
  - When applying a video effect, stream copy (-c copy) is not possible: re-encoding is required.
  - The script takes encoding parameters from Input1 and applies them to the output.
  - The second clip is adapted to the resolution/FPS/pix_fmt of the first clip so xfade works reliably.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$Input1,

  [Parameter(Mandatory=$true)]
  [string]$Input2,

  [Parameter(Mandatory=$true)]
  [string]$Output,

  # xfade transitions: allowed values validated by ValidateSet
  [ValidateSet('fade','wipeleft','wiperight','wipeup','wipedown','slideleft','slideright','slideup','slidedown','circleopen','circleclose','vertopen','vertclose','hlslice','hrslice','squeeze','distance','fadeblack','fadewhite', IgnoreCase=$true)]
  [string]$Transition = "wipedown",

  # Transition duration in seconds
  [double]$TransitionDuration = 1.0,

  # Time (seconds) in the first video when the transition starts
  [double]$TransitionOffset = 5.0,

  # If the source has no video bitrate, use default CRF
  [int]$DefaultCrf = 18,

  # If the source has no audio bitrate, use this (in bps)
  [int]$DefaultAudioBitrate = 192000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Tool([string]$name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Tool '$name' not found in PATH. Install ffmpeg/ffprobe and add to PATH."
  }
}

function Get-FFProbeJson([string]$file) {
  $json = & ffprobe -v error -print_format json -show_format -show_streams -- "$file"
  if (-not $json) { throw "ffprobe returned no data for file: $file" }
  return $json | ConvertFrom-Json
}

function Parse-FractionToDouble([string]$frac) {
  # "30000/1001" -> 29.970...
  if ([string]::IsNullOrWhiteSpace($frac)) { return $null }
  if ($frac -notmatch '^\s*(\d+)\s*/\s*(\d+)\s*$') { return $null }
  $num = [double]$Matches[1]
  $den = [double]$Matches[2]
  if ($den -eq 0) { return $null }
  return $num / $den
}

function Pick-VideoEncoder([string]$codecName, [bool]$useNvidia = $false) {
  # If NVidia is available and requested, prefer nvenc encoders
  if ($useNvidia) {
    switch -Regex ($codecName) {
      '^h264$'  { return 'h264_nvenc' }
      '^(hevc|h265)$' { return 'hevc_nvenc' }
    }
  }

  switch -Regex ($codecName) {
    '^h264$'  { return 'libx264' }
    '^(hevc|h265)$' { return 'libx265' }
      '^av1$'   { return 'libaom-av1' }  # not always 1:1 for parameters, but encodes AV1
      default   { return $null }         # unknown -> let ffmpeg pick, but better to fail early
  }
}

function Get-NvidiaCapabilities() {
  # Check ffmpeg for CUDA hwaccel, NVENC encoders and CUVID decoders
  $hwaccels = & ffmpeg -hide_banner -hwaccels 2>&1 | Out-String
  $encoders = & ffmpeg -hide_banner -encoders 2>&1 | Out-String
  $decoders = & ffmpeg -hide_banner -decoders 2>&1 | Out-String

  $hasCuda = $hwaccels -match '\bcuda\b'
  $hasNvenc = $encoders -match 'nvenc'
  $hasCuvid = $decoders -match 'cuvid'

  return @{ HasCuda = [bool]$hasCuda; HasNvenc = [bool]$hasNvenc; HasCuvid = [bool]$hasCuvid; Encoders = $encoders; Decoders = $decoders }
}

function Pick-AudioEncoder([string]$codecName) {
  switch -Regex ($codecName) {
    '^aac$'  { return 'aac' }
    '^mp3$'  { return 'libmp3lame' }
    '^opus$' { return 'libopus' }
    '^vorbis$' { return 'libvorbis' }
    '^flac$' { return 'flac' }
    default  { return $null }
  }
}

Assert-Tool ffmpeg
Assert-Tool ffprobe

# Detect NVidia hardware acceleration capabilities (NVENC/CUVID)
$nvidia = Get-NvidiaCapabilities
$UseNvidia = ($nvidia.HasCuda -and $nvidia.HasNvenc -and $nvidia.HasCuvid)

# On Windows, ensure nvcuda.dll is present (drivers). If not, disable NVidia path.
if ($UseNvidia -and $IsWindows) {
  $cudaDllPaths = @(
    (Join-Path $env:SystemRoot 'System32\nvcuda.dll'),
    (Join-Path $env:SystemRoot 'SysWOW64\nvcuda.dll')
  )
  $cudaPresent = $false
  foreach ($p in $cudaDllPaths) { if (Test-Path $p) { $cudaPresent = $true; break } }
  if (-not $cudaPresent) {
    Write-Host "nvcuda.dll not found — NVidia drivers not available. Falling back to software encoders." -ForegroundColor Yellow
    $UseNvidia = $false
  }
}

# Final NVidia availability message (after driver check)
if ($UseNvidia) {
  Write-Host "NVidia CUDA/NVENC/CUVID available — will attempt hardware decode/encode." -ForegroundColor Green
} else {
  Write-Host "NVidia hardware acceleration not available or incomplete — using software paths." -ForegroundColor Yellow
}


# Capture a short nvidia-smi snapshot (if available) for logs
$nvSmiOutput = $null
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
  try {
    $nvSmiOutput = & nvidia-smi -q -d MEMORY,UTILIZATION 2>&1 | Out-String
  } catch {
    $nvSmiOutput = (& nvidia-smi 2>&1) | Out-String
  }
  Write-Host "nvidia-smi snapshot:" -ForegroundColor Cyan
  Write-Host $nvSmiOutput -ForegroundColor DarkCyan
} else {
  Write-Host "nvidia-smi not found in PATH; skipping GPU snapshot." -ForegroundColor Yellow
}
# (Transition validation moved to param() via ValidateSet)

function SafeAddRange([System.Collections.Generic.List[string]]$list, [object]$items, [string]$label) {
  try {
    $arr = @()
    if ($null -eq $items) {
      return
    }
    if ($items -is [System.Collections.IEnumerable] -and -not ($items -is [string])) {
      foreach ($it in $items) {
        if ($it -ne $null) { $arr += [string]$it } else { $arr += "" }
      }
    } else {
      $arr += [string]$items
    }
    $list.AddRange([string[]]$arr)
  } catch {
    Write-Host "SafeAddRange failed for $label. Items type: $($items.GetType().FullName)" -ForegroundColor Red
    Write-Host $_.Exception.ToString() -ForegroundColor Red
    throw
  }
}

# --- Read parameters from the first file ---
$meta1 = Get-FFProbeJson $Input1

 $vid1 = $meta1.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
if (-not $vid1) { throw "No video stream found in $Input1." }

$aud1 = $meta1.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1
# audio may be absent — output will be video-only

# Probe second input as well (used for input-specific decoder decision)
$meta2 = Get-FFProbeJson $Input2
$vid2 = $meta2.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
if (-not $vid2) { throw "No video stream found in $Input2." }

$width  = [int]$vid1.width
$height = [int]$vid1.height

# FPS: prefer avg_frame_rate, otherwise r_frame_rate (needed for frame-accurate offset)
$fpsVal = Parse-FractionToDouble ($vid1.avg_frame_rate)
if (-not $fpsVal -or $fpsVal -le 0) { $fpsVal = Parse-FractionToDouble ($vid1.r_frame_rate) }
if (-not $fpsVal -or $fpsVal -le 0) { $fpsVal = 30.0 }
$fps = [math]::Round($fpsVal, 3)
$fpsExact = $fpsVal

# --- Duration of the first file (seconds) and automatic transition start offset ---
$duration1 = $null
if ($meta1.format -and $meta1.format.PSObject.Properties.Name -contains 'duration' -and $meta1.format.duration) {
  $duration1 = [double]::Parse($meta1.format.duration, [System.Globalization.CultureInfo]::InvariantCulture)
} elseif ($vid1.PSObject.Properties.Name -contains 'duration' -and $vid1.duration) {
  $duration1 = [double]::Parse($vid1.duration, [System.Globalization.CultureInfo]::InvariantCulture)
}

if ($null -ne $duration1) {
  # Compute offset in frame units to avoid dropping/duplicating frames due to floating point rounding.
  $frameCount1 = [int][math]::Round($duration1 * $fpsExact)
  $transitionFrames = [int][math]::Round([double]$TransitionDuration * $fpsExact)
  $offsetFrames = [int][math]::Max(0, ($frameCount1 - $transitionFrames))
  $autoOffset = [double]$offsetFrames / $fpsExact
  $autoOffset = [double]([math]::Round($autoOffset, 6))
  Write-Host "Auto-computed TransitionOffset = $autoOffset (frames: $offsetFrames of $frameCount1; duration=$duration1, transition duration=$TransitionDuration)" -ForegroundColor Cyan
  $TransitionOffset = $autoOffset
} else {
  Write-Host "Warning: could not determine duration of $Input1; using TransitionOffset=$TransitionOffset" -ForegroundColor Yellow
}


if ($vid1.PSObject.Properties.Name -contains 'pix_fmt' -and $vid1.pix_fmt) { 
  $pixFmt = [string]$vid1.pix_fmt 
} else { 
  $pixFmt = "yuv420p" 
}

# When using NVENC, map 10-bit pixel format to the encoder-expected format
if ($UseNvidia -and $pixFmt -eq 'yuv420p10le') {
  $outPixFmt = 'p010le'
} else {
  $outPixFmt = $pixFmt
}

# Pixel format used inside CPU filter graph: use standard yuv420p10le for 10-bit
if ($outPixFmt -eq 'p010le') {
  $filterPixFmt = 'yuv420p10le'
} else {
  $filterPixFmt = $pixFmt
}

$videoCodec = [string]$vid1.codec_name
# Force H.265 output per user request: prefer NVENC when available, otherwise libx265
if ($UseNvidia) {
  $videoEnc = 'hevc_nvenc'
} else {
  $videoEnc = 'libx265'
}
if (-not $videoEnc) {
  throw "Unknown encoder mapping for codec_name='$videoCodec'. Add mapping in Pick-VideoEncoder."
}

# Bitrate/quality: if the video stream has a bit_rate — use it as target -b:v.
# Note: this does not guarantee identical mode (CBR/VBR), but approximates it.
$videoBitrate = $null
if ($vid1.PSObject.Properties.Name -contains "bit_rate" -and $vid1.bit_rate) {
  $videoBitrate = [int64]$vid1.bit_rate
}

# Profile/level (apply for H.264/H.265, but values can be strings)
if ($vid1.PSObject.Properties.Name -contains 'profile' -and $vid1.profile) { 
  $profile = [string]$vid1.profile 
} else { 
  $profile = $null 
}

if ($vid1.PSObject.Properties.Name -contains 'level' -and $vid1.level) { 
  $level = [string]$vid1.level 
} else { 
  $level = $null 
}

# Color metadata (if present)
if ($vid1.PSObject.Properties.Name -contains 'color_primaries' -and $vid1.color_primaries) { 
  $colorPrimaries = [string]$vid1.color_primaries 
} else { 
  $colorPrimaries = $null 
}

if ($vid1.PSObject.Properties.Name -contains 'color_transfer' -and $vid1.color_transfer) { 
  $colorTrc = [string]$vid1.color_transfer 
} else { 
  $colorTrc = $null 
}

if ($vid1.PSObject.Properties.Name -contains 'colorspace' -and $vid1.colorspace) { 
  $colorspace = [string]$vid1.colorspace 
} else { 
  $colorspace = $null 
}

# --- Audio parameters ---
$audioEnc = $null
$audioCodec = $null
$audioBitrate = $null
$audioRate = $null
$audioChannels = $null

if ($aud1) {
  $audioCodec = [string]$aud1.codec_name
  $audioEnc = Pick-AudioEncoder $audioCodec
  if (-not $audioEnc) {
    throw "Unknown audio encoder mapping for codec_name='$audioCodec'. Add mapping in Pick-AudioEncoder."
  }

  if ($aud1.PSObject.Properties.Name -contains "bit_rate" -and $aud1.bit_rate) {
    $audioBitrate = [int64]$aud1.bit_rate
  } else {
    $audioBitrate = [int64]$DefaultAudioBitrate
  }

  if ($aud1.PSObject.Properties.Name -contains "sample_rate" -and $aud1.sample_rate) {
    $audioRate = [int]$aud1.sample_rate
  } else {
    $audioRate = 48000
  }

  if ($aud1.PSObject.Properties.Name -contains "channels" -and $aud1.channels) {
    $audioChannels = [int]$aud1.channels
  } else {
    $audioChannels = 2
  }
}

# --- Build filter_complex ---
# Normalize both inputs to match the first input's parameters:
# - scale to (width,height)
# - fps to fps
# - format to pixFmt
# For audio, normalize sample_rate/channel_layout so acrossfade behaves predictably.
$filterParts = New-Object System.Collections.Generic.List[string]

$scaleFps = "scale=$($width):$($height),fps=$($fps.ToString([System.Globalization.CultureInfo]::InvariantCulture))"
if ($UseNvidia) {
  # Choose appropriate hwdownload format per input based on source pix_fmt (10-bit -> p010le, else nv12)
  $inPix0 = if ($vid1.PSObject.Properties.Name -contains 'pix_fmt' -and $vid1.pix_fmt) { [string]$vid1.pix_fmt } else { 'yuv420p' }
  $inPix1 = if ($vid2.PSObject.Properties.Name -contains 'pix_fmt' -and $vid2.pix_fmt) { [string]$vid2.pix_fmt } else { 'yuv420p' }

  $dl0 = if ($inPix0 -match '10le') { 'p010le' } else { 'nv12' }
  $dl1 = if ($inPix1 -match '10le') { 'p010le' } else { 'nv12' }

  $filterParts.Add("[0:v]hwdownload,format=$dl0,$scaleFps,format=$($filterPixFmt)[v0]")
  $filterParts.Add("[1:v]hwdownload,format=$dl1,$scaleFps,format=$($filterPixFmt)[v1]")
} else {
  $filterParts.Add("[0:v]$scaleFps,format=$($filterPixFmt)[v0]")
  $filterParts.Add("[1:v]$scaleFps,format=$($filterPixFmt)[v1]")
}
$filterParts.Add("[v0][v1]xfade=transition=$($Transition):duration=$($TransitionDuration.ToString([System.Globalization.CultureInfo]::InvariantCulture)):offset=$($TransitionOffset.ToString([System.Globalization.CultureInfo]::InvariantCulture))[v]")

if ($aud1) {
  # Channels: 1 -> mono, 2 -> stereo, otherwise leave unconstrained (but attempt conversion)
  $layout = switch ($audioChannels) {
    1 { "mono" }
    2 { "stereo" }
    default { $null }
  }

  if ($layout) {
    $filterParts.Add("[0:a]aformat=sample_rates=$($audioRate):channel_layouts=$($layout)[a0]")
    $filterParts.Add("[1:a]aformat=sample_rates=$($audioRate):channel_layouts=$($layout)[a1]")
  } else {
    $filterParts.Add("[0:a]aresample=$($audioRate)[a0]")
    $filterParts.Add("[1:a]aresample=$($audioRate)[a1]")
  }

  $filterParts.Add("[a0][a1]acrossfade=d=$($TransitionDuration.ToString([System.Globalization.CultureInfo]::InvariantCulture))[a]")
}

$filterComplex = ($filterParts -join "; ")

# --- Video encoding arguments ---
$videoArgs = New-Object System.Collections.Generic.List[string]
SafeAddRange $videoArgs @("-c:v", $videoEnc) "videoArgs: -c:v"

# Profile/level apply to some encoders; usually ok for libx264/libx265.
if ($profile -and ($videoEnc -in @("libx264","libx265"))) {
  # Normalize profile: remove spaces and lowercase (e.g., "Main 10" -> "main10")
  $profNorm = ($profile -replace '\s+', '')
  SafeAddRange $videoArgs @("-profile:v", ($profNorm.ToLower())) "videoArgs: profile"
}
if ($level -and ($videoEnc -in @("libx264","libx265"))) {
  # ffprobe level may be numeric like 41 => "4.1" (for h264). Try to convert.
  # If it's already dotted string — leave as is.
  $lvlStr = $level
  if ($lvlStr -match '^\d+$') {
    # 41 -> 4.1, 31 -> 3.1, 40 -> 4.0
    if ($lvlStr.Length -ge 2) {
      $lvlStr = $lvlStr.Substring(0, $lvlStr.Length-1) + "." + $lvlStr.Substring($lvlStr.Length-1, 1)
    }
  }
  SafeAddRange $videoArgs @("-level:v", $lvlStr) "videoArgs: level"
}

$null = $outPixFmt # ensure variable exists for debug
SafeAddRange $videoArgs @("-pix_fmt", $outPixFmt) "videoArgs: pix_fmt"
SafeAddRange $videoArgs @("-r", $fps.ToString([System.Globalization.CultureInfo]::InvariantCulture)) "videoArgs: r"

# Color metadata (if present)
if ($colorPrimaries) { SafeAddRange $videoArgs @("-color_primaries", $colorPrimaries) "videoArgs: color_primaries" }
if ($colorTrc)       { SafeAddRange $videoArgs @("-color_trc", $colorTrc) "videoArgs: color_trc" }
if ($colorspace)     { SafeAddRange $videoArgs @("-colorspace", $colorspace) "videoArgs: colorspace" }

# Quality/bitrate
if ($videoBitrate -and $videoBitrate -gt 0) {
  # match source target bitrate
  SafeAddRange $videoArgs @("-b:v", $videoBitrate.ToString()) "videoArgs: b:v"
  # soften VBV settings (not always appropriate, but often helps maintain level)
  SafeAddRange $videoArgs @("-maxrate", $videoBitrate.ToString()) "videoArgs: maxrate"
  SafeAddRange $videoArgs @("-bufsize", ([int64]($videoBitrate * 2)).ToString()) "videoArgs: bufsize"
} else {
  # If source provided no bitrate — use CRF
  if ($videoEnc -in @("libx264","libx265")) {
    SafeAddRange $videoArgs @("-crf", $DefaultCrf.ToString()) "videoArgs: crf"
  } elseif ($videoEnc -eq "libaom-av1") {
    # for AV1 in aom CRF logic differs; use cq-level
    SafeAddRange $videoArgs @("-crf", $DefaultCrf.ToString()) "videoArgs: crf"
  }
}

# sensible default presets (cannot be extracted from stream)
if ($videoEnc -in @("libx264","libx265")) {
  SafeAddRange $videoArgs @("-preset", "medium") "videoArgs: preset"
}

# --- Audio encoding arguments ---
$audioArgs = New-Object System.Collections.Generic.List[string]
$mapArgs = New-Object System.Collections.Generic.List[string]
$null = $mapArgs
SafeAddRange $mapArgs @("-map", "[v]") "mapArgs: map v"

if ($aud1) {
  SafeAddRange $mapArgs @("-map", "[a]") "mapArgs: map a"
  SafeAddRange $audioArgs @("-c:a", $audioEnc) "audioArgs: c:a"
  SafeAddRange $audioArgs @("-b:a", $audioBitrate.ToString()) "audioArgs: b:a"
  SafeAddRange $audioArgs @("-ar", $audioRate.ToString()) "audioArgs: ar"
  if ($audioChannels) {
    SafeAddRange $audioArgs @("-ac", $audioChannels.ToString()) "audioArgs: ac"
  }
} else {
  # if the first file has no audio — produce output without audio
  $audioArgs.Add("-an")
}

# --- Собираем и запускаем ffmpeg ---
# Start ffmpeg args and force overwrite so ffmpeg won't prompt
$ffArgs = New-Object System.Collections.Generic.List[string]
SafeAddRange $ffArgs @("-y") "ffArgs: overwrite"

# Build input arguments; if NVidia hwaccel available, provide global hwaccel flags and
# prefer CUVID decoders for supported codecs (so decoding can use GPU).
if ($UseNvidia) {
  SafeAddRange $ffArgs @("-hwaccel", "cuda", "-hwaccel_output_format", "cuda") "ffArgs: hwaccel"

  # map a few common codecs to their CUVID decoder names
  $decoderMap = @{ 'h264' = 'h264_cuvid'; 'hevc' = 'hevc_cuvid'; 'mpeg2' = 'mpeg2_cuvid'; 'vc1' = 'vc1_cuvid' }

  $inputArgs = @()
  foreach ($pair in @(@{File=$Input1; Vid=$vid1}, @{File=$Input2; Vid=$vid2})) {
    $decOpt = $null
    if ($pair.Vid -and $pair.Vid.codec_name) {
      $c = [string]$pair.Vid.codec_name
      if ($decoderMap.ContainsKey($c)) {
        $cand = $decoderMap[$c]
        if ($nvidia.Decoders -match $cand) { $decOpt = $cand }
      }
    }
    if ($decOpt) {
      $inputArgs += @("-c:v", $decOpt, "-i", $pair.File)
    } else {
      $inputArgs += @("-i", $pair.File)
    }
  }

  SafeAddRange $ffArgs $inputArgs "ffArgs: inputs with hwdec"
} else {
  SafeAddRange $ffArgs @("-y", "-i", $Input1, "-i", $Input2) "ffArgs: inputs"
}
SafeAddRange $ffArgs @("-filter_complex", $filterComplex) "ffArgs: filter_complex"
SafeAddRange $ffArgs $mapArgs "ffArgs: mapArgs"
SafeAddRange $ffArgs $videoArgs "ffArgs: videoArgs"
SafeAddRange $ffArgs $audioArgs "ffArgs: audioArgs"

# faststart for mp4 (if mp4 container)
$ext = [IO.Path]::GetExtension($Output).ToLowerInvariant()
if ($ext -eq ".mp4" -or $ext -eq ".m4v") {
  SafeAddRange $ffArgs @("-movflags", "+faststart") "ffArgs: movflags"
}

$ffArgs.Add($Output)

Write-Host "Running ffmpeg with the following arguments:" -ForegroundColor Cyan
Write-Host ("ffmpeg " + ($ffArgs -join " ")) -ForegroundColor DarkCyan
# Planned decode mode for logging
$plannedDecode = if ($UseNvidia) { 'hw' } else { 'sw' }
Write-Host "Planned decode mode: $plannedDecode" -ForegroundColor Cyan
$attemptUsedHw = $false
if ($plannedDecode -eq 'hw') { Write-Host "Attempting hardware decode (CUVID) ..." -ForegroundColor Cyan; $attemptUsedHw = $true } else { Write-Host "Using software decode ..." -ForegroundColor Cyan }

# Primary attempt: hardware decode (if requested) + chosen encoder
& ffmpeg @ffArgs

if ($LASTEXITCODE -eq 0) {
  if ($attemptUsedHw) { Write-Host "Used hw decode (CUVID)" -ForegroundColor Green } else { Write-Host "Used sw decode" -ForegroundColor Green }
}
if ($LASTEXITCODE -ne 0 -and $UseNvidia) {
  Write-Host "Hardware decode path failed (ffmpeg exit $LASTEXITCODE). Retrying with software decode and NVENC encode..." -ForegroundColor Yellow

  # Rebuild filter_complex for software decode (no hwdownload)
  $filterParts2 = New-Object System.Collections.Generic.List[string]
  $scaleFps = "scale=$($width):$($height),fps=$($fps.ToString([System.Globalization.CultureInfo]::InvariantCulture))"
  $filterParts2.Add("[0:v]$scaleFps,format=$($filterPixFmt)[v0]")
  $filterParts2.Add("[1:v]$scaleFps,format=$($filterPixFmt)[v1]")
  $filterParts2.Add("[v0][v1]xfade=transition=$($Transition):duration=$($TransitionDuration.ToString([System.Globalization.CultureInfo]::InvariantCulture)):offset=$($TransitionOffset.ToString([System.Globalization.CultureInfo]::InvariantCulture))[v]")

  if ($aud1) {
    $layout = switch ($audioChannels) {1 { "mono" } 2 { "stereo" } default { $null }}
    if ($layout) {
      $filterParts2.Add("[0:a]aformat=sample_rates=$($audioRate):channel_layouts=$($layout)[a0]")
      $filterParts2.Add("[1:a]aformat=sample_rates=$($audioRate):channel_layouts=$($layout)[a1]")
    } else {
      $filterParts2.Add("[0:a]aresample=$($audioRate)[a0]")
      $filterParts2.Add("[1:a]aresample=$($audioRate)[a1]")
    }
    $filterParts2.Add("[a0][a1]acrossfade=d=$($TransitionDuration.ToString([System.Globalization.CultureInfo]::InvariantCulture))[a]")
  }

  $filterComplex2 = ($filterParts2 -join "; ")

  # Build ffmpeg args for software-decode + (prefer) NVENC encode
  $ffArgs2 = New-Object System.Collections.Generic.List[string]
  SafeAddRange $ffArgs2 @("-y", "-i", $Input1, "-i", $Input2) "ffArgs2: inputs"
  SafeAddRange $ffArgs2 @("-filter_complex", $filterComplex2) "ffArgs2: filter_complex"
  SafeAddRange $ffArgs2 $mapArgs "ffArgs2: mapArgs"

  # Ensure encoder selection: prefer NVENC if available, otherwise fall back to libx265
  if ($nvidia.HasNvenc) {
    # replace any existing -c:v in videoArgs with NVENC
    $videoArgs2 = New-Object System.Collections.Generic.List[string]
    SafeAddRange $videoArgs2 @("-c:v", "hevc_nvenc") "videoArgs2: c:v"
    foreach ($a in $videoArgs) { if ($a -ne '-c:v' -and $a -ne 'libx265' -and $a -ne 'hevc_nvenc' -and $a -ne 'libx264' -and $a -ne 'h264_nvenc') { $videoArgs2.Add($a) } }
  } else {
    $videoArgs2 = $videoArgs
  }

  SafeAddRange $ffArgs2 $videoArgs2 "ffArgs2: videoArgs"
  SafeAddRange $ffArgs2 $audioArgs "ffArgs2: audioArgs"
  if ($ext -eq ".mp4" -or $ext -eq ".m4v") { SafeAddRange $ffArgs2 @("-movflags", "+faststart") }
  $ffArgs2.Add($Output)

  Write-Host "Retrying ffmpeg with software decode (NVENC encode if available):" -ForegroundColor Cyan
  Write-Host ("ffmpeg " + ($ffArgs2 -join " ")) -ForegroundColor DarkCyan
  & ffmpeg @ffArgs2
  if ($LASTEXITCODE -ne 0) { throw "ffmpeg exited with error code: $LASTEXITCODE" } else { Write-Host "Used sw decode (fallback)" -ForegroundColor Green }
}

if ($LASTEXITCODE -ne 0) { throw "ffmpeg exited with error code: $LASTEXITCODE" }

Write-Host "Done: $Output" -ForegroundColor Green
