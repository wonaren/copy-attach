// Image encode/decode, hashing, and metadata/label/preview tests.

use crate::image::{create_thumbnail, decode_png, encode_png, encode_png_into, image_hash};
use crate::types::ClipboardEntry;
use super::{make_image, make_test_image_rgba, make_text};

#[test]
fn test_encode_png_into_reuses_buffer() {
    let rgba = make_test_image_rgba(16, 16, 100);
    let expected = encode_png(16, 16, &rgba).expect("encode should succeed");

    // Stale content longer than the PNG output: a missing clear() would leave
    // a poisoned tail and fail the equality check below.
    let mut reused = Vec::with_capacity(64 * 1024);
    reused.extend_from_slice(&[0xAB; 4096]);
    assert!(encode_png_into(16, 16, &rgba, &mut reused).is_some());
    assert_eq!(reused, expected, "encode_png_into must clear stale bytes");

    // Second encode into the same buffer must not grow the allocation —
    // capacity is retained between captures (the whole point of the scratch).
    let cap = reused.capacity();
    assert!(encode_png_into(16, 16, &rgba, &mut reused).is_some());
    assert_eq!(reused.capacity(), cap, "scratch buffer must be reused, not reallocated");
    assert_eq!(reused, expected);
}

#[test]
fn test_encode_decode_png() {
    let rgba = make_test_image_rgba(16, 16, 100);
    let png = encode_png(16, 16, &rgba).expect("encode should succeed");
    assert!(!png.is_empty());
    let (decoded, w, h) = decode_png(&png).expect("decode should succeed");
    assert_eq!(w, 16);
    assert_eq!(h, 16);
    assert_eq!(decoded.len(), 16 * 16 * 4);
}

#[test]
fn test_decode_png_rgba8_into_pooled_buffer() {
    // The capture fast path: an 8-bit RGBA PNG (what `encode_png` produces —
    // exactly the pasteboard screenshot format) decodes straight into the
    // caller's buffer, byte-identical to the generic decoder.
    let rgba = make_test_image_rgba(4, 3, 7);
    let png = encode_png(4, 3, &rgba).expect("encode should succeed");

    let mut pooled = Vec::with_capacity(1024); // pre-grown scratch, like the pool
    pooled.extend_from_slice(&[0xEE; 64]);
    let (w, h) = crate::image::decode_png_rgba8_into(&png, &mut pooled)
        .expect("RGBA8 PNG must decode into the pooled buffer");
    assert_eq!((w, h), (4, 3));
    assert_eq!(pooled.len(), 4 * 3 * 4, "buffer must be exactly the image size");
    assert_eq!(&pooled[..], &rgba[..], "pooled decode must match generic decode bytes");
    assert!(pooled.capacity() >= 1024, "pre-grown scratch capacity must be retained");
}

#[test]
fn test_decode_png_rgba8_into_rejects_other_formats() {
    // RGB8 (no alpha), grayscale, and palette PNGs are not the fast path:
    // the function must refuse them so callers fall back to the generic
    // decoder instead of misreading a 3-channel buffer as RGBA.
    let rgb = image::ImageBuffer::<image::Rgb<u8>, Vec<u8>>::from_pixel(2, 2, image::Rgb([1, 2, 3]));
    let mut bytes = Vec::new();
    rgb.write_to(&mut std::io::Cursor::new(&mut bytes), image::ImageFormat::Png).unwrap();

    let gray = image::ImageBuffer::<image::Luma<u8>, Vec<u8>>::from_pixel(2, 2, image::Luma([9]));
    let mut gray_bytes = Vec::new();
    gray.write_to(&mut std::io::Cursor::new(&mut gray_bytes), image::ImageFormat::Png).unwrap();

    for png in [&bytes, &gray_bytes] {
        let mut buf = Vec::new();
        assert!(
            crate::image::decode_png_rgba8_into(png, &mut buf).is_none(),
            "non-RGBA8 PNG must fall back to the generic decoder"
        );
    }
}

#[test]
fn test_create_thumbnail() {
    let rgba = make_test_image_rgba(200, 100, 150);
    let thumb = create_thumbnail(200, 100, &rgba, 50);
    assert!(thumb.is_some());
    let (_, tw, th) = thumb.unwrap();
    assert!(tw <= 50 && th <= 50);
}

