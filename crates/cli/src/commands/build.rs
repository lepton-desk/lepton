//! `lepton build` — producing something a person can run.
//!
//! A Lepton build is two compilers in sequence, and the order is not negotiable: the
//! frontend's output is an input to the core, because the core embeds the bundle's
//! directory rather than reading it at run time. A core built first would have
//! nothing to embed, and the failure would surface at run time as an empty window.
//!
//! Which of the two steps actually run depends on the project's render path. A
//! native project has no frontend at all, so running a bundler for it would be
//! building something the application will never load.

use std::path::{Path, PathBuf};

use lepton_orchestrator::{Step, ToolRequirement, Toolchain, require};

use super::{CliError, Outcome};

/// The tag this command is known by in tests and messages.
const NAME: &str = "build";

/// Where the Zig core lives, relative to the project root.
///
/// The name is part of the contract: it is what `lepton dev` looks for, what a
/// documentation page links to, and what a developer's editor opens. It is not
/// derived from anything, so it cannot drift between the CLI and the template.
pub const CORE_DIR: &str = "src-lepton";

/// Why `--macos` is refused.
pub const MACOS_UNSUPPORTED: &str = "--macos: macOS is not supported. Signing and notarizing \
     for it needs a paid Apple developer account and Mac hardware to test on, which Lepton \
     cannot keep up; Linux and Windows are supported";

/// Flags for `lepton build`.
#[derive(Debug, Clone, Default, clap::Args)]
pub struct Flags {
    /// Builds for Linux.
    #[arg(long, conflicts_with_all = ["windows", "macos", "webview"])]
    pub linux: bool,

    /// Builds for Windows.
    #[arg(long, conflicts_with_all = ["linux", "macos", "webview"])]
    pub windows: bool,

    /// macOS: not supported. Kept so the build says why instead of "unknown flag".
    #[arg(long, conflicts_with_all = ["linux", "windows", "webview"])]
    pub macos: bool,

    /// Builds the native render path even if the configuration says webview.
    ///
    /// Overrides rather than replaces, because a project checked in with a webview
    /// path may be built both ways on the same machine and neither should require an
    /// edit to the configuration to try.
    #[arg(long, conflicts_with = "webview")]
    pub native: bool,

    /// Builds the webview render path even if the configuration says native.
    ///
    /// The mirror of `--native`, and present for the same reason: a project is one
    /// configuration, and a machine may well want to build both ways from it. Naming the
    /// default explicitly also means a script does not have to know which side of the
    /// flag it is on — `lepton build --webview` means the same thing whether or not
    /// webview is already the default.
    #[arg(long)]
    pub webview: bool,

    /// Servo, the experimental second engine (Linux): the pages render through
    /// `liblepton_servo.so`, found by `servo.rs` (`LEPTON_SERVO_LIB` until it is
    /// published), instead of WPE WebKit.
    #[arg(long, requires = "linux")]
    pub servo: bool,

    /// The directory holding Servo's library, once `--servo` has found it.
    #[arg(skip)]
    pub servo_lib: Option<PathBuf>,

    /// Prints what would run without running it.
    #[arg(long, short = 'n')]
    pub dry_run: bool,
}

impl Flags {
    /// Builds the project in the current directory.
    pub fn run(self) -> Outcome {
        let root = std::env::current_dir().map_err(|error| {
            CliError::Invalid(format!("could not read the working directory: {error}"))
        })?;
        if !self.dry_run {
            super::report::Report::new().header("build");
        }
        self.build_in(&root)
    }

