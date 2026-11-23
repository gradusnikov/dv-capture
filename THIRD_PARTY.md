# Third-party components

## tapecap

Vendored from https://github.com/xingrz/tapecap at commit `826b9a2a1c1982222114de2e52fc0f6652f2a222` (version 0.4.0). Distributed under the MIT license in `tapecap/LICENSE`.

Local changes add runtime stdin transport commands, a low-latency DV receive option, and flushing completed frames to stdout. The receive ring keeps its original total cycle capacity. See the backend README, AGENTS.md, and docs/BACKGROUND.md for details.

## Apple AVCVideoServices

Vendored by tapecap from Apple's FireWire SDK 26 sample code. Original source headers and `tapecap/third_party/AVCVideoServices/NOTICE.md` retain provenance and license terms. The app build copies the notices into its Resources/Licenses directory.

## FFmpeg

The release includes FFmpeg and ffprobe 7.1.3, built from the unmodified [FFmpeg release source](https://ffmpeg.org/releases/ffmpeg-7.1.3.tar.xz) under LGPL 2.1 or later. The same source archive accompanies the binary release. See `bundle-runtime.sh` for configuration and build commands. The helpers invoke the executables as separate processes.

## Python

The app bundles CPython 3.12.11 from [python-build-standalone release 20250818](https://github.com/astral-sh/python-build-standalone/releases/tag/20250818). The build script verifies the Apple Silicon archive checksum. The app includes the Python license and component notices from the corresponding full distribution under Resources/Licenses.

The third-party licenses apply to their respective components; no separate license has yet been selected for the app-specific Swift/Python code.
