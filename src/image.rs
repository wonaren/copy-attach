#[cfg(test)]
use image::imageops::FilterType;

pub(crate) fn encode_png_into(width: u32, height: u32, rgba_bytes: &[u8], output: &mut Vec<u8>) -> Option<()> {
    use image::{ImageBuffer, Rgba};
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    output.clear();
    if output.capacity() < rgba_bytes.len() {
        let fresh: Vec<u8> = Vec::with_capacity(rgba_bytes.len());
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

pub(crate) fn encode_png(width: u32, height: u32, rgba_bytes: &[u8]) -> Option<Vec<u8>> {
    let mut output = Vec::new();
    encode_png_into(width, height, rgba_bytes, &mut output)?;
    Some(output)
}

pub(crate) fn decode_png(png_data: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    let img = image::load_from_memory(png_data).ok()?;
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    Some((rgba.into_raw(), w, h))
}

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
        let fresh: Vec<u8> = Vec::with_capacity(needed);
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

#[cfg(test)]
pub(crate) fn create_thumbnail(
    width: u32, height: u32, rgba_bytes: &[u8],
) -> Option<(Vec<u8>, u32, u32)> {
    create_thumbnail_with_filter(width, height, rgba_bytes, FilterType::Lanczos3)
}

pub(crate) fn create_thumbnail_fast(
    width: u32, height: u32, rgba_bytes: &[u8],
) -> Option<(Vec<u8>, u32, u32)> {
    let (new_w, new_h) = match thumbnail_target_dims(width, height) {
        Some(d) => d,
        None => return encode_png(width, height, rgba_bytes).map(|d| (d, width, height)),
    };
    let resized = resize_rgba(rgba_bytes, width, height, new_w, new_h)?;
    let encoded = encode_png(new_w, new_h, &resized).map(|d| (d, new_w, new_h));
    crate::backend::mark_pages_reusable(resized.as_ptr(), resized.capacity());
    encoded
}

pub(crate) const THUMB_BOX_W_PT: u32 = 460;
pub(crate) const THUMB_BOX_H_PT: u32 = 100;

pub(crate) const THUMB_MAX_DISPLAY_SCALE: u32 = 2;

pub(crate) const THUMB_BOX_W: u32 = THUMB_BOX_W_PT * THUMB_MAX_DISPLAY_SCALE;
pub(crate) const THUMB_BOX_H: u32 = THUMB_BOX_H_PT * THUMB_MAX_DISPLAY_SCALE;

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

pub(crate) fn image_hash(data: &[u8], width: u32, height: u32) -> u64 {
    crate::types::fnv1a(
        width
            .to_le_bytes()
            .into_iter()
            .chain(height.to_le_bytes())
            .chain(data.iter().copied()),
    )
}

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
        let cx = (center.round() as i64).clamp(0, width as i64 - 1) as usize;
        out.copy_from_slice(&row[cx * 4..cx * 4 + 4]);
    }
}

const RESIZE_RING_ROWS: usize = 8;

