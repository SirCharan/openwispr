//! Hardware probe behind the onboarding "which model can this PC run?" step.
//!
//! Cores and SIMD width come from std. RAM and GPU are per-platform: on Windows via
//! `GlobalMemoryStatusEx` + DXGI, elsewhere via `sysctl` so the step still shows
//! real numbers on the macOS dev box.

#[derive(Debug, Clone)]
pub struct Hardware {
    pub cores: usize,
    pub fast_simd: bool,
    pub ram_gb: f64,
    /// `Description` of the beefiest discrete adapter, e.g. "NVIDIA GeForce RTX 4060".
    /// `None` for integrated-only machines and for the Microsoft Basic Render Driver.
    pub gpu: Option<String>,
    pub gpu_vram_gb: f64,
}

const GB: f64 = (1u64 << 30) as f64;

pub fn probe() -> Hardware {
    let (gpu, gpu_vram_gb) = imp::discrete_gpu().unwrap_or((None, 0.0));
    Hardware {
        cores: std::thread::available_parallelism().map_or(1, |n| n.get()),
        fast_simd: fast_simd(),
        ram_gb: imp::total_ram_gb(),
        gpu,
        gpu_vram_gb,
    }
}

/// Does this CPU have the wide SIMD whisper.cpp needs to stay interactive?
///
/// On x86 that means AVX2. An x86_64 build running emulated on ARM64 Windows reports no AVX2
/// here, which is correct: emulated SIMD really is slow, so that machine should get tiny.
/// A NATIVE aarch64 build is the opposite case — NEON is mandatory in the aarch64 baseline and
/// whisper.cpp uses it, so the answer is yes. Returning false there would recommend tiny to a
/// fast machine.
fn fast_simd() -> bool {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        std::arch::is_x86_feature_detected!("avx2")
    }
    #[cfg(target_arch = "aarch64")]
    {
        true
    }
    // Anything else: assume the slow path rather than promise speed we have not checked.
    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64", target_arch = "aarch64")))]
    {
        false
    }
}

impl Hardware {
    /// The whisper.cpp model id to download. Thresholds are deliberately conservative:
    /// a first run that is slow feels broken, a first run that is merely less accurate does not.
    ///
    /// ponytail: heuristic, not physics — benchmark one 4-core no-GPU box and one RTX
    /// laptop and move the numbers.
    pub fn recommend(&self) -> &'static str {
        // No AVX2 means whisper.cpp falls back to scalar GEMM, roughly 4-5x slower —
        // only tiny stays interactive. Same call for a machine too small to spare
        // ~1 GB for weights plus working set alongside the user's browser.
        if !self.fast_simd || self.ram_gb < 4.0 {
            return "tiny.en";
        }
        // Turbo is only pleasant with GPU offload, so it needs a build that HAS offload:
        // whisper-rs turns `use_gpu` on only when a gpu feature (cuda/vulkan/...) is
        // compiled in. A CPU-only binary must never be handed the biggest model.
        if GPU_OFFLOAD && self.gpu.is_some() && self.gpu_vram_gb >= 4.0 && self.ram_gb >= 8.0 {
            return "large-v3-turbo-q5_0";
        }
        // small.en is ~466 MB and needs real CPU width to hit realtime on dictation-length
        // clips; 8 logical cores plus 16 GB is the floor where that holds without swapping.
        if self.cores >= 8 && self.ram_gb >= 16.0 {
            return "small.en";
        }
        // Everything else: base.en is the safe middle — noticeably better than tiny,
        // still comfortably realtime on 4 cores.
        "base.en"
    }

    /// One plain sentence for the onboarding card. No jargon beyond the SIMD name, which is
    /// the one term a user might paste into a search.
    pub fn verdict(&self) -> String {
        let mut facts = vec![
            format!("{} CPU core{}", self.cores, plural(self.cores)),
            simd_label(self.fast_simd),
            format!("{} GB RAM", round_gb(self.ram_gb)),
        ];
        match &self.gpu {
            Some(name) => facts.push(format!(
                "and a {} ({} GB VRAM)",
                name,
                round_gb(self.gpu_vram_gb)
            )),
            None => facts.push("and no discrete graphics card".to_string()),
        }
        let tagline = match self.recommend() {
            "large-v3-turbo-q5_0" => "you can run the best model",
            "small.en" => "you can run a large, accurate model",
            "base.en" => "the balanced model is the best fit",
            _ => "the fastest, smallest model is the safe choice here",
        };
        format!(
            "Found {} — {} ({}).",
            facts.join(", "),
            tagline,
            self.recommend()
        )
    }
}

