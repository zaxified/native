//! Lazily heap-allocated per-thread scratch.
//!
//! Large `threadlocal` arrays land in the executable's static TLS
//! template, and the OS loader materializes that whole template for
//! EVERY thread of the process — window host, COM, accessibility, and
//! worker threads all pay for the full multi-megabyte canvas planner
//! scratch even though only a runtime loop thread ever touches it
//! (measured on Windows as ~6.5 MiB of heap-backed private working set
//! per thread). `LazyTls` keeps only one pointer in static TLS: the
//! backing storage is heap-allocated the first time a thread actually
//! asks for it, so threads that never plan a frame pay eight bytes
//! instead of megabytes.
//!
//! Semantics match the `threadlocal var scratch: T = .{}` it replaces:
//! each thread gets its own instance, initialized to the struct's field
//! defaults on that thread's first access. Fields declared WITHOUT a
//! default stay uninitialized, matching the `= undefined` statics they
//! replace. The instance lives until process exit — one long-lived
//! runtime loop thread per process is the designed shape, and a static
//! TLS block was process-lifetime address space per thread too.
//!
//! Allocation failure panics: this is the render path's fixed scratch,
//! sized at compile time, and a process that cannot commit it cannot
//! render at all — the old static-TLS commit would have failed thread
//! creation under the same pressure.

const std = @import("std");

pub fn LazyTls(comptime T: type) type {
    return struct {
        threadlocal var instance: ?*T = null;

        /// This thread's instance, allocated and default-initialized on
        /// first use. The pointer is stable for the thread's lifetime,
        /// so hot loops may hoist it once per operation.
        pub fn get() *T {
            return instance orelse create();
        }

        /// This thread's instance only if something already used it —
        /// for stats accessors that must observe without allocating.
        pub fn peek() ?*T {
            return instance;
        }

        fn create() *T {
            const ptr = std.heap.page_allocator.create(T) catch
                @panic("out of memory allocating per-thread canvas scratch");
            inline for (typeFields(@typeInfo(T).@"struct")) |field| {
                if (comptime field.defaultValue()) |value| @field(ptr, field.name) = value;
            }
            instance = ptr;
            return ptr;
        }
    };
}

test "lazy tls initializes defaults once per access pattern" {
    const Scratch = struct {
        counter: u64 = 7,
        buffer: [32]u8, // no default: stays uninitialized, like `= undefined`
    };
    const tls = LazyTls(Scratch);
    try std.testing.expectEqual(@as(?*Scratch, null), tls.peek());
    const first = tls.get();
    try std.testing.expectEqual(@as(u64, 7), first.counter);
    first.counter += 1;
    first.buffer[0] = 42;
    const second = tls.get();
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u64, 8), second.counter);
    try std.testing.expectEqual(@as(?*Scratch, first), tls.peek());
}

// Zig 0.17: @typeInfo is struct-of-arrays; rebuild the old per-field record.
const TypeField = struct {
    name: [:0]const u8,
    type: type,
    value: comptime_int,
    default_value_ptr: ?*const anyopaque,
    is_comptime: bool,
    alignment: comptime_int,

    inline fn defaultValue(comptime self: TypeField) ?self.type {
        const p: *const self.type = @ptrCast(@alignCast(self.default_value_ptr orelse return null));
        return p.*;
    }
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
