//! Image encoding, decoding, thumbnail generation, and content hashing.

#[cfg(test)]
use image::imageops::FilterType;

/// Encode raw RGBA bytes into PNG, reusing `output`'s capacity.
pub(crate) fn encode_png_into(width: u32, height: u32, rgba_bytes: &[u8], output: &mut Vec<u8>) -> Option<()> {
    use image::{ImageBuffer, Rgba};
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    output.clear();
    // Same rule as `decode_png_rgba8_into`: never let the pooled buffer grow
    // through a realloc chain (the spliced mapping rejects madvise). PNG output
    // never exceeds the raw RGBA size, so a single whole allocation of that
    // size is an upper bound; pages the encoder never touches stay clean.
    if output.capacity() < rgba_bytes.len() {
        let fresh: Vec<u8> = Vec::with_capacity(rgba_bytes.len());
        // Claim before the encoder writes. The encoder writes the whole PNG
        // stream and the reader below never sees bytes it did not produce, so
        // a rejected claim is not recoverable by reading around it — bail out
        // and let the caller treat the encode as failed.
        if !crate::backend::claim_pages(fresh.as_ptr(), fresh.capacity()) {
            crate::error_log!("CopyAttach: encode scratch cap={} could not be claimed", fresh.capacity());
            return None;
        }
        let old = std::mem::replace(output, fresh);
        crate::backend::mark_pages_reusable(old.as_ptr(), old.capacity());
    }
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

/// Decode an 8-bit RGBA PNG directly into `out` (zero intermediate allocation).
/// Returns None for other formats so callers can fall back to the generic path.
pub(crate) fn decode_png_rgba8_into(png: &[u8], out: &mut Vec<u8>) -> Option<(u32, u32)> {
    use image::codecs::png::PngDecoder;
    use image::ImageDecoder;
    let decoder = PngDecoder::new(std::io::Cursor::new(png)).ok()?;
    let (w, h) = decoder.dimensions();
    if decoder.color_type() != image::ColorType::Rgba8 || w == 0 || h == 0 {
        return None;
    }
    let needed = (w as usize) * (h as usize) * 4;
    if out.capacity() < needed {
        // Never grow the pooled buffer via realloc: libmalloc extends large
        // blocks in place across several VM entries and the resulting mapping
        // rejects MADV_FREE_REUSABLE/REUSE (EINVAL), which would defeat the
        // idle-pool footprint contract. A fresh whole allocation is always a
        // single mapping; claim it before the decoder writes.
        let fresh: Vec<u8> = Vec::with_capacity(needed);
        // Same rule as the encode path: the decoder writes every byte the
        // caller will read, so an unclaimable buffer means the decode cannot
        // be trusted. Report it as a decode failure (callers fall back or
        // decline) instead of decoding onto reclaimable pages.
        if !crate::backend::claim_pages(fresh.as_ptr(), fresh.capacity()) {
            crate::error_log!("CopyAttach: decode scratch cap={} could not be claimed", fresh.capacity());
            return None;
        }
        let old = std::mem::replace(out, fresh);
        crate::backend::mark_pages_reusable(old.as_ptr(), old.capacity());
    }
    if out.len() < needed {
        out.resize(needed, 0);
    }
    decoder.read_image(&mut out[..needed]).ok()?;
    out.truncate(needed);
    Some((w, h))
}

/// Create a thumbnail with Lanczos3 filtering (highest quality).
///
/// Test-only: production capture/preview paths use [`create_thumbnail_fast`]
/// (in-house two-pass CatmullRom). Keeping this `imageops::resize` path in
/// release builds would leave the very `dst_w × src_h × 16B` float
/// intermediate the memory work removed from the hot path.
#[cfg(test)]
pub(crate) fn create_thumbnail(
    width: u32, height: u32, rgba_bytes: &[u8],
) -> Option<(Vec<u8>, u32, u32)> {
    create_thumbnail_with_filter(width, height, rgba_bytes, FilterType::Lanczos3)
}

/// Create a thumbnail with `CatmullRom` filtering.
/// Visually indistinguishable from Lanczos3 at small output sizes, ~2× faster.
///
/// Resizes via the in-house u8 two-pass [`resize_rgba`]: `imageops::resize`
/// would allocate a `dst_w × src_h × 16B` float intermediate per capture
/// (~14MB for a 5K screenshot) whose pages are never returned to the OS.
pub(crate) fn create_thumbnail_fast(
    width: u32, height: u32, rgba_bytes: &[u8],
) -> Option<(Vec<u8>, u32, u32)> {
    let (new_w, new_h) = match thumbnail_target_dims(width, height) {
        Some(d) => d,
        None => return encode_png(width, height, rgba_bytes).map(|d| (d, width, height)),
    };
    let resized = resize_rgba(rgba_bytes, width, height, new_w, new_h)?;
    let encoded = encode_png(new_w, new_h, &resized).map(|d| (d, new_w, new_h));
    // Release-path symmetry: `resize_rgba` claims the output pages before
    // returning, so they must be marked reusable when this transient buffer
    // drops (the encode above has already read every byte).
    crate::backend::mark_pages_reusable(resized.as_ptr(), resized.capacity());
    encoded
}

/// Row thumbnail display budget, in points. The list row renders an image with
/// `.resizable().aspectRatio(.fit).frame(maxHeight: 100)` inside a 500pt-wide
/// popup; after the app-icon column and row/list padding an image may span
/// ~460pt of width and 100pt of height. The budget is therefore a **box**
/// (460 × 100 pt), not a single longest-edge cap: a 30:1 panorama is bounded by
/// the width, a screenshot by the height. Swift mirrors these numbers in
/// `RowThumbnailBox`; changing one side without the other reintroduces the
/// upscale blur this replaced.
pub(crate) const THUMB_BOX_W_PT: u32 = 460;
pub(crate) const THUMB_BOX_H_PT: u32 = 100;

/// Highest display scale the stored blob must stay sharp at. macOS ships 1× and
/// 2× (Retina) only; capturing at the maximum means a Retina screen never
/// upscales, and the Swift decode box clamps back down to the live screen's scale.
pub(crate) const THUMB_MAX_DISPLAY_SCALE: u32 = 2;

/// Pixel box the stored thumbnail must fit: 920 × 200.
pub(crate) const THUMB_BOX_W: u32 = THUMB_BOX_W_PT * THUMB_MAX_DISPLAY_SCALE;
pub(crate) const THUMB_BOX_H: u32 = THUMB_BOX_H_PT * THUMB_MAX_DISPLAY_SCALE;

/// Aspect-preserving thumbnail target dims: fit the source into the display box
/// (`THUMB_BOX_W` × `THUMB_BOX_H`), never upscaling. Returns `None` when the
/// source already fits (encode it as-is).
///
/// A box fit — rather than the previous "long side 300, short side bumped to
/// 60, long side re-capped at 900" rule — is what keeps flat images sharp: the
/// row gives a 30:1 panorama ~460pt of width, so its stored long edge must be
/// ~920px, not 300.
///
/// The box's axes are width and height, **not** the source's long and short
/// sides. Matching a portrait source by long/short would bound it with the
/// box's 920 side when it is really the 200 side that limits it, letting the
/// blob exceed the row on the height axis.
pub(crate) fn thumbnail_target_dims(width: u32, height: u32) -> Option<(u32, u32)> {
    if width <= THUMB_BOX_W && height <= THUMB_BOX_H {
        return None;
    }
    let scale = (f64::from(THUMB_BOX_W) / f64::from(width))
        .min(f64::from(THUMB_BOX_H) / f64::from(height))
        .min(1.0);
    Some((
        (f64::from(width) * scale).round().max(1.0) as u32,
        (f64::from(height) * scale).round().max(1.0) as u32,
    ))
}

/// Core thumbnail logic parameterized by resize filter.
#[cfg(test)]
fn create_thumbnail_with_filter(
    width: u32, height: u32, rgba_bytes: &[u8],
    filter: FilterType,
) -> Option<(Vec<u8>, u32, u32)> {
    use image::{ImageBuffer, Rgba};
    let (new_w, new_h) = match thumbnail_target_dims(width, height) {
        Some(d) => d,
        None => return encode_png(width, height, rgba_bytes).map(|d| (d, width, height)),
    };
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    let thumb = image::imageops::resize(&img, new_w, new_h, filter);
    let mut output = Vec::new();
    thumb.write_to(&mut std::io::Cursor::new(&mut output), image::ImageFormat::Png).ok()?;
    Some((output, new_w, new_h))
}

/// Stable FNV-1a hash of dimensions + raw pixels for image dedup.
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

/// Sample one RGBA8 row at fractional `center` with an edge-clamped CatmullRom kernel.
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
/// Avoids `imageops::resize`'s large float intermediate and handles alpha as
/// straight (non-premultiplied). Never upscales.
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
        // Never upscale; return source pixels unchanged.
        return Some(src[..src_len].to_vec());
    }

    let scale_x = width as f32 / dst_w as f32;
    let scale_y = height as f32 / dst_h as f32;

    // Horizontal pass: src -> tmp.
    let tmp_len = (dst_w as usize) * (height as usize) * 4;
    let mut tmp = vec![0u8; tmp_len];
    // Claim pages before writing: every byte of both passes is written before
    // it is read, so a rejected claim would mean resampling from memory the
    // kernel may zero mid-pass. Fail the resize rather than produce a
    // possibly-corrupted image.
    if !crate::backend::claim_pages(tmp.as_ptr(), tmp.capacity()) {
        crate::error_log!("CopyAttach: resize horizontal scratch cap={} could not be claimed", tmp.capacity());
        return None;
    }
    for y in 0..height {
        let src_row = &src[(y as usize) * (width as usize) * 4..];
        let tmp_row = &mut tmp[(y as usize) * (dst_w as usize) * 4..];
        for x in 0..dst_w {
            let center = (x as f32 + 0.5) * scale_x - 0.5;
            sample_catmull_row(src_row, width, center, &mut tmp_row[(x as usize) * 4..]);
        }
    }

    // Vertical pass: tmp -> out.
    let mut out = vec![0u8; (dst_w as usize) * (dst_h as usize) * 4];
    if !crate::backend::claim_pages(out.as_ptr(), out.capacity()) {
        crate::error_log!("CopyAttach: resize output cap={} could not be claimed", out.capacity());
        return None;
    }
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

    // Return the intermediate's pages to the system before it drops.
    crate::backend::mark_pages_reusable(tmp.as_ptr(), tmp.capacity());
    Some(out)
}
