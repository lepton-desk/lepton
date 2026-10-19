//! What a Lepton project is told about itself, in a file it can read.
//!
//! `lepton.config.json` is the one place a project's identity is written down: what
//! it is called, which render path it uses, which window it opens, and how its
//! frontend is wired to the core. It exists as JSON because a developer will open
//! it, edit it, and paste it into an issue — not because anything in Lepton reads
//! it as text at runtime. The IPC path is zero-copy binary and always will be; a
//! configuration file that a person reads is not that path.
//!
//! The manifest is therefore rendered from a typed value rather than assembled by
//! string concatenation, so a window title containing a quote cannot produce a
//! file that does not parse.

use std::fmt::Write as _;

/// Which render path a project uses.
///
/// The two paths share nothing below the channel: one needs a web engine, the other
/// needs none at all. Recording which a project uses is what lets `lepton info`
/// explain why a project costs what it costs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderPath {
    /// A web engine hosts the interface and shares memory with the core.
    Webview,
    /// The interface is drawn straight to the window. No engine is loaded.
    Native,
}

impl RenderPath {
    /// The spelling used in the configuration file.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Webview => "webview",
            Self::Native => "native",
        }
    }

    /// Parses the configuration file's spelling.
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "webview" => Some(Self::Webview),
            "native" => Some(Self::Native),
            _ => None,
        }
    }

    /// One line for `lepton info`, saying what this path costs rather than what it
    /// is called.
    pub fn describe(self) -> &'static str {
        match self {
            Self::Webview => "webview (a web engine hosts the interface)",
            Self::Native => "native (no web engine is loaded)",
        }
    }
}

/// Which framework a project's frontend is built on.
///
/// Recorded so the CLI can report what it scaffolded and so a future preset can be
/// recognised without guessing from the dependency list.
/// Which language a project's sources are written in.
///
/// Separate from `Target` because `Target` answers "what framework" and this answers
/// "in what language" — and conflating them is how a JavaScript project ends up with a
/// `src/main.ts` injected into it while its `index.html` loads `src/main.js`. That is not
/// a cosmetic disagreement: the project does not build.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Language {
    #[default]
    TypeScript,
    JavaScript,
}

impl Language {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TypeScript => "ts",
            Self::JavaScript => "js",
        }
    }

    /// The suffix on a source file, as in `main.ts`.
    pub fn extension(self) -> &'static str {
        match self {
            Self::TypeScript => "ts",
            Self::JavaScript => "js",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "ts" | "typescript" => Some(Self::TypeScript),
            "js" | "javascript" => Some(Self::JavaScript),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    VanillaTs,
    React,
    Vue,
    Svelte,
    Solid,
    Preact,
    Lit,
    Angular,
}

impl Target {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::VanillaTs => "vanilla-ts",
            Self::React => "react",
            Self::Vue => "vue",
            Self::Svelte => "svelte",
            Self::Solid => "solid",
            Self::Preact => "preact",
            Self::Lit => "lit",
            Self::Angular => "angular",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "vanilla-ts" => Some(Self::VanillaTs),
            "react" => Some(Self::React),
            "vue" => Some(Self::Vue),
            "svelte" => Some(Self::Svelte),
            "solid" => Some(Self::Solid),
            "preact" => Some(Self::Preact),
            "lit" => Some(Self::Lit),
            "angular" => Some(Self::Angular),
            _ => None,
        }
    }
}

/// Everything written into a project's configuration file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub product_name: String,
    pub identifier: String,
    pub version: String,
    pub render_path: RenderPath,
    pub target: Target,
    /// Window title as the developer will see it in their taskbar.
    pub window_title: String,
    /// Window size in physical pixels, not logical ones: on a scaled display the
    /// two differ, and a window sized in the wrong unit is wrong by the scale.
    pub window_width: u32,
    pub window_height: u32,
    /// The shared-memory channel's name. Prefixed with `/` as POSIX requires, and
    /// namespaced by identifier so two projects never collide on one machine.
    pub channel_name: String,
    /// The npm scope the project's SDK comes from.
    pub sdk_scope: String,

    /// The language the project's sources are written in.
    ///
    /// Drives the file extensions of everything injected, so a JavaScript project gets
    /// `main.js` and its `index.html` agrees.
    pub language: Language,

    /// Plugins chosen at `lepton new` (`plugin_catalog` names): their commands join
    /// `permissions`, `fs` gets `$APPDATA` as its scope, and each package becomes a
    /// dependency.
    pub plugins: Vec<&'static str>,
}

