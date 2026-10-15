//! `lepton run` — build once and open the application, with no server.
//!
//! The single-shot half of `dev`. The frontend is bundled to disk (`dist/`) instead of
//! served, and the core is built *without* `-Ddev-server`, so the binary reads the
//! files it will read when packaged. That makes `run` the command that answers "does
//! the thing I will ship actually open?" without the bundler's HMR client and its
//! live connection in the page hiding a difference.
//!
//! Debug by default: `run` is still a developer's command, and a backtrace with
//! symbols is worth more here than the size `build` optimises for. `--release`
//! swaps in the optimisation the shipped binary uses.

use std::path::Path;

use lepton_orchestrator::{Step, ToolRequirement, Toolchain, display, run_streaming};

use super::build::{CORE_DIR, artifact_dir, read_manifest};
use super::{CliError, Outcome};

/// The tag this command is known by in tests and messages.
const NAME: &str = "run";

/// Flags for `lepton run`.
#[derive(Debug, Clone, Default, clap::Args)]
pub struct Flags {
    /// Runs the native render path even if the configuration says webview.
    #[arg(long, conflicts_with = "webview")]
    pub native: bool,

    /// Runs the webview render path even if the configuration says native.
    #[arg(long)]
    pub webview: bool,

    /// Builds the core with the optimisation `lepton build` ships.
    #[arg(long)]
    pub release: bool,

    /// Prints the steps instead of running them.
    #[arg(long)]
    pub print_plan: bool,
}

impl Flags {
    /// Runs the project in the current directory.
    pub fn run(self) -> Outcome {
        let root = std::env::current_dir().map_err(|error| {
            CliError::Invalid(format!("could not read the working directory: {error}"))
        })?;

        self.run_in(&root)
    }

    /// Builds and opens the project rooted at `root`.
    pub fn run_in(&self, root: &Path) -> Outcome {
        lepton_orchestrator::require_project(root)?;
        // A SIGTERM to `lepton` ends the build or the application it started.
        lepton_orchestrator::supervise::install();

        let manifest = read_manifest(root)?;
        let chain = Toolchain::detect();
        lepton_orchestrator::require(&chain, ToolRequirement::Build)?;

        let native = !self.webview
            && (self.native
                || manifest.render_path == lepton_template_injector::RenderPath::Native);
        let mut steps = self.plan(root, &chain, native);
        if !native {
            super::command_types::types_first(&mut steps, root);
        }
        let binary = super::launch::binary_name(&manifest.product_name);
        super::launch::name_core(&mut steps, &binary);
        super::launch::grant_permissions(&mut steps, root)?;
        super::plugins::pass_to_core(&mut steps, root)?;
        super::launch::hand_over_frontend(&mut steps, root);
        // A linked `@lepton-desk/*` checkout whose `dist/` predates its `src/` is built
        // first, so the bundle sees the package as it is (`linked.rs`).
        if !native {
            super::linked::rebuild_first(&mut steps, root, &chain);
        }

        if self.print_plan {
            for step in &steps {
                println!("{}", display(step));
            }
            return Ok(());
        }

        for step in &steps {
            run_streaming(step).map_err(CliError::from)?;
            // After every core build, the declarations step included: the frontend step
            // that follows type-checks against them.
            if super::launch::is_core_build(step) {
                super::command_types::sync_and_report(root);
            }
        }

        super::desktop_entry::announce(
            &manifest.identifier,
            &manifest.product_name,
            &artifact_dir(root).join(&binary),
        );
        super::launch::launch(NAME, &artifact_dir(root), &binary)
    }

    /// The build steps, in order; opening the binary follows them.
    pub fn plan(&self, root: &Path, chain: &Toolchain, native: bool) -> Vec<Step> {
        let mut steps = Vec::new();

        // The bundle is written to disk because the binary reads it from there; a
        // native build has no bundle to write.
        if !native && root.join("package.json").is_file() {
            steps.push(
                Step::new(NAME, super::launch::package_manager(chain))
                    .args(["run", "build"])
                    .in_dir(root.to_path_buf()),
            );
        }

        let zig = match &chain.zig.path {
            Some(path) => path.clone(),
            None => String::from("zig"),
        };
        let optimize = if self.release {
            "-Doptimize=ReleaseSmall"
        } else {
            "-Doptimize=Debug"
        };
        // No `-Ddev-server`: an empty address is what makes the binary read `dist/`.
        let mut core = Step::new(NAME, zig)
            .arg("build")
            .arg(optimize)
            .in_dir(root.join(CORE_DIR));
        if native {
            core = core.arg("-Drender=native");
        }
        steps.push(core);

        steps
    }
}