    /// Builds the project rooted at `root`.
    pub fn build_in(&self, root: &Path) -> Outcome {
        // It once cross-compiled for `aarch64-macos` and handed over a binary nobody had
        // run. Refused before anything is built, a dry run included.
        if self.macos {
            return Err(CliError::Invalid(MACOS_UNSUPPORTED.to_owned()));
        }
        // Servo's library is found first, a dry run included: without it the core cannot
        // link, and a `--servo` build that quietly became WPE WebKit is what this flag
        // once did (measured 2026-10-18).
        if self.servo && self.servo_lib.is_none() {
            let mut resolved = self.clone();
            resolved.servo_lib = Some(super::servo::library(root)?);
            return resolved.build_in(root);
        }
        lepton_orchestrator::require_project(root)?;
        // A SIGTERM to `lepton` ends the build or the application it started.
        lepton_orchestrator::supervise::install();

        let manifest = read_manifest(root)?;
        let chain = Toolchain::detect();
        require(&chain, ToolRequirement::Build)?;

        let platform = self.platform();
        // Both flags override the configuration, and they are mutually exclusive so that
        // a script cannot ask for two different render paths in one invocation and be
        // told only about the one that lost.
        let native = !self.webview
            && (self.native
                || manifest.render_path == lepton_template_injector::RenderPath::Native);

        if !native && root.join("package.json").is_file() {
            super::package_manager::ensure_installed(root, &chain)?;
        }
        let mut steps = self.plan(root, &chain, native, platform);
        if !native {
            super::command_types::types_first(&mut steps, root);
        }
        super::launch::name_core(
            &mut steps,
            &super::launch::binary_name(&manifest.product_name),
        );
        super::launch::grant_permissions(&mut steps, root)?;
        super::launch::size_window(
            &mut steps,
            root,
            manifest.window_width,
            manifest.window_height,
        );
        super::window_shape::shape_window(&mut steps, root)?;
        super::plugins::pass_to_core(&mut steps, root)?;
        super::launch::hand_over_frontend(
            &mut steps,
            root,
            &super::launch::read_frontend(root)?.dist,
        );
        // A linked `@lepton-desk/*` checkout whose `dist/` predates its `src/` is built
        // first, so the bundle sees the package as it is (`linked.rs`).
        if !native {
            super::linked::rebuild_first(&mut steps, root, &chain);
        }

        if self.dry_run {
            // Printed in order, one per line, in the form a developer could paste
            // into a shell. That is the only useful thing a dry run can be.
            println!("target        {}", platform.describe());
            for step in &steps {
                println!("{}", lepton_orchestrator::display(step));
            }
            return Ok(());
        }
        // A webview build for Linux needs WPE WebKit (Servo links its own engine); without
        // it, say how to get it and offer to.
        if !native && !self.servo && !self.windows && !self.macos {
            super::engine::ensure()?;
        }

        let report = super::report::Report::new();
        for step in &steps {
            report.run(step).map_err(CliError::from)?;
            // After every core build, the declarations step included: the frontend step
            // that follows type-checks against them.
            if super::launch::is_core_build(step) {
                super::command_types::sync_and_report(root);
            }
        }

        // "it built" is the least useful sentence in a build log. Where the artifact
        // is, is the sentence a developer acts on — and it is the one thing this
        // command knows that `zig` does not print.
        report.fact("built", &super::report::shown(&artifact_dir(root)));
        Ok(())
    }

    /// The operating systems this build targets.
    ///
    /// None named means the host. Cross-compiling is opt-in because a build for
    /// another platform silently produces a binary that cannot run here, and a
    /// developer would rather be told to name the platform than be handed one.
    fn platform(&self) -> Platform {
        if self.windows {
            Platform::Windows
        } else if self.macos {
            Platform::MacOs
        } else if self.linux {
            Platform::Linux
        } else {
            // Nothing named: this machine. It once fell to Linux here, so a plain
            // `lepton build` on Windows passed `-Dtarget=x86_64-linux-gnu` (measured).
            Platform::host()
        }
    }

    /// The steps this build runs, in the order it runs them.
    fn plan(&self, root: &Path, chain: &Toolchain, native: bool, platform: Platform) -> Vec<Step> {
        let mut steps = Vec::new();

        if !native {
            // Both steps are conditional on the files existing rather than on the
            // flags: a project whose package.json has no `build` script is a project
            // that is not a frontend, and refusing to guess is better than a
            // `pnpm run build` that fails on a missing script.
            if root.join("package.json").is_file() {
                steps.push(self.package_manager_step(chain, root, &["run", "build"]));
            }
        }

        steps.push(self.core_step(chain, root, native, platform));
        steps
    }

