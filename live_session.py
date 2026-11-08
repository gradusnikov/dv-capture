#!/usr/bin/python3
"""One FireWire receiver, lossless DV recording, bounded video and audio preview."""
import base64, json, os, queue, shutil, signal, subprocess, sys, threading, time

output_lock = threading.Lock()
record_lock = threading.Lock()
record_file = None
record_path = None
ending = threading.Event()
frames = queue.Queue(maxsize=1)
audio_frames = queue.Queue(maxsize=4)

def emit(kind, **values):
    with output_lock:
        print(json.dumps(dict(event=kind, **values)), flush=True)

def finish_record():
    global record_file, record_path
    with record_lock:
        if record_file:
            try:
                record_file.flush()
                os.fsync(record_file.fileno())
            finally:
                record_file.close()
                record_file = None
            emit('saved', path=record_path)

ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
try:
    decoder = subprocess.Popen([ffmpeg, '-hide_banner', '-loglevel', 'error', '-probesize', '32', '-analyzeduration', '0', '-threads', '1', '-flags', 'low_delay', '-f', 'dv', '-i', 'pipe:0', '-an', '-fps_mode', 'passthrough', '-vf', 'bwdif=mode=send_frame:parity=auto:deint=all,scale=640:480', '-c:v', 'mjpeg', '-q:v', '5', '-threads', '1', '-f', 'image2pipe', '-flush_packets', '1', 'pipe:1'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    engine = subprocess.Popen([sys.argv[1], 'capture', '--format', 'dv', '--no-control', '--eot-timeout', '0', '--stdin-control', '--low-latency', '-'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
except Exception as e:
    emit('error', message=str(e))
    if 'decoder' in globals(): decoder.terminate()
    sys.exit(1)

# Audio has its own decoder so a missing audio track cannot stop video/recording.
audio_decoder = None

def audio_reader(process):
    while not ending.is_set():
        pcm = process.stdout.read(7680)  # 40 ms, stereo s16le at 48 kHz
        if not pcm: break
        if len(pcm) % 4 == 0:
            emit('audio', data=base64.b64encode(pcm).decode())

def audio_writer():
    global audio_decoder
    try:
        while not ending.is_set():
            try: frame = audio_frames.get(timeout=.2)
            except queue.Empty: continue
            # Repair only the known PAL VX1000 AAUX defect in the monitor copy.
            data = bytearray(frame)
            if data[3] & 0x80:
                for i in range(0, len(data) - 79, 80):
                    if data[i] >> 5 == 3 and data[i+3] == 0x40 and data[i+6] == 0xe0 and data[i+7] == 0xc1:
                        data[i+3] = 0x50; data[i+7] = 0xd1
            if audio_decoder is None:
                audio_decoder = subprocess.Popen([ffmpeg, '-hide_banner', '-loglevel', 'error',
                    '-probesize', '144000', '-analyzeduration', '0', '-threads', '1', '-f', 'dv', '-i', 'pipe:0',
                    '-map', '0:a:0', '-vn', '-ac', '2', '-ar', '48000', '-c:a', 'pcm_s16le',
                    '-f', 's16le', '-flush_packets', '1', 'pipe:1'],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                threading.Thread(target=audio_reader, args=(audio_decoder,), daemon=True).start()
            audio_decoder.stdin.write(data); audio_decoder.stdin.flush()
    except (BrokenPipeError, OSError):
        if not ending.is_set(): emit('audio_error', message='No decodable live audio. Video and recording continue.')


def engine_logs():
    for line in iter(engine.stderr.readline, b''):
        message = line.decode(errors='replace').strip()
        emit('log', message=message)
        if 'Capturing' in message: emit('ready')

def jpeg_reader():
    buffer = bytearray()
    while True:
        data = decoder.stdout.read1(65536)
        if not data: return
        buffer.extend(data)
        while True:
            start = buffer.find(b'\xff\xd8'); end = buffer.find(b'\xff\xd9', max(0, start))
            if start < 0 or end < 0: break
            emit('frame', data=base64.b64encode(buffer[start:end+2]).decode())
            del buffer[:end+2]
        if len(buffer) > 4000000: buffer.clear()

def decoder_writer():
    while not ending.is_set():
        try: frame = frames.get(timeout=.2)
        except queue.Empty: continue
        try: decoder.stdin.write(frame); decoder.stdin.flush()
        except (BrokenPipeError, OSError): return

def receiver():
    buffer = bytearray()
    try:
        while True:
            data = engine.stdout.read1(262144)
            if not data: break
            buffer.extend(data)
            while len(buffer) >= 4:
                size = 144000 if buffer[3] & 0x80 else 120000
                if len(buffer) < size: break
                frame = bytes(buffer[:size]); del buffer[:size]
                with record_lock:
                    if record_file: record_file.write(frame)
                try: audio_frames.put_nowait(frame)
                except queue.Full:
                    try: audio_frames.get_nowait()
                    except queue.Empty: pass
                    try: audio_frames.put_nowait(frame)
                    except queue.Full: pass
                # Keep the newest picture under load; never queue old footage.
                try: frames.put_nowait(frame)
                except queue.Full:
                    try: frames.get_nowait()
                    except queue.Empty: pass
                    try: frames.put_nowait(frame)
                    except queue.Full: pass
    except Exception as e:
        emit('error', message='Capture failed: ' + str(e))
        engine.send_signal(signal.SIGINT)
    finally:
        finish_record()
        ending.set()
        emit('ended')
        # Wake the command reader if the camera disappears.
        # Main loop notices ending within 200 ms.

threads = [threading.Thread(target=f, daemon=True) for f in (engine_logs, jpeg_reader, decoder_writer, receiver, audio_writer)]
for thread in threads: thread.start()
try:
    commands = queue.Queue()
    def read_commands():
        for line in sys.stdin: commands.put(line)
        commands.put('')
    threading.Thread(target=read_commands, daemon=True).start()
    while not ending.is_set():
        try: line = commands.get(timeout=.2)
        except queue.Empty: continue
        if not line: break
        cmd = json.loads(line)
        action = cmd.get('action')
        if action == 'quit': break
        if action == 'record':
            with record_lock:
                if record_file: raise ValueError('Already recording')
                record_path = cmd['path']
                record_file = open(record_path, 'xb')
            emit('recording', path=record_path)
        elif action == 'save': finish_record()
        elif action in ('play', 'pause', 'stop', 'rewind', 'forward'):
            engine.stdin.write((action+'\n').encode()); engine.stdin.flush()
except Exception as e:
    if not ending.is_set(): emit('error', message=str(e))
finally:
    if engine.poll() is None:
        engine.send_signal(signal.SIGINT)
        try: engine.wait(timeout=8)
        except subprocess.TimeoutExpired: engine.kill(); engine.wait()
    threads[3].join(timeout=2)
    finish_record()
    ending.set()
    decoder.terminate()
    try: decoder.wait(timeout=2)
    except subprocess.TimeoutExpired: decoder.kill()

    threads[4].join(timeout=1)
    if audio_decoder is not None:
        audio_decoder.terminate()
        try: audio_decoder.wait(timeout=2)
        except subprocess.TimeoutExpired: audio_decoder.kill()