#[cfg(test)]
mod tests {
    use super::Flags;
    use crate::commands::build::CORE_DIR;
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{ToolStatus, Toolchain, assert_contains, assert_eq, ensure};

    fn complete() -> Toolchain {
        let tool = |name: &'static str, version: &str| ToolStatus {
            name,
            path: None,
            version: Some(version.to_owned()),
            problem: None,
        };
        Toolchain {
            zig: tool("zig", "0.16.0"),
            node: tool("node", "v26.10.0"),
            package_manager: tool("pnpm", "12.5.1"),
            display: Default::default(),
        }
    }

    fn frontend(tag: &str) -> Result<Scratch, Failure> {
        let scratch = Scratch::new(tag)?;
        scratch.write("package.json", "{}\n")?;
        Ok(scratch)
    }

    #[test]
    fn a_webview_run_bundles_to_disk_before_the_core() -> Result<(), Failure> {
        let root = frontend("run-order")?;

        let steps = Flags::default().plan(root.path(), &complete(), false);

        assert_eq!(steps.len(), 2);
        assert_eq!(steps[0].args.join(" "), "run build");
        assert_eq!(
            steps[1].cwd.as_deref(),
            Some(root.path().join(CORE_DIR).as_path())
        );
        Ok(())
    }

    #[test]
    fn the_core_reads_its_frontend_from_disk_not_a_server() -> Result<(), Failure> {
        // The whole point of `run` over `dev`: what opens is what ships. A dev-server
        // address baked in would make the binary blank the moment no server listens.
        let root = frontend("run-disk")?;

        for native in [true, false] {
            let steps = Flags::default().plan(root.path(), &complete(), native);
            for step in &steps {
                ensure!(
                    !step.args.iter().any(|arg| arg.starts_with("-Ddev-")),
                    "run must not point the binary at a server: {:?}",
                    step.args
                );
            }
        }
        Ok(())
    }

    #[test]
    fn the_core_is_built_but_not_opened_by_zig() -> Result<(), Failure> {
        let root = frontend("run-once")?;

        let steps = Flags::default().plan(root.path(), &complete(), true);

        ensure!(
            !steps
                .iter()
                .any(|step| step.args.iter().any(|arg| arg == "run")),
            "zig must not open the window; the command does: {:?}",
            steps.iter().map(|step| &step.args).collect::<Vec<_>>()
        );
        Ok(())
    }

    #[test]
    fn a_native_run_has_no_bundle_step() -> Result<(), Failure> {
        let root = frontend("run-native")?;

        let steps = Flags::default().plan(root.path(), &complete(), true);

        assert_eq!(steps.len(), 1);
        assert_contains!(&steps[0].args.join(" "), "-Drender=native");
        Ok(())
    }

    #[test]
    fn debug_by_default_and_release_on_request() -> Result<(), Failure> {
        let root = frontend("run-optimize")?;

        let debug = Flags::default().plan(root.path(), &complete(), true);
        assert_contains!(&debug[0].args.join(" "), "-Doptimize=Debug");

        let release = Flags {
            release: true,
            ..Flags::default()
        }
        .plan(root.path(), &complete(), true);
        assert_contains!(&release[0].args.join(" "), "-Doptimize=ReleaseSmall");
        Ok(())
    }

    #[test]
    fn native_and_webview_together_are_refused() -> Result<(), Failure> {
        use clap::Parser as _;

        let refused = crate::Cli::try_parse_from(["lepton", "run", "--native", "--webview"]);
        ensure!(refused.is_err(), "--native --webview must be refused");

        let accepted = crate::Cli::try_parse_from(["lepton", "run", "--native", "--release"]);
        ensure!(accepted.is_ok(), "--native --release should parse");
        Ok(())
    }
}