pub(crate) fn resize_rgba_into(
    src: &[u8],
    width: u32,
    height: u32,
    dst_w: u32,
    dst_h: u32,
    dst: &mut [u8],
) -> Option<()> {
    if width == 0 || height == 0 || dst_w == 0 || dst_h == 0 {
        return None;
    }
    let src_len = (width as usize) * (height as usize) * 4;
    if src.len() < src_len {
        return None;
    }
    let row_bytes = (dst_w as usize) * 4;
    let dst_len = row_bytes * (dst_h as usize);
    if dst.len() < dst_len {
        return None;
    }
    if dst_w >= width && dst_h >= height {
        dst[..src_len].copy_from_slice(&src[..src_len]);
        return Some(());
    }

    let scale_x = width as f32 / dst_w as f32;
    let scale_y = height as f32 / dst_h as f32;

    let mut ring = vec![0u8; row_bytes * RESIZE_RING_ROWS];
    if !crate::backend::claim_pages(ring.as_ptr(), ring.capacity()) {
        crate::error_log!("CopyAttach: resize ring scratch cap={} could not be claimed", ring.capacity());
        return None;
    }
    let mut ring_valid = [-1i64; RESIZE_RING_ROWS];

    for y in 0..dst_h as usize {
        let center = (y as f32 + 0.5) * scale_y - 0.5;
        let base = center.floor() as i64;
        for i in 0..4 {
            let cy = (base - 1 + i as i64).clamp(0, height as i64 - 1);
            let slot = (cy as usize) % RESIZE_RING_ROWS;
            if ring_valid[slot] != cy {
                let src_row = &src[(cy as usize) * (width as usize) * 4..];
                let dst_row = &mut ring[slot * row_bytes..(slot + 1) * row_bytes];
                for x in 0..dst_w as usize {
                    let cx = (x as f32 + 0.5) * scale_x - 0.5;
                    sample_catmull_row(src_row, width, cx, &mut dst_row[x * 4..]);
                }
                ring_valid[slot] = cy;
            }
        }
        let out_row = &mut dst[y * row_bytes..(y + 1) * row_bytes];
        for x in 0..dst_w as usize {
            let mut acc = [0f32; 4];
            let mut wsum = 0f32;
            for i in 0..4 {
                let src_y = base - 1 + i as i64;
                let wt = catmull_rom(center - src_y as f32);
                if wt == 0.0 {
                    continue;
                }
                let cy = src_y.clamp(0, height as i64 - 1);
                let slot = (cy as usize) % RESIZE_RING_ROWS;
                wsum += wt;
                let p = &ring[slot * row_bytes + x * 4..];
                acc[0] += wt * p[0] as f32;
                acc[1] += wt * p[1] as f32;
                acc[2] += wt * p[2] as f32;
                acc[3] += wt * p[3] as f32;
            }
            let o = &mut out_row[x * 4..];
            if wsum > 0.0 {
                o[0] = (acc[0] / wsum).round().clamp(0.0, 255.0) as u8;
                o[1] = (acc[1] / wsum).round().clamp(0.0, 255.0) as u8;
                o[2] = (acc[2] / wsum).round().clamp(0.0, 255.0) as u8;
                o[3] = (acc[3] / wsum).round().clamp(0.0, 255.0) as u8;
            } else {
                let cy = (center.round() as i64).clamp(0, height as i64 - 1) as usize;
                let slot = cy % RESIZE_RING_ROWS;
                let p = &ring[slot * row_bytes + x * 4..];
                o.copy_from_slice(&p[..4]);
            }
        }
    }

    crate::backend::mark_pages_reusable(ring.as_ptr(), ring.capacity());
    Some(())
}

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
        return Some(src[..src_len].to_vec());
    }
    let mut out = vec![0u8; (dst_w as usize) * (dst_h as usize) * 4];
    if !crate::backend::claim_pages(out.as_ptr(), out.capacity()) {
        crate::error_log!("CopyAttach: resize output cap={} could not be claimed", out.capacity());
        return None;
    }
    match resize_rgba_into(src, width, height, dst_w, dst_h, &mut out) {
        Some(()) => Some(out),
        None => {
            crate::backend::mark_pages_reusable(out.as_ptr(), out.capacity());
            None
        }
    }
}

#[cfg(test)]
pub(crate) fn resize_rgba_reference(
    src: &[u8], width: u32, height: u32, dst_w: u32, dst_h: u32,
) -> Option<Vec<u8>> {
    if width == 0 || height == 0 || dst_w == 0 || dst_h == 0 {
        return None;
    }
    let src_len = (width as usize) * (height as usize) * 4;
    if src.len() < src_len {
        return None;
    }
    if dst_w >= width && dst_h >= height {
        return Some(src[..src_len].to_vec());
    }
    let scale_x = width as f32 / dst_w as f32;
    let scale_y = height as f32 / dst_h as f32;
    let row_bytes = (dst_w as usize) * 4;
    let mut tmp = vec![0u8; row_bytes * (height as usize)];
    for y in 0..height as usize {
        let src_row = &src[y * (width as usize) * 4..];
        let tmp_row = &mut tmp[y * row_bytes..(y + 1) * row_bytes];
        for x in 0..dst_w as usize {
            let center = (x as f32 + 0.5) * scale_x - 0.5;
            sample_catmull_row(src_row, width, center, &mut tmp_row[x * 4..]);
        }
    }
    let mut out = vec![0u8; row_bytes * (dst_h as usize)];
    for y in 0..dst_h as usize {
        let center = (y as f32 + 0.5) * scale_y - 0.5;
        let base = center.floor() as i64;
        let out_row = &mut out[y * row_bytes..(y + 1) * row_bytes];
        for x in 0..dst_w as usize {
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
                let p = &tmp[clamped * row_bytes + x * 4..];
                acc[0] += wt * p[0] as f32;
                acc[1] += wt * p[1] as f32;
                acc[2] += wt * p[2] as f32;
                acc[3] += wt * p[3] as f32;
            }
            let o = &mut out_row[x * 4..];
            if wsum > 0.0 {
                o[0] = (acc[0] / wsum).round().clamp(0.0, 255.0) as u8;
                o[1] = (acc[1] / wsum).round().clamp(0.0, 255.0) as u8;
                o[2] = (acc[2] / wsum).round().clamp(0.0, 255.0) as u8;
                o[3] = (acc[3] / wsum).round().clamp(0.0, 255.0) as u8;
            } else {
                let cy = (center.round() as i64).clamp(0, height as i64 - 1) as usize;
                o.copy_from_slice(&tmp[cy * row_bytes + x * 4..][..4]);
            }
        }
    }
    Some(out)
}