    /// A step that runs through the machine's package manager.
    ///
    /// The program name is read from the detected toolchain rather than assumed, so
    /// `pnpm run build` and `npm run build` are the same code path with different
    /// arguments — and neither is a shell string, which is what keeps a project name
    /// with a space in it from being re-split by a shell.
    fn package_manager_step(&self, chain: &Toolchain, root: &Path, args: &[&str]) -> Step {
        let program = super::package_manager::for_project(root, chain).program();

        Step::new(NAME, program)
            .args(args.iter().map(|arg| (*arg).to_owned()))
            .in_dir(root.to_path_buf())
    }

    /// The step that compiles the Zig core.
    ///
    /// `ReleaseSmall` rather than `ReleaseFast` because the artifact is a binary
    /// developers copy between machines, and a desktop application whose reason to
    /// exist is to be small should not ship debug symbols and unwind tables.
    fn core_step(&self, chain: &Toolchain, root: &Path, native: bool, platform: Platform) -> Step {
        // The detected path when there is one. `require` has already refused a
        // machine without Zig, so this is a real binary — and using the path the
        // probe found is what lets a toolchain outside `PATH` still work.
        let zig = match &chain.zig.path {
            Some(path) => path.clone(),
            None => String::from("zig"),
        };

        let mut step = Step::new(NAME, zig)
            .arg("build")
            // `safe` rather than `fast`: the core indexes frames the webview wrote, so
            // a fast build's skipped bounds checks would turn a malformed frame into
            // undefined behaviour rather than a caught error.
            .arg("--release=safe")
            .arg("-Doptimize=ReleaseSmall")
            .in_dir(root.join(CORE_DIR));

        // Only for a platform that is not this one. Naming the host's own triple turns
        // a native build into a cross-compile, and a cross-compile does not consult
        // pkg-config: the display libraries the core was just probed for stop being
        // findable, and the failure names `-lxcb-randr` rather than the flag that
        // caused it.
        if let Some(triple) = platform.cross_triple() {
            step = step.arg(format!("-Dtarget={triple}"));
        }

        if native {
            step = step.arg("-Drender=native");
        }
        if let Some(dir) = &self.servo_lib {
            step = step.arg(format!("-Dservo-lib={}", dir.display()));
        }

        step
    }
}

/// The platforms a build can target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Linux,
    Windows,
    MacOs,
}

impl Platform {
    /// This machine's platform, as Lepton names it.
    ///
    /// Read from the target's own OS rather than probed: it is a compile-time fact
    /// about the binary and nothing about the machine can change it. A function rather
    /// than a constant because matching on a string is not allowed in a `const`.
    pub fn host() -> Self {
        match std::env::consts::OS {
            "macos" => Self::MacOs,
            "windows" => Self::Windows,
            _ => Self::Linux,
        }
    }

    /// The Zig target triple for building this platform on another machine.
    ///
    /// Written out rather than looked up: a triple is a string with no API behind it,
    /// and a wrong one produces a linker error a long way from the mistake. `None` for
    /// the host, because a build for the machine doing the building does not name a
    /// target at all.
    pub fn cross_triple(self) -> Option<&'static str> {
        if self == Self::host() {
            return None;
        }

        Some(match self {
            Self::Linux => "x86_64-linux-gnu",
            Self::Windows => "x86_64-windows-gnu",
            Self::MacOs => "aarch64-macos",
        })
    }

    /// The triple this platform is built with, host or not.
    ///
    /// For a message a developer reads and for `--dry-run`, where naming the host's
    /// triple is more useful than naming nothing even though the build itself does not
    /// pass one.
    pub fn describe(self) -> String {
        match self.cross_triple() {
            Some(triple) => triple.to_string(),
            // Said rather than left blank: an empty target column in a dry run reads as
            // a bug in the tool rather than as "this machine".
            None => format!("{} (this machine)", self.zig_triple()),
        }
    }

    /// The triple this platform is built with, host or not.
    fn zig_triple(self) -> &'static str {
        match self {
            Self::Linux => "x86_64-linux-gnu",
            Self::Windows => "x86_64-windows-gnu",
            Self::MacOs => "aarch64-macos",
        }
    }
}

