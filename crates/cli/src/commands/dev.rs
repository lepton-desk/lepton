//! `lepton dev` — the development loop.
//!
//! Two processes that have to agree on a port, a directory and a channel name, and a
//! watcher that has to notice when either of the first two changes. Lepton's part is
//! small: the bundler is the bundler's, the core is the core's, and this command's
//! job is to start the right one of each and shut both down cleanly.
//!
//! It does not run them concurrently. Two long-lived children with different
//! lifetimes — one ends when the developer saves a file, the other ends when the
//! window closes — are two things to supervise, and supervising them properly is a
//! separate concern from describing them. What this command owns is the description.

use std::path::Path;

use lepton_orchestrator::{Step, ToolRequirement, Toolchain, display, run_streaming};

use super::build::CORE_DIR;
use super::{CliError, Outcome};

/// The tag this command is known by in tests and messages.
const NAME: &str = "dev";

/// The port the development server listens on when nothing else is said.
pub const DEFAULT_PORT: u16 = 5173;

/// The address both the dev server and the core use. A literal, not `localhost`.
pub const DEV_HOST: &str = "127.0.0.1";

/// Flags for `lepton dev`.
#[derive(Debug, Clone, clap::Args)]
pub struct Flags {
    /// The port the development server listens on.
    #[arg(long, short = 'p', default_value_t = DEFAULT_PORT)]
    pub port: u16,

    /// Skips the web engine entirely and draws straight to the window.
    #[arg(long)]
    pub native: bool,

    /// Opens the window against an already-running server at `--port` instead of
    /// starting one.
    ///
    /// For the case where the developer started the bundler themselves to watch its
    /// output, which is a legitimate reason to not want a second copy of it.
    #[arg(long, conflicts_with = "port")]
    pub no_server: bool,

    /// Prints the loop instead of running it.
    ///
    /// The only useful thing a plan can do is be read, and being able to ask for the plan
    /// without running it is what makes `--print-plan` honest: without the flag, running
    /// the loop is what the command does.
    #[arg(long)]
    pub print_plan: bool,

    /// Leaves the loop's window open when the application exits.
    ///
    /// Off by default because a developer watching output wants the command to end when
    /// the program does, not to sit there afterwards waiting for a keypress that will not
    /// come in a script.
    #[arg(long)]
    pub keep_open: bool,
}

impl Flags {
    /// Runs the development loop in the current directory.
    pub fn run(self) -> Outcome {
        let root = std::env::current_dir().map_err(|error| {
            CliError::Invalid(format!("could not read the working directory: {error}"))
        })?;

        self.dev_in(&root)
    }

