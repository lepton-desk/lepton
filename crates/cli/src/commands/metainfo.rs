//! The AppStream metainfo file a Linux package carries: `share/metainfo/<id>.metainfo.xml`.
//!
//! What GNOME Software, KDE Discover and Flathub read to show an application before it is
//! installed. A `desktop-application` component must have `id`, `name`, `summary`,
//! `description`, `metadata_license` and a `launchable` (AppStream's specification,
//! "Desktop Applications"); this writes those, and `project_license`, the homepage, the
//! developer, the binary it provides and the release when the configuration gives them.
//!
//! Nothing is invented: the summary is `bundle.description` (else `productName`), the
//! description `bundle.longDescription` (else the summary), one paragraph per blank-line
//! block, as AppStream allows no other markup here. The developer is `bundle.maintainer`'s
//! name under the identifier's owner (`com.<owner>`). The release is dated by
//! `SOURCE_DATE_EPOCH`, else `bundle.releaseDate`; with neither there is no `<releases>`,
//! since AppStream refuses an undated release (`release-time-missing`, measured). The
//! content rating is `bundle.contentRating`'s OARS 1.1 answers; without them it is empty,
//! which AppStream reads as "no age restrictions".

use lepton_template_injector::Details;

/// The licence of the metainfo file itself when `bundle.metadataLicense` names none:
/// public domain, as most GNOME and KDE applications give theirs.
pub const DEFAULT_METADATA_LICENSE: &str = "CC0-1.0";

/// What the file says about one application.
pub struct Component<'a> {
    pub app_id: &'a str,
    pub product: &'a str,
    pub binary: &'a str,
    pub version: &'a str,
    pub details: &'a Details,
    /// `bundle.maintainer` (`Name <email>`); only the name is written.
    pub maintainer: Option<&'a str>,
    /// Seconds since the epoch (`SOURCE_DATE_EPOCH`), 0 for none.
    pub released: u64,
}

/// Below this many characters the description's first paragraph is short for a software
/// centre (`appstreamcli validate`: `description-first-para-too-short`, < 80).
pub const SHORTEST_FIRST_PARAGRAPH: usize = 80;

/// The description's first paragraph's length when it is under
/// [`SHORTEST_FIRST_PARAGRAPH`] characters, for `lepton package` to warn about.
pub fn short_first_paragraph(component: &Component<'_>) -> Option<usize> {
    let length = paragraphs(description(component))
        .first()
        .map_or(0, |paragraph| paragraph.chars().count());
    (length < SHORTEST_FIRST_PARAGRAPH).then_some(length)
}

/// The release's day: `SOURCE_DATE_EPOCH`'s, else `bundle.releaseDate`, else none (and no
/// `<releases>`; `lepton package` warns).
pub fn release_date(component: &Component<'_>) -> Option<String> {
    date(component.released).or_else(|| component.details.release_date.clone())
}

fn summary<'a>(component: &Component<'a>) -> &'a str {
    component
        .details
        .description
        .as_deref()
        .unwrap_or(component.product)
}

fn description<'a>(component: &Component<'a>) -> &'a str {
    component
        .details
        .long_description
        .as_deref()
        .unwrap_or_else(|| summary(component))
}

/// The file's name under `share/metainfo/`.
pub fn file_name(app_id: &str) -> String {
    format!("{app_id}.metainfo.xml")
}

