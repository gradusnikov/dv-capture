mod export;
mod live;

use std::{
    env, io,
    path::{Path, PathBuf},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn media_tool(name: &str) -> io::Result<PathBuf> {
    let exe = env::current_exe()?;
    let contents = exe
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| io::Error::other("Cannot locate app resources"))?;
    Ok(contents.join("Resources/runtime/bin").join(name))
}

// Nine audio DIF blocks in each 150-block sequence. Only metadata is altered.
fn repair_audio(frame: &mut [u8]) -> usize {
    let mut count = 0;
    if frame.get(3).is_some_and(|v| v & 0x80 != 0) {
        for sequence in frame.chunks_mut(12000) {
            for block in sequence.chunks_exact_mut(80).skip(6).step_by(16) {
                if block[0] >> 5 == 3 && block[3] == 0x40 && block[6..8] == [0xe0, 0xc1] {
                    block[3] = 0x50;
                    block[7] = 0xd1;
                    count += 1;
                }
            }
        }
    }
    count
}

fn main() {
    let args: Vec<_> = env::args_os().skip(1).collect();
    let result = match args.as_slice() {
        [cmd, engine] if cmd == "live" => {
            live::run(Path::new(engine)).inspect_err(|e| live::error(&e.to_string()))
        }
        [cmd, src, dst] if cmd == "export" => {
            export::run(src.as_ref(), dst.as_ref(), export::Mode::Full)
        }
        [cmd, src, dst, mode] if cmd == "export" && mode == "preview" => {
            export::run(src.as_ref(), dst.as_ref(), export::Mode::Preview)
        }
        [cmd, src, dst, mode] if cmd == "export" && mode == "full" => {
            export::run(src.as_ref(), dst.as_ref(), export::Mode::Full)
        }
        [cmd, src, dst, mode] if cmd == "export" && mode == "streaming" => {
            export::run(src.as_ref(), dst.as_ref(), export::Mode::Streaming)
        }
        _ => Err(
            "Usage: dv-media live TAPECAP | export INPUT OUTPUT.mov [full|streaming|preview]"
                .into(),
        ),
    };
    if let Err(e) = result {
        eprintln!("DV media error: {e}");
        std::process::exit(1);
    }
}
