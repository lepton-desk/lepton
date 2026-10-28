//! `lepton icon` — every icon a package needs, from one square picture.
//!
//! As `tauri icon` does: the developer draws one SVG (or a PNG of at least 512 px) and the
//! CLI writes the sizes each system asks for into `src-lepton/icons/`:
//!
//! - `<n>x<n>.png` for 16 to 512 px: the Linux icon theme's `hicolor` sizes, for desktops
//!   and stores that read no SVG, and the AppImage's `.DirIcon` (256);
//! - `icon.ico` for Windows (the program, the installers), 16 to 256 px, each a PNG — the
//!   form Windows reads from Vista on, and the one this needs no second encoder for;
//! - `icon.svg`, the source itself when it is one, for `hicolor/scalable`.
//!
//! Drawn by `resvg` (pure Rust). The same source gives the same bytes, so packages built
//! from them stay reproducible. A large PNG is halved step by step before the last scale:
//! one bicubic jump from 1024 to 16 px samples a few pixels and aliases.

use std::path::{Path, PathBuf};

use resvg::{tiny_skia, usvg};

use super::build::CORE_DIR;
use super::report::{Report, shown};
use super::{CliError, Outcome};

/// The PNG sizes written, in pixels.
pub const PNG_SIZES: [u32; 8] = [16, 24, 32, 48, 64, 128, 256, 512];

/// The sizes in `icon.ico`: Windows reads up to 256.
pub const ICO_SIZES: [u32; 6] = [16, 24, 32, 48, 64, 256];

/// Where the icons go, under `src-lepton/`.
pub const ICONS_DIR: &str = "icons";

/// The smallest PNG source: the largest size written, so nothing is drawn larger than it
/// was given.
const SMALLEST_PNG: u32 = 512;

/// Flags for `lepton icon`.
#[derive(Debug, Clone, Default, clap::Args)]
pub struct Flags {
    /// A square SVG, or a square PNG of at least 512 px. Default: src-lepton/icon.svg.
    #[arg(value_name = "SOURCE")]
    pub source: Option<PathBuf>,

    /// The directory to write them to. Default: src-lepton/icons.
    #[arg(long, value_name = "DIR")]
    pub out: Option<PathBuf>,
}

impl Flags {
    pub fn run(self) -> Outcome {
        let root = std::env::current_dir().map_err(|error| {
            CliError::Invalid(format!("could not read the working directory: {error}"))
        })?;
        let source = match self.source {
            Some(path) => root.join(path),
            None => root.join(CORE_DIR).join("icon.svg"),
        };
        let out = match self.out {
            Some(path) => root.join(path),
            None => root.join(CORE_DIR).join(ICONS_DIR),
        };
        let report = Report::new();
        report.header("icon");
        let written = write_icons(&source, &out)?;
        report.fact("source", &shown(&source));
        report.fact("icons", &format!("{}  {}", shown(&out), written.join(" ")));
        Ok(())
    }
}

/// The source, read once and drawn at each size.
enum Picture {
    Svg { tree: Box<usvg::Tree>, text: String },
    Png(tiny_skia::Pixmap),
}

fn read(source: &Path) -> Result<Picture, CliError> {
    let bytes = std::fs::read(source).map_err(|error| {
        CliError::Invalid(format!("could not read {}: {error}", source.display()))
    })?;
    let is_svg = source
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("svg"));
    if is_svg {
        let text = String::from_utf8(bytes)
            .map_err(|_| CliError::Invalid(format!("{} is not UTF-8 text", source.display())))?;
        return svg(text, &source.display().to_string());
    }
    let pixmap = tiny_skia::Pixmap::decode_png(&bytes).map_err(|error| {
        CliError::Invalid(format!(
            "{} is neither an SVG nor a PNG: {error}",
            source.display()
        ))
    })?;
    if pixmap.width() != pixmap.height() || pixmap.width() < SMALLEST_PNG {
        return Err(CliError::Invalid(format!(
            "{} is {}×{} px; a PNG icon must be square and at least {SMALLEST_PNG} px (or give an SVG)",
            source.display(),
            pixmap.width(),
            pixmap.height()
        )));
    }
    Ok(Picture::Png(pixmap))
}