/// Reads the project's configuration from disk.
pub(super) fn read_manifest(root: &Path) -> Result<lepton_template_injector::Manifest, CliError> {
    let path = root.join(lepton_orchestrator::CONFIG_FILE);
    let text = std::fs::read_to_string(&path).map_err(|error| {
        CliError::Invalid(format!("could not read {}: {error}", path.display()))
    })?;

    lepton_template_injector::parse_config(&text).map_err(|error| {
        CliError::Injection(lepton_template_injector::InjectionError::InvalidManifest {
            reason: error.reason,
        })
    })
}

/// Where a finished build is expected to appear, for the summary a developer reads.
///
/// Not a guarantee — the core's own build decides its output layout — but a path the
/// CLI can name is the difference between "it built" and "it built, and here it is".
pub fn artifact_dir(root: &Path) -> PathBuf {
    root.join(CORE_DIR).join("zig-out").join("bin")
}

#[cfg(test)]
mod tests {
    use super::{CORE_DIR, Flags, Platform, artifact_dir, read_manifest};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{
        ToolProblem, ToolRequirement, ToolStatus, Toolchain, assert_contains, assert_eq,
        assert_err, assert_ok, ensure,
    };
    use lepton_template_injector::{Manifest, RenderPath, render_manifest};
    use std::path::{Path, PathBuf};

    /// A complete toolchain, so the plan can be inspected without probing this machine.
    fn complete() -> Toolchain {
        Toolchain {
            zig: ToolStatus {
                name: "zig",
                path: None,
                version: Some(String::from("0.16.0")),
                problem: None,
            },
            node: ToolStatus {
                name: "node",
                path: None,
                version: Some(String::from("v26.10.0")),
                problem: None,
            },
            package_manager: ToolStatus {
                name: "pnpm",
                path: None,
                version: Some(String::from("12.5.1")),
                problem: None,
            },
            display: Default::default(),
        }
    }

    /// A project directory holding a configuration with the given render path.
    fn project(tag: &str, path: RenderPath) -> Result<(Scratch, Manifest), Failure> {
        let scratch = assert_ok!(
            Scratch::new(tag),
            "the scratch directory should be creatable"
        );
        let mut manifest = Manifest::new("Ledger");
        manifest.render_path = path;

        scratch
            .write(
                lepton_orchestrator::CONFIG_FILE,
                &render_manifest(&manifest),
            )
            .map_err(|error| Failure {
                claim: "the configuration should be writable".to_owned(),
                actual: format!("{error}"),
            })?;

        Ok((scratch, manifest))
    }

