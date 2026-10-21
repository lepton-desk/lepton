//! Linked `@lepton-desk/*` packages whose build output is older than their source.
//!
//! A project developing against a local checkout links the package (`pnpm add
//! @lepton-desk/api@link:../lepton/packages/api`). Its `exports` point at `dist/`, so the
//! project sees the package as it was last built, not as it is: measured — a typo in an
//! event name passed `tsc` because `dist/` predated the typed `listen`, and was caught only
//! after a manual `pnpm run build`. So before the frontend is bundled, `lepton` finds each
//! linked package whose `src/` changed after its `dist/` was written and puts its `build`
//! into the plan, where `--print-plan` shows it.
//!
//! Only links: a package installed from the registry lives under `node_modules/` and has
//! no `src/` to compare, and is never rebuilt on its behalf.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

use lepton_orchestrator::{Step, Toolchain};

/// The scope whose linked packages are checked.
pub const SCOPE: &str = "@lepton-desk";
/// The tool name these steps carry in a plan.
pub const TOOL: &str = "linked";

/// Linked packages under `root/node_modules/@lepton-desk` whose `dist/` is stale.
pub fn stale(root: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(root.join("node_modules").join(SCOPE)) else {
        return Vec::new();
    };
    let mut found: Vec<PathBuf> = entries
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_symlink()))
        .filter_map(|entry| super::resolve(&entry.path()).ok())
        .filter(|target| is_linked_checkout(target) && needs_build(target))
        .collect();
    found.sort();
    found
}

/// The `build` steps for every stale linked package, run with `program` (`pnpm`/`npm`).
///
/// The package's directory is an argument (`pnpm --dir <path>`, `npm --prefix <path>`), not
/// only the working directory, so a printed plan says which package it builds rather than
/// showing a second, identical `pnpm run build`.
pub fn rebuild_steps(root: &Path, program: &str) -> Vec<Step> {
    stale(root)
        .into_iter()
        .map(|package| {
            // The package's own manager (its lockfile), `program` only when it has none:
            // a linked checkout is built the way its own repository builds it.
            let manager = super::package_manager::detect(&package, None, program == "pnpm").0;
            Step::new(TOOL, manager.program())
                .arg(manager.directory_flag())
                .arg(package.display().to_string())
                .args(["run", "build"])
                .in_dir(package)
        })
        .collect()
}

/// The package manager the project's own frontend steps use.
pub fn program(chain: &Toolchain) -> &'static str {
    if chain.package_manager.is_usable() && chain.package_manager.name == "pnpm" {
        "pnpm"
    } else {
        "npm"
    }
}

/// Puts the rebuilds at the front of `steps`, before anything bundles the frontend.
pub fn rebuild_first(steps: &mut Vec<Step>, root: &Path, chain: &Toolchain) {
    let rebuilds = rebuild_steps(root, program(chain));
    if !rebuilds.is_empty() {
        steps.splice(0..0, rebuilds);
    }
}

/// How often `lepton dev` looks at linked packages while the window is open.
pub const WATCH_INTERVAL: Duration = Duration::from_millis(500);

/// What one rebuild during `lepton dev` did.
#[derive(Debug)]
pub struct Rebuilt {
    pub package: PathBuf,
    pub took: Duration,
    pub succeeded: bool,
}

/// Rebuilds linked packages as their sources change, one pass at a time.
///
/// A failed build is not retried until the source changes again: a half-typed file must
/// not turn into a build every half second.
#[derive(Debug, Default)]
pub struct Watch {
    attempted: HashMap<PathBuf, SystemTime>,
}

impl Watch {
    /// One look: builds each stale package whose source changed since the last attempt.
    pub fn pass(&mut self, root: &Path, program: &str) -> Vec<Rebuilt> {
        let mut done = Vec::new();
        for step in rebuild_steps(root, program) {
            let Some(package) = step.cwd.clone() else {
                continue;
            };
            let Some(source) = newest(&package.join("src")) else {
                continue;
            };
            if self.attempted.get(&package) == Some(&source) {
                continue;
            }
            self.attempted.insert(package.clone(), source);
            let began = Instant::now();
            let succeeded = lepton_orchestrator::run_streaming(&step).is_ok();
            done.push(Rebuilt {
                package,
                took: began.elapsed(),
                succeeded,
            });
        }
        done
    }
}

