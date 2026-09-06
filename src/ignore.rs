//! Capture-time ignore rules.
//!
//! Rules are evaluated before an entry is allocated, inserted into history, or
//! persisted. Application matching deliberately uses bundle identifiers: display
//! names are mutable and are not an application identity.

#[derive(Clone, Debug, Default)]
pub(crate) struct IgnoreRules {
    pub(crate) app_bundle_ids: Vec<String>,
    pub(crate) ignore_text: bool,
    pub(crate) ignore_images: bool,
    /// Ignore text whose Unicode scalar count is strictly below this value.
    /// `None` means that no length rule is active.
    pub(crate) min_text_characters: Option<usize>,
    /// Ignore sensitive clipboard items (passwords, concealed, transient types).
    pub(crate) ignore_sensitive: bool,
}

impl IgnoreRules {
    /// Decodes the newline-delimited bundle-ID wire format used by the FFI.
    /// Empty fields are omitted and duplicates retain their first occurrence.
    pub(crate) fn from_encoded(
        encoded_bundle_ids: &str,
        ignore_text: bool,
        ignore_images: bool,
        min_text_characters: Option<usize>,
        ignore_sensitive: bool,
    ) -> Self {
        let mut app_bundle_ids = Vec::new();
        for id in encoded_bundle_ids.split('\n').filter(|id| !id.is_empty()) {
            if !app_bundle_ids.iter().any(|existing| existing == id) {
                app_bundle_ids.push(id.to_owned());
            }
        }
        Self {
            app_bundle_ids,
            ignore_text,
            ignore_images,
            min_text_characters,
            ignore_sensitive,
        }
    }

    pub(crate) fn ignores_app(&self, bundle_id: &str) -> bool {
        !bundle_id.is_empty() && self.app_bundle_ids.iter().any(|id| id == bundle_id)
    }

    pub(crate) fn ignores_text(&self, text: &str) -> bool {
        self.ignore_text
            || self.min_text_characters.is_some_and(|minimum| text.chars().count() < minimum)
    }

    pub(crate) fn ignores_image(&self) -> bool {
        self.ignore_images
    }

    pub(crate) fn ignores_sensitive(&self) -> bool {
        self.ignore_sensitive
    }
}

#[cfg(test)]
mod tests {
    use super::IgnoreRules;

    #[test]
    fn default_rules_capture_every_supported_content_type() {
        let rules = IgnoreRules::default();
        assert!(!rules.ignores_app("com.example.any"));
        assert!(!rules.ignores_text("a"));
        assert!(!rules.ignores_image());
        assert!(!rules.ignores_sensitive());
    }

    #[test]
    fn app_rules_are_exact_and_never_match_an_unknown_empty_bundle_id() {
        let rules = IgnoreRules::from_encoded("com.example.secret", false, false, None, false);
        assert!(rules.ignores_app("com.example.secret"));
        assert!(!rules.ignores_app("com.example.Secret"));
        assert!(!rules.ignores_app("com.example.secret.helper"));
        assert!(!rules.ignores_app(""));
    }

    #[test]
    fn text_type_rule_overrides_all_length_boundaries() {
        let rules = IgnoreRules::from_encoded("", true, false, Some(3), false);
        for text in ["", "a", "你好啊", "a very long text"] {
            assert!(rules.ignores_text(text), "{text:?} must be ignored by type");
        }
    }

    #[test]
    fn short_text_rule_uses_unicode_scalar_count_with_a_strict_boundary() {
        let rules = IgnoreRules::from_encoded("", false, false, Some(3), false);
        assert!(rules.ignores_text("ab"));
        assert!(!rules.ignores_text("abc"));
        assert!(rules.ignores_text("你好"));
        assert!(!rules.ignores_text("你好啊"));
        // A combining mark is a Unicode scalar and is intentionally counted.
        assert!(rules.ignores_text("e\u{301}"));
        assert!(!rules.ignores_text("e\u{301}x"));
    }

    #[test]
    fn absent_length_rule_does_not_filter_short_or_empty_text() {
        let rules = IgnoreRules::from_encoded("", false, false, None, false);
        assert!(!rules.ignores_text(""));
        assert!(!rules.ignores_text("a"));
    }

    #[test]
    fn image_rule_is_independent_of_text_rules() {
        let allowed = IgnoreRules::from_encoded("", true, false, Some(10), false);
        assert!(!allowed.ignores_image());
        let ignored = IgnoreRules::from_encoded("", false, true, None, false);
        assert!(ignored.ignores_image());
    }

    #[test]
    fn sensitive_rule_is_configurable() {
        let off = IgnoreRules::from_encoded("", false, false, None, false);
        assert!(!off.ignores_sensitive());
        let on = IgnoreRules::from_encoded("", false, false, None, true);
        assert!(on.ignores_sensitive());
    }

    #[test]
    fn encoded_rules_preserve_unique_nonempty_app_ids_and_all_options() {
        let rules = IgnoreRules::from_encoded(
            "com.example.one\n\ncom.example.two\ncom.example.one\n",
            true,
            true,
            Some(5),
            true,
        );
        assert_eq!(rules.app_bundle_ids, ["com.example.one", "com.example.two"]);
        assert!(rules.ignore_text);
        assert!(rules.ignores_image());
        assert!(rules.ignores_sensitive());
        // The type toggle takes precedence, even at the length boundary.
        assert!(rules.ignores_text("1234"));
        assert!(rules.ignores_text("12345"));
    }
}
