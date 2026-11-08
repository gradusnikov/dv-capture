# Third-party components

## tapecap

Vendored from https://github.com/xingrz/tapecap at commit `826b9a2a1c1982222114de2e52fc0f6652f2a222` (version 0.4.0). Distributed under the MIT license in `tapecap/LICENSE`.

Local changes add runtime stdin transport commands, a low-latency DV receive option, and flushing completed frames to stdout. The receive ring keeps its original total cycle capacity. See the backend README, AGENTS.md, and docs/BACKGROUND.md for details.

## Apple AVCVideoServices

Vendored by tapecap from Apple's FireWire SDK 26 sample code. Original source headers and `tapecap/third_party/AVCVideoServices/NOTICE.md` retain provenance and license terms. The app build copies the notices into its Resources/Licenses directory.

## FFmpeg

Invoked as an external installed dependency; FFmpeg binaries are not included in this repository or app bundle. See https://ffmpeg.org/legal.html for FFmpeg's licensing details.

The third-party licenses apply to their respective components; no separate license has yet been selected for the app-specific Swift/Python code.
