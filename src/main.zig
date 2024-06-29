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

fn getExtensionNames(allocator: *std.mem.Allocator) ![][*]const u8 {
    var glfwExtensionCount: u32 = 0;
    var glfwExtensions = c.glfwGetRequiredInstanceExtensions(&glfwExtensionCount);

    var extensions = std.ArrayList([*]const u8).init(allocator.*);
    errdefer extensions.deinit();

    // if this is NULLm the vvulklan is likely init before glfw - change order
    std.debug.assert(glfwExtensionCount > 0);
    for (glfwExtensions[0..glfwExtensionCount]) |ext| {
        try extensions.append(ext);
    }

    const extra_extensions = switch (buildin.os.tag) {
        // see: https://vulkan.lunarg.com/doc/sdk/1.3.283.0/mac/getting_started.html
        // section `Common Problems - Encountered VK_ERROR_INCOMPATIBLE_DRIVER`
        .ios, .macos, .tvos, .watchos => &[_][*]const u8{
            c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
            c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        },
        else => &.{},
    };

    try extensions.appendSlice(extra_extensions);

    return extensions.toOwnedSlice();
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

    fn init(allocator: *std.mem.Allocator, entry: Entry) !Self {
        const extensions = try getExtensionNames(allocator);
        defer allocator.free(extensions);

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

const Window = struct {
    const Self = @This();
    instance: *c.GLFWwindow,

    fn init() !Self {
        if (c.glfwInit() == 0) return error.GlfwInitFailed;

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);

        const window = c.glfwCreateWindow(800, 600, "Vulkan", null, null) orelse return error.GlfwCreateWindowFailed;
        return .{ .instance = window };
    }

    fn deinit(self: *Self) void {
        c.glfwDestroyWindow(self.instance);
        c.glfwTerminate();
    }

    fn should_close(self: *Self) bool {
        return c.glfwWindowShouldClose(self.instance) != 0;
    }
};

const Loop = struct {
    const Self = @This();
    window: *Window,

    fn init(window: *Window) !Self {
        return .{ .window = window };
    }

    fn deinit(self: *Self) void {
        _ = self;
    }

    fn is_running(self: *Self) bool {
        return !self.window.should_close();
    }
};

pub fn main() !void {
    var allocator = std.heap.c_allocator;

    var window = try Window.init();
    defer window.deinit();

    var entry = try Entry.init();
    defer entry.deinit();

    var vulkan = try Vulkan.init(&allocator, entry);
    defer vulkan.deinit();

    var loop = try Loop.init(&window);
    defer loop.deinit();

    while (loop.is_running()) {
        c.glfwPollEvents();
    }
}
