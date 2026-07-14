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

/// Core thumbnail logic parameterized by resize filter.
fn create_thumbnail_with_filter(
    width: u32, height: u32, rgba_bytes: &[u8], max_dim: u32,
    filter: FilterType,
) -> Option<(Vec<u8>, u32, u32)> {
    use image::{ImageBuffer, Rgba};
    let scale = (max_dim as f64 / width.max(height) as f64).min(1.0);
    if scale >= 1.0 {
        return encode_png(width, height, rgba_bytes).map(|d| (d, width, height));
    }
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
