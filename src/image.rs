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

/// Decode an 8-bit RGBA PNG directly into a caller-owned buffer (the pooled
/// capture decode scratch) — the capture path's dominant and largest transient
/// (macOS pasteboard screenshots are exactly 8-bit RGBA PNGs). The generic
/// `image::load_from_memory` decoder allocates a `DynamicImage` plus an RGBA
/// `ImageBuffer` per capture; this path writes the pixels straight into the
/// pooled buffer with zero intermediate allocation.
///
/// Returns `None` for any other color type / bit depth (RGB8, grayscale,
/// palette, 16-bit, APNG — the generic path handles those) — never a
/// different format: callers must fall back, not proceed. On success `out` is
/// exactly `width * height * 4` bytes (grown if needed, truncated from any
/// larger pooled capacity).
pub(crate) fn decode_png_rgba8_into(png: &[u8], out: &mut Vec<u8>) -> Option<(u32, u32)> {
    use image::codecs::png::PngDecoder;
    use image::ImageDecoder;
    let decoder = PngDecoder::new(std::io::Cursor::new(png)).ok()?;
    let (w, h) = decoder.dimensions();
    if decoder.color_type() != image::ColorType::Rgba8 || w == 0 || h == 0 {
        return None;
    }
    let needed = (w as usize) * (h as usize) * 4;
    if out.len() < needed {
        out.resize(needed, 0);
    }
    decoder.read_image(&mut out[..needed]).ok()?;
    out.truncate(needed);
    Some((w, h))
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

/// Aspect-preserving downscale dimensions to at most `max_dim` on the longest
/// side (never upscales). Identity when `max_dim` is 0 or the image fits.
pub(crate) fn resize_dims(width: u32, height: u32, max_dim: u32) -> (u32, u32) {
    let longest = width.max(height);
    if max_dim == 0 || longest <= max_dim {
        return (width, height);
    }
    let scale = f64::from(max_dim) / f64::from(longest);
    (
        (f64::from(width) * scale).round().max(1.0) as u32,
        (f64::from(height) * scale).round().max(1.0) as u32,
    )
}

/// CatmullRom kernel: `c(0) = 1`, `c(1) = 0`, `c(2) = 0`, symmetric.
fn catmull_rom(t: f32) -> f32 {
    let t = t.abs();
    if t < 1.0 {
        1.5 * t * t * t - 2.5 * t * t + 1.0
    } else if t < 2.0 {
        -0.5 * t * t * t + 2.5 * t * t - 4.0 * t + 2.0
    } else {
        0.0
    }
}

/// Sample `width` RGBA8 pixels of `row` at fractional position `center`
/// (in source-pixel coordinates) with a 4-tap CatmullRom kernel, edge-clamped
/// and renormalized (interior taps already sum to 1; clamping makes the edge
/// weights exceed 1, so renormalization keeps edges from darkening).
fn sample_catmull_row(row: &[u8], width: u32, center: f32, out: &mut [u8]) {
    let base = center.floor() as i64;
    let mut acc = [0f32; 4];
    let mut wsum = 0f32;
    for i in 0..4 {
        let src_x = base - 1 + i as i64;
        let wt = catmull_rom(center - src_x as f32);
        if wt == 0.0 {
            continue;
        }
        let clamped = src_x.clamp(0, width as i64 - 1) as usize;
        wsum += wt;
        let p = &row[clamped * 4..clamped * 4 + 4];
        acc[0] += wt * p[0] as f32;
        acc[1] += wt * p[1] as f32;
        acc[2] += wt * p[2] as f32;
        acc[3] += wt * p[3] as f32;
    }
    if wsum > 0.0 {
        out[0] = (acc[0] / wsum).round().clamp(0.0, 255.0) as u8;
        out[1] = (acc[1] / wsum).round().clamp(0.0, 255.0) as u8;
        out[2] = (acc[2] / wsum).round().clamp(0.0, 255.0) as u8;
        out[3] = (acc[3] / wsum).round().clamp(0.0, 255.0) as u8;
    } else {
        // Degenerate (impossible for width >= 1): copy the nearest pixel.
        let cx = (center.round() as i64).clamp(0, width as i64 - 1) as usize;
        out.copy_from_slice(&row[cx * 4..cx * 4 + 4]);
    }
}

/// Two-pass CatmullRom RGBA8 downscale into a fresh buffer.
///
/// Replaces `image::imageops::resize`, which converts through an
/// `Rgba32FImage` working buffer of `width × dst_h × 16` bytes — a 60.5 MB
/// calloc for a 2940×1846→2048 preview. That buffer is freed without ever
/// being returned to the process footprint on macOS (the freed-but-retained
/// residue this session is eliminating), so it must not be allocated at all.
/// This implementation resamples in u8 with a single horizontal intermediate
/// (`dst_w × src_h × 4`) whose pages are marked reusable before it drops.
///
/// The horizontal pass writes the intermediate, the vertical pass reads it
/// (strided but one-shot); alpha is treated as straight (non-premultiplied),
/// matching the pool buffers — unlike `imageops::resize`, which assumes
/// premultiplied alpha and can tint semi-transparent pixels.
///
/// Returns None only when the source is empty or `src` is shorter than
/// `width × height × 4`. Never upscales: an output equal to or larger than
/// the input returns a copy of the source.
pub(crate) fn resize_rgba(
    src: &[u8],
    width: u32,
    height: u32,
    dst_w: u32,
    dst_h: u32,
) -> Option<Vec<u8>> {
    if width == 0 || height == 0 || dst_w == 0 || dst_h == 0 {
        return None;
    }
    let src_len = (width as usize) * (height as usize) * 4;
    if src.len() < src_len {
        return None;
    }
    if dst_w >= width && dst_h >= height {
        // Never upscale (callers route through `resize_dims`, which already
        // guarantees this) — return the source pixels unchanged.
        return Some(src[..src_len].to_vec());
    }

    let scale_x = width as f32 / dst_w as f32;
    let scale_y = height as f32 / dst_h as f32;

    // Horizontal pass: src(w×h) → tmp(dst_w×h).
    let tmp_len = (dst_w as usize) * (height as usize) * 4;
    let mut tmp = vec![0u8; tmp_len];
    // Claim before writing: the allocator may have handed back pages still
    // marked reusable from an earlier scratch (they stay kernel-reclaimable —
    // and uncounted — until claimed; every byte below is rewritten after the
    // claim, so any prior contents are irrelevant).
    crate::backend::claim_pages(tmp.as_ptr(), tmp.capacity());
    for y in 0..height {
        let src_row = &src[(y as usize) * (width as usize) * 4..];
        let tmp_row = &mut tmp[(y as usize) * (dst_w as usize) * 4..];
        for x in 0..dst_w {
            let center = (x as f32 + 0.5) * scale_x - 0.5;
            sample_catmull_row(src_row, width, center, &mut tmp_row[(x as usize) * 4..]);
        }
    }

    // Vertical pass: tmp(dst_w×h) → out(dst_w×dst_h).
    let mut out = vec![0u8; (dst_w as usize) * (dst_h as usize) * 4];
    crate::backend::claim_pages(out.as_ptr(), out.capacity());
    let row_bytes = (dst_w as usize) * 4;
    for y in 0..dst_h {
        let center = (y as f32 + 0.5) * scale_y - 0.5;
        let base = center.floor() as i64;
        let out_row = &mut out[(y as usize) * row_bytes..];
        for x in 0..dst_w {
            let mut acc = [0f32; 4];
            let mut wsum = 0f32;
            for i in 0..4 {
                let src_y = base - 1 + i as i64;
                let wt = catmull_rom(center - src_y as f32);
                if wt == 0.0 {
                    continue;
                }
                let clamped = src_y.clamp(0, height as i64 - 1) as usize;
                wsum += wt;
                let p = &tmp[clamped * row_bytes + (x as usize) * 4..];
                acc[0] += wt * p[0] as f32;
                acc[1] += wt * p[1] as f32;
                acc[2] += wt * p[2] as f32;
                acc[3] += wt * p[3] as f32;
            }
            let o = &mut out_row[(x as usize) * 4..];
            if wsum > 0.0 {
                o[0] = (acc[0] / wsum).round().clamp(0.0, 255.0) as u8;
                o[1] = (acc[1] / wsum).round().clamp(0.0, 255.0) as u8;
                o[2] = (acc[2] / wsum).round().clamp(0.0, 255.0) as u8;
                o[3] = (acc[3] / wsum).round().clamp(0.0, 255.0) as u8;
            } else {
                let cy = (center.round() as i64).clamp(0, height as i64 - 1) as usize;
                let p = &tmp[cy * row_bytes + (x as usize) * 4..];
                o.copy_from_slice(&p[..4]);
            }
        }
    }

    // The intermediate never leaves this function — return its pages to the
    // system now (on macOS, freed large malloc blocks stay in the footprint
    // otherwise, which is exactly the residue this function avoids).
    crate::backend::mark_pages_reusable(tmp.as_ptr(), tmp.capacity());
    Some(out)
}
