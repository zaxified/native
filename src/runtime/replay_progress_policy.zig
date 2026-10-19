//! Copied replay progress plans. Storage, source reads, rendering and OS calls
//! remain native; portable comparisons receive exact words and raw labels.
const std = @import("std");
const platform = @import("../platform/root.zig");
comptime {
    if (platform.max_windows != 16 or platform.max_views != 32 or platform.max_view_label_bytes != 64 or
        @intFromEnum(platform.ViewKind.gpu_surface) != 17 or typeFields(@typeInfo(platform.ViewKind).@"enum").len != 19)
        @compileError("update the portable replay target schema with the platform bounds");
}
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { count, compare, blob_admission, blob_result, finish, window, view };
pub const Action = enum(u8) { proceed, missing, over_budget, corrupt, divergence };
pub const Slot = struct { open: bool, kind: platform.ViewKind = .webview, id: u64, label: []const u8 = "" };
pub const Facts = struct {
    code: u8 = 0,
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
    d: u64 = 0,
    label: []const u8 = "",
    slots: []const Slot = &.{},
};
pub const Plan = struct {
    action: Action = .proceed,
    mismatch: bool = false,
    mismatch_slot: ?usize = null,
    index: ?usize = null,
    counter: u64 = 0,
    mismatch_count: u64 = 0,
};
pub fn plan(policy: Policy, stage: Stage, facts: Facts) Plan {
    const callback = policy orelse return @import("replay_progress_reference.zig").plan(stage, facts);
    std.debug.assert(facts.slots.len <= (if (stage == .window) platform.max_windows else platform.max_views));
    var input: [96 + platform.max_views * 80]u8 = @splat(0);
    input[0..4].* = .{ 25, @intFromEnum(stage), facts.code, @intCast(facts.slots.len) };
    inline for (.{ facts.a, facts.b, facts.c, facts.d }, 0..) |value, i| std.mem.writeInt(u64, input[8 + i * 8 ..][0..8], value, .little);
    if (stage == .view) {
        std.mem.writeInt(u64, input[8..16], facts.label.len, .little);
        const len = @min(facts.label.len, platform.max_view_label_bytes);
        @memcpy(input[32..][0..len], facts.label[0..len]);
    }
    for (facts.slots, 0..) |slot, i| {
        const at = 96 + i * 80;
        std.debug.assert(slot.label.len <= platform.max_view_label_bytes);
        input[at] = @intFromBool(slot.open);
        input[at + 1] = @intFromEnum(slot.kind);
        input[at + 2] = @intCast(slot.label.len);
        std.mem.writeInt(u64, input[at + 8 ..][0..8], slot.id, .little);
        @memcpy(input[at + 16 ..][0..slot.label.len], slot.label);
    }
    var output: [32]u8 = undefined;
    if (callback(input[0 .. 96 + facts.slots.len * 80], &output) != output.len or output[0] > 4 or output[1] > 1 or
        (output[2] != 255 and output[2] >= 16) or output[3] != 0 or !std.mem.allEqual(u8, output[24..], 0)) @panic("invalid compiled replay progress plan");
    const index = std.mem.readInt(u32, output[4..8], .little);
    if (index != std.math.maxInt(u32) and index >= facts.slots.len) @panic("invalid compiled replay selection");
    return .{
        .action = @enumFromInt(output[0]),
        .mismatch = output[1] != 0,
        .mismatch_slot = if (output[2] == 255) null else output[2],
        .index = if (index == std.math.maxInt(u32)) null else index,
        .counter = std.mem.readInt(u64, output[8..16], .little),
        .mismatch_count = std.mem.readInt(u64, output[16..24], .little),
    };
}

// Zig 0.17: @typeInfo is struct-of-arrays; rebuild the old per-field record.
const TypeField = struct {
    name: [:0]const u8,
    type: type,
    value: comptime_int,
    default_value_ptr: ?*const anyopaque,
    is_comptime: bool,
    alignment: comptime_int,
};

inline fn typeFields(comptime info: anytype) []const TypeField {
    const result = comptime blk: {
        var out: [info.field_names.len]TypeField = undefined;
        for (info.field_names, 0..) |n, i| {
            out[i] = .{
                .name = n,
                .type = if (@hasField(@TypeOf(info), "field_types")) info.field_types[i] else void,
                .value = if (@hasField(@TypeOf(info), "field_values")) info.field_values[i] else 0,
                .default_value_ptr = if (@hasField(@TypeOf(info), "field_attrs") and @hasField(@TypeOf(info.field_attrs[i]), "default_value_ptr")) info.field_attrs[i].default_value_ptr else null,
                .is_comptime = if (@hasField(@TypeOf(info), "field_attrs") and @hasField(@TypeOf(info.field_attrs[i]), "comptime")) info.field_attrs[i].@"comptime" else false,
                .alignment = if (@hasField(@TypeOf(info), "field_attrs")) (info.field_attrs[i].@"align" orelse 0) else 0,
            };
        }
        const final = out;
        break :blk final;
    };
    return &result;
}

inline fn typeFieldsOf(comptime T: type) []const TypeField {
    return switch (@typeInfo(T)) {
        .@"struct" => |i| typeFields(i),
        .@"enum" => |i| typeFields(i),
        .@"union" => |i| typeFields(i),
        else => @compileError("typeFieldsOf: no fields"),
    };
}
