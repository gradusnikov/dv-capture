#!/bin/bash
# Run from the source checkout on Apple Silicon.
set -euo pipefail
resources="${1:?app Resources directory required}"
vendor="$PWD/build/vendor"
mkdir -p "$vendor" "$resources/runtime/bin"
fetch() {
    local url="$1" archive="$2" digest="$3"
    if [[ ! -f "$archive" ]]; then
        curl -fL --retry 3 "$url" -o "$archive.part"
        mv "$archive.part" "$archive"
    fi
    echo "$digest  $archive" | shasum -a 256 -c -
}
fetch https://ffmpeg.org/releases/ffmpeg-7.1.3.tar.xz "$vendor/ffmpeg.tar.xz" f0bf043299db9e3caacb435a712fc541fbb07df613c4b893e8b77e67baf3adbe
src="$vendor/ffmpeg-7.1.3"
tar -xf "$vendor/ffmpeg.tar.xz" -C "$vendor"
(
    cd "$src"
    export MACOSX_DEPLOYMENT_TARGET=13.0
    ./configure --disable-autodetect --disable-network --disable-doc --disable-debug \
        --disable-ffplay --disable-everything --enable-ffmpeg --enable-ffprobe \
        --enable-protocol=file,pipe --enable-demuxer=dv,mov \
        --enable-muxer=mov,image2pipe,pcm_s16le --enable-decoder=dvvideo,pcm_s16le \
        --enable-encoder=pcm_s16le,mjpeg,aac,mpeg4 --enable-parser=mpeg4video \
        --enable-filter=bwdif,scale,format,aresample,aformat,trim,atrim,null,anull \
        --enable-swscale --enable-swresample --cc=clang \
        --extra-cflags=-mmacosx-version-min=13.0 --extra-ldflags=-mmacosx-version-min=13.0
    make -j"$(sysctl -n hw.ncpu || echo 4)" ffmpeg ffprobe
)
cp "$src/ffmpeg" "$src/ffprobe" "$resources/runtime/bin/"
cp "$src/COPYING.LGPLv2.1" "$resources/Licenses/FFmpeg.txt"
cp THIRD_PARTY.md "$resources/Licenses/"
for binary in "$resources/runtime/bin/"*; do
    codesign --force --sign - "$binary"
done
