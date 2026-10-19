//! zaxified/native, branch zig-0.17: the Native SDK v0.11.0 sources ported to Zig 0.17.0.
//!
//! Upstream's build system (custom make steps, configure-time file and environment reads)
//! does not compile on Zig 0.17, and the 0.17 build runner compiles the build.zig of every
//! fetched package, so it is replaced by this empty one. This branch is consumed as SOURCE:
//! the consumer (WrapGridStation) creates its modules from `src/` itself and compiles the
//! platform hosts (`src/platform/*/`) directly. Nothing else here is built or tested on 0.17.
//! Upstream's build.zig is unchanged in history at tag v0.11.0.
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}