/// An SVG's text as a picture; `origin` names it in an error.
fn svg(text: String, origin: &str) -> Result<Picture, CliError> {
    // System fonts: an icon with lettering draws it as a browser would, rather than
    // leaving the text out without a word.
    let mut options = usvg::Options::default();
    options.fontdb_mut().load_system_fonts();
    let tree = usvg::Tree::from_str(&text, &options).map_err(|error| {
        CliError::Invalid(format!("{origin} is not an SVG resvg can draw: {error}"))
    })?;
    let size = tree.size();
    if (size.width() - size.height()).abs() > 0.5 {
        return Err(CliError::Invalid(format!(
            "{origin} is {}×{}; an icon must be square",
            size.width(),
            size.height()
        )));
    }
    Ok(Picture::Svg {
        tree: Box::new(tree),
        text,
    })
}

/// The PNG icons a Linux package installs under `hicolor/<n>x<n>/apps`, by size: those
/// `lepton icon` wrote into `src-lepton/icons/` when the project has them (all of them:
/// a partial set is a stale one), else drawn here from `svg`, the project's icon.
pub fn hicolor_pngs(root: &Path, svg_text: &str) -> Result<Vec<(u32, Vec<u8>)>, CliError> {
    let dir = root.join(CORE_DIR).join(ICONS_DIR);
    if dir.is_dir() {
        let mut found = Vec::new();
        for size in PNG_SIZES {
            let path = dir.join(format!("{size}x{size}.png"));
            let bytes = std::fs::read(&path).map_err(|error| {
                CliError::Invalid(format!(
                    "{} is missing ({error}); run `lepton icon` again",
                    path.display()
                ))
            })?;
            found.push((size, bytes));
        }
        return Ok(found);
    }
    let picture = svg(svg_text.to_owned(), "the project's icon")?;
    PNG_SIZES
        .iter()
        .map(|size| Ok((*size, draw(&picture, *size)?)))
        .collect()
}

/// The Windows icon when `bundle.icon` names none: `src-lepton/icons/icon.ico` if
/// `lepton icon` wrote one, else `None` (Lepton's mark).
pub fn project_ico(root: &Path) -> Option<PathBuf> {
    let path = root.join(CORE_DIR).join(ICONS_DIR).join("icon.ico");
    path.is_file().then_some(path)
}

/// `picture` as a `size`×`size` PNG.
fn draw(picture: &Picture, size: u32) -> Result<Vec<u8>, CliError> {
    let pixmap = match picture {
        Picture::Svg { tree, .. } => {
            let mut pixmap = blank(size)?;
            let given = tree.size();
            let transform = tiny_skia::Transform::from_scale(
                size as f32 / given.width(),
                size as f32 / given.height(),
            );
            resvg::render(tree, transform, &mut pixmap.as_mut());
            pixmap
        }
        Picture::Png(source) => {
            let mut current = source.clone();
            while current.width() / 2 >= size {
                current = scaled(&current, current.width() / 2)?;
            }
            if current.width() == size {
                current
            } else {
                scaled(&current, size)?
            }
        }
    };
    pixmap
        .encode_png()
        .map_err(|error| CliError::Invalid(format!("could not encode a {size} px icon: {error}")))
}

fn blank(size: u32) -> Result<tiny_skia::Pixmap, CliError> {
    tiny_skia::Pixmap::new(size, size)
        .ok_or_else(|| CliError::Invalid(format!("could not make a {size} px picture")))
}