/// True only when whisper.cpp was built with a GPU backend. `asr-gpu` is an opt-in
/// feature that enables `whisper-rs/vulkan`; the shipped installer is CPU-only today.
const GPU_OFFLOAD: bool = cfg!(feature = "asr-gpu");

fn plural(n: usize) -> &'static str {
    if n == 1 {
        ""
    } else {
        "s"
    }
}

/// 31.9 GB reads as a spec-sheet typo to a normal person; 32 GB reads as the truth.
fn round_gb(gb: f64) -> String {
    if gb >= 1.0 {
        format!("{}", gb.round() as u64)
    } else {
        format!("{gb:.1}")
    }
}

#[cfg(windows)]
mod imp {
    use super::GB;
    use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIFactory1};
    use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};

    /// Below this, an adapter is integrated or software-only, not something worth
    /// offloading to. Integrated GPUs report 0 (or a ~128 MB stolen-memory carve-out)
    /// in `DedicatedVideoMemory` and put their real capacity in `SharedSystemMemory`.
    const DISCRETE_VRAM_MIN_GB: f64 = 1.0;

    /// Microsoft's software rasteriser (the Basic Render Driver) enumerates as a real
    /// adapter. Vendor 0x1414 is Microsoft; never a card worth offloading whisper onto.
    const VENDOR_MICROSOFT: u32 = 0x1414;

    pub fn total_ram_gb() -> f64 {
        let mut status = MEMORYSTATUSEX {
            // GlobalMemoryStatusEx rejects the call unless dwLength is preset.
            dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
            ..Default::default()
        };
        match unsafe { GlobalMemoryStatusEx(&mut status) } {
            Ok(()) => status.ullTotalPhys as f64 / GB,
            Err(_) => 0.0,
        }
    }

    /// Walk every DXGI adapter and keep the one with the most dedicated VRAM.
    ///
    /// `EnumAdapters` returns `DXGI_ERROR_NOT_FOUND` once the list is exhausted, which
    /// windows-rs surfaces as `Err` — that is the loop's exit condition, not a failure.
    /// Adapter 0 is whatever the OS prefers, so on a hybrid laptop it may well be the
    /// integrated Intel part; taking the max is what actually finds the dGPU.
    ///
    /// Three-way discrimination, in order:
    ///   1. `VendorId == 0x1414` -> Microsoft Basic Render Driver (software). Reject.
    ///   2. `DedicatedVideoMemory < 1 GB` -> integrated (Intel UHD/Iris, AMD APU): their
    ///      capacity lives in `SharedSystemMemory`, not here. Reject.
    ///   3. Anything left has real VRAM on a real board — NVIDIA 0x10DE, AMD 0x1002,
    ///      Intel Arc 0x8086. Accept. Deliberately vendor-agnostic: Arc shares Intel's
    ///      vendor id with the integrated parts, so VRAM is the honest test, not VendorId.
    pub fn discrete_gpu() -> Option<(Option<String>, f64)> {
        // DXGI needs no CoInitialize.
        let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1() }.ok()?;
        let mut best: Option<(String, f64)> = None;
        for i in 0.. {
            // IDXGIFactory1 derefs to IDXGIFactory, which owns EnumAdapters.
            let Ok(adapter) = (unsafe { factory.EnumAdapters(i) }) else {
                break;
            };
            let Ok(desc) = (unsafe { adapter.GetDesc() }) else {
                continue;
            };
            if desc.VendorId == VENDOR_MICROSOFT {
                continue;
            }
            // usize on a 64-bit build; a >4 GB card would truncate on i686, which we do not ship.
            let vram = desc.DedicatedVideoMemory as f64 / GB;
            if vram < DISCRETE_VRAM_MIN_GB {
                continue;
            }
            if vram > best.as_ref().map_or(0.0, |(_, v)| *v) {
                best = Some((utf16_name(&desc.Description), vram));
            }
        }
        Some(match best {
            Some((name, vram)) => (Some(name), vram),
            None => (None, 0.0),
        })
    }

    /// `Description` is a fixed 128-wchar buffer, NUL-padded. Trim at the first NUL.
    fn utf16_name(buf: &[u16; 128]) -> String {
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        String::from_utf16_lossy(&buf[..end]).trim().to_string()
    }
}

#[cfg(not(windows))]
mod imp {
    use super::GB;

    /// Dev-box only, so the onboarding card shows real numbers on macOS. `sysctl` beats
    /// adding `libc` for one number we never ship.
    pub fn total_ram_gb() -> f64 {
        std::process::Command::new("sysctl")
            .args(["-n", "hw.memsize"])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .and_then(|s| s.trim().parse::<u64>().ok())
            .map_or(0.0, |bytes| bytes as f64 / GB)
    }