/// The metainfo XML.
pub fn text(component: &Component<'_>) -> String {
    let details = component.details;
    let summary = summary(component);
    let long = description(component);
    let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push_str("<component type=\"desktop-application\">\n");
    line(&mut out, "id", component.app_id);
    line(
        &mut out,
        "metadata_license",
        details
            .metadata_license
            .as_deref()
            .unwrap_or(DEFAULT_METADATA_LICENSE),
    );
    if let Some(license) = &details.license {
        line(&mut out, "project_license", license);
    }
    line(&mut out, "name", component.product);
    line(&mut out, "summary", summary);
    out.push_str("  <description>\n");
    for paragraph in paragraphs(long) {
        out.push_str(&format!("    <p>{}</p>\n", escape(&paragraph)));
    }
    out.push_str("  </description>\n");
    out.push_str(&format!(
        "  <launchable type=\"desktop-id\">{}.desktop</launchable>\n",
        escape(component.app_id)
    ));
    if let Some(homepage) = &details.homepage {
        out.push_str(&format!(
            "  <url type=\"homepage\">{}</url>\n",
            escape(homepage)
        ));
    }
    if let (Some(owner), Some(name)) = (
        owner(component.app_id),
        component.maintainer.and_then(maintainer_name),
    ) {
        out.push_str(&format!(
            "  <developer id=\"{}\">\n    <name>{}</name>\n  </developer>\n",
            escape(owner),
            escape(name)
        ));
    }
    out.push_str(&format!(
        "  <provides>\n    <binary>{}</binary>\n  </provides>\n",
        escape(component.binary)
    ));
    if let Some(day) = release_date(component) {
        out.push_str(&format!(
            "  <releases>\n    <release version=\"{}\" date=\"{day}\"/>\n  </releases>\n",
            escape(component.version)
        ));
    }
    if details.content_rating.is_empty() {
        out.push_str("  <content_rating type=\"oars-1.1\"/>\n");
    } else {
        out.push_str("  <content_rating type=\"oars-1.1\">\n");
        for (id, value) in &details.content_rating {
            out.push_str(&format!(
                "    <content_attribute id=\"{}\">{}</content_attribute>\n",
                escape(id),
                escape(value)
            ));
        }
        out.push_str("  </content_rating>\n");
    }
    out.push_str("</component>\n");
    out
}

fn line(out: &mut String, tag: &str, value: &str) {
    out.push_str(&format!("  <{tag}>{}</{tag}>\n", escape(value)));
}

/// Blank-line separated blocks, each joined onto one line.
fn paragraphs(text: &str) -> Vec<String> {
    text.split("\n\n")
        .map(|block| block.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|block| !block.is_empty())
        .collect()
}

/// `com.example` of `com.example.notes`: who publishes it, in reverse DNS.
fn owner(app_id: &str) -> Option<&str> {
    app_id
        .rsplit_once('.')
        .map(|(owner, _)| owner)
        .filter(|owner| owner.contains('.'))
}

/// `Ada Lovelace` of `Ada Lovelace <ada@example.org>`: AppStream allows no address in it.
fn maintainer_name(maintainer: &str) -> Option<&str> {
    let name = maintainer.split('<').next().unwrap_or(maintainer).trim();
    (!name.is_empty()).then_some(name)
}

