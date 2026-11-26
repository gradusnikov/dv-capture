use super::{media_tool, repair_audio, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    fs::File,
    io::{self, BufRead, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{mpsc, Arc, Condvar, Mutex},
    thread,
    time::{Duration, Instant},
};

fn emit(value: Value) {
    let mut out = io::stdout().lock();
    if serde_json::to_writer(&mut out, &value).is_ok() {
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }
}
pub fn error(message: &str) {
    emit(json!({"event":"error","message":message}));
}

// Recording consumes every frame. Each preview decoder has a small independent
// queue and replaces its oldest frame when display or sound falls behind.
struct Frames {
    queue: Mutex<(VecDeque<Arc<[u8]>>, bool)>,
    changed: Condvar,
    capacity: usize,
}
impl Frames {
    fn new(capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            queue: Mutex::new((VecDeque::new(), false)),
            changed: Condvar::new(),
            capacity,
        })
    }
    fn push(&self, frame: Arc<[u8]>) {
        let mut q = self.queue.lock().unwrap();
        if q.0.len() == self.capacity {
            q.0.pop_front();
        }
        q.0.push_back(frame);
        self.changed.notify_one();
    }
    fn next(&self) -> Option<Arc<[u8]>> {
        let q = self.queue.lock().unwrap();
        self.changed
            .wait_while(q, |q| q.0.is_empty() && !q.1)
            .unwrap()
            .0
            .pop_front()
    }
    fn close(&self) {
        self.queue.lock().unwrap().1 = true;
        self.changed.notify_all();
    }
}

struct Process(Child);
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn decoder(args: &[&str]) -> Result<Process> {
    Ok(Process(
        Command::new(media_tool("ffmpeg")?)
            .args(["-hide_banner", "-loglevel", "error"])
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?,
    ))
}

fn audio_output(mut source: impl Read, paused: Arc<Mutex<bool>>) {
    let mut pcm = [0; 7680];
    while source.read_exact(&mut pcm).is_ok() {
        let state = paused.lock().unwrap();
        if !*state {
            emit(json!({"event":"audio","data":STANDARD.encode(pcm)}));
        }
    }
}

struct Recording {
    path: PathBuf,
    file: File,
}
type Recorder = Mutex<Option<Recording>>;
fn finish(rec: &Recorder) -> io::Result<()> {
    let mut slot = rec.lock().unwrap();
    if let Some(recording) = slot.take() {
        recording.file.sync_all()?;
        drop(recording.file);
        emit(json!({"event":"saved","path":recording.path}));
    }
    Ok(())
}
fn receive(
    mut source: impl Read,
    rec: &Recorder,
    video: &Frames,
    audio: &Frames,
) -> io::Result<()> {
    let mut header = [0; 4];
    loop {
        match source.read_exact(&mut header) {
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            other => other?,
        }
        let size = if header[3] & 0x80 != 0 {
            144000
        } else {
            120000
        };
        let mut frame = vec![0; size];
        frame[..4].copy_from_slice(&header);
        match source.read_exact(&mut frame[4..]) {
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            other => other?,
        }
        if let Some(r) = rec.lock().unwrap().as_mut() {
            r.file.write_all(&frame)?;
        }
        let frame: Arc<[u8]> = frame.into();
        video.push(frame.clone());
        audio.push(frame);
    }
}