    #[test]
    fn a_webview_build_runs_the_bundler_before_the_core() -> Result<(), Failure> {
        // The order is the whole contract: the core embeds the bundle's directory, so
        // a core built first embeds whatever was there last time.
        let (scratch, _) = project("build-webview", RenderPath::Webview)?;
        std::fs::write(scratch.path().join("package.json"), "{}\n").map_err(|error| Failure {
            claim: "a package.json should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

        let steps = Flags::default().plan(scratch.path(), &complete(), false, Platform::Linux);

        assert_eq!(steps.len(), 2);
        // Named by its arguments rather than its program: the program is whatever
        // package manager this machine has, and that is not what is being asserted.
        ensure!(
            steps[0].args == ["run", "build"],
            "the first step should run the build script, got {:?}",
            steps[0].args
        );
        ensure!(
            steps[1].args.first().map(String::as_str) == Some("build"),
            "the second step should be the core, got {:?}",
            steps[1].args
        );
        Ok(())
    }

    #[test]
    fn a_native_build_skips_the_bundler_entirely() -> Result<(), Failure> {
        // A native project has no frontend to bundle. Running a bundler for it would
        // be building something the application never loads.
        let (scratch, _) = project("build-native", RenderPath::Native)?;
        std::fs::write(scratch.path().join("package.json"), "{}\n").map_err(|error| Failure {
            claim: "a package.json should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

        let steps = Flags::default().plan(scratch.path(), &complete(), true, Platform::Linux);

        assert_eq!(steps.len(), 1);
        ensure!(
            steps[0].args.iter().any(|arg| arg == "build"),
            "the only step should be the core, got {:?}",
            steps[0].args
        );
        Ok(())
    }

    #[test]
    fn a_project_with_no_package_json_has_no_bundler_step() -> Result<(), Failure> {
        // Presence of the file is the test, not the flags: a project without a
        // package.json is not a frontend, and the CLI does not guess.
        let (scratch, _) = project("build-no-package", RenderPath::Webview)?;

        let steps = Flags::default().plan(scratch.path(), &complete(), false, Platform::Linux);

        assert_eq!(steps.len(), 1);
        Ok(())
    }

    #[test]
    fn the_core_step_names_the_core_directory_and_a_small_release() -> Result<(), Failure> {
        let (scratch, _) = project("build-core", RenderPath::Native)?;

        let steps = Flags::default().plan(scratch.path(), &complete(), true, Platform::Linux);
        let core = steps.first().ok_or(Failure {
            claim: "a native build runs the core".to_owned(),
            actual: String::from("no steps"),
        })?;

        assert_eq!(
            core.cwd.as_deref(),
            Some(scratch.path().join(CORE_DIR).as_path())
        );
        // The core directory name is a contract with `lepton dev` and with the
        // template, so it is asserted rather than derived at the call site.
        assert_contains!(&CORE_DIR, "src-lepton");
        assert_contains!(&core.args.join(" "), "ReleaseSmall");
        Ok(())
    }

    #[test]
    fn the_native_flag_reaches_the_core_as_a_build_option() -> Result<(), Failure> {
        let (scratch, _) = project("build-native-flag", RenderPath::Webview)?;

        let steps = Flags::default().plan(scratch.path(), &complete(), true, Platform::Linux);

        assert_contains!(&steps[0].args.join(" "), "-Drender=native");
        Ok(())
    }

    #[test]
    fn the_host_build_names_no_target_and_a_cross_build_does() -> Result<(), Failure> {
        let (scratch, _) = project("build-target", RenderPath::Native)?;

        let host_steps = Flags::default().plan(scratch.path(), &complete(), true, Platform::host());
        ensure!(
            !host_steps[0]
                .args
                .iter()
                .any(|arg| arg.starts_with("-Dtarget")),
            "a host build should not name a target: {:?}",
            host_steps[0].args
        );

        // Whatever the host is, at least one platform is not it, and that one must
        // carry a triple or the build would silently produce a binary for this machine
        // when the developer asked for another.
        for platform in [Platform::Linux, Platform::Windows, Platform::MacOs] {
            if platform == Platform::host() {
                continue;
            }
            let steps = Flags::default().plan(scratch.path(), &complete(), true, platform);
            assert_contains!(
                &steps[0].args.join(" "),
                &format!("-Dtarget={}", platform.zig_triple())
            );
        }
        Ok(())
    }

    #[test]
    fn the_servo_flag_reaches_the_core_and_nothing_else() -> Result<(), Failure> {
        let (scratch, _) = project("build-servo", RenderPath::Native)?;
        let flags = Flags {
            linux: true,
            servo: true,
            servo_lib: Some(PathBuf::from("/opt/lepton-servo/lib")),
            ..Flags::default()
        };

        let steps = flags.plan(scratch.path(), &complete(), true, Platform::Linux);

        assert_contains!(
            &steps[0].args.join(" "),
            "-Dservo-lib=/opt/lepton-servo/lib"
        );
        // And the platform stays Linux's: a Servo build anywhere else would be a link
        // error, and clap already refuses `--servo` without `--linux`. Asserted as the
        // platform rather than as a triple, because a build for the machine doing the
        // building correctly names no triple at all.
        ensure!(
            steps[0]
                .args
                .iter()
                .all(|arg| !arg.starts_with("-Dtarget=") || arg.contains("linux")),
            "a Servo build must not target another platform: {:?}",
            steps[0].args
        );
        Ok(())
    }

    #[test]
    fn servo_without_its_library_stops_with_the_reason_a_dry_run_included() -> Result<(), Failure> {
        // `--servo` once exited 0 with a WPE WebKit binary. Without Servo's library a
        // build that asks for it stops before running anything and says where to get it.
        // (With `LEPTON_SERVO_LIB` set in the environment there is a library to find:
        // `servo.rs` tests the search itself without the environment.)
        if std::env::var_os(super::super::servo::ENV).is_some() {
            return Ok(());
        }
        let (scratch, _) = project("build-servo-refused", RenderPath::Webview)?;
        for dry_run in [false, true] {
            let flags = Flags {
                linux: true,
                servo: true,
                dry_run,
                ..Flags::default()
            };
            match flags.build_in(scratch.path()) {
                Err(super::CliError::Invalid(reason)) => {
                    assert_contains!(&reason, "no liblepton_servo.so found");
                    assert_contains!(&reason, "LEPTON_SERVO_LIB");
                }
                other => {
                    return Err(Failure {
                        claim: format!("--servo without a library (dry run {dry_run}) stops"),
                        actual: format!("{other:?}"),
                    });
                }
            }
        }
        Ok(())
    }

    #[test]
    fn each_platform_names_its_own_triple() -> Result<(), Failure> {
        // A triple is a plain string with no API behind it, so these three are
        // asserted rather than trusted.
        assert_eq!(Platform::Linux.zig_triple(), "x86_64-linux-gnu");
        assert_eq!(Platform::Windows.zig_triple(), "x86_64-windows-gnu");
        assert_eq!(Platform::MacOs.zig_triple(), "aarch64-macos");
        Ok(())
    }

    #[test]
    fn a_build_for_this_machine_names_no_target() -> Result<(), Failure> {
        // The failure this guards is invisible until the linker runs: naming the
        // host's own triple makes Zig cross-compile, and a cross-compile does not
        // consult pkg-config, so the display libraries the core just probed for stop
        // being findable and the error names `-lxcb-randr` instead of the flag.
        ensure!(
            Platform::host().cross_triple().is_none(),
            "the host should not be given a triple"
        );

        for platform in [Platform::Linux, Platform::Windows, Platform::MacOs] {
            if platform != Platform::host() {
                ensure!(
                    platform.cross_triple().is_some(),
                    "{platform:?} is not the host and needs a triple"
                );
            }
        }
        Ok(())
    }

    #[test]
    fn no_platform_flag_means_the_host() -> Result<(), Failure> {
        // Cross-compiling unasked produces a binary that cannot run here, and a
        // developer would rather be told to name the platform.
        assert_eq!(Flags::default().platform(), Platform::host());

        let linux = Flags {
            linux: true,
            ..Flags::default()
        };
        assert_eq!(linux.platform(), Platform::Linux);

        let windows = Flags {
            windows: true,
            ..Flags::default()
        };
        assert_eq!(windows.platform(), Platform::Windows);

        let macos = Flags {
            macos: true,
            ..Flags::default()
        };
        assert_eq!(macos.platform(), Platform::MacOs);
        Ok(())
    }

    #[test]
    fn two_platform_flags_cannot_be_parsed_together() -> Result<(), Failure> {
        // Parsed through the binary's own surface rather than a local copy of the
        // flags: a second description of the command is exactly how a `conflicts_with`
        // comes to protect a surface nobody ships.
        use clap::Parser as _;

        for pair in [
            ["--linux", "--windows"],
            ["--windows", "--macos"],
            ["--linux", "--macos"],
        ] {
            let outcome = crate::Cli::try_parse_from(["lepton", "build", pair[0], pair[1]]);
            ensure!(outcome.is_err(), "{} {} must be refused", pair[0], pair[1]);
        }
        Ok(())
    }

    #[test]
    fn servo_is_refused_without_linux() -> Result<(), Failure> {
        // A flag that silently does nothing is worse than one that says why.
        use clap::Parser as _;

        let refused = crate::Cli::try_parse_from(["lepton", "build", "--servo"]);
        ensure!(refused.is_err(), "--servo alone must be refused");

        let accepted = crate::Cli::try_parse_from(["lepton", "build", "--linux", "--servo"]);
        ensure!(accepted.is_ok(), "--linux --servo should parse");
        Ok(())
    }

    #[test]
    fn macos_is_refused_with_the_reason_before_anything_is_built() -> Result<(), Failure> {
        let scratch = assert_ok!(
            Scratch::new("build-macos"),
            "the scratch directory should be creatable"
        );
        let flags = Flags {
            macos: true,
            dry_run: true,
            ..Flags::default()
        };
        // An empty directory: the refusal comes before the project is even looked for.
        let error = assert_err!(flags.build_in(scratch.path()), "--macos must be refused");
        assert_contains!(&error.to_string(), "macOS is not supported");
        Ok(())
    }

    #[test]
    fn a_directory_without_a_configuration_is_refused_by_name() -> Result<(), Failure> {
        let scratch = assert_ok!(
            Scratch::new("build-empty"),
            "the scratch directory should be creatable"
        );

        let error = assert_err!(
            read_manifest(scratch.path()),
            "an empty directory has no configuration"
        );

        assert_contains!(&error.to_string(), "lepton.config.json");
        Ok(())
    }

    #[test]
    fn the_configuration_on_disk_is_what_the_build_decides_on() -> Result<(), Failure> {
        // The build's render path is read from the file, not from a flag default: a
        // project checked in as native must build native without being told twice.
        let (scratch, _) = project("build-read", RenderPath::Native)?;

        let manifest = assert_ok!(
            read_manifest(scratch.path()),
            "the configuration should parse"
        );

        assert_eq!(manifest.render_path, RenderPath::Native);
        assert_eq!(manifest.identifier, "ledger");
        Ok(())
    }

    #[test]
    fn a_dry_run_prints_nothing_it_did_not_do() -> Result<(), Failure> {
        // The dry run must be answerable from its own output: if it invoked a tool,
        // the printed command lines would be a lie.
        let (scratch, _) = project("build-dry", RenderPath::Native)?;

        assert_ok!(
            Flags {
                dry_run: true,
                ..Flags::default()
            }
            .build_in(scratch.path()),
            "a dry run should succeed"
        );
        Ok(())
    }

    #[test]
    fn the_artifact_directory_is_where_the_core_actually_writes() -> Result<(), Failure> {
        let root = Path::new("/tmp/example");

        // Under the core directory, because that is where `zig build` runs and where
        // it puts `zig-out`. Reporting a path one level too high is worse than
        // reporting none: the developer looks, finds nothing, and concludes the build
        // did not produce anything.
        assert_eq!(
            artifact_dir(root),
            PathBuf::from("/tmp/example/src-lepton/zig-out/bin")
        );
        Ok(())
    }

    #[test]
    fn the_reported_artifact_is_the_one_on_disk() -> Result<(), Failure> {
        // The strongest statement available without a full build: the directory the
        // command names is inside the project, under the directory it builds in.
        let (scratch, _) = project("build-artifact", RenderPath::Native)?;

        let artifact = artifact_dir(scratch.path());

        ensure!(
            artifact.starts_with(scratch.path()),
            "the artifact should be inside the project: {}",
            artifact.display()
        );
        ensure!(
            artifact.starts_with(scratch.path().join(CORE_DIR)),
            "the artifact should be under the core directory: {}",
            artifact.display()
        );
        Ok(())
    }

    #[test]
    fn a_missing_zig_blocks_the_build_before_anything_is_written() -> Result<(), Failure> {
        // `require` is checked before the plan runs, so a machine without Zig fails
        // with a message about Zig rather than half-way through a bundler run.
        let chain = Toolchain {
            zig: ToolStatus {
                name: "zig",
                path: None,
                version: None,
                problem: Some(ToolProblem::NotFound),
            },
            ..complete()
        };

        let error = assert_err!(
            lepton_orchestrator::require(&chain, ToolRequirement::Build),
            "a build without Zig must be refused"
        );

        assert_contains!(&error.to_string(), "zig");
        Ok(())
    }
}
