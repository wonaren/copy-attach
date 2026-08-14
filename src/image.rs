//! Image encoding, decoding, thumbnail generation, and content hashing.

use image::imageops::FilterType;

/// Encode raw RGBA bytes into PNG format, writing into `output`. The buffer
/// is reused across captures: capacity is retained between calls, so repeated
/// image copies don't allocate-and-free a fresh multi-MB Vec (and its
/// doubling realloc chain) each time.
pub(crate) fn encode_png_into(width: u32, height: u32, rgba_bytes: &[u8], output: &mut Vec<u8>) -> Option<()> {
    use image::{ImageBuffer, Rgba};
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    output.clear();
    img.write_to(&mut std::io::Cursor::new(output), image::ImageFormat::Png).ok()?;
    Some(())
}

/// Encode raw RGBA bytes into PNG format.
pub(crate) fn encode_png(width: u32, height: u32, rgba_bytes: &[u8]) -> Option<Vec<u8>> {
    let mut output = Vec::new();
    encode_png_into(width, height, rgba_bytes, &mut output)?;
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

/// Create a thumbnail with `CatmullRom` filtering.
/// Visually indistinguishable from Lanczos3 at small output sizes, ~2× faster.
pub(crate) fn create_thumbnail_fast(
    width: u32, height: u32, rgba_bytes: &[u8], max_dim: u32,
) -> Option<(Vec<u8>, u32, u32)> {
    create_thumbnail_with_filter(width, height, rgba_bytes, max_dim, FilterType::CatmullRom)
}

/// Ensure the thumbnail short side has at least this many pixels
/// so that horizontally long images don't render blurry in the UI.
/// Computed as `max_dim/5` so it scales with the caller's `max_dim`
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
    let scale_long = (f64::from(max_dim) / f64::from(width.max(height))).min(1.0);
    if scale_long >= 1.0 {
        return encode_png(width, height, rgba_bytes).map(|d| (d, width, height));
    }

    // Ensure the short side doesn't drop below max_dim / MIN_THUMB_SHORT_RATIO.
    // Without this, a 1920×100 image would produce a 300×16 thumbnail
    // that gets upscaled 3× in the UI row → blurry.
    let min_short = (max_dim / MIN_THUMB_SHORT_RATIO).max(1);
    let scale = if (f64::from(width.min(height)) * scale_long) < f64::from(min_short) {
        let by_short = (f64::from(min_short) / f64::from(width.min(height))).min(1.0);
        let long_candidate = f64::from(width.max(height)) * by_short;
        if long_candidate > f64::from(MAX_THUMB_LONG) {
            f64::from(MAX_THUMB_LONG) / f64::from(width.max(height))
        } else {
            by_short
        }
    } else {
        scale_long
    };

    let new_w = (f64::from(width) * scale).round() as u32;
    let new_h = (f64::from(height) * scale).round() as u32;
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    let thumb = image::imageops::resize(&img, new_w.max(1), new_h.max(1), filter);
    let mut output = Vec::new();
    thumb.write_to(&mut std::io::Cursor::new(&mut output), image::ImageFormat::Png).ok()?;
    Some((output, new_w.max(1), new_h.max(1)))
}

/// Compute a content hash (dimensions + raw pixels) for image deduplication.
///
/// FNV-1a 64 via `types::fnv1a` — the same stable-algorithm rationale as
/// `text_hash`: the value is persisted in SQLite, and a std `DefaultHasher`
/// drift would silently break cross-restart image dedup.
pub(crate) fn image_hash(data: &[u8], width: u32, height: u32) -> u64 {
    crate::types::fnv1a(
        width
            .to_le_bytes()
            .into_iter()
            .chain(height.to_le_bytes())
            .chain(data.iter().copied()),
    )
}