fn scaled(source: &tiny_skia::Pixmap, size: u32) -> Result<tiny_skia::Pixmap, CliError> {
    let mut pixmap = blank(size)?;
    let factor = size as f32 / source.width() as f32;
    let paint = tiny_skia::PixmapPaint {
        quality: tiny_skia::FilterQuality::Bicubic,
        ..tiny_skia::PixmapPaint::default()
    };
    pixmap.draw_pixmap(
        0,
        0,
        source.as_ref(),
        &paint,
        tiny_skia::Transform::from_scale(factor, factor),
        None,
    );
    Ok(pixmap)
}

/// An `.ico` of PNG images: `ICONDIR`, one 16-byte `ICONDIRENTRY` each, then the PNGs.
/// Width and height 0 mean 256.
pub fn ico(images: &[(u32, Vec<u8>)]) -> Result<Vec<u8>, CliError> {
    let count = u16::try_from(images.len())
        .map_err(|_| CliError::Invalid("too many images for one .ico".to_owned()))?;
    let mut out = Vec::new();
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&count.to_le_bytes());
    let mut offset = 6 + 16 * images.len();
    for (size, png) in images {
        let side = if *size >= 256 { 0 } else { *size as u8 };
        let length = u32::try_from(png.len())
            .map_err(|_| CliError::Invalid(format!("the {size} px image is too large")))?;
        let at = u32::try_from(offset)
            .map_err(|_| CliError::Invalid("the .ico is too large".to_owned()))?;
        out.extend_from_slice(&[side, side, 0, 0]);
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&32u16.to_le_bytes());
        out.extend_from_slice(&length.to_le_bytes());
        out.extend_from_slice(&at.to_le_bytes());
        offset += png.len();
    }
    for (_, png) in images {
        out.extend_from_slice(png);
    }
    Ok(out)
}

/// Writes every icon of `source` into `out` and returns the file names, in order.
pub fn write_icons(source: &Path, out: &Path) -> Result<Vec<String>, CliError> {
    let picture = read(source)?;
    std::fs::create_dir_all(out).map_err(|error| {
        CliError::Invalid(format!("could not create {}: {error}", out.display()))
    })?;
    let write = |name: &str, bytes: &[u8]| -> Result<String, CliError> {
        let path = out.join(name);
        std::fs::write(&path, bytes).map_err(|error| {
            CliError::Invalid(format!("could not write {}: {error}", path.display()))
        })?;
        Ok(name.to_owned())
    };

    let mut written = Vec::new();
    let mut pngs = Vec::new();
    for size in PNG_SIZES {
        let png = draw(&picture, size)?;
        written.push(write(&format!("{size}x{size}.png"), &png)?);
        pngs.push((size, png));
    }
    let mut images = Vec::new();
    for size in ICO_SIZES {
        let png = match pngs.iter().find(|(drawn, _)| *drawn == size) {
            Some((_, png)) => png.clone(),
            None => draw(&picture, size)?,
        };
        images.push((size, png));
    }
    written.push(write("icon.ico", &ico(&images)?)?);
    if let Picture::Svg { text, .. } = &picture {
        written.push(write("icon.svg", text.as_bytes())?);
    }
    Ok(written)
}

