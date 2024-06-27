const std = @import("std");
const c = @import("c.zig");
const buildin = @import("builtin");

fn getLibrary() !std.DynLib {
    return switch (buildin.os.tag) {
        .windows => std.DynLib.open("vulkan-1.dll"),
        .ios, .macos, .tvos, .watchos => {
            const LibraryNames = [_][]const u8{ "libvulkan.dylib", "libvulkan.1.dylib", "libMoltenVK.dylib" };
            for (LibraryNames) |name| {
                const lib = std.DynLib.open(name) catch continue;
                return lib;
            }
            return error.LibraryNotFound;
        },
        else => error.LibraryNotFound,
    };
}

const Entry = struct {
    const Self = @This();
    handle: std.DynLib,

    fn init() !Self {
        return .{ .handle = try getLibrary() };
    }

    fn deinit() void {}
};

pub fn main() !void {
    _ = try Entry.init();
    //std.DynLib
}
