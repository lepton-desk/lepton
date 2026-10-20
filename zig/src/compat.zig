//! What differs between Zig 0.16 and 0.17 in the language itself, in one place.
//!
//! Lepton builds with either. 0.17 describes a type's fields as parallel lists
//! (`field_names`, `field_types`, `field_values`) where 0.16 has one list of field structs
//! (`fields`); the version is told apart by which one `@typeInfo` has, and only the
//! matching branch is analysed.

const std = @import("std");

const parallel = @hasField(std.builtin.Type.Struct, "field_names");

/// An enum's field names, in declaration order.
pub fn enumNames(comptime T: type) []const [:0]const u8 {
    const info = @typeInfo(T).@"enum";
    return if (comptime parallel) info.field_names else comptime blk: {
        var names: [info.fields.len][:0]const u8 = undefined;
        for (info.fields, 0..) |field, index| names[index] = field.name;
        const final = names;
        break :blk &final;
    };
}

/// An enum's field values, in the same order as `enumNames`.
pub fn enumValues(comptime T: type) []const comptime_int {
    const info = @typeInfo(T).@"enum";
    return if (comptime parallel) info.field_values else comptime blk: {
        var values: [info.fields.len]comptime_int = undefined;
        for (info.fields, 0..) |field, index| values[index] = field.value;
        const final = values;
        break :blk &final;
    };
}

/// A struct's field types, in declaration order.
pub fn structTypes(comptime T: type) []const type {
    const info = @typeInfo(T).@"struct";
    return if (comptime parallel) info.field_types else comptime blk: {
        var types: [info.fields.len]type = undefined;
        for (info.fields, 0..) |field, index| types[index] = field.type;
        const final = types;
        break :blk &final;
    };
}

/// `T`'s value read from its bytes. 0.17 no longer lets `@bitCast` turn an array into an
/// extern struct; copying the bytes does the same in both.
pub fn fromBytes(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes);
    return value;
}

test "enum and struct fields read the same in both versions" {
    const Kind = enum(u8) { one = 1, two = 2 };
    try std.testing.expectEqualStrings("two", enumNames(Kind)[1]);
    try std.testing.expect(comptime enumValues(Kind)[1] == 2);
    const Pair = extern struct { a: u8, b: u16 };
    try std.testing.expect(comptime structTypes(Pair)[1] == u16);
    const read = fromBytes(Pair, &.{ 7, 0, 1, 2 });
    try std.testing.expectEqual(@as(u8, 7), read.a);
}