#[cfg(test)]
mod tests {
    use super::{ICO_SIZES, PNG_SIZES, write_icons};
    use crate::commands::desktop_entry::DEFAULT_SVG;
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_eq, assert_ok, ensure};

    const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];

    /// Width and height from a PNG's `IHDR`.
    fn png_size(bytes: &[u8]) -> Option<(u32, u32)> {
        if bytes.get(..8)? != PNG_SIGNATURE || bytes.get(12..16)? != b"IHDR" {
            return None;
        }
        let width = u32::from_be_bytes(bytes.get(16..20)?.try_into().ok()?);
        let height = u32::from_be_bytes(bytes.get(20..24)?.try_into().ok()?);
        Some((width, height))
    }

    #[test]
    fn an_svg_gives_every_png_the_ico_and_itself() -> Result<(), Failure> {
        let scratch = Scratch::new("icon-svg")?;
        scratch.write("icon.svg", DEFAULT_SVG)?;
        let out = scratch.path().join("icons");
        let written = assert_ok!(write_icons(&scratch.path().join("icon.svg"), &out), "icons");
        assert_eq!(written.len(), PNG_SIZES.len() + 2);
        for size in PNG_SIZES {
            let bytes = assert_ok!(std::fs::read(out.join(format!("{size}x{size}.png"))), "png");
            assert_eq!(png_size(&bytes), Some((size, size)));
        }
        let svg = assert_ok!(std::fs::read_to_string(out.join("icon.svg")), "svg");
        assert_eq!(svg, DEFAULT_SVG);

        let ico = assert_ok!(std::fs::read(out.join("icon.ico")), "ico");
        assert_eq!(
            ico.get(..6),
            Some(&[0u8, 0, 1, 0, ICO_SIZES.len() as u8, 0][..])
        );
        for (index, size) in ICO_SIZES.iter().enumerate() {
            let entry = assert_ok!(
                ico.get(6 + 16 * index..6 + 16 * (index + 1))
                    .ok_or("no entry"),
                "entry"
            );
            let side = if *size >= 256 { 0 } else { *size as u8 };
            assert_eq!(entry.first(), Some(&side));
            let field = |at: usize| -> Option<usize> {
                Some(u32::from_le_bytes(entry.get(at..at + 4)?.try_into().ok()?) as usize)
            };
            let length = assert_ok!(field(8).ok_or("no length"), "length");
            let offset = assert_ok!(field(12).ok_or("no offset"), "offset");
            let image = assert_ok!(
                ico.get(offset..offset + length)
                    .ok_or("the entry points past the file"),
                "entry"
            );
            assert_eq!(png_size(image), Some((*size, *size)));
        }
        Ok(())
    }

    #[test]
    fn the_same_source_gives_the_same_bytes() -> Result<(), Failure> {
        let scratch = Scratch::new("icon-same")?;
        scratch.write("icon.svg", DEFAULT_SVG)?;
        let source = scratch.path().join("icon.svg");
        assert_ok!(write_icons(&source, &scratch.path().join("a")), "first");
        assert_ok!(write_icons(&source, &scratch.path().join("b")), "second");
        for name in ["16x16.png", "512x512.png", "icon.ico"] {
            let a = assert_ok!(std::fs::read(scratch.path().join("a").join(name)), "a");
            let b = assert_ok!(std::fs::read(scratch.path().join("b").join(name)), "b");
            ensure!(a == b, "{name} differs between two runs");
        }
        Ok(())
    }

    #[test]
    fn a_png_source_is_scaled_and_a_small_or_oblong_one_refused() -> Result<(), Failure> {
        let scratch = Scratch::new("icon-png")?;
        scratch.write("icon.svg", DEFAULT_SVG)?;
        let drawn = scratch.path().join("drawn");
        assert_ok!(
            write_icons(&scratch.path().join("icon.svg"), &drawn),
            "from svg"
        );

        // The 512 px PNG drawn above is a valid source in turn: no 1024 px PNG needed.
        let out = scratch.path().join("from-png");
        let written = assert_ok!(write_icons(&drawn.join("512x512.png"), &out), "from png");
        assert_eq!(written.len(), PNG_SIZES.len() + 1);
        let small = assert_ok!(std::fs::read(out.join("16x16.png")), "16");
        assert_eq!(png_size(&small), Some((16, 16)));

        let refused = write_icons(&drawn.join("256x256.png"), &scratch.path().join("no"));
        ensure!(refused.is_err(), "a 256 px PNG is refused");

        scratch.write(
            "wide.svg",
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"/>"#,
        )?;
        let oblong = write_icons(&scratch.path().join("wide.svg"), &scratch.path().join("no"));
        ensure!(oblong.is_err(), "an oblong SVG is refused");
        Ok(())
    }
}
