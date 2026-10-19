//! The short (8.3) names the Directory and File tables need beside the long ones.

/// `short|long` names for the Directory and File tables, unique per parent directory.
#[derive(Default)]
pub(super) struct ShortNames {
    taken: Vec<(String, String)>,
}

impl ShortNames {
    /// The table form of `long` under `parent`: the name alone when it is already a valid
    /// 8.3 name, otherwise `STEM~N.EXT|long`.
    pub(super) fn named(&mut self, parent: &str, long: &str) -> String {
        if is_short(long) && !self.has(parent, &long.to_ascii_uppercase()) {
            self.taken
                .push((parent.to_owned(), long.to_ascii_uppercase()));
            return long.to_owned();
        }
        let (stem, extension) = match long.rsplit_once('.') {
            Some((stem, extension)) if !stem.is_empty() => (stem, extension),
            _ => (long, ""),
        };
        let clean = |text: &str, keep: usize| -> String {
            text.chars()
                .filter(char::is_ascii_alphanumeric)
                .take(keep)
                .collect::<String>()
                .to_ascii_uppercase()
        };
        let base = clean(stem, 6);
        let base = if base.is_empty() {
            String::from("FILE")
        } else {
            base
        };
        let extension = clean(extension, 3);
        let mut number = 1;
        loop {
            let tail = format!("~{number}");
            let room = 8usize.saturating_sub(tail.len());
            let head: String = base.chars().take(room).collect();
            let candidate = if extension.is_empty() {
                format!("{head}{tail}")
            } else {
                format!("{head}{tail}.{extension}")
            };
            if !self.has(parent, &candidate) {
                self.taken.push((parent.to_owned(), candidate.clone()));
                return format!("{candidate}|{long}");
            }
            number += 1;
        }
    }

    fn has(&self, parent: &str, name: &str) -> bool {
        self.taken
            .iter()
            .any(|(dir, taken)| dir == parent && taken == name)
    }
}

/// Whether `name` is already a valid 8.3 name: up to 8 + 3 characters from the short-name
/// set, one dot at most.
pub(super) fn is_short(name: &str) -> bool {
    let allowed = |c: char| c.is_ascii_alphanumeric() || "_-$~!#%&@^{}()'`".contains(c);
    let (stem, extension) = name.split_once('.').unwrap_or((name, ""));
    !stem.is_empty()
        && stem.len() <= 8
        && extension.len() <= 3
        && !extension.contains('.')
        && stem.chars().all(allowed)
        && extension.chars().all(allowed)
}
