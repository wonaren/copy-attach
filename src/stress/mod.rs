//! Stress-test data generation and in-app benchmarking.
//!
//! All items here are gated behind the `stress-test` feature (never ships in
//! release builds). The CLI binary `stress-gen` and the Swift stress panel both
//! call into this module.
//!
//! ## Data Distribution (10,000 entries)
//!
//! **Text (6,000; 60%)** — 5 length bands, 1,200 each:
//!   - short:   16–64 B    (tweet-like snippets)
//!   - medium:  256–1024 B (paragraphs)
//!   - medlong:  4k–16k B  (markdown docs)
//!   - long:    16k–32k B  (code files, logs)
//!   - xlong:   48k–64k B  (long articles)
//!
//! **Image (4,000; 40%)** — 5 resolutions, 800 each:
//!   540p (960×540), 1k (1920×1080), 2k (2560×1440),
//!   4k (3840×2160), 8k (7680×4320)
//!
//! Submodules: `text` (word-pool content generation), `image` (block-based RGBA
//! rendering), `inject` (DB injection + FFI/benchmark helpers). The shared RNG
//! `splitmix64` and the public types live here; the `pub use` re-exports keep
//! the `copy_attach::stress::*` API stable for the binaries and the FFI layer.

mod text;
mod image;
mod inject;

pub use inject::{bench_count, bench_snapshot_clone, default_db_path, ffi_inject, ffi_reset, inject_into_db};

/// Text length categories with their target byte ranges.
#[derive(Clone, Copy)]
pub enum TextLength {
    Short,     // 16–64 B
    Medium,    // 256–1024 B
    MedLong,   // 4k–16k B
    Long,      // 16k–32k B
    XLong,     // 48k–64k B
}

/// Resolution categories.
#[derive(Clone, Copy)]
pub enum ImageResolution {
    Res540p,   // 960×540
    Res1k,     // 1920×1080
    Res2k,     // 2560×1440
    Res4k,     // 3840×2160
    Res8k,     // 7680×4320
}

impl ImageResolution {
    pub fn dims(&self) -> (u32, u32) {
        match self {
            ImageResolution::Res540p => (960, 540),
            ImageResolution::Res1k => (1920, 1080),
            ImageResolution::Res2k => (2560, 1440),
            ImageResolution::Res4k => (3840, 2160),
            ImageResolution::Res8k => (7680, 4320),
        }
    }
}

/// Stats collected during data generation.
#[derive(Default)]
pub struct InjectStats {
    pub total: usize,
    pub texts: usize,
    pub images: usize,
    pub db_size_bytes: i64,
    pub elapsed_ms: u64,
    pub text_sizes: [usize; 5], // per-category counts
    pub image_sizes: [usize; 5],
}

/// SplitMix64 pseudo-random generator (fast, deterministic).
/// Shared by text and image generation so both derive content from the same
/// deterministic stream for a given seed.
fn splitmix64(mut state: u64) -> impl FnMut() -> u64 {
    move || {
        state = state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
}