    /// Describes and prints the loop for the project rooted at `root`.
    pub fn dev_in(&self, root: &Path) -> Outcome {
        lepton_orchestrator::require_project(root)?;

        let manifest = super::build::read_manifest(root)?;
        let chain = Toolchain::detect();
        // `Develop` rather than `Build`: the loop needs Node for the dev server, and
        // a machine that can build but cannot develop is a machine whose `dev` should
        // say so rather than fail later inside a watcher.
        lepton_orchestrator::require(&chain, ToolRequirement::Develop)?;

        let native =
            self.native || manifest.render_path == lepton_template_injector::RenderPath::Native;

        let mut steps = self.plan(root, &chain, native);
        let binary = super::launch::binary_name(&manifest.product_name);
        super::launch::name_core(&mut steps, &binary);
        super::launch::grant_permissions(&mut steps, root)?;
        // Built before the dev server starts: it serves a linked package from its `dist/`.
        let rebuilds = if native {
            Vec::new()
        } else {
            super::linked::rebuild_steps(root, super::linked::program(&chain))
        };
        // Held so the servers can be stopped when the loop ends; dropping a `Child`
        // without killing it leaves a listener holding the port, and the next `dev`
        // then fails on a port nothing has closed.
        let mut background_children = Background::default();

        if self.print_plan {
            for step in rebuilds.iter().chain(&steps) {
                println!("{}", display(step));
            }
            return Ok(());
        }

        // The server goes first and goes to the **background**. The core asks it for the
        // bundle the moment it starts, so it has to be listening before then — and it
        // never exits, so running it in the foreground would mean the core is never built.
        //
        // This is the structural difference from a toolchain that restarts the whole
        // application on every edit: the frontend is a *runtime address*, not part of the
        // binary, so the core is built once and the window keeps its state while the
        // server serves new bundles.
        let mut background = Vec::new();
        let mut foreground = Vec::new();
        for step in steps {
            if step.tool == NAME && step.program != "zig" {
                background.push(step);
            } else {
                foreground.push(step);
            }
        }

        // A SIGTERM to `lepton` must end the server and the application with it.
        lepton_orchestrator::supervise::install();

        for step in &rebuilds {
            run_streaming(step).map_err(CliError::from)?;
        }

        for step in &background {
            let child = std::process::Command::new(&step.program)
                .args(&step.args)
                .current_dir(step.cwd.as_deref().unwrap_or(root))
                // Not the terminal's: a server reading a TTY from outside the foreground
                // group is stopped by SIGTTIN, and Vite's key shortcuts are not ours to offer.
                .stdin(std::process::Stdio::null())
                .spawn()
                .map_err(|error| {
                    CliError::Invalid(format!("could not start the dev server: {error}"))
                })?;
            println!("dev server  started, pid {}", child.id());
            lepton_orchestrator::supervise::track(child.id());
            background_children.0.push(child);
        }

        // Measured for the session receipt: when edits start counting, and what the core
        // build actually cost.
        let session_started = std::time::SystemTime::now();
        let mut core_builds = 0;
        let mut core_build_time = std::time::Duration::ZERO;
        for step in &foreground {
            let began = std::time::Instant::now();
            run_streaming(step).map_err(CliError::from)?;
            if step.program == "zig" {
                core_builds += 1;
                core_build_time += began.elapsed();
            }
        }
        super::command_types::sync_and_report(root);

        // The application's own binary, started last and in the foreground: a development
        // loop that returned while its window closed behind it is not a loop.
        super::desktop_entry::announce(
            &manifest.identifier,
            &manifest.product_name,
            &super::build::artifact_dir(root).join(&binary),
        );
        let window_opened = std::time::Instant::now();
        // The same receipt when the loop ends by Ctrl-C or SIGTERM instead of a closed window.
        let receipt_root = root.to_path_buf();
        lepton_orchestrator::supervise::on_interrupt(move || {
            println!(
                "\n{}",
                super::session::receipt(&super::session::Session {
                    window_open: window_opened.elapsed(),
                    core_builds,
                    core_build_time,
                    frontend_edits: super::session::edited_since(
                        &receipt_root.join("src"),
                        session_started
                    ),
                })
            );
        });
        // A linked `@lepton-desk/*` checkout keeps being rebuilt while the window is open,
        // so the dev server serves the package as it is now (`linked.rs`). Stopped when
        // this function returns, after the window has closed.
        let _linked_watcher = (!native).then(|| {
            super::linked::Watcher::start(root.to_path_buf(), super::linked::program(&chain))
        });
        let outcome = super::launch::launch(NAME, &super::build::artifact_dir(root), &binary);
        if lepton_orchestrator::supervise::interrupted() {
            // The handler is ending the session and prints the receipt; let it finish.
            lepton_orchestrator::supervise::await_exit();
        }
        if outcome.is_ok() {
            // "0 rebuilds, 0 restarts" is structural, not a guess: this loop has no path that
            // rebuilds the core or restarts the window while it runs.
            println!(
                "\n{}",
                super::session::receipt(&super::session::Session {
                    window_open: window_opened.elapsed(),
                    core_builds,
                    core_build_time,
                    frontend_edits: super::session::edited_since(
                        &root.join("src"),
                        session_started
                    ),
                })
            );
        }
        if self.keep_open {
            println!("lepton: the application exited; the directory is still on disk");
        }

        // `background_children` ends the server when it drops — here, and on every early
        // return above, which the previous explicit loop at this point never reached.
        drop(background_children);
        outcome
    }

    /// The processes this loop runs, in start order.
    pub fn plan(&self, root: &Path, chain: &Toolchain, native: bool) -> Vec<Step> {
        let mut steps = Vec::new();

        if !native && !self.no_server && root.join("package.json").is_file() {
            steps.push(self.server_step(chain, root));
        }

        steps.push(self.core_step(root, native));
        steps
    }

    /// The dev server, on the port the developer chose.
    ///
    /// `run dev` rather than a bare `dev` because the script name is a project's
    /// choice, not Lepton's; the flag is what Lepton owns.
    fn server_step(&self, chain: &Toolchain, root: &Path) -> Step {
        let manager = super::launch::package_manager(chain);
        let mut step = Step::new(NAME, manager).args(["run", "dev"]);
        // npm needs `--` to forward flags to the script; pnpm forwards them on its own and
        // passes a `--` through *literally* — measured: `vite -- --port 5199` opened on
        // 5173, i.e. Vite ignored every flag after it, `--port` and `--strict-port`
        // included, ever since this command existed.
        if manager == "npm" {
            step = step.arg("--");
        }
        step.arg("--port")
            .arg(self.port.to_string())
            .arg("--strict-port")
            // The exact address the core is given below. `localhost` resolves to `::1`
            // on some machines, and a server there is refused at `127.0.0.1`.
            .arg("--host")
            .arg(DEV_HOST)
            .in_dir(root.to_path_buf())
    }