impl Manifest {
    /// A manifest with sensible defaults for a project named `product_name`.
    ///
    /// The identifier follows the reverse-DNS form every desktop platform expects,
    /// because the window manager uses it to match a window to an icon and an
    /// entry — a name like `my app` matches nothing.
    pub fn new(product_name: &str) -> Self {
        let identifier = identifier_for(product_name);
        Self {
            product_name: product_name.to_owned(),
            channel_name: format!("/lepton-{identifier}"),
            identifier,
            version: "0.1.0".to_owned(),
            render_path: RenderPath::Webview,
            target: Target::VanillaTs,
            window_title: product_name.to_owned(),
            window_width: 1200,
            window_height: 800,
            sdk_scope: "@lepton-desk".to_owned(),
            language: Language::default(),
            plugins: Vec::new(),
        }
    }
}

/// Turns a project name into a reverse-DNS identifier.
///
/// Spaces and punctuation become separators, and anything that cannot appear in an
/// identifier is dropped. An empty result is replaced rather than emitted, because
/// a project whose identifier is empty cannot own a channel name or an icon.
pub fn identifier_for(product_name: &str) -> String {
    let mut out = String::with_capacity(product_name.len());
    let mut last_was_separator = false;

    for character in product_name.chars() {
        if character.is_ascii_alphanumeric() {
            out.push(character.to_ascii_lowercase());
            last_was_separator = false;
        } else if !last_was_separator && !out.is_empty() {
            out.push('-');
            last_was_separator = true;
        }
    }

    while out.ends_with('-') {
        out.pop();
    }

    if out.is_empty() {
        "app".to_owned()
    } else {
        out
    }
}

/// Renders the manifest as the JSON a developer will read.
///
/// Written by hand rather than derived: the shape is small and fixed, and a
/// hand-written renderer keeps the file's formatting stable and reviewable
/// instead of at the mercy of a serialiser's defaults.
pub fn render_manifest(manifest: &Manifest) -> String {
    let mut out = String::with_capacity(512);

    // Every string goes through `json_string`, so a title containing a quote or a
    // newline produces a file that still parses.
    let _ = writeln!(out, "{{");
    let _ = writeln!(
        out,
        "  \"$schema\": {},",
        json_string("https://lepton.style/schema/config.json")
    );
    let _ = writeln!(
        out,
        "  \"productName\": {},",
        json_string(&manifest.product_name)
    );
    let _ = writeln!(
        out,
        "  \"identifier\": {},",
        json_string(&manifest.identifier)
    );
    let _ = writeln!(out, "  \"version\": {},", json_string(&manifest.version));
    let _ = writeln!(
        out,
        "  \"renderPath\": {},",
        json_string(manifest.render_path.as_str())
    );
    let _ = writeln!(
        out,
        "  \"target\": {},",
        json_string(manifest.target.as_str())
    );
    let _ = writeln!(out, "  \"sdkScope\": {},", json_string(&manifest.sdk_scope));
    let _ = writeln!(out, "  \"channel\": {{");
    let _ = writeln!(
        out,
        "    \"name\": {},",
        json_string(&manifest.channel_name)
    );
    let _ = writeln!(out, "    \"geometry\": {{");
    let _ = writeln!(out, "      \"cellCount\": 64,");
    let _ = writeln!(out, "      \"payloadCapacity\": 4096");
    let _ = writeln!(out, "    }}");
    let _ = writeln!(out, "  }},");
    let _ = writeln!(out, "  \"window\": {{");
    let _ = writeln!(
        out,
        "    \"title\": {},",
        json_string(&manifest.window_title)
    );
    let _ = writeln!(out, "    \"width\": {},", manifest.window_width);
    let _ = writeln!(out, "    \"height\": {}", manifest.window_height);
    let _ = writeln!(out, "  }},");
    // The commands the page may call. Explicit and short: the template's own `app.name`
    // and nothing else. A command is granted by naming it here — there is no wildcard.
    let mut granted = vec![json_string("app.name")];
    for name in &manifest.plugins {
        if let Some(plugin) = crate::plugin_catalog::find(name) {
            granted.extend(plugin.commands.iter().map(|command| json_string(command)));
        }
    }
    let fs = manifest.plugins.contains(&"fs");
    let comma = if fs { "," } else { "" };
    // On one line while it fits the project's `biome.json` line width, one name per line
    // after that: Biome formats an array this way, and a project made with plugins failed
    // `biome check` before its first build on a 140-character line (measured 2026-10-17).
    let line = format!("  \"permissions\": [{}]{comma}", granted.join(", "));
    if line.chars().count() <= BIOME_LINE_WIDTH {
        let _ = writeln!(out, "{line}");
    } else {
        let _ = writeln!(out, "  \"permissions\": [");
        let _ = writeln!(out, "    {}", granted.join(",\n    "));
        let _ = writeln!(out, "  ]{comma}");
    }
    if fs {
        // The application's own directory and nothing else; widening it is the
        // developer's decision, written here by name.
        let _ = writeln!(out, "  \"plugins\": {{");
        let _ = writeln!(out, "    \"fs\": {{ \"scope\": [\"$APPDATA\"] }}");
        let _ = writeln!(out, "  }}");
    }
    let _ = writeln!(out, "}}");

    out
}

