//! Wiring Lepton's SDK, configuration and bindings into a scaffolded frontend.
//!
//! A frontend scaffolder produces a working web project. What it cannot know is
//! anything about Lepton: that this project needs a shared-memory channel to a Zig
//! core, that its dependencies include the Lepton SDK, that its build has to invoke
//! the core as well as the bundler. This crate adds exactly that, and nothing else.
//!
//! The order matters. Vite has to produce the project first, because its structure
//! is what the injection adapts to — and adapting to a structure rather than
//! imposing one is why a Lepton project is still a Vite project that a developer
//! can read, edit and take apart.
//!
//! Every file written here is either a whole file or a marked region inside one.
//! Re-running is therefore safe: a second injection replaces its own region and
//! leaves the developer's code between markers untouched, instead of rewriting a
//! file they may have changed.

#![forbid(unsafe_code)]

pub mod assets;
pub mod base;
pub mod bundle;
pub mod manifest;
pub mod merge;
pub mod permissions;
pub mod plan;
pub mod plugin_catalog;
pub mod read;
pub mod update;

pub use assets::{
    BIOME_CONFIG, BIOME_VERSION, MAIN_ENTRY, MEASURES, REACT_ENTRY, REACT_SCREEN, SDK_ENTRY,
    STYLESHEET, ZIG_BUILD, index_html, package_manifest, zig_entry,
};
pub use base::{BaseFrontend, Bindings, TemplateError};
pub use bundle::{Bundle, BundleTarget, parse_bundle};
pub use manifest::{
    Language, Manifest, ManifestError, RenderPath, Target, render_manifest, validate,
};
pub use permissions::{
    PERMISSION_ANSWER, WEB_PERMISSION_KINDS, parse_permissions, parse_web_permissions,
};
pub use plan::{Injection, InjectionError, Mode, Plan, apply, plan};
pub use read::parse_config;

/// Where a project's configuration file lives, relative to its root.
pub const CONFIG_PATH: &str = "lepton.config.json";

#[cfg(test)]
mod tests {
    use super::CONFIG_PATH;
    use lepton_orchestrator::CONFIG_FILE;
    use lepton_orchestrator::assert_eq;
    use lepton_orchestrator::testing::Failure;

    #[test]
    fn the_config_path_is_the_one_the_orchestrator_looks_for() -> Result<(), Failure> {
        // Two crates naming the file independently would drift, and the drift would
        // show only as a project the CLI cannot recognise — the worst time to find out.
        assert_eq!(CONFIG_PATH, CONFIG_FILE);
        Ok(())
    }
}

#[cfg(test)]
mod measures_tests;