/// The watcher `lepton dev` runs beside the window; stopped and joined when dropped.
pub struct Watcher {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Watcher {
    /// Starts watching the linked packages of the project at `root`.
    pub fn start(root: PathBuf, program: &'static str) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let seen = Arc::clone(&stop);
        let thread = std::thread::spawn(move || {
            let mut watch = Watch::default();
            while !seen.load(Ordering::Relaxed) {
                std::thread::sleep(WATCH_INTERVAL);
                for rebuilt in watch.pass(&root, program) {
                    let name = rebuilt
                        .package
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    if rebuilt.succeeded {
                        super::report::Report::new().fact(
                            "linked",
                            &format!(
                                "{SCOPE}/{name} rebuilt in {:.1} s",
                                rebuilt.took.as_secs_f64()
                            ),
                        );
                    } else {
                        super::report::Report::new().warn(
                            "linked",
                            &format!("{SCOPE}/{name} failed to build; waiting for the next edit"),
                        );
                    }
                }
            }
        });
        Self {
            stop,
            thread: Some(thread),
        }
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// A checkout, not an install: outside any `node_modules`, with a `build` script.
fn is_linked_checkout(target: &Path) -> bool {
    if target
        .components()
        .any(|part| part.as_os_str() == "node_modules")
    {
        return false;
    }
    std::fs::read_to_string(target.join("package.json"))
        .is_ok_and(|text| text.contains("\"build\""))
}

/// `dist/` is missing, or some file under `src/` is newer than the oldest file in it.
fn needs_build(package: &Path) -> bool {
    let Some(source) = newest(&package.join("src")) else {
        return false;
    };
    match oldest(&package.join("dist")) {
        Some(built) => source > built,
        None => true,
    }
}

fn newest(dir: &Path) -> Option<SystemTime> {
    times(dir).into_iter().max()
}

fn oldest(dir: &Path) -> Option<SystemTime> {
    times(dir).into_iter().min()
}

/// Modification times of every regular file below `dir`.
fn times(dir: &Path) -> Vec<SystemTime> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let Ok(meta) = std::fs::symlink_metadata(entry.path()) else {
            continue;
        };
        if meta.is_dir() {
            out.extend(times(&entry.path()));
        } else if meta.is_file()
            && let Ok(modified) = meta.modified()
        {
            out.push(modified);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{TOOL, rebuild_steps, stale};
    use lepton_orchestrator::testing::{Failure, Scratch, fail};
    use lepton_orchestrator::{assert_eq, ensure};
    use std::time::{Duration, SystemTime};

    /// Sets a file's modification time, so "older" and "newer" are exact.
    fn age(path: &std::path::Path, seconds_ago: u64) -> Result<(), Failure> {
        let file = std::fs::File::options()
            .write(true)
            .open(path)
            .map_err(|error| fail("open", error))?;
        file.set_modified(SystemTime::now() - Duration::from_secs(seconds_ago))
            .map_err(|error| fail("set_modified", error))
    }

    /// Links `at` to `target` the way pnpm's `link:` does: a symlink on Unix, a directory
    /// junction on Windows (no administrator needed, unlike a symlink there).
    fn link(target: &std::path::Path, at: &std::path::Path) -> Result<(), Failure> {
        #[cfg(unix)]
        let made = std::os::unix::fs::symlink(target, at).map_err(|error| fail("symlink", error));
        // `cmd` reads a `/` inside a path as a switch; rejoining the components gives `\`.
        #[cfg(windows)]
        let made = std::process::Command::new("cmd")
            .arg("/c")
            .arg("mklink")
            .arg("/J")
            .arg(at.components().collect::<std::path::PathBuf>())
            .arg(target.components().collect::<std::path::PathBuf>())
            .stdout(std::process::Stdio::null())
            .status()
            .map_err(|error| fail("mklink /J", error))
            .and_then(|status| {
                if status.success() {
                    Ok(())
                } else {
                    Err(fail("mklink /J", status))
                }
            });
        made
    }

    /// A project with `@lepton-desk/api` linked to a checkout beside it.
    fn linked(scratch: &Scratch, src_age: u64, dist_age: Option<u64>) -> Result<(), Failure> {
        scratch.write("api/package.json", r#"{"scripts":{"build":"tsc"}}"#)?;
        scratch.write("api/src/core.ts", "export {};\n")?;
        age(&scratch.path().join("api/src/core.ts"), src_age)?;
        if let Some(seconds) = dist_age {
            scratch.write("api/dist/core.js", "export {};\n")?;
            age(&scratch.path().join("api/dist/core.js"), seconds)?;
        }
        std::fs::create_dir_all(scratch.path().join("app/node_modules/@lepton-desk"))
            .map_err(|error| fail("mkdir", error))?;
        link(
            &scratch.path().join("api"),
            &scratch.path().join("app/node_modules/@lepton-desk/api"),
        )
    }

    #[test]
    fn source_newer_than_the_build_is_stale_and_gets_a_build_step() -> Result<(), Failure> {
        let scratch = Scratch::new("linked-stale")?;
        linked(&scratch, 10, Some(100))?;
        let app = scratch.path().join("app");
        assert_eq!(stale(&app).len(), 1);
        let steps = rebuild_steps(&app, "pnpm");
        ensure!(steps.len() == 1, "one step: {}", steps.len());
        ensure!(steps[0].tool == TOOL, "tool {}", steps[0].tool);
        ensure!(
            steps[0].args == ["--dir", &steps[0].args[1], "run", "build"],
            "`pnpm --dir <package> run build`: {:?}",
            steps[0].args
        );
        ensure!(
            steps[0].args[1].ends_with("api"),
            "names the package: {:?}",
            steps[0].args
        );
        ensure!(
            steps[0]
                .cwd
                .as_ref()
                .is_some_and(|dir| dir.ends_with("api")),
            "runs in the package: {:?}",
            steps[0].cwd
        );
        Ok(())
    }

    #[test]
    fn a_fresh_build_is_left_alone() -> Result<(), Failure> {
        let scratch = Scratch::new("linked-fresh")?;
        linked(&scratch, 100, Some(10))?;
        assert_eq!(stale(&scratch.path().join("app")).len(), 0);
        Ok(())
    }

    #[test]
    fn a_missing_dist_is_stale() -> Result<(), Failure> {
        let scratch = Scratch::new("linked-unbuilt")?;
        linked(&scratch, 10, None)?;
        assert_eq!(stale(&scratch.path().join("app")).len(), 1);
        Ok(())
    }

    #[test]
    fn an_installed_package_is_never_rebuilt() -> Result<(), Failure> {
        let scratch = Scratch::new("linked-installed")?;
        // pnpm's layout: the scope entry links into `node_modules/.pnpm/…`.
        let store = "app/node_modules/.pnpm/@lepton-desk+api@0.1.0/node_modules/@lepton-desk/api";
        scratch.write(
            &format!("{store}/package.json"),
            r#"{"scripts":{"build":"tsc"}}"#,
        )?;
        scratch.write(&format!("{store}/src/core.ts"), "export {};\n")?;
        std::fs::create_dir_all(scratch.path().join("app/node_modules/@lepton-desk"))
            .map_err(|error| fail("mkdir", error))?;
        link(
            &scratch.path().join(store),
            &scratch.path().join("app/node_modules/@lepton-desk/api"),
        )?;
        assert_eq!(stale(&scratch.path().join("app")).len(), 0);
        Ok(())
    }

    /// A linked package whose `build` is a real command: `node` copying `src` to `dist`,
    /// or exiting 1. Run through the real `pnpm`, as `lepton dev` would.
    fn buildable(scratch: &Scratch, script: &str) -> Result<(), Failure> {
        scratch.write(
            "api/package.json",
            &format!(r#"{{"name":"api","scripts":{{"build":{script:?}}}}}"#),
        )?;
        scratch.write("api/src/core.ts", "export {};\n")?;
        std::fs::create_dir_all(scratch.path().join("app/node_modules/@lepton-desk"))
            .map_err(|error| fail("mkdir", error))?;
        link(
            &scratch.path().join("api"),
            &scratch.path().join("app/node_modules/@lepton-desk/api"),
        )
    }

    fn has_pnpm() -> bool {
        std::process::Command::new(lepton_orchestrator::program::resolve("pnpm"))
            .arg("--version")
            .output()
            .is_ok_and(|out| out.status.success())
    }

    #[test]
    fn a_watch_pass_builds_a_changed_package_once() -> Result<(), Failure> {
        if !has_pnpm() {
            return Ok(());
        }
        let scratch = Scratch::new("linked-watch")?;
        buildable(
            &scratch,
            "node -e \"require('fs').mkdirSync('dist',{recursive:true});require('fs').copyFileSync('src/core.ts','dist/core.js')\"",
        )?;
        let app = scratch.path().join("app");
        let mut watch = super::Watch::default();
        let first = watch.pass(&app, "pnpm");
        ensure!(first.len() == 1 && first[0].succeeded, "built: {first:?}");
        ensure!(scratch.exists("api/dist/core.js"), "dist written");
        ensure!(watch.pass(&app, "pnpm").is_empty(), "nothing left to build");
        Ok(())
    }

    #[test]
    fn a_failing_build_waits_for_the_next_edit() -> Result<(), Failure> {
        if !has_pnpm() {
            return Ok(());
        }
        let scratch = Scratch::new("linked-watch-fail")?;
        buildable(&scratch, "node -e \"process.exit(1)\"")?;
        let app = scratch.path().join("app");
        let mut watch = super::Watch::default();
        let first = watch.pass(&app, "pnpm");
        ensure!(
            first.len() == 1 && !first[0].succeeded,
            "failed once: {first:?}"
        );
        ensure!(
            watch.pass(&app, "pnpm").is_empty(),
            "not retried without an edit"
        );
        age(&scratch.path().join("api/src/core.ts"), 0)?;
        std::thread::sleep(Duration::from_millis(20));
        scratch.write("api/src/core.ts", "export const edited = 1;\n")?;
        ensure!(
            watch.pass(&app, "pnpm").len() == 1,
            "retried after the edit"
        );
        Ok(())
    }

    #[test]
    fn a_project_without_the_scope_has_nothing_to_rebuild() -> Result<(), Failure> {
        let scratch = Scratch::new("linked-none")?;
        assert_eq!(stale(scratch.path()).len(), 0);
        Ok(())
    }
}
