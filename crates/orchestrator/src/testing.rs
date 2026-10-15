//! Assertions that report failure by returning it.
//!
//! Rust's built-in `assert!`, `unwrap` and `expect` all unwind on failure. That
//! is fine in a language with exceptions to catch and wrong in this one: a panic
//! here would be a control-flow mechanism, and Lepton's Rust side has no
//! unwinding paths at all — the release profile is built with `panic = "abort"`.
//! A test that panicked would therefore not be catchable, it would end the test
//! binary, and the harness would report a crash rather than the assertion that
//! actually failed.
//!
//! So the helpers here return the failure instead. Every test returns
//! `Result<(), Failure>`, which the harness reports as a failure carrying the
//! message, and the code under test keeps a single rule: every failure is a value.
//!
//! The macros exist for their messages. `ensure!(cond, "why")` reads better than
//! `if !cond { return Err(...) }` at a hundred call sites, and neither of them
//! unwinds. Each expands to a `return` on failure, so a test using one must
//! return `Result` — which every test here does.

use std::fmt::{self, Display};

/// A failed assertion, carrying enough context to act on without re-running.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    /// What was being claimed.
    pub claim: String,
    /// What was actually true.
    pub actual: String,
}

impl Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}\n  actual: {}", self.claim, self.actual)
    }
}

impl std::error::Error for Failure {}

/// Builds a failure.
///
/// Public because the macros expand at call sites in other modules, where a
/// private item of this one would not be reachable. It is not part of the crate's
/// intended surface; the macros are.
pub fn fail(claim: impl Display, actual: impl Display) -> Failure {
    Failure {
        claim: claim.to_string(),
        actual: actual.to_string(),
    }
}

/// Records a claim that must hold.
#[macro_export]
macro_rules! ensure {
    ($condition:expr, $($claim:tt)+) => {
        if !$condition {
            return ::std::result::Result::Err($crate::testing::fail(
                format!($($claim)+),
                format!("{:?}", $condition),
            ));
        }
    };
}

/// Asserts equality, naming both sides.
#[macro_export]
macro_rules! assert_eq {
    ($actual:expr, $expected:expr) => {
        if $actual != $expected {
            return ::std::result::Result::Err($crate::testing::fail(
                format!(
                    "expected {} to equal {}",
                    ::std::stringify!($actual),
                    ::std::stringify!($expected),
                ),
                format!("left: {:?}\n  right: {:?}", $actual, $expected),
            ));
        }
    };
}

/// Asserts inequality, naming both sides.
#[macro_export]
macro_rules! assert_ne {
    ($actual:expr, $forbidden:expr) => {
        if $actual == $forbidden {
            return ::std::result::Result::Err($crate::testing::fail(
                format!(
                    "expected {} not to equal {}",
                    ::std::stringify!($actual),
                    ::std::stringify!($forbidden),
                ),
                format!("both: {:?}", $actual),
            ));
        }
    };
}

/// Asserts that a `Result` is `Ok`, returning the value.
#[macro_export]
macro_rules! assert_ok {
    ($result:expr, $($claim:tt)+) => {
        match $result {
            ::std::result::Result::Ok(value) => value,
            ::std::result::Result::Err(error) => {
                return ::std::result::Result::Err($crate::testing::fail(
                    format!($($claim)+),
                    format!("{:?}", error),
                ));
            }
        }
    };
}

/// Asserts that a `Result` is `Err`, returning the error for further checks.
#[macro_export]
macro_rules! assert_err {
    ($result:expr, $($claim:tt)+) => {
        match $result {
            ::std::result::Result::Ok(value) => {
                return ::std::result::Result::Err($crate::testing::fail(
                    format!($($claim)+),
                    format!("Ok({:?})", value),
                ));
            }
            ::std::result::Result::Err(error) => error,
        }
    };
}

/// Asserts that a haystack contains a needle.
#[macro_export]
macro_rules! assert_contains {
    ($haystack:expr, $needle:expr) => {
        if !$haystack.contains($needle) {
            return ::std::result::Result::Err($crate::testing::fail(
                format!("expected text to contain {:?}", $needle),
                $haystack,
            ));
        }
    };
}

/// Asserts that a haystack does not contain a needle.
#[macro_export]
macro_rules! assert_absent {
    ($haystack:expr, $needle:expr) => {
        if $haystack.contains($needle) {
            return ::std::result::Result::Err($crate::testing::fail(
                format!("expected text not to contain {:?}", $needle),
                $haystack,
            ));
        }
    };
}

