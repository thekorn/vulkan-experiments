const std = @import("std");
const c = @import("c.zig");
const buildin = @import("builtin");

fn GetFunctionPointer(comptime name: []const u8) type {
    return std.meta.Child(@field(c, "PFN_" ++ name));
}

fn lookup(library: *std.DynLib, comptime name: [:0]const u8) !GetFunctionPointer(name) {
    return library.lookup(GetFunctionPointer(name), name) orelse error.SymbolNotFound;
}

fn load(comptime name: []const u8, proc_addr: anytype, handle: anytype) GetFunctionPointer(name) {
    return @ptrCast(proc_addr(handle, name.ptr));
}

fn getExtensionNames() []const [*:0]const u8 {
    return switch (buildin.os.tag) {
        // see: https://vulkan.lunarg.com/doc/sdk/1.3.283.0/mac/getting_started.html
        // section `Common Problems - Encountered VK_ERROR_INCOMPATIBLE_DRIVER`
        .ios, .macos, .tvos, .watchos => &[_][*:0]const u8{
            c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
            c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        },
        else => &.{},
    };
}

fn loadLibrary() !std.DynLib {
    // logic taken from `volk` library (https://github.com/zeux/volk)
    return switch (buildin.os.tag) {
        .windows => std.DynLib.open("vulkan-1.dll"),
        .ios, .macos, .tvos, .watchos => {
            const LibraryNames = [_][]const u8{
                "libvulkan.dylib",
                "libvulkan.1.dylib",
                "libMoltenVK.dylib",
            };
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
    get_instance_proc_addr: GetFunctionPointer("vkGetInstanceProcAddr"),

    fn init() !Self {
        var library = try loadLibrary();
        return .{
            .handle = library,
            .get_instance_proc_addr = try lookup(&library, "vkGetInstanceProcAddr"),
        };
    }

    fn deinit(self: *Self) void {
        self.handle.close();
    }
};

const Vulkan = struct {
    const Self = @This();
    entry: Entry,
    instance: c.VkInstance,
    destroy_instance: GetFunctionPointer("vkDestroyInstance"),
    allocation_callbacks: ?*c.VkAllocationCallbacks,

    fn init(entry: Entry) !Self {
        const extensions = getExtensionNames();

        const info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .flags = c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
            .enabledExtensionCount = @intCast(extensions.len),
            .ppEnabledExtensionNames = extensions.ptr,
        };
        const create_instance = load("vkCreateInstance", entry.get_instance_proc_addr, null);
        var instance: c.VkInstance = undefined;
        const allocation_callbacks: ?*c.VkAllocationCallbacks = null;
        switch (create_instance(&info, allocation_callbacks, &instance)) {
            c.VK_SUCCESS => {},
            c.VK_ERROR_OUT_OF_HOST_MEMORY => return error.OutOfHostMemory,
            c.VK_ERROR_OUT_OF_DEVICE_MEMORY => return error.OutOfDeviceMemory,
            c.VK_ERROR_INITIALIZATION_FAILED => return error.InitializationFailed,
            c.VK_ERROR_LAYER_NOT_PRESENT => return error.LayerNotPresent,
            c.VK_ERROR_EXTENSION_NOT_PRESENT => return error.ExtensionNotPresent,
            c.VK_ERROR_INCOMPATIBLE_DRIVER => return error.IncompatibleDriver,
            else => unreachable,
        }

        const destroy_instance = load("vkDestroyInstance", entry.get_instance_proc_addr, instance);
        return .{
            .entry = entry,
            .instance = instance,
            .destroy_instance = destroy_instance,
            .allocation_callbacks = allocation_callbacks,
        };
    }

    fn deinit(self: *Self) void {
        self.destroy_instance(self.instance, self.allocation_callbacks);
    }
};

pub fn main() !void {
    var entry = try Entry.init();
    defer entry.deinit();

    var vulkan = try Vulkan.init(entry);
    defer vulkan.deinit();
}
