use super::{media_tool, repair_audio, Result};
use std::{
    fs::{self, File},
    io::{self, Read, Seek, Write},
    os::unix::fs::DirBuilderExt,
    path::{Path, PathBuf},
    process::Command,
};

// A private staging directory on the destination volume. Incomplete MOVs are
// never exposed under the requested name, even when an export fails.
struct Scratch(PathBuf);
impl Scratch {
    fn new(parent: &Path) -> io::Result<Self> {
        for n in 0.. {
            let path = parent.join(format!(".dv-export-{}-{n}", std::process::id()));
            match fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        }
        unreachable!()
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn publish(src: &Path, dst: &Path) -> io::Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let from = CString::new(src.as_os_str().as_bytes())?;
    let to = CString::new(dst.as_os_str().as_bytes())?;
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if !matches!(
        error.raw_os_error(),
        Some(libc::ENOTSUP | libc::EINVAL | libc::ENOSYS)
    ) {
        return Err(error);
    }
    // Some external volumes only support ordinary rename. Reserve the name
    // exclusively, then replace that empty reservation with the complete file.
    let reservation = File::create_new(dst)?;
    if let Err(e) = fs::rename(src, dst) {
        drop(reservation);
        let _ = fs::remove_file(dst);
        return Err(e);
    }
    Ok(())
}

fn audio_tracks(path: &Path) -> Result<usize> {
    let result = Command::new(media_tool("ffprobe")?)
        .args([
            "-v",
            "error",
            "-select_streams",
            "a",
            "-show_entries",
            "stream=index",
            "-of",
            "csv=p=0",
        ])
        .arg(path)
        .output()?;
    if !result.status.success() {
        return Err(String::from_utf8_lossy(&result.stderr).into_owned().into());
    }
    Ok(String::from_utf8(result.stdout)?
        .lines()
        .filter(|s| !s.is_empty())
        .count())
}

fn recover(src: &Path, repaired: &Path) -> Result<usize> {
    let mut input = File::open(src)?;
    let mut frame = vec![0; 144000];
    let mut total = 0;
    let mut position = 0;
    let mut dest = None;
    loop {
        let mut size = 0;
        while size < frame.len() {
            let n = input.read(&mut frame[size..])?;
            if n == 0 {
                break;
            }
            size += n;
        }
        if size == 0 {
            break;
        }
        total += repair_audio(&mut frame[..size]);
        if total > 0 && dest.is_none() {
            let mut out = File::create_new(repaired)?;
            input.rewind()?;
            io::copy(&mut Read::by_ref(&mut input).take(position), &mut out)?;
            input.seek(io::SeekFrom::Start(position + size as u64))?;
            dest = Some(out);
        }
        if let Some(out) = &mut dest {
            out.write_all(&frame[..size])?
        }
        position += size as u64;
    }
    if let Some(out) = dest {
        out.sync_all()?
    }
    Ok(total)
}

pub fn run(src: &Path, dst: &Path, preview: bool) -> Result<()> {
    if dst.exists() {
        return Err("Output already exists; choose a new file name.".into());
    }
    let mut input = File::open(src)?;
    let mut header = [0; 4];
    input.read_exact(&mut header)?;
    let pal = header[3] & 0x80 != 0;
    if header[0] >> 5 != 0 || input.metadata()?.len() < if pal { 144000 } else { 120000 } {
        return Err("This is not a complete raw DV recording.".into());
    }
    let scratch = Scratch::new(dst.parent().unwrap_or(Path::new(".")))?;
    let fixed = scratch.0.join("recovered.dv");
    let mut media = src.to_owned();
    if pal {
        let count = recover(src, &fixed)?;
        if count > 0 {
            println!("Recovered {count} malformed audio-source packs.");
            media = fixed.clone();
        }
    }
    if audio_tracks(&media)? == 0 {
        return Err("No recoverable audio track found.".into());
    }
    if media == fixed && !preview {
        // The original may live on another volume. Stage its corrected sibling
        // there before publishing; retry only name collisions.
        let local = Scratch::new(src.parent().unwrap_or(Path::new(".")))?;
        let staged = local.0.join("corrected.dv");
        match fs::rename(&fixed, &staged) {
            Ok(()) => {}
            Err(e) if e.raw_os_error() == Some(libc::EXDEV) => {
                fs::copy(&fixed, &staged)?;
                File::open(&staged)?.sync_all()?;
            }
            Err(e) => return Err(e.into()),
        }
        for n in 0.. {
            let ext = if n == 0 {
                "corrected.dv".to_string()
            } else {
                format!("corrected-{n}.dv")
            };
            let candidate = src.with_extension(ext);
            match publish(&staged, &candidate) {
                Ok(()) => {
                    println!("Saved corrected DV: {}", candidate.display());
                    media = candidate;
                    break;
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e.into()),
            }
        }
    }
    let staged = scratch.0.join("export.mov");
    let mut cmd = Command::new(media_tool("ffmpeg")?);
    cmd.args([
        "-hide_banner",
        "-loglevel",
        "warning",
        "-nostdin",
        "-n",
        "-i",
    ])
    .arg(&media);
    if preview {
        cmd.args([
            "-t", "15", "-map", "0:v:0", "-map", "0:a:0", "-c:v", "mpeg4", "-q:v", "3", "-pix_fmt",
            "yuv420p", "-c:a", "aac", "-b:a", "192k",
        ]);
    } else {
        cmd.args([
            "-map",
            "0:v:0",
            "-map",
            "0:a",
            "-c:v",
            "copy",
            "-c:a",
            "pcm_s16le",
        ]);
    }
    if !cmd
        .args([
            "-r",
            if pal { "25" } else { "30000/1001" },
            "-movflags",
            "+faststart",
        ])
        .arg(&staged)
        .status()?
        .success()
    {
        return Err("FFmpeg export failed".into());
    }
    let tracks = audio_tracks(&staged)?;
    if tracks == 0 {
        return Err("Export has no recognized audio.".into());
    }
    publish(&staged, dst)?;
    println!("Saved MOV with {tracks} audio track(s): {}", dst.display());
    Ok(())
}
