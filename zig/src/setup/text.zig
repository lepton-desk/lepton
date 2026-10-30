//! What the window says, in English or Turkish by Windows' display language. `{p}` is the
//! product, `{v}` the version being installed, `{o}` the one installed, `{d}` a folder and
//! `{e}` Windows' own text for an error.

const std = @import("std");

pub const Language = enum { english, turkish };

pub const Id = enum {
    setup_title,
    uninstall_title,
    fresh,
    upgrade,
    same,
    newer,
    foreign,
    installing,
    installed,
    install_failed,
    in_use,
    damaged,
    uninstall_ask,
    remove_data,
    removing,
    removed,
    remove_failed,
    not_installed,
    install,
    update,
    reinstall,
    cancel,
    close,
    open,
    remove,
};

const english = [_][]const u8{
    "{p} Setup",
    "Uninstall {p}",
    "{p} {v} will be installed for you in {d}.",
    "{p} {o} will be updated to {v}.",
    "{p} {v} is already installed; it will be installed again.",
    "A newer version of {p} ({o}) is already installed.",
    "{d} already exists and was not installed by this setup.",
    "Installing {p}…",
    "{p} is installed.",
    "{p} could not be installed: {e}.",
    "{p} is running. Close it and try again.",
    "This setup file is damaged. Download it again.",
    "{p} {v} will be removed from this computer.",
    "Also delete its data and settings",
    "Removing {p}…",
    "{p} is removed.",
    "{p} could not be removed: {e}.",
    "Nothing installed was found beside this program.",
    "Install",
    "Update",
    "Reinstall",
    "Cancel",
    "Close",
    "Open",
    "Uninstall",
};

const turkish = [_][]const u8{
    "{p} Kurulumu",
    "{p} Kaldırma",
    "{p} {v}, {d} klasörüne sizin için kurulacak.",
    "{p} {o} sürümü {v} sürümüne güncellenecek.",
    "{p} {v} zaten kurulu; yeniden kurulacak.",
    "{p} uygulamasının daha yeni bir sürümü ({o}) zaten kurulu.",
    "{d} klasörü zaten var ve bu kurulumla kurulmamış.",
    "{p} kuruluyor…",
    "{p} kuruldu.",
    "{p} kurulamadı: {e}.",
    "{p} çalışıyor. Kapatıp yeniden deneyin.",
    "Bu kurulum dosyası bozuk. Yeniden indirin.",
    "{p} {v} bu bilgisayardan kaldırılacak.",
    "Verilerini ve ayarlarını da sil",
    "{p} kaldırılıyor…",
    "{p} kaldırıldı.",
    "{p} kaldırılamadı: {e}.",
    "Bu programın yanında kurulu bir uygulama bulunamadı.",
    "Kur",
    "Güncelle",
    "Yeniden kur",
    "İptal",
    "Kapat",
    "Aç",
    "Kaldır",
};

comptime {
    std.debug.assert(english.len == turkish.len);
}

pub fn get(language: Language, id: Id) []const u8 {
    return switch (language) {
        .english => english[@intFromEnum(id)],
        .turkish => turkish[@intFromEnum(id)],
    };
}

/// The values the placeholders take, each UTF-16.
pub const Values = struct {
    p: []const u16 = &.{},
    v: []const u16 = &.{},
    o: []const u16 = &.{},
    d: []const u16 = &.{},
    e: []const u16 = &.{},
};

/// `id`'s text with its placeholders filled, UTF-16 and NUL-terminated, into `out`;
/// cut short when it does not fit.
pub fn format(out: []u16, language: Language, id: Id, values: Values) [:0]const u16 {
    const template = get(language, id);
    var used: usize = 0;
    var at: usize = 0;
    while (at < template.len) {
        if (template[at] == '{' and at + 2 < template.len and template[at + 2] == '}') {
            const value = switch (template[at + 1]) {
                'p' => values.p,
                'v' => values.v,
                'o' => values.o,
                'd' => values.d,
                'e' => values.e,
                else => &[_]u16{},
            };
            const fits = @min(value.len, out.len - 1 - used);
            @memcpy(out[used..][0..fits], value[0..fits]);
            used += fits;
            at += 3;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(template[at]) catch 1;
        var units: [2]u16 = undefined;
        const count = std.unicode.utf8ToUtf16Le(&units, template[at..][0..len]) catch 0;
        if (used + count + 1 > out.len) break;
        @memcpy(out[used..][0..count], units[0..count]);
        used += count;
        at += len;
    }
    out[used] = 0;
    return out[0..used :0];
}

const W = std.unicode.utf8ToUtf16LeStringLiteral;

test "placeholders are filled and the rest is copied as UTF-16" {
    var out: [128]u16 = undefined;
    const text = format(&out, .turkish, .upgrade, .{ .p = W("Notlar"), .o = W("1.0.0"), .v = W("1.1.0") });
    try std.testing.expectEqualSlices(u16, W("Notlar 1.0.0 sürümü 1.1.0 sürümüne güncellenecek."), text);
    var short: [8]u16 = undefined;
    try std.testing.expectEqualSlices(u16, W("Install"), format(&short, .english, .installing, .{ .p = W("Notlar") }));
}

test "both languages have every text" {
    for (std.enums.values(Id)) |id| {
        try std.testing.expect(get(.english, id).len > 0);
        try std.testing.expect(get(.turkish, id).len > 0);
    }
    try std.testing.expectEqual(english.len, std.enums.values(Id).len);
}
