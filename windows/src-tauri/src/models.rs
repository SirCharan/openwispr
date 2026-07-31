//! Whisper **ggml** models offered by the first-run downloader, plus the resumable fetcher.
//!
//! These are whisper.cpp `.bin` files, magic `lmgg` (`GGML_FILE_MAGIC` 0x67676d6c) — NOT
//! GGUF. A real `.gguf` file is rejected by whisper.cpp's loader with "invalid model data
//! (bad magic)", so never reach for a gguf parser here.
//!
//! URLs, byte sizes and digests verified 2026-07-31 against
//! huggingface.co/ggerganov/whisper.cpp @ 5359861c739e955e79d9a303bcbc70fb988958b1
//! (repo lastModified 2024-10-29, i.e. frozen).
//! `bytes` = observed `content-length` / `x-linked-size`; `sha256` = the `x-linked-etag`
//! on the huggingface.co 302, which equals the HF API `lfs.sha256` and the real digest.
//! NOTE: the *final* CDN hop's `etag` is the Xet content hash, NOT sha256 — never verify
//! against it. We hash the bytes on disk and compare with the constants below.

use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub struct Model {
    pub id: &'static str,
    pub label: &'static str,
    pub file: &'static str,
    pub url: &'static str,
    pub bytes: u64,
    pub sha256: &'static str,
    /// Approximate peak RAM in MB. tiny/base/small are whisper.cpp's published figures for
    /// the *multilingual* tiny/base/small (273/388/852) — upstream publishes none per-`.en`
    /// and none at all for turbo/quantized variants, so 1500 is an estimate.
    /// ponytail: calibration knob — measure on a real Windows box and move it.
    pub ram_mb: u32,
}

pub const MODELS: [Model; 4] = [
    Model {
        id: "tiny.en",
        label: "Tiny (English) — fastest, ~275 MB RAM",
        file: "ggml-tiny.en.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
        bytes: 77_704_715,
        sha256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
        ram_mb: 273,
    },
    Model {
        id: "base.en",
        label: "Base (English) — recommended, ~390 MB RAM",
        file: "ggml-base.en.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
        bytes: 147_964_211,
        sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        ram_mb: 388,
    },
    Model {
        id: "small.en",
        label: "Small (English) — more accurate, ~850 MB RAM",
        file: "ggml-small.en.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
        bytes: 487_614_201,
        sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        ram_mb: 852,
    },
    Model {
        id: "large-v3-turbo-q5_0",
        label: "Large v3 Turbo (q5_0) — multilingual, best accuracy, ~1.5 GB RAM",
        file: "ggml-large-v3-turbo-q5_0.bin",
        url:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
        bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        ram_mb: 1500,
    },
];

/// First four bytes of every whisper.cpp model file.
const GGML_MAGIC: [u8; 4] = *b"lmgg";

pub fn by_id(id: &str) -> Option<&'static Model> {
    MODELS.iter().find(|m| m.id == id)
}

/// Where models live. ponytail: plain env lookup rather than a `dirs`/Tauri path dep —
/// swap for `app.path().app_local_data_dir()` when the GUI needs the same directory.
pub fn dir() -> PathBuf {
    let base = if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
    } else {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support"))
    };
    base.unwrap_or_else(std::env::temp_dir)
        .join("OpenWispr")
        .join("models")
}

pub fn path_of(model: &Model) -> PathBuf {
    dir().join(model.file)
}

/// Launch-time check: exact size plus the ggml container magic. Deliberately does NOT
/// re-hash — sha256 of 550 MB on every start is not worth it; the digest is checked once,
/// at the end of the download, before the file is renamed into place.
pub fn looks_installed(model: &Model) -> bool {
    let path = path_of(model);
    match fs::metadata(&path) {
        Ok(md) if md.len() == model.bytes => magic_ok(&path),
        _ => false,
    }
}

fn magic_ok(path: &Path) -> bool {
    let mut head = [0u8; 4];
    File::open(path)
        .and_then(|mut f| f.read_exact(&mut head))
        .is_ok()
        && head == GGML_MAGIC
}

pub fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .fold(String::with_capacity(64), |mut s, b| {
            use std::fmt::Write;
            let _ = write!(s, "{b:02x}");
            s
        }))
}

