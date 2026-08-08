// Image generation for stress-test data — fast block-based RGBA rendering.

use super::splitmix64;

/// Generate a RGBA pixel buffer using fast block-based rendering.
///
/// Much faster than per-pixel computation at high resolutions.
/// The image is divided into a grid of cells. Each cell gets a solid colour
/// derived from its position + seed.  Thin horizontal lines and window blocks
/// are drawn using slice fills (not per-pixel loops), making this viable even
/// at 8K resolution.
pub(super) fn generate_image_rgba(width: u32, height: u32, seed: u64) -> Vec<u8> {
    let total = (width as usize) * (height as usize) * 4;
    let mut pixels = vec![0u8; total];

    // Grid size scales with resolution to keep block count manageable.
    let grid = if width >= 3840 { 12 } else if width >= 1920 { 8 } else { 4 };
    let cell_w = (width / grid).max(1);
    let cell_h = (height / grid).max(1);

    let mut rng = splitmix64(seed);
    let cell_colors: Vec<(u8, u8, u8)> = (0..grid * grid)
        .map(|_| ((rng() as u8), (rng() as u8), (rng() as u8)))
        .collect();

    for cy in 0..grid {
        for cx in 0..grid {
            let (r0, g0, b0) = cell_colors[(cy * grid + cx) as usize];

            // Warm up the base with a gradient shift
            let grad_r = (cy as f64 / grid as f64 * 60.0) as u8;
            let grad_g = (cx as f64 / grid as f64 * 40.0) as u8;
            let grad_b = ((grid - cy) as f64 / grid as f64 * 50.0) as u8;

            let x0 = cx * cell_w;
            let y0 = cy * cell_h;
            let x1 = (x0 + cell_w).min(width);
            let y1 = (y0 + cell_h).min(height);

            let has_window = (cx + cy) % 3 == 1;

            // Pre-compute the two colors used in this cell
            let base_r = r0.wrapping_add(grad_r);
            let base_g = g0.wrapping_add(grad_g);
            let base_b = b0.wrapping_add(grad_b);

            let text_r = base_r.wrapping_sub(30);
            let text_g = base_g.wrapping_sub(30);
            let text_b = base_b.wrapping_sub(20);

            let (win_r, win_g, win_b) = if has_window {
                ((rng() as u8 & 0x3f) + 0x40,
                 (rng() as u8 & 0x3f) + 0x40,
                 (rng() as u8 & 0x3f) + 0x40)
            } else {
                (0u8, 0u8, 0u8)
            };

            let is_window_cell = has_window;
            let win_margin = 4u32;

            for y in y0..y1 {
                let row_start = ((y * width + x0) * 4) as usize;
                let row_end = ((y * width + x1) * 4) as usize;
                let row = &mut pixels[row_start..row_end];

                let (r, g, b) = if y % 12 < 2 {
                    // Text line
                    (text_r, text_g, text_b)
                } else if is_window_cell && y > y0 + win_margin && y < y1 - win_margin {
                    (win_r, win_g, win_b)
                } else {
                    (base_r, base_g, base_b)
                };

                // Fast uniform fill of the entire row slice
                let rgba = [r, g, b, 255];
                for chunk in row.chunks_exact_mut(4) {
                    chunk.copy_from_slice(&rgba);
                }
            }
        }
    }
    pixels
}