enum Event {
    Command(String),
    Quit,
    Ended,
}
pub fn run(engine_path: &Path) -> Result<()> {
    let mut audio = decoder(&[
        "-probesize",
        "144000",
        "-analyzeduration",
        "0",
        "-threads",
        "1",
        "-f",
        "dv",
        "-i",
        "pipe:0",
        "-map",
        "0:a:0",
        "-vn",
        "-ac",
        "2",
        "-ar",
        "48000",
        "-c:a",
        "pcm_s16le",
        "-f",
        "s16le",
        "-flush_packets",
        "1",
        "pipe:1",
    ])?;
    let mut engine = Process(
        Command::new(engine_path)
            .args([
                "capture",
                "--format",
                "dv",
                "--no-control",
                "--eot-timeout",
                "0",
                "--stdin-control",
                "--low-latency",
                "-",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?,
    );
    let mut control = engine.0.stdin.take().unwrap();
    let source = engine.0.stdout.take().unwrap();
    let logs = engine.0.stderr.take().unwrap();
    let paused = Arc::new(Mutex::new(false));
    let audio_state = paused.clone();
    let log_reader = thread::spawn(move || {
        for line in io::BufReader::new(logs).lines().map_while(|l| l.ok()) {
            if line == "Monitor pause: on" || line == "Monitor pause: off" {
                let mut state = paused.lock().unwrap();
                *state = line.ends_with("on");
                emit(json!({"event":"monitor_pause","paused":*state}));
            } else if let Some(fields) = line.strip_prefix("Tape metadata: ") {
                if let Some((tc, date)) = fields.split_once('|') {
                    emit(json!({"event":"metadata","timecode":tc,"recorded":date}));
                }
            } else if let Some(result) = line.strip_prefix("Seek result: ") {
                emit(json!({"event":"seek_result","result":result}));
            } else if let Some(token) = line.strip_prefix("DV end detected ") {
                emit(json!({"event":"tape_end","token":token}));
            } else {
                emit(json!({"event":"log","message":line}));
                if line.contains("Capturing") {
                    emit(json!({"event":"ready"}));
                }
            }
        }
    });
    let pictures = Frames::new(1);
    let sound = Frames::new(4);

    let source_audio = audio.0.stdout.take().unwrap();

    let mut audio_in = audio.0.stdin.take().unwrap();

    let audio_reader = thread::spawn(move || audio_output(source_audio, audio_state));
    let q = pictures.clone();
    let video_writer = thread::spawn(move || {
        while let Some(frame) = q.next() {
            // Keep the header and its binary payload atomic relative to JSON events.
            let mut out = io::stdout().lock();
            if writeln!(out, "{{\"event\":\"dv\",\"bytes\":{}}}", frame.len()).is_err()
                || out.write_all(&frame).and_then(|_| out.flush()).is_err()
            {
                break;
            }
        }
    });
    let q = sound.clone();
    let audio_writer = thread::spawn(move || {
        while let Some(f) = q.next() {
            let mut frame = f.to_vec();
            repair_audio(&mut frame);
            if audio_in.write_all(&frame).is_err() {
                emit(
                    json!({"event":"audio_error","message":"No decodable live audio. Video and recording continue."}),
                );
                break;
            }
        }
    });
    let (send, events) = mpsc::channel();
    let rec = Arc::new(Mutex::new(None));
    let record = rec.clone();
    let notify = send.clone();
    let receiver = thread::spawn(move || {
        let result = receive(source, &record, &pictures, &sound);
        pictures.close();
        sound.close();
        let _ = notify.send(Event::Ended);
        result
    });
    thread::spawn(move || {
        for line in io::stdin().lock().lines().map_while(|l| l.ok()) {
            if send.send(Event::Command(line)).is_err() {
                return;
            }
        }
        let _ = send.send(Event::Quit);
    });
    let commands = (|| -> Result<()> {
        while let Ok(Event::Command(line)) = events.recv() {
            let cmd: Value = serde_json::from_str(&line)?;
            match cmd["action"].as_str() {
                Some("quit") => break,
                Some("record") => {
                    let path = PathBuf::from(cmd["path"].as_str().ok_or("Missing record path")?);
                    let mut slot = rec.lock().unwrap();
                    if slot.is_some() {
                        return Err("Already recording".into());
                    }
                    let file = File::create_new(&path)?;
                    *slot = Some(Recording {
                        path: path.clone(),
                        file,
                    });
                    if let Some(token) = cmd["end_token"].as_str() {
                        if token.len() == 36
                            && token.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-')
                        {
                            writeln!(control, "watch-end {token}")?;
                        }
                    }
                    emit(json!({"event":"recording","path":path}));
                }
                Some("seek") => {
                    if let Some(seconds) = cmd["seconds"]
                        .as_str()
                        .and_then(|s| s.parse::<u32>().ok())
                        .filter(|s| *s < 86400)
                    {
                        if rec.lock().unwrap().is_none() {
                            writeln!(control, "seek {seconds}")?;
                        } else {
                            emit(json!({"event":"seek_result","result":"failed"}));
                        }
                    } else {
                        emit(json!({"event":"seek_result","result":"failed"}));
                    }
                }
                Some("cancel-seek") => writeln!(control, "cancel-seek")?,
                Some("save") => {
                    finish(&rec)?;
                    writeln!(control, "unwatch-end")?;
                }
                Some(
                    action @ ("play" | "pause" | "toggle-play" | "stop" | "rewind" | "forward"
                    | "navigate-back" | "navigate-forward"),
                ) => writeln!(control, "{action}")?,
                _ => {}
            }
        }
        Ok(())
    })();
    drop(control);
    if engine.0.try_wait()?.is_none() {
        // tapecap handles SIGINT by closing its receiver and stopping the deck.
        unsafe {
            libc::kill(engine.0.id() as i32, libc::SIGINT);
        }
        let deadline = Instant::now() + Duration::from_secs(8);
        while engine.0.try_wait()?.is_none() {
            if Instant::now() >= deadline {
                engine.0.kill()?;
                break;
            }
            thread::sleep(Duration::from_millis(25));
        }
    }
    engine.0.wait()?;
    let received = receiver
        .join()
        .map_err(|_| "DV reader stopped unexpectedly")?;
    finish(&rec)?;
    emit(json!({"event":"ended"}));
    let _ = log_reader.join();
    // Termination releases blocked decoder pipe writes even for a damaged stream.
    drop(audio);
    let _ = video_writer.join();
    let _ = audio_writer.join();
    let _ = audio_reader.join();
    received?;
    commands
}
