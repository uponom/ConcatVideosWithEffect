# ConcatVideosWithEffect

Tool to concatenate two video files with a visual transition (ffmpeg `xfade`) and an audio crossfade (`acrossfade`).

This repository contains a single PowerShell script, `cvwe.ps1`, that:

- extracts key encoding parameters from the first input video (resolution, fps, color information, bitrate, audio sample rate/channels);
- computes a frame-accurate transition offset so the visual `xfade` and audio `acrossfade` align correctly;
- builds a filter graph that applies scaling/fps normalization, the video `xfade` transition, and an audio `acrossfade` transition;
- re-encodes the merged result to HEVC (H.265) while trying to preserve the important parameters from the first input;
- attempts to use NVIDIA hardware acceleration (CUVID/NVDEC for decode and NVENC for encode) when available, and automatically falls back to software decoding/encoding if hardware support is missing or incompatible.

The script aims to produce a single output file with a smooth visual/audio transition and encoding parameters close to the first source.

---

## Features

- Frame-accurate video transition using `xfade` (many transition types supported).
- Audio crossfade using `acrossfade` to avoid abrupt audio cuts.
- Automatic probing of the first input with `ffprobe` to reuse resolution, fps, pixel format and audio settings when reasonable.
- Optional NVIDIA hardware acceleration (if `ffmpeg` build and system drivers support it); safe software fallback if drivers/builds are missing or fail.
- Preserves 10-bit color where possible (script handles `yuv420p10le` and maps formats as required).
 - New: folder-mode (`-InputFolder`) — merge all video files from a directory into a single output using chained `xfade`+`acrossfade` transitions.

---

## Requirements

- PowerShell 7 (pwsh) or newer.
- `ffmpeg` and `ffprobe` in PATH (build with nvenc/cuvid support if you want GPU acceleration).
- Optional: NVIDIA drivers + `nvidia-smi` available in PATH to produce a GPU snapshot in logs.

Note: The script verifies presence of the NVIDIA driver DLL (`nvcuda.dll`) on Windows before declaring GPU support. If drivers are missing or incompatible, the script falls back to software paths.

---

## Quick start / Usage

Open PowerShell and run the script with the two input files and desired output path. Example:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\cvwe.ps1 `
  -Input1 'C:\path\to\input1.mp4' `
  -Input2 'C:\path\to\input2.mp4' `
  -Output 'C:\path\to\output.mp4'
```

Folder mode (merge all videos from a directory):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\cvwe.ps1 `
	-InputFolder 'C:\path\to\videos' `
	-Output 'C:\path\to\output.mp4'
```

Notes about folder mode:
- The script scans `-InputFolder` and selects files with common video extensions (mkv, mp4, avi, mov, webm, m4v, ts, mpg, mpeg, flv, wmv).
- Files are sorted by name and chained in that order; each adjacent pair receives an `xfade`+`acrossfade` at a computed offset near the end of the preceding clip.
- The script excludes the output file (if present in the input folder) to avoid re-processing previous runs.
- If an input file lacks audio, the script generates silence of the same duration so `acrossfade` can proceed smoothly.

The script accepts additional optional parameters (check the script header for `param()` usage). Common parameters you may see or tweak inside the script:

- `-Transition` — transition type for `xfade` (many transitions supported by ffmpeg; the script validates allowed names).
- `-TransitionDuration` — length of the visual/audio transition in seconds (default: 1s in the shipped script).

Example (explicit transition):

```powershell
pwsh -File .\cvwe.ps1 -Input1 inputA.mp4 -Input2 inputB.mp4 -Output out.mp4 -Transition wipeleft -TransitionDuration 1
```

After running, the script prints status messages about planned decode mode (hw/sw), any GPU snapshot info, and final outcome.

---

## What the script does (internals)

1. Probes the first input with `ffprobe` (JSON) to extract video and audio stream parameters: codec, width, height, fps (exact rational parsed to a floating value), pixel format, color primaries/transfer, audio sample rate, channels, and bitrates.
2. Computes an exact TransitionOffset in frames and seconds so the `xfade` happens at the expected frame boundary (avoids visible timing drift between audio and video).
3. Builds an `ffmpeg` `-filter_complex` that:
	- individually scales and normalizes fps/pixel format for each input stream;
	- applies `xfade` between the two video streams at the computed offset;
	- applies `aformat`/`aresample` and `acrossfade` for audio.
4. Decoding path:
	- The script calls a helper to detect whether the host `ffmpeg` reports CUDA/NVENC/CUVID support.
	- On Windows it also checks for the `nvcuda.dll` driver file; if present it will attempt hardware decode/encode using CUVID/NVDEC and NVENC.
	- Because `xfade` is a CPU filter, when decoding with the GPU the script uses `hwdownload` to move frames to system memory and selects compatible pixel formats (special handling for 10-bit formats like `p010le` ↔ `yuv420p10le`).
	- If the hardware path fails (some FFmpeg builds and drivers have format conversion limitations), the script automatically retries using software decoding while still preferring NVENC encode when safe.
5. Encoding path:
	- The script forces H.265 encoding for the output (HEVC), attempts to reuse main parameters from input1 (profile, level, bitrate, pix_fmt when possible), and chooses `libx265` or `hevc_nvenc` depending on GPU availability and success.
6. Logging:
	- The script reports whether it will attempt hardware acceleration and whether it actually used hardware or software decode.
	- If `nvidia-smi` is available, the script captures a brief snapshot and prints it to the console to help debug GPU availability.

---

## Troubleshooting & notes

- If you see a message like "nvcuda.dll not found — NVidia drivers not available", the script is correctly falling back to software modes. Install NVIDIA drivers and ensure `nvcuda.dll` exists (and `nvidia-smi` is in PATH) to enable GPU mode.
- Some ffmpeg builds have limited format conversion support between GPU-backed pixel formats and CPU filter formats (10-bit pipelines can fail with a filter error). In such cases the script will detect the failure and automatically re-run with software decode.
 - Some ffmpeg builds have limited format conversion support between GPU-backed pixel formats and CPU filter formats (10-bit pipelines can fail with a filter error). In such cases the script will detect the failure and automatically re-run with software decode. This fallback behavior also applies in folder mode.
- If you need to force software-only processing, run the script on a machine without CUDA drivers or edit `cvwe.ps1` to set the NVidia flag off.
- The script is conservative about preserving color depth and will try to keep 10-bit where the pipeline allows. If your target player or web platform needs 8-bit, transcode the output afterwards or modify the `-pix_fmt` option in the script.

Additional troubleshooting for folder mode:
- If your output file already exists in the input directory, either remove/rename it before running or specify an output path outside the input folder; the script will also try to exclude the output file automatically.

---

## Development & testing notes

- The main script file is `cvwe.ps1`. It is self-contained and contains parameter definitions at the top.
- Tests performed during development include runs on machines with and without NVIDIA GPUs, exercising the hw→sw fallback path and validating the timing of the `xfade`/`acrossfade` pairing.

---

## License & contact

This project does not include an explicit license file. Use and modify at your own discretion. For questions or issues, open an issue or contact the repository owner.