/// Download `model` into [`dir`] unless it is already there, resuming a partial `.part`
/// file. `progress(done, total)` is called every 256 KB. Verifies size, then sha256, then
/// the ggml magic before renaming into place, so a half file is never visible as a model.
///
/// One retry: a truncated/corrupt `.part` is deleted and fetched from scratch once. That
/// also covers a `416 Range Not Satisfiable` (ureq surfaces any non-2xx as `Err`).
pub fn ensure(model: &Model, progress: &mut dyn FnMut(u64, u64)) -> Result<PathBuf, String> {
    let target = path_of(model);
    if looks_installed(model) {
        return Ok(target);
    }
    let dir = dir();
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let part = dir.join(format!("{}.part", model.file));

    let mut last_err = String::new();
    for attempt in 0..2 {
        let have = fs::metadata(&part).map(|md| md.len()).unwrap_or(0);
        let from = if have > model.bytes { 0 } else { have };
        match fetch(model, from, &part, progress).and_then(|()| verify(model, &part)) {
            Ok(()) => {
                // Windows rename fails onto an existing file, so clear a stale target first.
                let _ = fs::remove_file(&target);
                fs::rename(&part, &target)
                    .map_err(|e| format!("{} -> {}: {e}", part.display(), target.display()))?;
                return Ok(target);
            }
            Err(e) => {
                last_err = e;
                let _ = fs::remove_file(&part);
                if attempt == 1 {
                    break;
                }
            }
        }
    }
    Err(format!(
        "could not download {}: {last_err}\nDownload it by hand and drop it in {}",
        model.file,
        dir.display()
    ))
}

fn fetch(
    model: &Model,
    from: u64,
    part: &Path,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<(), String> {
    if from >= model.bytes {
        return Ok(());
    }
    let mut request = ureq::get(model.url)
        .config()
        .timeout_connect(Some(Duration::from_secs(30)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .build();
    if from > 0 {
        request = request.header("range", format!("bytes={from}-"));
    }
    // HF answers 302 -> a time-signed CDN URL; ureq follows up to 10 redirects and keeps
    // the Range header (only auth headers are stripped). Never cache that CDN URL.
    let mut response = request
        .call()
        .map_err(|e| format!("GET {}: {e}", model.url))?;

    // 206 means the server honoured the range; anything else (200) restarts from zero.
    let resumed = response.status().as_u16() == 206;
    let mut file = if resumed {
        OpenOptions::new().append(true).open(part)
    } else {
        File::create(part)
    }
    .map_err(|e| format!("{}: {e}", part.display()))?;

    let mut done = if resumed { from } else { 0 };
    let mut reader = response.body_mut().as_reader();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = reader
            .read(&mut buf)
            .map_err(|e| format!("reading {}: {e}", model.file))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])
            .map_err(|e| format!("{}: {e}", part.display()))?;
        done += n as u64;
        progress(done, model.bytes);
    }
    file.flush().map_err(|e| format!("{}: {e}", part.display()))
}

fn verify(model: &Model, part: &Path) -> Result<(), String> {
    let size = fs::metadata(part)
        .map(|md| md.len())
        .map_err(|e| format!("{}: {e}", part.display()))?;
    if size != model.bytes {
        return Err(format!(
            "{} is {size} bytes, expected {}",
            model.file, model.bytes
        ));
    }
    let got = sha256_file(part)?;
    if got != model.sha256 {
        return Err(format!(
            "{} sha256 {got}, expected {}",
            model.file, model.sha256
        ));
    }
    if !magic_ok(part) {
        return Err(format!(
            "{} is not a whisper.cpp ggml model (bad magic)",
            model.file
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_and_digests_wellformed() {
        for m in &MODELS {
            assert!(m.url.ends_with(m.file), "{} url/file mismatch", m.id);
            assert!(
                m.url
                    .starts_with("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"),
                "{} must use the canonical resolve/main host",
                m.id
            );
            assert_eq!(m.sha256.len(), 64, "{} sha256 wrong length", m.id);
            assert!(m
                .sha256
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
            assert!(m.bytes > 0 && m.ram_mb > 0);
            assert!(by_id(m.id).is_some());
        }
        assert!(by_id("nope").is_none());
    }

    #[test]
    fn sha256_file_matches_shasum() {
        // Hashing the committed fixture keeps the hex formatting honest without a network.
        let path = Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../core/fixtures/speech.wav"
        ));
        assert_eq!(
            sha256_file(path).unwrap(),
            "f9a0193a1c97008b864149368fe5635595c109df815a8b10a869fff92b8bd7ec"
        );
    }

    #[test]
    fn magic_check_rejects_a_gguf_file() {
        let path = std::env::temp_dir().join("openwispr-magic-test.bin");
        fs::write(&path, b"GGUF\0\0\0\0").unwrap();
        assert!(!magic_ok(&path), "a real GGUF file must be rejected");
        fs::write(&path, b"lmgg\0\0\0\0").unwrap();
        assert!(magic_ok(&path));
        let _ = fs::remove_file(&path);
    }
}