/// `lineWidth` in the `biome.json` every project gets (`assets/biome.json`).
const BIOME_LINE_WIDTH: usize = 100;

/// Quotes and escapes a string as JSON.
///
/// Control characters are escaped rather than dropped, so a title containing a tab
/// survives a round trip instead of quietly changing.
pub fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');

    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if control.is_control() => {
                let _ = write!(out, "\\u{:04x}", control as u32);
            }
            other => out.push(other),
        }
    }

    out.push('"');
    out
}

/// A manifest that could not be rendered because it is not valid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestError {
    pub reason: String,
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.reason)
    }
}

impl std::error::Error for ManifestError {}

/// Checks a manifest before it is written, so a bad project is refused at the
/// point the developer can still fix it.
///
/// The window size is checked because a zero-sized window cannot be opened, and
/// the channel name because POSIX requires exactly one leading slash and no other
/// path separator — both of which would otherwise surface much later as a kernel
/// error with no useful context.
pub fn validate(manifest: &Manifest) -> Result<(), ManifestError> {
    if manifest.product_name.trim().is_empty() {
        return Err(ManifestError {
            reason: "a project needs a name".to_owned(),
        });
    }
    if manifest.window_width == 0 || manifest.window_height == 0 {
        return Err(ManifestError {
            reason: format!(
                "a window needs a non-zero size, got {}x{}",
                manifest.window_width, manifest.window_height
            ),
        });
    }
    if !manifest.channel_name.starts_with('/') || manifest.channel_name[1..].contains('/') {
        return Err(ManifestError {
            reason: format!(
                "a shared-memory name must start with `/` and contain no other separator, got {:?}",
                manifest.channel_name
            ),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        Manifest, RenderPath, Target, identifier_for, json_string, render_manifest, validate,
    };
    use lepton_orchestrator::testing::{Failure, balanced};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ne, ensure};

    #[test]
    fn the_configuration_fits_the_projects_biome_line_width() -> Result<(), Failure> {
        // Every project runs `biome check`; with all four plugins the permissions once
        // came out on one 140-character line and a new project failed it unbuilt.
        for plugins in [vec![], vec!["fs"], vec!["os", "clipboard", "fs", "dialog"]] {
            let mut manifest = Manifest::new("Ledger");
            manifest.plugins = plugins.clone();
            let text = render_manifest(&manifest);
            for line in text.lines() {
                ensure!(
                    line.chars().count() <= super::BIOME_LINE_WIDTH,
                    "plugins {plugins:?}: line over the width: {line}"
                );
            }
            let parsed = crate::permissions::parse_permissions(&text);
            ensure!(
                parsed.is_ok(),
                "plugins {plugins:?}: permissions do not parse"
            );
        }
        Ok(())
    }

    #[test]
    fn a_project_name_becomes_a_usable_identifier() -> Result<(), Failure> {
        assert_eq!(identifier_for("Lepton Notes"), "lepton-notes");
        assert_eq!(identifier_for("my_app"), "my-app");
        assert_eq!(identifier_for("Ledger 2.0"), "ledger-2-0");
        Ok(())
    }

    #[test]
    fn a_name_with_nothing_usable_still_yields_an_identifier() -> Result<(), Failure> {
        // An empty identifier would produce a channel name no process could open,
        // so a placeholder is better than a blank.
        assert_eq!(identifier_for("***"), "app");
        assert_eq!(identifier_for(""), "app");
        Ok(())
    }

    #[test]
    fn an_identifier_is_always_something_a_channel_name_can_be_built_from() -> Result<(), Failure> {
        // A blank name is deliberately absent: it is refused rather than given the
        // placeholder identifier, because a project called nothing is a mistake and
        // a project called "app" is worse.
        for name in ["Ledger", "123", "Ünïcode", "a-b-c", "---"] {
            let manifest = Manifest::new(name);
            let ok = validate(&manifest);
            ensure!(
                ok.is_ok(),
                "the manifest for {name:?} should be valid: {ok:?}"
            );
            assert_eq!(manifest.channel_name.matches('/').count(), 1);
        }
        Ok(())
    }

    #[test]
    fn the_channel_name_is_namespaced_so_projects_do_not_collide() -> Result<(), Failure> {
        let first = Manifest::new("Ledger");
        let second = Manifest::new("Notes");

        assert_ne!(first.channel_name, second.channel_name);
        ensure!(
            first.channel_name.starts_with('/'),
            "POSIX requires a leading slash"
        );
        // POSIX allows exactly one separator, at the front.
        assert_eq!(first.channel_name.matches('/').count(), 1);
        Ok(())
    }

    #[test]
    fn a_valid_manifest_is_accepted() -> Result<(), Failure> {
        let manifest = Manifest::new("Ledger");
        let outcome = validate(&manifest);
        ensure!(
            outcome.is_ok(),
            "a fresh manifest should be valid: {outcome:?}"
        );
        Ok(())
    }

    #[test]
    fn a_zero_sized_window_is_refused_with_its_size_named() -> Result<(), Failure> {
        let mut manifest = Manifest::new("Ledger");
        manifest.window_width = 0;

        let error = assert_err!(validate(&manifest), "a zero width must be refused");
        // The message has to carry the size, because "invalid window" alone leaves
        // the developer guessing which of the two numbers is wrong.
        assert_contains!(&error.reason, "0x800");
        Ok(())
    }

    #[test]
    fn an_unnamed_project_is_refused() -> Result<(), Failure> {
        let manifest = Manifest::new("   ");
        assert_err!(validate(&manifest), "a blank name must be refused");
        Ok(())
    }

    #[test]
    fn a_channel_name_without_the_leading_slash_is_refused() -> Result<(), Failure> {
        let mut manifest = Manifest::new("Ledger");
        manifest.channel_name = "lepton-ledger".to_owned();

        let error = assert_err!(validate(&manifest), "POSIX requires a leading slash");
        assert_contains!(&error.reason, "`");
        Ok(())
    }

    #[test]
    fn a_channel_name_with_a_second_separator_is_refused() -> Result<(), Failure> {
        let mut manifest = Manifest::new("Ledger");
        manifest.channel_name = "/lepton/ledger".to_owned();
        assert_err!(validate(&manifest), "a second separator must be refused");
        Ok(())
    }

    #[test]
    fn the_rendered_manifest_is_balanced_and_carries_every_field() -> Result<(), Failure> {
        let rendered = render_manifest(&Manifest::new("Ledger"));

        balanced(&rendered, '{', '}')?;
        balanced(&rendered, '[', ']')?;

        for key in [
            "productName",
            "identifier",
            "renderPath",
            "target",
            "sdkScope",
            "channel",
            "window",
            "width",
            "height",
        ] {
            ensure!(rendered.contains(key), "missing {key} in:\n{rendered}");
        }
        Ok(())
    }

    #[test]
    fn a_title_with_a_quote_produces_a_file_that_still_parses() -> Result<(), Failure> {
        // The failure this guards is subtle and total: a manifest that does not
        // parse makes the project unreadable to the very tool that wrote it.
        let mut manifest = Manifest::new("Ledger");
        manifest.window_title = "He said \"hello\" \\ then left".to_owned();

        let rendered = render_manifest(&manifest);
        assert_contains!(&rendered, &json_string(&manifest.window_title));
        balanced(&rendered, '{', '}')?;
        Ok(())
    }

    #[test]
    fn control_characters_are_escaped_rather_than_dropped() -> Result<(), Failure> {
        assert_eq!(json_string("a\tb"), "\"a\\tb\"");
        assert_eq!(json_string("a\nb"), "\"a\\nb\"");
        assert_eq!(json_string("a\u{1}b"), "\"a\\u0001b\"");
        Ok(())
    }

    #[test]
    fn a_render_path_survives_a_round_trip() -> Result<(), Failure> {
        for path in [RenderPath::Webview, RenderPath::Native] {
            assert_eq!(RenderPath::parse(path.as_str()), Some(path));
        }
        assert_eq!(RenderPath::parse("web"), None::<RenderPath>);
        Ok(())
    }

    #[test]
    fn a_target_survives_a_round_trip() -> Result<(), Failure> {
        for target in [
            Target::VanillaTs,
            Target::React,
            Target::Vue,
            Target::Svelte,
            Target::Solid,
            Target::Preact,
            Target::Lit,
            Target::Angular,
        ] {
            assert_eq!(Target::parse(target.as_str()), Some(target));
        }
        assert_eq!(Target::parse("qwik"), None::<Target>);
        Ok(())
    }

    #[test]
    fn each_render_path_describes_what_it_costs() -> Result<(), Failure> {
        // The description is what a developer reads when wondering why their app
        // uses so much memory, so it has to say the thing that explains it.
        assert_contains!(RenderPath::Native.describe(), "no web engine");
        assert_contains!(RenderPath::Webview.describe(), "web engine");
        Ok(())
    }
}
