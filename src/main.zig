const std = @import("std");
const c = @import("c.zig");
const buildin = @import("builtin");

const PFN_vkGetInstanceProcAddr = std.meta.Child(c.PFN_vkGetInstanceProcAddr);
const PFN_vkCreateInstance = std.meta.Child(c.PFN_vkCreateInstance);
const PFN_vkDestroyInstance = std.meta.Child(c.PFN_vkDestroyInstance);

fn getLibrary() !std.DynLib {
    return switch (buildin.os.tag) {
        .windows => std.DynLib.open("vulkan-1.dll"),
        .ios, .macos, .tvos, .watchos => {
            const LibraryNames = [_][]const u8{ "libMoltenVK.dylib", "libvulkan.dylib", "libvulkan.1.dylib" };
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
    get_instance_proc_addr: PFN_vkGetInstanceProcAddr,

    fn init() !Self {
        var library = try getLibrary();
        return .{
            .handle = library,
            .get_instance_proc_addr = library.lookup(PFN_vkGetInstanceProcAddr, "vkGetInstanceProcAddr").?,
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
    destroy_instance: PFN_vkDestroyInstance,
    allocation_callbacks: ?*c.VkAllocationCallbacks,

    fn init(entry: Entry) !Self {
        const info = c.VkInstanceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
        const create_instance: PFN_vkCreateInstance = @ptrCast(entry.get_instance_proc_addr(null, "vkCreateInstance"));
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

        const destroy_instance: PFN_vkDestroyInstance = @ptrCast(entry.get_instance_proc_addr(instance, "vkDestroyInstance"));
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