    /// No DXGI off Windows, and this probe only ever gates a Windows download.
    pub fn discrete_gpu() -> Option<(Option<String>, f64)> {
        None
    }
}

/// Name the instruction set by architecture. Saying "no AVX2" on an ARM machine would be
/// meaningless to the person reading the onboarding card.
fn simd_label(present: bool) -> String {
    let name = if cfg!(any(target_arch = "x86", target_arch = "x86_64")) {
        "AVX2"
    } else {
        "NEON"
    };
    if present {
        format!("{name} support")
    } else {
        format!("no {name}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Synthetic machines only — no probe() here, so this passes identically in CI on
    /// macOS, on a GPU-less Windows runner, and on ck's laptop.
    fn hw(cores: usize, fast_simd: bool, ram_gb: f64, vram_gb: f64) -> Hardware {
        Hardware {
            cores,
            fast_simd,
            ram_gb,
            gpu: (vram_gb > 0.0).then(|| "NVIDIA GeForce RTX 4060".to_string()),
            gpu_vram_gb: vram_gb,
        }
    }

    #[test]
    fn no_avx2_always_gets_tiny() {
        // Even a monster box without AVX2 runs scalar kernels.
        assert_eq!(hw(32, false, 128.0, 24.0).recommend(), "tiny.en");
    }

    #[test]
    fn tiny_ram_gets_tiny() {
        assert_eq!(hw(8, true, 3.5, 0.0).recommend(), "tiny.en");
    }

    #[test]
    fn wide_cpu_no_gpu_gets_small() {
        assert_eq!(hw(16, true, 32.0, 0.0).recommend(), "small.en");
    }

    #[test]
    fn typical_laptop_gets_base() {
        assert_eq!(hw(8, true, 8.0, 0.0).recommend(), "base.en"); // enough cores, not enough RAM
        assert_eq!(hw(4, true, 16.0, 0.0).recommend(), "base.en"); // enough RAM, not enough cores
    }

    #[test]
    fn thresholds_are_inclusive_at_the_boundary() {
        assert_eq!(hw(8, true, 4.0, 0.0).recommend(), "base.en");
        assert_eq!(hw(8, true, 16.0, 0.0).recommend(), "small.en");
    }

    /// A big card only unlocks turbo in a build that can actually offload to it.
    #[test]
    fn turbo_needs_a_gpu_build() {
        let big = hw(8, true, 16.0, 8.0).recommend();
        if GPU_OFFLOAD {
            assert_eq!(big, "large-v3-turbo-q5_0");
        } else {
            assert_eq!(big, "small.en");
        }
        // A 2 GB card never gets turbo: weights fit, KV cache and activations do not.
        assert_eq!(hw(8, true, 16.0, 2.0).recommend(), "small.en");
    }

    #[test]
    fn verdict_names_the_gpu_and_the_model() {
        let v = hw(16, true, 32.0, 8.0).verdict();
        assert!(v.contains("16 CPU cores"), "{v}");
        assert!(v.contains("32 GB RAM"), "{v}");
        assert!(v.contains("RTX 4060"), "{v}");
    }

    #[test]
    fn verdict_says_so_when_there_is_no_gpu() {
        let v = hw(4, true, 8.0, 0.0).verdict();
        assert!(v.contains("no discrete graphics card"), "{v}");
        assert!(v.contains("base.en"), "{v}");
    }

    #[test]
    fn verdict_singular_core_reads_correctly() {
        let v = hw(1, false, 2.0, 0.0).verdict();
        assert!(v.contains("1 CPU core,"), "{v}");
        // Named per architecture, so assert against the helper rather than hardcoding "AVX2":
        // this test also runs on the aarch64 dev box, where the label is NEON.
        assert!(v.contains(&simd_label(false)), "{v}");
        assert!(v.contains("tiny.en"), "{v}");
    }

    /// The recommender's output is fed straight to models::by_id, so it must always name
    /// a catalog entry.
    #[test]
    fn every_recommendation_is_in_the_catalog() {
        for cores in [1usize, 4, 8, 16] {
            for ram in [2.0f64, 4.0, 8.0, 16.0, 64.0] {
                for vram in [0.0f64, 2.0, 8.0] {
                    for fast_simd in [false, true] {
                        let id = hw(cores, fast_simd, ram, vram).recommend();
                        assert!(crate::models::by_id(id).is_some(), "{id} not in catalog");
                    }
                }
            }
        }
    }
}