    /// The core, told where the bundle is and how to talk to it.
    fn core_step(&self, root: &Path, native: bool) -> Step {
        // `build`, not `build run`: the template's `run` step opens the window itself,
        // and this command opens it once more after the build — twice in total.
        let mut step = Step::new(NAME, "zig")
            .arg("build")
            // Dev builds keep debug info: the core is the layer a developer is most
            // likely to be stepping through, and a stripped dev build turns a
            // backtrace into a list of addresses.
            .arg("-Doptimize=Debug")
            .in_dir(root.join(CORE_DIR));

        if native {
            step = step.arg("-Drender=native");
        } else {
            step = step
                .arg(format!("-Ddev-server=http://{DEV_HOST}:{}", self.port))
                .arg(format!("-Ddev-port={}", self.port));
        }

        step
    }
}

/// The servers a loop started, ended when the loop ends by any path.
///
/// SIGTERM rather than `Child::kill` (SIGKILL), so the package manager can pass the
/// signal on, and waited for, so the port is free before `dev` returns.
#[derive(Default)]
struct Background(Vec<std::process::Child>);

impl Drop for Background {
    fn drop(&mut self) {
        for child in &mut self.0 {
            lepton_orchestrator::supervise::terminate(child.id());
            let _ = child.wait();
            lepton_orchestrator::supervise::untrack(child.id());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_PORT, Flags, display};
    use crate::commands::build::CORE_DIR;
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{
        ToolStatus, Toolchain, assert_contains, assert_eq, assert_ok, ensure,
    };

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

    /// A root that looks like a frontend project.
    ///
    /// The guard is returned rather than just its path: `Scratch` deletes itself when
    /// dropped, so a helper that handed back a bare path would return a directory that
    /// no longer exists by the time the caller looked at it.
    fn webview_root(tag: &str) -> Result<lepton_orchestrator::testing::Scratch, Failure> {
        let scratch = assert_ok!(
            lepton_orchestrator::testing::Scratch::new(tag),
            "the scratch directory should be creatable"
        );
        scratch
            .write("package.json", "{}\n")
            .map_err(|error| Failure {
                claim: "the package manifest should be writable".to_owned(),
                actual: format!("{error}"),
            })?;

        Ok(scratch)
    }

    /// The flags `lepton dev` runs with by default.
    fn default_flags() -> Flags {
        Flags {
            port: DEFAULT_PORT,
            native: false,
            no_server: false,
            print_plan: false,
            keep_open: false,
        }
    }

    #[test]
    fn the_server_starts_before_the_core() -> Result<(), Failure> {
        // The core asks the dev server for the bundle when it starts; a core that
        // started first would ask a server that is not listening yet, once.
        let root = webview_root("dev-order")?;

        let steps = default_flags().plan(root.path(), &complete(), false);

        assert_eq!(steps.len(), 2);
        ensure!(
            steps[0].args.iter().any(|arg| arg == "dev"),
            "the first step should be the server, got {:?}",
            steps[0].args
        );
        ensure!(
            steps[1].program == "zig" && steps[1].args.first().is_some_and(|arg| arg == "build"),
            "the second step should be the core, got {:?}",
            steps[1].args
        );
        Ok(())
    }

    #[test]
    fn the_core_is_told_the_port_it_should_load_from() -> Result<(), Failure> {
        // The port is the one thing the two processes share, so it appears in both
        // steps: a mismatch here is the classic "the window is blank" bug.
        let root = webview_root("dev-port")?;
        let flags = Flags {
            port: 4321,
            ..default_flags()
        };

        let steps = flags.plan(root.path(), &complete(), false);

        for step in &steps {
            ensure!(
                step.args.iter().any(|arg| arg.contains("4321")),
                "{:?} should carry the port",
                step.args
            );
        }
        Ok(())
    }

    #[test]
    fn pnpm_gets_the_flags_without_a_separator_and_npm_with_one() -> Result<(), Failure> {
        let root = webview_root("dev-separator")?;

        let pnpm = default_flags().plan(root.path(), &complete(), false);
        ensure!(
            !pnpm[0].args.iter().any(|arg| arg == "--"),
            "pnpm forwards a literal `--` and Vite then ignores every flag: {:?}",
            pnpm[0].args
        );

        let mut without_pnpm = complete();
        without_pnpm.package_manager.version = None;
        without_pnpm.package_manager.problem = Some(lepton_orchestrator::ToolProblem::NotFound);
        let npm = default_flags().plan(root.path(), &without_pnpm, false);
        assert_eq!(npm[0].program, "npm");
        assert_eq!(npm[0].args.get(2).map(String::as_str), Some("--"));
        Ok(())
    }

    #[test]
    fn the_server_listens_on_the_address_the_core_loads() -> Result<(), Failure> {
        // Measured: Vite bound `localhost`, which resolved to `[::1]` here, while the core
        // loaded `http://127.0.0.1:5173` and got "Connection refused". The address is
        // named on both sides so neither depends on how the machine resolves a name.
        let root = webview_root("dev-host")?;

        let steps = default_flags().plan(root.path(), &complete(), false);

        let server = steps[0].args.join(" ");
        assert_contains!(&server, "--host 127.0.0.1");
        assert_contains!(&steps[1].args.join(" "), "-Ddev-server=http://127.0.0.1:");
        Ok(())
    }

    #[test]
    fn the_default_port_is_the_one_the_ecosystem_already_uses() -> Result<(), Failure> {
        // 5173 is the port every Vite project starts on, so a developer's muscle
        // memory and the browser's bookmark both still work.
        assert_eq!(DEFAULT_PORT, 5173);
        Ok(())
    }

    #[test]
    fn a_native_project_starts_no_server() -> Result<(), Failure> {
        // There is no bundle to serve, so a dev server would be a process doing
        // nothing that the developer still has to remember to stop.
        let root = webview_root("dev-native")?;

        let steps = default_flags().plan(root.path(), &complete(), true);

        assert_eq!(steps.len(), 1);
        ensure!(
            steps[0].program == "zig",
            "the only step should be the core, got {:?}",
            steps[0].args
        );
        assert_contains!(&steps[0].args.join(" "), "-Drender=native");
        Ok(())
    }

    #[test]
    fn no_server_skips_the_bundler_even_for_a_webview_project() -> Result<(), Failure> {
        let root = webview_root("dev-no-server")?;
        let flags = Flags {
            no_server: true,
            ..default_flags()
        };

        let steps = flags.plan(root.path(), &complete(), false);

        assert_eq!(steps.len(), 1);
        // With no server of our own, the core is still told where the bundle is —
        // the developer's own server is at the same address.
        assert_contains!(&steps[0].args.join(" "), "5173");
        Ok(())
    }

    #[test]
    fn the_core_is_built_but_not_opened_by_zig() -> Result<(), Failure> {
        // `zig build run` opens the window, and the loop opens the installed binary
        // afterwards: running both showed the application twice, the second window
        // appearing when the developer closed the first.
        let root = webview_root("dev-once")?;

        for native in [true, false] {
            let steps = default_flags().plan(root.path(), &complete(), native);
            for step in steps.iter().filter(|step| step.program == "zig") {
                ensure!(
                    !step.args.iter().any(|arg| arg == "run"),
                    "the core step must not open the window itself: {:?}",
                    step.args
                );
            }
        }
        Ok(())
    }

    #[test]
    fn a_core_step_keeps_its_debug_info() -> Result<(), Failure> {
        // The core is the layer a developer is most likely to step through; a stripped
        // dev build turns a backtrace into a list of addresses.
        let root = webview_root("dev-debug")?;

        let steps = default_flags().plan(root.path(), &complete(), true);

        assert_contains!(&steps[0].args.join(" "), "-Doptimize=Debug");
        Ok(())
    }

    #[test]
    fn the_core_runs_from_the_core_directory() -> Result<(), Failure> {
        let root = webview_root("dev-cwd")?;

        let steps = default_flags().plan(root.path(), &complete(), true);

        assert_eq!(
            steps[0].cwd.as_deref(),
            Some(root.path().join(CORE_DIR).as_path())
        );
        Ok(())
    }

    #[test]
    fn no_server_cannot_be_asked_for_a_port_too() -> Result<(), Failure> {
        // Naming a port and refusing to start a server is a contradiction a
        // developer would not notice until nothing was listening. Parsed through the
        // binary's own surface so the test cannot drift from what ships.
        use clap::Parser as _;

        let refused =
            crate::Cli::try_parse_from(["lepton", "dev", "--no-server", "--port", "4321"]);
        ensure!(refused.is_err(), "--no-server --port must be refused");

        let accepted = crate::Cli::try_parse_from(["lepton", "dev", "--no-server"]);
        ensure!(accepted.is_ok(), "--no-server alone should parse");
        Ok(())
    }

    #[test]
    fn the_printed_loop_is_pasteable_into_a_shell() -> Result<(), Failure> {
        // What `lepton dev` prints is the thing a developer copies when something is
        // wrong and they want to run one half of it by hand.
        let root = webview_root("dev-display")?;

        let steps = default_flags().plan(root.path(), &complete(), false);
        let rendered: Vec<String> = steps.iter().map(display).collect();

        for line in rendered {
            ensure!(
                line.contains("zig") || line.contains("pnpm") || line.contains("npm"),
                "a printed line should name its program: {line}"
            );
            ensure!(!line.is_empty(), "no printed line should be empty");
        }
        Ok(())
    }
}
