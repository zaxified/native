//! Copied frame observations and surface results. Native retains resource
//! selection execution, buffers, command observation and OS/GPU capabilities.
const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const wire = @import("glyph_atlas_policy.zig");
pub const Policy = wire.Policy;
pub const Mode = enum(u8) { defaults, admission, repaint, bounds, scale, pixels, screenshot };
pub const Facts = struct {
    surface: geometry.SizeF = .{},
    gpu_size: geometry.SizeF = .{},
    frame_size: geometry.SizeF = .{},
    scale: f32 = 1,
    requested_scale: ?f32 = null,
    fallback_scale: f32 = 1,
    previous_surface: geometry.SizeF = .{},
    previous_scale: f32 = 1,
    baseline_surface: geometry.SizeF = .{},
    baseline_scale: f32 = 1,
    revision: u64 = 0,
    presented_revision: u64 = 0,
    previous_overrides: usize = 0,
    current_overrides: usize = 0,
    images: usize = 0,
    fonts: usize = 0,
    budget: canvas.CanvasFrameBudget = .{},
    render_bounds: ?geometry.RectF = null,
    full_repaint: bool = false,
    presented_valid: bool = false,
    presented_unkeyed: bool = false,
    current_unkeyed: bool = false,
    baseline_valid: bool = false,
};
pub const Program = struct {
    surface: geometry.SizeF,
    scale: f32,
    inherit_images: bool,
    inherit_fonts: bool,
    inherit_budget: bool,
    no_op: bool,
    canvas_changed: bool,
    surface_changed: bool,
    observe_unkeyed: bool,
    full_repaint: bool,
    refine_damage: bool,
    bounds: ?geometry.RectF,
    invalid_pixels: bool,
    pixel_width: usize,
    pixel_height: usize,
    pixel_bytes: usize,
};

pub fn resultValid(result: []const u8, mode: Mode) bool {
    if (result.len != 64 or wire.word(result, 0) != 1) return false;
    const mask: u32 = switch (mode) {
        .defaults => 7,
        .admission => 248,
        .repaint => 384,
        .bounds => 512,
        .scale, .screenshot => 0,
        .pixels => 1024,
    };
    if (wire.word(result, 4) & ~mask != 0) return false;
    for (result[48..64]) |byte| if (byte != 0) return false;
    return true;
}

pub fn plan(facts: Facts, mode: Mode, owner: Policy) Program {
    var request: [320]u8 = @splat(0);
    request[0..4].* = .{ 75, 1, @intFromEnum(mode), 0 };
    const flags = @as(u32, @intFromBool(facts.full_repaint)) | (@as(u32, @intFromBool(facts.presented_valid)) << 1) |
        (@as(u32, @intFromBool(facts.presented_unkeyed)) << 2) | (@as(u32, @intFromBool(facts.current_unkeyed)) << 3) |
        (@as(u32, @intFromBool(facts.baseline_valid)) << 4) | (@as(u32, @intFromBool(facts.requested_scale != null)) << 5) |
        (@as(u32, @intFromBool(facts.render_bounds != null)) << 6);
    wire.put(&request, 4, flags);
    inline for (.{ "surface", "gpu_size", "frame_size" }, 0..) |field, i| {
        wire.float(&request, 8 + i * 8, @field(facts, field).width);
        wire.float(&request, 12 + i * 8, @field(facts, field).height);
    }
    wire.float(&request, 32, facts.requested_scale orelse facts.scale);
    wire.float(&request, 36, facts.fallback_scale);
    wire.float(&request, 40, facts.previous_surface.width);
    wire.float(&request, 44, facts.previous_surface.height);
    wire.float(&request, 48, facts.previous_scale);
    wire.float(&request, 52, facts.baseline_surface.width);
    wire.float(&request, 56, facts.baseline_surface.height);
    wire.float(&request, 60, facts.baseline_scale);
    inline for (.{ "revision", "presented_revision", "previous_overrides", "current_overrides", "images", "fonts" }, 0..) |field, i|
        std.mem.writeInt(u64, request[64 + i * 8 ..][0..8], @field(facts, field), .little);
    const bounds = facts.render_bounds orelse geometry.RectF{};
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| wire.float(&request, 112 + i * 4, @field(bounds, field));
    const budget_fields = typeFields(@typeInfo(canvas.CanvasFrameBudget).@"struct");
    if (budget_fields.len != 23) @compileError("update copied frame budget contract");
    inline for (budget_fields, 0..) |field, i| std.mem.writeInt(u64, request[128 + i * 8 ..][0..8], @field(facts.budget, field.name), .little);
    var result: [64]u8 = @splat(0xa5);
    const length = owner(&request, &result);
    if (length > result.len or !resultValid(result[0..length], mode)) @panic("invalid compiled canvas frame coordination result");
    const bits = wire.word(&result, 4);
    return .{
        .surface = .init(float(&result, 8), float(&result, 12)),
        .scale = float(&result, 16),
        .inherit_images = bits & 1 != 0,
        .inherit_fonts = bits & 2 != 0,
        .inherit_budget = bits & 4 != 0,
        .no_op = bits & 8 != 0,
        .canvas_changed = bits & 16 != 0,
        .surface_changed = bits & 32 != 0,
        .observe_unkeyed = bits & 64 != 0,
        .full_repaint = bits & 128 != 0,
        .refine_damage = bits & 256 != 0,
        .bounds = if (bits & 512 == 0) null else geometry.RectF.init(float(&result, 20), float(&result, 24), float(&result, 28), float(&result, 32)),
        .invalid_pixels = bits & 1024 != 0,
        .pixel_width = wire.word(&result, 36),
        .pixel_height = wire.word(&result, 40),
        .pixel_bytes = wire.word(&result, 44),
    };
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(wire.word(bytes, at));
}

test "canvas frame coordination copied transport bounds modes flags and reserved bytes" {
    var result: [64]u8 = @splat(0);
    wire.put(&result, 0, 1);
    for (std.enums.values(Mode)) |mode| {
        try std.testing.expect(resultValid(&result, mode));
        for (0..result.len) |length| try std.testing.expect(!resultValid(result[0..length], mode));
        inline for (.{ 0, 4, 48, 52, 56, 60 }) |at| {
            var bad = result;
            wire.put(&bad, at, 0xffffffff);
            try std.testing.expect(!resultValid(&bad, mode));
        }
    }
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