/// `YYYY-MM-DD` (UTC) of `seconds`, or `None` for 0 (no `SOURCE_DATE_EPOCH`).
fn date(seconds: u64) -> Option<String> {
    if seconds == 0 {
        return None;
    }
    // Howard Hinnant's `civil_from_days`.
    let days = i64::try_from(seconds / 86_400).ok()? + 719_468;
    let era = days.div_euclid(146_097);
    let of_era = days.rem_euclid(146_097);
    let year_of_era = (of_era - of_era / 1460 + of_era / 36_524 - of_era / 146_096) / 365;
    let day_of_year = of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted + 2) / 5 + 1;
    let month = if shifted < 10 {
        shifted + 3
    } else {
        shifted - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    Some(format!("{year:04}-{month:02}-{day:02}"))
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use super::{Component, date, release_date, short_first_paragraph, text};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, ensure};
    use lepton_template_injector::Details;

    fn component<'a>(
        details: &'a Details,
        maintainer: Option<&'a str>,
        released: u64,
    ) -> Component<'a> {
        Component {
            app_id: "com.example.notes",
            product: "Notes & Co",
            binary: "notes",
            version: "1.2.0-beta.1",
            details,
            maintainer,
            released,
        }
    }

    #[test]
    fn the_required_tags_are_there_with_nothing_configured() -> Result<(), Failure> {
        let details = Details::default();
        let xml = text(&component(&details, None, 0));
        assert_contains!(&xml, "<component type=\"desktop-application\">\n");
        assert_contains!(&xml, "  <id>com.example.notes</id>\n");
        assert_contains!(&xml, "  <metadata_license>CC0-1.0</metadata_license>\n");
        assert_contains!(&xml, "  <name>Notes &amp; Co</name>\n");
        // No description: the summary is the name, and the description that summary.
        assert_contains!(&xml, "  <summary>Notes &amp; Co</summary>\n");
        assert_contains!(
            &xml,
            "  <description>\n    <p>Notes &amp; Co</p>\n  </description>\n"
        );
        assert_contains!(
            &xml,
            "<launchable type=\"desktop-id\">com.example.notes.desktop</launchable>"
        );
        assert_contains!(
            &xml,
            "<provides>\n    <binary>notes</binary>\n  </provides>"
        );
        // No date to give it: no release, which AppStream accepts (an undated one it refuses).
        ensure!(!xml.contains("<releases>"), "an undated release");
        // No answers: an empty rating, AppStream's "no age restrictions".
        assert_contains!(&xml, "  <content_rating type=\"oars-1.1\"/>\n");
        for absent in ["project_license", "<url", "<developer"] {
            ensure!(
                !xml.contains(absent),
                "{absent} written without a value for it"
            );
        }
        Ok(())
    }

    #[test]
    fn everything_configured_reaches_it() -> Result<(), Failure> {
        let details = Details {
            description: Some("Take notes, offline".to_owned()),
            long_description: Some("Notes keeps them <here>.\n\nNo account,\nno sync.".to_owned()),
            license: Some("MIT OR Apache-2.0".to_owned()),
            homepage: Some("https://example.com/notes?a=1&b=2".to_owned()),
            metadata_license: Some("FSFAP".to_owned()),
            content_rating: vec![
                ("money-purchasing".to_owned(), "mild".to_owned()),
                ("social-chat".to_owned(), "intense".to_owned()),
            ],
            ..Details::default()
        };
        let xml = text(&component(
            &details,
            Some("Ada Lovelace <ada@example.org>"),
            1_793_145_600,
        ));
        assert_contains!(&xml, "<metadata_license>FSFAP</metadata_license>");
        assert_contains!(&xml, "<project_license>MIT OR Apache-2.0</project_license>");
        assert_contains!(&xml, "<summary>Take notes, offline</summary>");
        assert_contains!(
            &xml,
            "    <p>Notes keeps them &lt;here&gt;.</p>\n    <p>No account, no sync.</p>\n"
        );
        assert_contains!(
            &xml,
            "<url type=\"homepage\">https://example.com/notes?a=1&amp;b=2</url>"
        );
        assert_contains!(
            &xml,
            "<developer id=\"com.example\">\n    <name>Ada Lovelace</name>\n  </developer>"
        );
        assert_contains!(
            &xml,
            "<release version=\"1.2.0-beta.1\" date=\"2026-10-28\"/>"
        );
        assert_contains!(
            &xml,
            "  <content_rating type=\"oars-1.1\">\n    <content_attribute id=\"money-purchasing\">mild</content_attribute>\n    <content_attribute id=\"social-chat\">intense</content_attribute>\n  </content_rating>\n"
        );
        Ok(())
    }

    #[test]
    fn the_release_is_dated_by_source_date_epoch_then_the_configuration() -> Result<(), Failure> {
        let dated = Details {
            release_date: Some("2026-01-02".to_owned()),
            ..Details::default()
        };
        assert_eq!(
            release_date(&component(&dated, None, 0)).as_deref(),
            Some("2026-01-02")
        );
        assert_eq!(
            release_date(&component(&dated, None, 1_793_145_600)).as_deref(),
            Some("2026-10-28")
        );
        assert_contains!(
            &text(&component(&dated, None, 0)),
            "  <releases>\n    <release version=\"1.2.0-beta.1\" date=\"2026-01-02\"/>\n  </releases>\n"
        );
        Ok(())
    }

    #[test]
    fn a_short_first_paragraph_is_reported() -> Result<(), Failure> {
        let short = Details::default();
        assert_eq!(short_first_paragraph(&component(&short, None, 0)), Some(10));
        let long = Details {
            long_description: Some(format!("{}\n\nshort", "x".repeat(80))),
            ..Details::default()
        };
        assert_eq!(
            short_first_paragraph(&component(&long, None, 0)),
            None::<usize>
        );
        Ok(())
    }

    #[test]
    fn epoch_seconds_become_the_utc_day() -> Result<(), Failure> {
        assert_eq!(date(0), None::<String>);
        assert_eq!(date(1).as_deref(), Some("1970-01-01"));
        assert_eq!(date(951_782_400).as_deref(), Some("2000-02-29"));
        assert_eq!(date(1_793_231_999).as_deref(), Some("2026-10-28"));
        Ok(())
    }
}
