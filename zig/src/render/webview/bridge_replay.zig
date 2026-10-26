//! A page replay's answers (`page_replay.zig`, `LEPTON_REPLAY_PAGE`): the bridge answers
//! the page's Nth call of a command with the recorded Nth, re-emits the events it emitted
//! and, for a deferred call, answers after the recorded delay.

const std = @import("std");
const invoke = @import("invoke.zig");
const page_replay = @import("page_replay.zig");
const record = @import("record.zig");
const respond = @import("respond.zig");
const wire = @import("../../ipc/wire.zig");
const engine = @import("request.zig");
const Bridge = @import("bridge.zig").Bridge;

/// A page replay's answer to `frame`, when the recording has one: the events the
/// command emitted, then the reply — now, or after the recorded delay for a deferred
/// call. False when the call runs live instead.
pub fn answerFromRecording(bridge: *Bridge, script: *page_replay.Script, request: ?*anyopaque, frame: []const u8) bool {
    const command = record.commandOf(frame) orelse return false;
    const header = wire.readHeader(frame) catch return false;
    const argument = page_replay.argumentOf(frame) orelse return false;
    const call = switch (script.decide(command, argument)) {
        .recorded => |call| call,
        .live => |why| {
            const name = bridge.registry.nameOf(command) orelse "unknown command";
            switch (why) {
                .other_argument => std.debug.print("page     {s}: another argument than recorded; run live\n", .{name}),
                .unrecorded => std.debug.print("page     {s}: called more often than recorded; run live\n", .{name}),
                .window, .masked => {},
            }
            return false;
        },
    };
    const owed = call.answer orelse return false;
    for (script.eventsOf(call)) |event| {
        const data = event.data orelse {
            std.debug.print("page     event {s} was recorded without its data; not sent\n", .{event.name});
            continue;
        };
        _ = bridge.emit(event.name, data) catch {};
    }
    bridge.invokes += 1;
    if (call.deferred and owed.delay_ns >= std.time.ns_per_ms and answerAfter(bridge, request, header.sequence, owed, bridge.registry.nameOf(command) orelse "unknown command")) return true;

    const raw = std.c.malloc(invoke.max_reply) orelse {
        respond.refuse(request, "no memory for the reply");
        return true;
    };
    const out: [*]u8 = @ptrCast(raw);
    const reply = invoke.reply(out[0..invoke.max_reply], header.sequence, owed.status, owed.result) catch {
        std.c.free(raw);
        respond.refuse(request, "the reply does not fit");
        return true;
    };
    if (respond.bytes(request, out, reply.len, std.c.free, "application/octet-stream", bridge.origin())) {
        bridge.counters.bytes_served += reply.len;
    }
    return true;
}

/// A recorded answer owed after a delay, as a timeout's data.
const Owed = struct {
    bridge: *Bridge,
    slot: u16,
    generation: u32,
    sequence: u64,
    answer: page_replay.Answer,
    name: []const u8,
    started: std.Io.Clock.Timestamp,

    fn fire(data: ?*anyopaque) callconv(.c) c_int {
        const owed: *Owed = @ptrCast(@alignCast(data orelse return 0));
        const io = std.Io.Threaded.global_single_threaded.io();
        const waited = owed.started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
        std.debug.print("page     {s}: the recorded answer after {d} ms (recorded {d} ms)\n", .{
            owed.name,
            @divTrunc(@max(waited, 0), std.time.ns_per_ms),
            owed.answer.delay_ns / std.time.ns_per_ms,
        });
        Bridge.finishLater(owed.bridge, owed.slot, owed.generation, owed.sequence, owed.answer.status, owed.answer.result);
        std.c.free(owed);
        return 0;
    }
};

/// Holds `request` in a free slot and answers it after `answer.delay_ns`; false when
/// no slot is free (the caller answers now).
fn answerAfter(bridge: *Bridge, request: ?*anyopaque, sequence: u64, recorded: page_replay.Answer, name: []const u8) bool {
    const index: u16 = for (bridge.later, 0..) |slot, at| {
        if (slot.request == null) break @intCast(at);
    } else return false;
    const raw = std.c.malloc(@sizeOf(Owed)) orelse return false;
    const owed: *Owed = @ptrCast(@alignCast(raw));
    owed.* = .{
        .bridge = bridge,
        .slot = index,
        .generation = bridge.later[index].generation,
        .sequence = sequence,
        .answer = recorded,
        .name = name,
        .started = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake),
    };
    bridge.later[index].request = engine.ref(request);
    const ms: c_uint = @intCast(@min(recorded.delay_ns / std.time.ns_per_ms, std.math.maxInt(c_uint)));
    engine.timeoutOnce(ms, &Owed.fire, owed);
    return true;
}
