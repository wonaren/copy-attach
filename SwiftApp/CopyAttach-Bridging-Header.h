// CopyAttach-Bridging-Header.h
// C FFI declarations for the Rust copy_attach library

#include <stdint.h>
#include <stdbool.h>

// ─── Lifecycle ───
int32_t clipboard_init(void);
void clipboard_cleanup(void);

// ─── Query ───
int32_t clipboard_get_count(void);
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
int32_t clipboard_select_and_paste(int32_t index);
int32_t clipboard_select_and_paste_by_id(uint64_t entry_id);

// ─── Lazy Text Loading (on-demand full text by entry ID) ───
char* clipboard_get_text_by_id(uint64_t entry_id);

// ─── Snapshot API (single-lock, race-free read) ───
void* clipboard_snapshot_acquire(void);
int32_t clipboard_snapshot_count(void* snap);
int32_t clipboard_snapshot_item_type(void* snap, int32_t index);
int64_t clipboard_snapshot_item_id(void* snap, int32_t index);
int64_t clipboard_snapshot_item_timestamp(void* snap, int32_t index);
char* clipboard_snapshot_item_label(void* snap, int32_t index);
char* clipboard_snapshot_item_text(void* snap, int32_t index);
char* clipboard_snapshot_item_source_name(void* snap, int32_t index);
char* clipboard_snapshot_item_source_bundle_id(void* snap, int32_t index);
int64_t clipboard_snapshot_get_image_db_id(void* snap, int32_t index);
int32_t clipboard_snapshot_get_image_width(void* snap, int32_t index);
int32_t clipboard_snapshot_get_image_height(void* snap, int32_t index);
void clipboard_snapshot_release(void* snap);

// ─── Image by DB row id (no history lock) ───
uint8_t* clipboard_get_image_thumb_by_db_id(int64_t db_id, int32_t* out_len);
uint8_t* clipboard_get_image_full_by_db_id(int64_t db_id, int32_t* out_len);

// ─── Source App ───
void clipboard_set_source_app(const char* name, const char* bundle_id);
char* clipboard_get_item_source_name(int32_t index);
char* clipboard_get_item_source_bundle_id(int32_t index);

// ─── Permissions ───
int32_t clipboard_check_permission(void);
void clipboard_open_preferences(void);

// ─── History Management ───
void clipboard_clear_history(void);
int32_t clipboard_trim_oldest_percent(int32_t percent);
int32_t clipboard_get_cleanup_threshold(void);
void clipboard_set_cleanup_threshold(int32_t threshold);
int64_t clipboard_get_storage_size(void);
int32_t clipboard_delete_by_id(uint64_t entry_id);
