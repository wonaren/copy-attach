mod text;
mod image;
mod inject;

pub use inject::{bench_count, bench_snapshot_clone, default_db_path, ffi_inject, ffi_reset, inject_into_db};

#[derive(Clone, Copy)]
pub enum TextLength {
    Short,
    Medium,
    MedLong,
    Long,
    XLong,
}

#[derive(Clone, Copy)]
pub enum ImageResolution {
    Res540p,
    Res1k,
    Res2k,
    Res4k,
    Res8k,
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

#[derive(Default)]
pub struct InjectStats {
    pub total: usize,
    pub texts: usize,
    pub images: usize,
    pub db_size_bytes: i64,
    pub elapsed_ms: u64,
    pub text_sizes: [usize; 5],
    pub image_sizes: [usize; 5],
}

fn splitmix64(mut state: u64) -> impl FnMut() -> u64 {
    move || {
        state = state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
}
