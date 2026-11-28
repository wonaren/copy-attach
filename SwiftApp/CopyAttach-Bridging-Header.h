#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

uint64_t clipboard_wait_for_history_change(uint64_t since, uint64_t timeout_ms);
int32_t clipboard_history_counters(uint64_t* out_revision, uint64_t* out_image_encoding);
void clipboard_set_capture_callback(void (*cb)(void));

int32_t clipboard_set_perf_enabled(int32_t state);
int32_t clipboard_perf_enabled(void);
uint64_t clipboard_perf_emit_probe(const char* token);
int32_t clipboard_perf_selfcheck(void);

int32_t clipboard_init_with_threshold_and_favorites(int32_t threshold, const char* favorite_ids_csv);
int32_t clipboard_recover_corrupt_db(void);
void clipboard_cleanup(void);
int32_t clipboard_set_debug_logging(int32_t enabled);
int32_t clipboard_is_debug_logging(void);

int32_t clipboard_get_count(void);
uint64_t clipboard_get_image_encoding_counter(void);
uint64_t clipboard_get_history_revision(void);

void clipboard_free_string(char* s);
void clipboard_free_bytes(uint8_t* data, int32_t len);

#define COPYATTACH_DELIVERY_KEYSTROKE 0
#define COPYATTACH_DELIVERY_CLIPBOARD_ONLY 1
int32_t clipboard_prepare_paste_by_id(uint64_t entry_id, bool as_path, int32_t delivery_mode);
int32_t clipboard_send_paste(int32_t pid);

int32_t clipboard_toggle_quick_slot(uint64_t entry_id, int32_t slot);
int32_t clipboard_remove_quick_slot(uint64_t entry_id, int32_t slot);
int32_t clipboard_clear_quick_slots(void);
int32_t clipboard_prepare_quick_paste_by_id(uint64_t entry_id, int32_t delivery_mode);
int32_t clipboard_prepare_quick_paste_by_slot(int32_t slot, int32_t delivery_mode);

char* clipboard_get_text_by_id(uint64_t entry_id);

void* clipboard_snapshot_acquire(void);
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

uint64_t* clipboard_search_ids(const char* query, int32_t* out_count);
void clipboard_free_u64_array(uint64_t* ptr, int32_t len);

void clipboard_purge_stale_drag_images(void);

uint8_t* clipboard_get_image_thumb_by_db_id(int64_t db_id, int32_t* out_len);
uint8_t* clipboard_get_image_full_by_db_id(int64_t db_id, int32_t* out_len);

int32_t clipboard_preview_dims(int32_t width, int32_t height, int32_t max_dim,
                               int32_t* out_w, int32_t* out_h);
int32_t clipboard_decode_preview_into(int64_t db_id, int32_t max_dim,
                                      uint8_t* dst, int32_t dst_len, int32_t stride,
                                      int32_t* out_w, int32_t* out_h, int32_t* out_is_gif);

void clipboard_set_source_app(const char* name, const char* bundle_id, int32_t pid);
int32_t clipboard_set_ignore_rules(const char* app_bundle_ids, int32_t ignore_text, int32_t ignore_images, int32_t min_text_characters, int32_t ignore_sensitive);

int32_t clipboard_check_permission(void);
void clipboard_open_preferences(void);

int32_t clipboard_clear_history(void);
int32_t clipboard_trim_oldest_percent(int32_t percent);
int32_t clipboard_get_cleanup_threshold(void);
int32_t clipboard_set_cleanup_threshold(int32_t threshold);
int32_t clipboard_get_storage_breakdown(int64_t* text_bytes, int64_t* image_bytes, int64_t* undo_bytes);
int32_t clipboard_shrink_db_memory(void);
int32_t clipboard_delete_by_id(uint64_t entry_id);
int32_t clipboard_set_custom_label(uint64_t entry_id, const char* label);
int32_t clipboard_set_favorite(uint64_t entry_id, int32_t favorite);
int32_t clipboard_undo_delete(void);
int32_t clipboard_undo_depth(void);
int32_t clipboard_undo_eviction_preview(uint64_t entry_id);
int64_t clipboard_get_undo_limit(void);
int32_t clipboard_set_undo_limit(int64_t limit);
uint64_t clipboard_last_restored_id(void);

int32_t clipboard_reload_history(void);

int32_t clipboard_stress_available(void);
int32_t clipboard_stress_inject(int32_t count, double text_ratio, int64_t seed);
void clipboard_stress_reset(void);
char* clipboard_stress_run_bench(void);

int32_t clipboard_export_backup(const char* target_path);
int32_t clipboard_inspect_backup(const char* backup_path, int32_t* out_item_count, int32_t* out_fav_count, uint64_t* out_timestamp);
int32_t clipboard_restore_backup_overwrite(const char* backup_path, char** out_fav_str);
int32_t clipboard_restore_backup_merge(const char* backup_path, char** out_fav_str);