#[test]
fn test_image_hash_consistency() {
    let data1 = make_test_image_rgba(10, 10, 200);
    let data2 = make_test_image_rgba(10, 10, 200);
    assert_eq!(image_hash(&data1, 10, 10), image_hash(&data2, 10, 10));
}

#[test]
fn test_image_hash_different() {
    let data1 = make_test_image_rgba(10, 10, 200);
    let data2 = make_test_image_rgba(10, 10, 100);
    assert_ne!(image_hash(&data1, 10, 10), image_hash(&data2, 10, 10));
}

#[test]
fn test_source_app_fields() {
    let mut t = make_text("hello", 1);
    let img_data = make_test_image_rgba(5, 5, 50);
    let mut i = make_image(&img_data, 5, 5, 2);
    if let ClipboardEntry::Text { ref mut source_name, ref mut source_bundle_id, .. } = t {
        *source_name = "Safari".into();
        *source_bundle_id = "com.apple.Safari".into();
    }
    if let ClipboardEntry::Image { ref mut source_name, ref mut source_bundle_id, .. } = i {
        *source_name = "Photos".into();
        *source_bundle_id = "com.apple.Photos".into();
    }
    assert_eq!(t.source_name(), "Safari");
    assert_eq!(t.source_bundle_id(), "com.apple.Safari");
    assert_eq!(i.source_name(), "Photos");
    assert_eq!(i.source_bundle_id(), "com.apple.Photos");
}

#[test]
fn test_item_types() {
    let t = make_text("test", 1);
    let img_data = make_test_image_rgba(5, 5, 50);
    let i = make_image(&img_data, 5, 5, 2);
    assert_eq!(t.content_type(), 0);
    assert_eq!(i.content_type(), 1);
}

#[test]
fn test_item_timestamps() {
    let t = make_text("a", 1000);
    let img_data = make_test_image_rgba(5, 5, 50);
    let i = make_image(&img_data, 5, 5, 2000);
    assert_eq!(t.timestamp(), 1000);
    assert_eq!(i.timestamp(), 2000);
}

#[test]
fn test_label_text() {
    let t = make_text("Hello World", 100);
    assert_eq!(t.label(), "Hello World");
}

#[test]
fn test_label_image() {
    let img_data = make_test_image_rgba(1920, 1080, 128);
    let i = make_image(&img_data, 1920, 1080, 100);
    assert_eq!(i.label(), "Image (1920×1080)");
}

#[test]
fn test_label_multibyte() {
    let cn = "这是一个测试中文文本用于验证标签截断功能是否正常工作";
    let t = make_text(cn, 100);
    let label = t.label();
    assert!(label.chars().count() <= 61);
    assert!(label.contains("这是一个"));
}

#[test]
fn test_preview_text() {
    let short = make_text("short", 100);
    assert_eq!(short.preview(), "short");

    // Bounded to 256 Unicode scalars — CJK counts per scalar, not per byte.
    let long: String = (0..300).map(|_| '汉').collect();
    let t = make_text(&long, 100);
    assert_eq!(t.preview().chars().count(), 256);
    assert!(t.preview().starts_with('汉'));

    // Multi-byte scalar (emoji) also bounded by scalar count.
    let emoji = make_text(&"😀".repeat(300), 100);
    assert_eq!(emoji.preview().chars().count(), 256);
}

#[test]
fn test_preview_text_elides_with_real_tail() {
    // Long text elides to head……tail; the tail must be the REAL ending of the
    // text, not a middle chunk of the truncated prefix.
    let text = format!("{}START{}", "中".repeat(500), "-THE-REAL-END");
    let t = make_text(&text, 100);
    let p = t.preview();
    assert_eq!(p.chars().count(), 256);
    assert!(p.starts_with('中'));
    assert!(p.ends_with("-THE-REAL-END"));
    assert_eq!(p.matches("……").count(), 1);

    // Text that just fits the budget stays whole — no elision.
    let fits = "a".repeat(256);
    assert_eq!(make_text(&fits, 100).preview(), fits);
    let just_over = "a".repeat(257);
    assert_ne!(make_text(&just_over, 100).preview(), just_over);
}