/// Reports whether a pair of delimiters balance.
///
/// A stylesheet or a generated file with unbalanced braces is a syntax error in
/// the first file a developer opens, so it earns a check of its own. Kept as a
/// function rather than a macro so a caller can hold the `Result` and decide what
/// to do with it — including converting it into a test's own return.
pub fn balanced(text: &str, open: char, close: char) -> Result<(), Failure> {
    let mut depth: i64 = 0;
    for character in text.chars() {
        if character == open {
            depth += 1;
        } else if character == close {
            depth -= 1;
            if depth < 0 {
                return Err(fail(
                    format!("{open}{close} should balance"),
                    format!("a closing {close} with nothing open"),
                ));
            }
        }
    }
    if depth != 0 {
        return Err(fail(
            format!("{open}{close} should balance"),
            format!("{depth} unclosed"),
        ));
    }
    Ok(())
}

/// A directory that removes itself when the guard is dropped.
///
/// A guard rather than a bare path so a failing assertion still cleans up: a
/// leftover directory would make the next run of this test pass for the wrong
/// reason, having found a file it did not write.
pub struct Scratch {
    path: std::path::PathBuf,
}

impl Scratch {
    /// Creates a directory named after this test's tag and the process id, so two
    /// runs — and two tests — cannot collide on it.
    pub fn new(tag: &str) -> Result<Self, Failure> {
        let path = std::env::temp_dir().join(format!("lepton-test-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path)
            .map_err(|error| fail(format!("a scratch directory at {}", path.display()), error))?;
        Ok(Self { path })
    }

    pub fn path(&self) -> &std::path::Path {
        &self.path
    }

    /// Reads a file inside the scratch directory.
    pub fn read(&self, relative: &str) -> Result<String, Failure> {
        std::fs::read_to_string(self.path.join(relative)).map_err(|error| {
            fail(
                format!("{} could be read", self.path.join(relative).display()),
                error,
            )
        })
    }

    /// Writes a file inside the scratch directory, creating parents.
    pub fn write(&self, relative: &str, contents: &str) -> Result<(), Failure> {
        let target = self.path.join(relative);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| fail(format!("{} could be created", parent.display()), error))?;
        }
        std::fs::write(&target, contents)
            .map_err(|error| fail(format!("{} could be written", target.display()), error))
    }

    /// Whether a path inside the directory exists.
    pub fn exists(&self, relative: &str) -> bool {
        self.path.join(relative).exists()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::{Failure, Scratch, balanced};

    #[test]
    fn a_passing_claim_returns_nothing() -> Result<(), Failure> {
        crate::ensure!(true, "a true claim holds");
        crate::assert_eq!(1 + 1, 2);
        crate::assert_eq!(assert_ok!(Ok::<u8, u8>(7), "seven is ok"), 7);
        crate::assert_contains!("lepton", "lept");
        assert_absent!("lepton", "electron");
        Ok(())
    }

    #[test]
    fn an_error_result_is_returned_rather_than_unwrapped() -> Result<(), Failure> {
        let error = assert_err!(Err::<u8, &str>("no"), "a string is an error");
        crate::assert_eq!(error, "no");
        Ok(())
    }

    #[test]
    fn balanced_delimiters_are_recognised_both_ways() -> Result<(), Failure> {
        balanced("a { b } c", '{', '}')?;
        balanced("()", '(', ')')?;
        // `balanced` returns a Result a caller can hold, which a macro could not do.
        let unclosed = balanced("a { b", '{', '}');
        crate::assert_err!(unclosed, "an unclosed brace is unbalanced");
        let stray = balanced("a } b", '{', '}');
        crate::assert_err!(stray, "a stray closing brace is unbalanced");
        Ok(())
    }

    #[test]
    fn a_failure_names_its_claim_and_its_actual() -> Result<(), Failure> {
        let failure = balanced("a { b", '{', '}').err().unwrap_or(Failure {
            claim: String::new(),
            actual: String::new(),
        });

        crate::assert_contains!(&failure.claim, "should balance");
        crate::assert_contains!(&failure.actual, "unclosed");
        Ok(())
    }

    #[test]
    fn a_scratch_directory_reads_back_what_it_wrote_and_then_removes_itself() -> Result<(), Failure>
    {
        let path = {
            let scratch = crate::assert_ok!(
                Scratch::new("self"),
                "the scratch directory should be creatable"
            );
            scratch.write("inner/file.txt", "contents")?;
            crate::assert_eq!(scratch.read("inner/file.txt")?, "contents");
            assert!(scratch.exists("inner/file.txt"));
            scratch.path().to_path_buf()
        };

        // After the guard drops the directory is gone: a leftover would make the
        // next run pass without having created anything.
        crate::assert_err!(
            std::fs::read_dir(&path),
            "the scratch directory should have been removed"
        );
        Ok(())
    }
}
