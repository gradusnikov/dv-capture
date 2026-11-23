#!/usr/bin/python3
"""Non-destructive DV export; narrow recovery for the observed VX1000 AAUX defect."""
import json
import os
import subprocess
import sys
import tempfile
import shutil
import uuid

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'runtime', 'bin')
FFMPEG = os.path.join(BIN, 'ffmpeg')
FFPROBE = os.path.join(BIN, 'ffprobe')

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
        raise RuntimeError('Bundled FFmpeg tools are missing. Reinstall DV Capture.')
    if os.path.exists(output):
        raise RuntimeError('Output already exists; choose a new file name.')
    with open(source, 'rb') as file:
        header = file.read(144000)
    if len(header) < 120000 or header[0] >> 5 != 0:
        raise RuntimeError('This is not a complete raw DV recording.')
    pal = bool(header[3] & 0x80)
    with tempfile.TemporaryDirectory(prefix='dv-audio-export-') as scratch:
        media = source
        if pal:
            fixed = os.path.join(scratch, 'metadata-recovery.dv')
            repaired = 0
            # A later scene can have different headers from the initial probe.
            # Copy the prefix only once, when the first repair becomes necessary.
            with open(source, 'rb') as src:
                dst = None
                try:
                    while True:
                        position = src.tell()
                        data = bytearray(src.read(144000))
                        if not data:
                            break
                        # Nine audio DIF blocks per 150-block DIF sequence.
                        for seq in range(0, len(data), 12000):
                            for i in range(seq + 480, min(seq + 12000, len(data) - 79), 1280):
                                if (data[i] >> 5 == 3 and data[i+3] == 0x40
                                        and data[i+6:i+8] == b'\xe0\xc1'):
                                    data[i+3] = 0x50
                                    data[i+7] = 0xd1
                                    repaired += 1
                        if repaired and dst is None:
                            dst = open(fixed, 'xb')
                            src.seek(0)
                            while src.tell() < position:
                                dst.write(src.read(min(position - src.tell(), 1024 * 1024)))
                            src.seek(position + len(data))
                        if dst is not None:
                            dst.write(data)
                finally:
                    if dst is not None:
                        dst.close()
            if repaired:
                media = fixed
                print(f'Recovered {repaired} malformed audio-source packs.', flush=True)
        if not audio_tracks(media):
            raise RuntimeError('No recoverable audio track found. Original capture is unchanged.')
        if media != source and not preview:
            # Preserve the repaired raw DV too, even if a later MOV export fails.
            media = save_corrected_dv(media, source)
        args = [FFMPEG, '-hide_banner', '-loglevel', 'warning', '-nostdin', '-n', '-i', media]
        if preview:
            args += ['-t', '15', '-map', '0:v:0', '-map', '0:a:0',
                     '-c:v', 'mpeg4', '-q:v', '3',
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