#[test]
fn test_preview_image() {
    let img_data = make_test_image_rgba(1920, 1080, 128);
    let i = make_image(&img_data, 1920, 1080, 100);
    assert!(i.preview().is_empty());
}

/// Locks the persisted image-hash algorithm: FNV-1a 64 over
/// width.to_le_bytes() ++ height.to_le_bytes() ++ pixel bytes. The value is
/// stored in SQLite — changing the algorithm would orphan every persisted
/// image hash in user DBs (cross-restart re-copy dedup would show
/// duplicates), so this vector is a tripwire, not incidental.
#[test]
fn test_image_hash_is_stable_fnv1a() {
    // width=2, height=3, pixels=[0,1,2,3]
    assert_eq!(image_hash(&[0, 1, 2, 3], 2, 3), 0xeaa1_0eff_b6c1_2ad4);
}

#[test]
fn test_resize_rgba_downscales() {
    // 4×4 → 2×2: dims correct, output sized exactly, all four channels kept.
    let src = make_test_image_rgba(4, 4, 42);
    let out = crate::image::resize_rgba(&src, 4, 4, 2, 2).expect("resize should succeed");
    assert_eq!(out.len(), 2 * 2 * 4);
    // CatmullRom of a constant-color image stays constant (kernel renormalized
    // at the edges — a bug here shows up as darkened edge pixels).
    let solid = [0x80u8, 0x40, 0x20, 0xFF];
    let src4 = solid.repeat(16);
    let out4 = crate::image::resize_rgba(&src4, 4, 4, 2, 2).expect("resize should succeed");
    for px in out4.as_chunks::<4>().0 {
        assert_eq!(px, &solid[..], "constant input must stay constant");
    }
}

#[test]
fn test_resize_rgba_no_upscale() {
    // Output equal to input returns a copy; larger output also never invents
    // pixels (callers route through resize_dims, which never upscales).
    let src = make_test_image_rgba(4, 3, 7);
    let same = crate::image::resize_rgba(&src, 4, 3, 4, 3).expect("resize should succeed");
    assert_eq!(same, src, "same-size output must be a byte copy");

    let bigger = crate::image::resize_rgba(&src, 4, 3, 8, 6).expect("resize should succeed");
    assert_eq!(bigger, src, "upscale request must return the source unchanged");
}

#[test]
fn test_resize_rgba_edges_and_invalid() {
    // Edge clamping must not panic or produce out-of-bounds writes at tiny
    // sizes (tap windows fall off the image on all sides).
    let tiny = vec![0xFFu8; 4];
    let out = crate::image::resize_rgba(&tiny, 1, 1, 1, 1).expect("1×1 resize should succeed");
    assert_eq!(out, tiny);
    let out2 = crate::image::resize_rgba(&tiny, 2, 2, 1, 1);
    assert!(out2.is_none(), "short source must be rejected, not read out of bounds");

    assert!(crate::image::resize_rgba(&tiny, 0, 1, 1, 1).is_none());
    assert!(crate::image::resize_rgba(&tiny, 1, 0, 1, 1).is_none());
    assert!(crate::image::resize_rgba(&tiny, 1, 1, 0, 1).is_none());
    assert!(crate::image::resize_rgba(&tiny, 1, 1, 1, 0).is_none());
    assert!(crate::image::resize_rgba(&[], 1, 1, 1, 1).is_none());
}

#[test]
fn test_resize_rgba_vertical_quality() {
    // A vertical gradient downscaled in the Y direction must keep its
    // monotonicity (the vertical pass reads the intermediate column-wise —
    // a row/column mixup would scramble it).
    let w = 2u32;
    let h = 8u32;
    let mut src = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for _ in 0..w {
            src.extend_from_slice(&[0u8, 0, 0, 255]);
            src[((y * w) as usize) * 4] = (y * 32) as u8;
        }
    }
    let out = crate::image::resize_rgba(&src, w, h, 2, 2).expect("resize should succeed");
    let top = out[0];
    let bottom = out[4 * 2];
    assert!(bottom > top, "downscaled gradient must keep dark→bright order");
    assert_eq!(out[3], 255, "alpha must survive the vertical pass");
}
