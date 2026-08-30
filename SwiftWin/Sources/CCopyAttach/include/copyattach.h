// CopyAttach Windows FFI — the same C ABI the macOS frontend consumes
// (subset used by the Windows MVP). Keep signatures in sync with
// SwiftApp/CopyAttach-Bridging-Header.h and src/ffi/.
#ifndef COPYATTACH_FFI_H
#define COPYATTACH_FFI_H

#include <stdint.h>

// ─── Lifecycle ───
int32_t clipboard_set_runtime_entitlement(int32_t state);
int32_t clipboard_init(void);
void clipboard_cleanup(void);
int32_t clipboard_set_debug_logging(int32_t enabled);

// ─── Query ───
uint64_t clipboard_get_history_revision(void);
uint64_t clipboard_get_image_encoding_counter(void);
int32_t clipboard_get_cleanup_threshold(void);
void clipboard_set_cleanup_threshold(int32_t threshold);
int64_t clipboard_get_storage_size(void);

// ─── Snapshot API (single-lock, race-free read) ───
void* clipboard_snapshot_acquire(void);
int32_t clipboard_snapshot_count(void* snap);
int32_t clipboard_snapshot_item_type(void* snap, int32_t index);
int64_t clipboard_snapshot_item_id(void* snap, int32_t index);
int64_t clipboard_snapshot_item_timestamp(void* snap, int32_t index);
char* clipboard_snapshot_item_label(void* snap, int32_t index);
char* clipboard_snapshot_item_preview(void* snap, int32_t index);
char* clipboard_snapshot_item_source_name(void* snap, int32_t index);
void clipboard_snapshot_release(void* snap);

// ─── Search ───
uint64_t* clipboard_search_ids(const char* query, int32_t* out_count);
void clipboard_free_u64_array(uint64_t* ptr, int32_t len);

// ─── Action ───
int32_t clipboard_select_and_paste_by_id(uint64_t entry_id);
char* clipboard_get_text_by_id(uint64_t entry_id);

// ─── History Management ───
int32_t clipboard_delete_by_id(uint64_t entry_id);
int32_t clipboard_undo_delete(void);
int32_t clipboard_can_undo(void);
int clipboard_clear_history(void);
int32_t clipboard_shrink_db_memory(void);

// ─── Free ───
void clipboard_free_string(char* s);
void clipboard_free_bytes(uint8_t* data, int32_t len);

#endif /* COPYATTACH_FFI_H */
