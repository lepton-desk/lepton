/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

use std::path::Path;
use std::str::FromStr;

use servo_url::ServoUrl;
use url::Url;

#[test]
fn test_matches_about_blank_matches_simple_about_blank() {
    let mut url = ServoUrl::from_str("about:blank").unwrap();
    assert!(url.matches_about_blank());

    // Cannot set password.
    assert!(url.set_password(Some("Test")).is_err());
    assert!(url.matches_about_blank());

    // Cannot set username.
    assert!(url.set_username("user1").is_err());
    assert!(url.matches_about_blank());

    // Note: cannot set host, `set_host` not available on `ServoUrl`.
    assert!(url.host().is_none());
}

#[test]
fn test_matches_about_blank_doest_matches_fake_about_blank() {
    let url = ServoUrl::from_str("about:blank2").unwrap();
    assert!(!url.matches_about_blank());
}

#[test]
fn test_matches_about_blank_does_not_match() {
    let mut url = ServoUrl::from_str("ftp://user1:secret1@example.com").unwrap();
    assert!(!url.matches_about_blank());

    url.set_password(Some("Test")).unwrap();
    assert!(!url.matches_about_blank());

    url.set_username("user1").unwrap();
    assert!(!url.matches_about_blank());
}

#[test]
fn test_matches_about_blank_does_not_match_from_other_url() {
    let mut url = Url::parse("https://example.com").unwrap();

    // Cannot construct something passing off like about:blank from url.
    assert!(url.set_scheme("about").is_err());
    assert!(url.set_host(None).is_err());
    assert!(url.set_password(Some("Test")).is_ok());
    url.set_path("blank");

    let servo_url = ServoUrl::from_url(url);
    assert!(!servo_url.matches_about_blank());
}

#[test]
fn test_matches_about_blank_does_not_match_invariants_maintained_from_url() {
    // Invariants of about:blank maintained at the url level as well.
    let mut url = Url::parse("about:blank").unwrap();

    // Cannot set password.
    assert!(url.set_password(Some("Test")).is_err());

    // Cannot set username.
    assert!(url.set_username("user1").is_err());

    // Cannot set host.
    assert!(url.set_host(Some("rust-lang.org")).is_err());

    let servo_url = ServoUrl::from_url(url.clone());
    assert!(servo_url.matches_about_blank());

    // Can set path, but match will fail.
    url.set_path("test");
    let servo_url = ServoUrl::from_url(url);
    assert!(!servo_url.matches_about_blank());
}

#[test]
fn test_file_urls_are_potentially_trustworthy() {
    let path = Path::new(&env!("CARGO_MANIFEST_PATH"))
        .canonicalize()
        .unwrap();
    let url: ServoUrl = ServoUrl::from_file_path(path.clone()).unwrap();

    assert!(url.origin().is_potentially_trustworthy())
}

// Lepton: a registered scheme's URLs have a tuple origin, so its pages get storage.
#[test]
fn test_registered_scheme_has_tuple_origin() {
    let before = ServoUrl::parse("leptontest://localhost/index.html").unwrap();
    assert!(!before.origin().is_tuple());

    servo_url::register_tuple_origin_scheme("leptontest");
    let page = ServoUrl::parse("leptontest://localhost/index.html").unwrap();
    let asset = ServoUrl::parse("leptontest://localhost/assets/app.js").unwrap();
    assert!(page.origin().is_tuple());
    assert_eq!(page.origin(), asset.origin());
    assert_eq!(page.origin().ascii_serialization(), "leptontest://localhost");
    // The serialization parses back to the same origin (web storage keys by it).
    let reparsed = ServoUrl::parse(&page.origin().ascii_serialization()).unwrap();
    assert_eq!(reparsed.origin(), page.origin());

    // Another host is another origin; other schemes are unchanged.
    let other = ServoUrl::parse("leptontest://elsewhere/").unwrap();
    assert_ne!(other.origin(), page.origin());

    // A blob URL the page creates has the page's origin, the same each time it is asked.
    let blob = ServoUrl::parse("blob:leptontest://localhost/93947d57-a49f-4b00-bdcc-fbf1ed8b60ab").unwrap();
    assert_eq!(blob.origin(), page.origin());
    assert_eq!(blob.origin(), blob.origin());
    let elsewhere = ServoUrl::parse("blob:leptontest://elsewhere/93947d57-a49f-4b00-bdcc-fbf1ed8b60ab").unwrap();
    assert_ne!(elsewhere.origin(), page.origin());
    assert!(!ServoUrl::parse("blob:other://localhost/93947d57-a49f-4b00-bdcc-fbf1ed8b60ab").unwrap().origin().is_tuple());
    assert!(!ServoUrl::parse("other://localhost/").unwrap().origin().is_tuple());
    assert!(!ServoUrl::parse("leptontest:no-host").unwrap().origin().is_tuple());
    assert_eq!(
        ServoUrl::parse("https://example.com/").unwrap().origin().ascii_serialization(),
        "https://example.com"
    );
}
