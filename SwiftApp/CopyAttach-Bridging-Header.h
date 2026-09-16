// CopyAttach-Bridging-Header.h
// C FFI declarations for the Rust copy_attach library

#include <stdint.h>
#include <stdbool.h>

// ─── History change events (event-driven UI refresh) ───
// Block until history changes after `since`, or timeout_ms elapses. Returns the
// newest observed revision (> since when awakened; == since on timeout).
uint64_t clipboard_wait_for_history_change(uint64_t since, uint64_t timeout_ms);
// Read the revision counters the UI keys its reload decision on, together.
int32_t clipboard_history_counters(uint64_t* out_revision, uint64_t* out_image_encoding);

// ─── Performance instrumentation (opt-in, see Utility/PerfTrace.swift) ───
// Enable/disable runtime perf tracing; returns the effective state (1/0).
int32_t clipboard_set_perf_enabled(int32_t state);
// Current effective state (1/0).
int32_t clipboard_perf_enabled(void);
// Write a probe record carrying the C string token; returns the monotonic ns
// stamp (0 on a null token). Used by the instrument self-check.
uint64_t clipboard_perf_emit_probe(const char* token);
// Self-check of the Rust-side instrument primitives (bitmask; 7 == all pass).
int32_t clipboard_perf_selfcheck(void);

// ─── Lifecycle ───
int32_t clipboard_set_runtime_entitlement(int32_t state);
// 1 = running, 0 = retryable failure, -1 = database corrupt (call
// clipboard_recover_corrupt_db and re-init, or quit).
int32_t clipboard_init(void);
// Moves history.db (+ -wal/-shm) aside as history.db.corrupt-<secs>. Only
// valid after clipboard_init returned -1. Returns 1 on success.
int32_t clipboard_recover_corrupt_db(void);
void clipboard_cleanup(void);
// Debug logging toggle: default is debug-build-on / release-build-off.
// Settings UI can override at runtime.
int32_t clipboard_set_debug_logging(int32_t enabled);
int32_t clipboard_is_debug_logging(void);

// ─── Query ───
int32_t clipboard_get_count(void);
uint64_t clipboard_get_image_encoding_counter(void);
uint64_t clipboard_get_history_revision(void);
int32_t clipboard_get_item_type(int32_t index);
int64_t clipboard_get_item_timestamp(int32_t index);
char* clipboard_get_item_label(int32_t index);
char* clipboard_get_item_text(int32_t index);

// Image data (caller must free with clipboard_free_bytes)
uint8_t* clipboard_get_image_thumb(int32_t index, int32_t* out_len);
uint8_t* clipboard_get_image_full(int32_t index, int32_t* out_len);
int32_t clipboard_get_image_size(int32_t index, int32_t* out_width, int32_t* out_height);

// ─── Free ───
void clipboard_free_string(char* s);
void clipboard_free_bytes(uint8_t* data, int32_t len);

// ─── Action ───
// Single-phase select-and-paste was removed: it blocked the caller thread and
// could post Cmd+V while the panel was still key. Use the two-phase
// clipboard_prepare_paste_by_id + clipboard_send_paste below.
// Two-phase paste. Phase 1 writes the pasteboard and returns the target pid
// (>0), or 0 on failure; phase 2 posts the paste keystroke to that pid. The
// caller must dismiss its own key window between the phases: posting the
// keystroke while the popup is still key makes a target that resolves the
// paste against its key window (WeChat) intermittently drop it.
int32_t clipboard_prepare_paste_by_id(uint64_t entry_id, bool as_path);
int32_t clipboard_send_paste(int32_t pid);

// ─── Lazy Text Loading (on-demand full text by entry ID) ───
char* clipboard_get_text_by_id(uint64_t entry_id);

