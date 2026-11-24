# Third-party components

## tapecap

Vendored from https://github.com/xingrz/tapecap at commit `826b9a2a1c1982222114de2e52fc0f6652f2a222` (version 0.4.0). Distributed under the MIT license in `tapecap/LICENSE`.

Local changes add runtime stdin transport commands, a low-latency DV receive option, and flushing completed frames to stdout. The receive ring keeps its original total cycle capacity. See the backend README, AGENTS.md, and docs/BACKGROUND.md for details.

## Apple AVCVideoServices

Vendored by tapecap from Apple's FireWire SDK 26 sample code. Original source headers and `tapecap/third_party/AVCVideoServices/NOTICE.md` retain provenance and license terms. The app build copies the notices into its Resources/Licenses directory.

## FFmpeg

The release includes FFmpeg and ffprobe 7.1.3, built from the unmodified [FFmpeg release source](https://ffmpeg.org/releases/ffmpeg-7.1.3.tar.xz) under LGPL 2.1 or later. The same source archive accompanies the binary release. See `bundle-runtime.sh` for configuration and build commands. The helpers invoke the executables as separate processes.

## Rust media helper

Cargo.lock in the media directory pins the dependencies used by dv-media. License notices for the linked crates and Rust standard library are in licenses/rust and in the app’s Resources/Licenses directory.

The third-party licenses apply to their respective components; no separate license has yet been selected for the app-specific Swift/Rust code.
