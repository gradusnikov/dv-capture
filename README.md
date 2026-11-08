# DV Capture

A small native macOS app for capturing DV camcorders over FireWire, with live video/audio preview and tape transport controls. Current app version: **1.6**.

## Features

- Side-by-side camera preview and capture controls.
- Low-latency, deinterlaced preview at the source frame rate (tested at 25 fps PAL).
- Live stereo audio monitoring, mute, and volume controls.
- Play, pause, stop, rewind, and fast-forward in VTR mode.
- Raw DV capture with optional duration limit and automatic tape playback.
- Automatic MOV export with copied DV video and uncompressed PCM audio.
- Narrow repair of an observed Sony VX1000 PAL audio-metadata defect. When needed, also saves a separate `.corrected.dv`; the original `.dv` remains untouched.

## Requirements

- Apple Silicon Mac running macOS 13–15 with a working FireWire connection.
- Xcode Command Line Tools / Xcode SDK containing the legacy IOKit FireWire and AV/C headers. macOS 26 removed FireWire support; this app targets the older stack.
- `/usr/bin/python3` (provided by Apple's developer tools on the tested Mac).
- Homebrew FFmpeg and ffprobe at `/opt/homebrew/bin` for preview and export: `brew install ffmpeg`.

The application and capture backend currently build for **arm64**. The backend's upstream Makefile also supports Intel, but this app packaging has only been tested on Apple Silicon.

## Build

```sh
./build.sh
```

The resulting app is `build/DV Capture.app`. The script builds the bundled tapecap backend and SwiftUI app, copies Python helpers and third-party license notices, and applies an ad-hoc signature. It is not notarized.

To install for all local accounts, copy the built app to `/Applications` with administrator authorization. FFmpeg and Python must also be accessible to each account. No credentials are embedded in the app.

## Use

1. Quit other capture apps. Connect the camera and select VTR for tape playback or CAMERA for a live feed.
2. Start Live Preview. Use Play for tape playback.
3. Choose a destination and file-name prefix. Duration `0` means capture until stopped.
4. Start Capture, then Stop & Save. Wait for the MOV export to finish.
5. Show MOV reveals the editor-ready result. The original DV and any corrected DV copy are in the same folder.

Capture also works without preview. Tape winding may not produce pictures. Transport controls are disabled while recording. Preview volume/mute never affect recorded audio. Live monitoring plays the first stereo pair; captures and full MOV exports preserve all recognized audio tracks.

Quitting during capture waits for saving and automatic export. Empty captures are not exported. An export failure leaves the original DV available; use Export MOV + Audio to retry or process an older recording.

## Audio repair boundaries

The observed PAL VX1000 defect is matched only in audio DIF blocks with source pack `0x40`, byte 3 of the pack `0xe0`, and byte 4 `0xc1`. Repair changes the source ID to `0x50` and the sample-rate/quantization byte to `0xd1` (32 kHz, 12-bit nonlinear). Video and audio sample bytes are not modified. Full export decodes audio to PCM; video is copied without re-encoding. Already recognized audio is not repaired by the export helper.

This is a compatibility workaround, not a claim to fix every damaged DV recording. Unknown missing-audio cases fail explicitly. The underlying fault has not been conclusively localized: diagnostics found the malformed bytes in the FireWire receive payload before frame assembly in both tape and live CAMERA modes. Camera output and the host transport/driver chain still need cross-testing.

## Troubleshooting and limitations

- If the camera is busy, quit iMovie, Final Cut, QuickTime, and other importers. Apple's AVCAssistant can retain a connection. A camera power cycle may be needed after reconnecting.
- Preview prioritizes recent frames and bounded audio buffering over building a delay under load. Raw recording is independent of preview frame dropping.
- Audio output latency depends on the selected sound device, particularly Bluetooth.
- The live session intentionally stays connected during no-data periods. Use a capture duration or Stop & Save.
- Long uninterrupted tapes, mixed DV modes, and Intel Macs have not been comprehensively tested.

## Source layout and validation

- `DVCapture.swift`: SwiftUI window, capture lifecycle, native video rendering, and audio monitoring.
- `live_session.py`: shared camera session, independent raw recording, video/audio preview decoders.
- `audio_export.py`: metadata recovery and non-destructive DV/MOV export.
- `tapecap/`: vendored capture backend and its upstream documentation/licenses.

Validated locally with a Sony VX1000: 25 fps preview, live audio, transport commands, timed capture, automatic MOV/corrected-DV export, empty capture handling, and waiting for export on quit. Recovery validation checked unchanged source files, changes confined to matched metadata bytes, recognized audio tracks, and identical decoded video pixels. Media fixtures and personal recordings are intentionally not included.

See [THIRD_PARTY.md](THIRD_PARTY.md) for provenance and licenses.