// ─── Snapshot API (single-lock, race-free read) ───
void* clipboard_snapshot_acquire(void);
// One-allocation wire-format snapshot: caller frees with clipboard_free_bytes.
uint8_t* clipboard_snapshot_packed_acquire(int32_t* out_len);
int32_t clipboard_snapshot_count(void* snap);
int32_t clipboard_snapshot_item_type(void* snap, int32_t index);
int64_t clipboard_snapshot_item_id(void* snap, int32_t index);
int64_t clipboard_snapshot_item_timestamp(void* snap, int32_t index);
char* clipboard_snapshot_item_label(void* snap, int32_t index);
char* clipboard_snapshot_item_custom_label(void* snap, int32_t index);
char* clipboard_snapshot_item_preview(void* snap, int32_t index);
char* clipboard_snapshot_item_source_name(void* snap, int32_t index);
char* clipboard_snapshot_item_source_bundle_id(void* snap, int32_t index);
int64_t clipboard_snapshot_get_image_db_id(void* snap, int32_t index);
int32_t clipboard_snapshot_get_image_width(void* snap, int32_t index);
int32_t clipboard_snapshot_get_image_height(void* snap, int32_t index);
void clipboard_snapshot_release(void* snap);

// ─── Search (case-insensitive substring over label/source/full text) ───
// Returns a malloc'd array of matching entry_ids; caller must free with
// clipboard_free_u64_array. Null + 0 count when no matches.
uint64_t* clipboard_search_ids(const char* query, int32_t* out_count);
void clipboard_free_u64_array(uint64_t* ptr, int32_t len);

// ─── Image by DB row id (no history lock) ───
uint8_t* clipboard_get_image_thumb_by_db_id(int64_t db_id, int32_t* out_len);
uint8_t* clipboard_get_image_full_by_db_id(int64_t db_id, int32_t* out_len);

// ─── Pooled preview decode (Rust-decoded RGBA, caller owns via
//     clipboard_preview_buffer_release) ───
// Decodes + downscales the stored image to at most `max_dim` on its longest
// side (aspect preserved; never upscales). Returns a Rust-owned RGBA8 buffer
// (length w*h*4) or null on failure. `out_is_gif` is set to 1 when the stored
// blob is an animated GIF; in that case the return value is null and callers
// should keep the NSImage(data:) path instead; the Rust side deliberately
// does not decode a throwaway first frame. The buffer's pages are marked
// reusable by `clipboard_preview_buffer_release`, so closed previews stop
// counting against the process footprint (the malloc pages never return
// otherwise).
uint8_t* clipboard_decode_preview_by_db_id(int64_t db_id, int32_t max_dim,
                                           int32_t* out_len, int32_t* out_w, int32_t* out_h,
                                           int32_t* out_is_gif);
void clipboard_preview_buffer_release(uint8_t* ptr, int32_t len);

// ─── Source App ───
void clipboard_set_source_app(const char* name, const char* bundle_id, int32_t pid);
// Newline-delimited application bundle IDs; 0 disables the text-length rule.
int32_t clipboard_set_ignore_rules(const char* app_bundle_ids, int32_t ignore_text, int32_t ignore_images, int32_t min_text_characters, int32_t ignore_sensitive);
char* clipboard_get_item_source_name(int32_t index);
char* clipboard_get_item_source_bundle_id(int32_t index);

// ─── Permissions ───
int32_t clipboard_check_permission(void);
void clipboard_open_preferences(void);

// ─── History Management ───
int clipboard_clear_history(void);
int32_t clipboard_trim_oldest_percent(int32_t percent);
int32_t clipboard_get_cleanup_threshold(void);
void clipboard_set_cleanup_threshold(int32_t threshold);
int64_t clipboard_get_storage_size(void);
int32_t clipboard_shrink_db_memory(void);
int32_t clipboard_delete_by_id(uint64_t entry_id);
int32_t clipboard_set_custom_label(uint64_t entry_id, const char* label);
int32_t clipboard_undo_delete(void);
int32_t clipboard_can_undo(void);
uint64_t clipboard_last_restored_id(void);

// ─── History Reload (for stress testing) ───
int32_t clipboard_reload_history(void);

// ─── Stress Test (cfg-gated, stubs at link time) ───
int32_t clipboard_stress_available(void);
int32_t clipboard_stress_inject(int32_t count, double text_ratio, int64_t seed);
void clipboard_stress_reset(void);
char* clipboard_stress_run_bench(void);
