//! Image encoding, decoding, thumbnail generation, and content hashing.

use image::imageops::FilterType;

/// Encode raw RGBA bytes into PNG format.
pub(crate) fn encode_png(width: u32, height: u32, rgba_bytes: &[u8]) -> Option<Vec<u8>> {
    use image::{ImageBuffer, Rgba};
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    let mut output = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut output), image::ImageFormat::Png).ok()?;
    Some(output)
}

/// Decode PNG bytes back into raw RGBA data plus dimensions.
pub(crate) fn decode_png(png_data: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    let img = image::load_from_memory(png_data).ok()?;
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    Some((rgba.into_raw(), w, h))
}

/// Create a thumbnail with Lanczos3 filtering (highest quality).
pub(crate) fn create_thumbnail(
    width: u32, height: u32, rgba_bytes: &[u8], max_dim: u32,
) -> Option<(Vec<u8>, u32, u32)> {
    create_thumbnail_with_filter(width, height, rgba_bytes, max_dim, FilterType::Lanczos3)
}

/// Create a thumbnail with CatmullRom filtering.
/// Visually indistinguishable from Lanczos3 at small output sizes, ~2× faster.
pub(crate) fn create_thumbnail_fast(
    width: u32, height: u32, rgba_bytes: &[u8], max_dim: u32,
) -> Option<(Vec<u8>, u32, u32)> {
    create_thumbnail_with_filter(width, height, rgba_bytes, max_dim, FilterType::CatmullRom)
}

/// Ensure the thumbnail short side has at least this many pixels
/// so that horizontally long images don't render blurry in the UI.
/// Computed as max_dim/5 so it scales with the caller's max_dim
/// (e.g. 60px for the standard 300px max thumbnail dimension).
const MIN_THUMB_SHORT_RATIO: u32 = 5;

/// Hard cap on the thumbnail long side to prevent extreme panoramas
/// from generating oversized thumbnails.
const MAX_THUMB_LONG: u32 = 900;

/// Core thumbnail logic parameterized by resize filter.
fn create_thumbnail_with_filter(
    width: u32, height: u32, rgba_bytes: &[u8], max_dim: u32,
    filter: FilterType,
) -> Option<(Vec<u8>, u32, u32)> {
    use image::{ImageBuffer, Rgba};
    let scale_long = (max_dim as f64 / width.max(height) as f64).min(1.0);
    if scale_long >= 1.0 {
        return encode_png(width, height, rgba_bytes).map(|d| (d, width, height));
    }

    // Ensure the short side doesn't drop below max_dim / MIN_THUMB_SHORT_RATIO.
    // Without this, a 1920×100 image would produce a 300×16 thumbnail
    // that gets upscaled 3× in the UI row → blurry.
    let min_short = (max_dim / MIN_THUMB_SHORT_RATIO).max(1);
    let scale = if (width.min(height) as f64 * scale_long) < min_short as f64 {
        let by_short = (min_short as f64 / width.min(height) as f64).min(1.0);
        let long_candidate = width.max(height) as f64 * by_short;
        if long_candidate > MAX_THUMB_LONG as f64 {
            MAX_THUMB_LONG as f64 / width.max(height) as f64
        } else {
            by_short
        }
    } else {
        scale_long
    };

    let new_w = (width as f64 * scale).round() as u32;
    let new_h = (height as f64 * scale).round() as u32;
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    let thumb = image::imageops::resize(&img, new_w.max(1), new_h.max(1), filter);
    let mut output = Vec::new();
    thumb.write_to(&mut std::io::Cursor::new(&mut output), image::ImageFormat::Png).ok()?;
    Some((output, new_w.max(1), new_h.max(1)))
}

/// Compute a content hash (dimensions + raw pixels) for image deduplication.
pub(crate) fn image_hash(data: &[u8], width: u32, height: u32) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    width.hash(&mut hasher);
    height.hash(&mut hasher);
    data.hash(&mut hasher);
    hasher.finish()
}
