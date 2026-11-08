#!/usr/bin/python3
"""Non-destructive DV export; narrow recovery for the observed VX1000 AAUX defect."""
import json
import os
import subprocess
import sys
import tempfile
import shutil
import uuid

FFMPEG = '/opt/homebrew/bin/ffmpeg'
FFPROBE = '/opt/homebrew/bin/ffprobe'

def audio_tracks(path):
    result = subprocess.run([FFPROBE, '-v', 'error', '-select_streams', 'a',
                             '-show_entries', 'stream=index', '-of', 'json', path],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout).get('streams', [])

def save_corrected_dv(repaired, original):
    stem = os.path.splitext(original)[0]
    destination = stem + '.corrected.dv'
    while True:
        try:
            output = open(destination, 'xb')
            break
        except FileExistsError:
            destination = stem + '.corrected-' + uuid.uuid4().hex[:8] + '.dv'
    try:
        with output, open(repaired, 'rb') as source:
            shutil.copyfileobj(source, output, 1024 * 1024)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        # This path was exclusively created by us; never delete an existing file.
        os.unlink(destination)
        raise
    print(f'Saved corrected DV: {destination}', flush=True)
    return destination


def export(source, output, preview=False):
    if not all(os.access(p, os.X_OK) for p in [FFMPEG, FFPROBE]):
        raise RuntimeError('FFmpeg is required at /opt/homebrew/bin. It is installed on this Mac.')
    if os.path.exists(output):
        raise RuntimeError('Output already exists; choose a new file name.')
    with open(source, 'rb') as file:
        header = file.read(144000)
    if len(header) < 120000 or header[0] >> 5 != 0:
        raise RuntimeError('This is not a complete raw DV recording.')
    pal = bool(header[3] & 0x80)
    with tempfile.TemporaryDirectory(prefix='dv-audio-export-') as scratch:
        media = source
        if not audio_tracks(source):
            if not pal:
                raise RuntimeError('No audio track recognized. Recovery is only verified for PAL VX1000 captures.')
            fixed = os.path.join(scratch, 'metadata-recovery.dv')
            repaired = 0
            with open(source, 'rb') as src, open(fixed, 'xb') as dst:
                while True:
                    data = bytearray(src.read(144000))
                    if not data:
                        break
                    for i in range(0, len(data) - 79, 80):
                        # Source pack ID 0x40 and impossible 48kHz/12-bit mode.
                        # Only match the precise PAL pattern observed here.
                        if (data[i] >> 5 == 3 and data[i+3] == 0x40
                                and data[i+6] == 0xe0 and data[i+7] == 0xc1):
                            data[i+3] = 0x50
                            data[i+7] = 0xd1  # 32kHz / 12-bit nonlinear audio
                            repaired += 1
                    dst.write(data)
            if not repaired or not audio_tracks(fixed):
                raise RuntimeError('No recoverable audio track found. Original capture is unchanged.')
            media = fixed
            print(f'Recovered {repaired} malformed PAL VX1000 audio-source packs in a temporary copy.', flush=True)
            print('Please listen to the export to verify the recovered sound. Original DV is unchanged.', flush=True)
        else:
            print('Standard DV audio detected; no metadata repair needed.', flush=True)
        if media != source and not preview:
            # Preserve the repaired raw DV too, even if a later MOV export fails.
            media = save_corrected_dv(media, source)
        args = [FFMPEG, '-hide_banner', '-loglevel', 'warning', '-nostdin', '-n', '-i', media]
        if preview:
            args += ['-t', '15', '-map', '0:v:0', '-map', '0:a:0',
                     '-c:v', 'libx264', '-preset', 'fast', '-crf', '20',
                     '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k']
        else:
            args += ['-map', '0:v:0', '-map', '0:a', '-c:v', 'copy', '-c:a', 'pcm_s16le']
        args += ['-r', '25' if pal else '30000/1001', '-movflags', '+faststart', output]
        subprocess.run(args, check=True)
        tracks = audio_tracks(output)
        if not tracks:
            raise RuntimeError('Export has no recognized audio; inspect the source recording.')
        print(f'Saved MOV with {len(tracks)} audio track(s): {output}', flush=True)

if __name__ == '__main__':
    try:
        if len(sys.argv) not in (3, 4):
            raise RuntimeError('Usage: audio_export.py input.dv output.mov [preview]')
        export(sys.argv[1], sys.argv[2], len(sys.argv) == 4 and sys.argv[3] == 'preview')
    except Exception as error:
        print(f'Audio export failed: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
