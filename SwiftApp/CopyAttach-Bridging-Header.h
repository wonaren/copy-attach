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

// ─── Source App ───
void clipboard_set_source_app(const char* name, const char* bundle_id);
char* clipboard_get_item_source_name(int32_t index);
char* clipboard_get_item_source_bundle_id(int32_t index);

// ─── Permissions ───
int32_t clipboard_check_permission(void);
void clipboard_open_preferences(void);
