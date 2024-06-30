const std = @import("std");
const c = @import("c.zig");
const buildin = @import("builtin");

const deviceExtensions = [_][*:0]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

fn checkSuccess(result: c.VkResult) !void {
    switch (result) {
        c.VK_SUCCESS => {},
        else => return error.Unexpected,
    }
}

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

const QueueFamilyIndices = struct {
    graphicsFamily: ?u32,
    presentFamily: ?u32,

    fn init() QueueFamilyIndices {
        return QueueFamilyIndices{
            .graphicsFamily = null,
            .presentFamily = null,
        };
    }

    fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphicsFamily != null and self.presentFamily != null;
    }
};

const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: std.ArrayList(c.VkSurfaceFormatKHR),
    presentModes: std.ArrayList(c.VkPresentModeKHR),

    fn init(allocator: *std.mem.Allocator) SwapChainSupportDetails {
        const result = SwapChainSupportDetails{
            .capabilities = undefined,
            .formats = std.ArrayList(c.VkSurfaceFormatKHR).init(allocator.*),
            .presentModes = std.ArrayList(c.VkPresentModeKHR).init(allocator.*),
        };
        //const slice = std.mem.sliceAsBytes(@as(*[1]c.VkSurfaceCapabilitiesKHR, &result.capabilities)[0..1]);
        //std.mem.set(u8, slice, 0);
        return result;
    }

    fn deinit(self: *SwapChainSupportDetails) void {
        self.formats.deinit();
        self.presentModes.deinit();
    }
};

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
    surface: c.VkSurfaceKHR,
    destroy_instance: GetFunctionPointer("vkDestroyInstance"),
    allocation_callbacks: ?*c.VkAllocationCallbacks,
    physicalDevice: c.VkPhysicalDevice,

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
        const surface: c.VkSurfaceKHR = undefined;
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
            .surface = surface,
            .physicalDevice = undefined,
        };
    }

    fn deinit(self: *Self) void {
        self.destroy_instance(self.instance, self.allocation_callbacks);
    }

    fn createSurface(self: *Self, window: *Window) !void {
        if (c.glfwCreateWindowSurface(self.instance, window.instance, null, &self.surface) != c.VK_SUCCESS) {
            return error.FailedToCreateWindowSurface;
        }
    }

    fn pickPhysicalDevice(self: *Self, allocator: *std.mem.Allocator) !void {
        var deviceCount: u32 = 0;

        const enum_physical_devices = try lookup(&self.entry.handle, "vkEnumeratePhysicalDevices");
        try checkSuccess(enum_physical_devices(self.instance, &deviceCount, null));

        if (deviceCount == 0) {
            return error.FailedToFindGPUsWithVulkanSupport;
        }

        const devices = try allocator.alloc(c.VkPhysicalDevice, deviceCount);
        defer allocator.free(devices);
        try checkSuccess(enum_physical_devices(self.instance, &deviceCount, devices.ptr));

        self.physicalDevice = for (devices) |device| {
            if (try self.isDeviceSuitable(allocator, device)) {
                break device;
            }
        } else return error.FailedToFindSuitableGPU;
    }

    fn isDeviceSuitable(self: *Self, allocator: *std.mem.Allocator, device: c.VkPhysicalDevice) !bool {
        const indices = try self.findQueueFamilies(allocator, device);

        const extensionsSupported = try self.checkDeviceExtensionSupport(allocator, device);

        var swapChainAdequate = false;
        if (extensionsSupported) {
            var swapChainSupport = try self.querySwapChainSupport(allocator, device);
            defer swapChainSupport.deinit();
            swapChainAdequate = swapChainSupport.formats.items.len != 0 and swapChainSupport.presentModes.items.len != 0;
        }

        return indices.isComplete() and extensionsSupported and swapChainAdequate;
    }

    fn querySwapChainSupport(self: *Self, allocator: *std.mem.Allocator, device: c.VkPhysicalDevice) !SwapChainSupportDetails {
        var details = SwapChainSupportDetails.init(allocator);
        const GetPhysicalDeviceSurfaceCapabilitiesKHR = try lookup(&self.entry.handle, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");

        const GetPhysicalDeviceSurfaceFormatsKHR = try lookup(&self.entry.handle, "vkGetPhysicalDeviceSurfaceFormatsKHR");

        try checkSuccess(GetPhysicalDeviceSurfaceCapabilitiesKHR(device, self.surface, &details.capabilities));

        var formatCount: u32 = undefined;
        try checkSuccess(GetPhysicalDeviceSurfaceFormatsKHR(device, self.surface, &formatCount, null));

        if (formatCount != 0) {
            try details.formats.resize(formatCount);
            try checkSuccess(GetPhysicalDeviceSurfaceFormatsKHR(device, self.surface, &formatCount, details.formats.items.ptr));
        }

        const GetPhysicalDeviceSurfacePresentModesKHR = try lookup(&self.entry.handle, "vkGetPhysicalDeviceSurfacePresentModesKHR");

        var presentModeCount: u32 = undefined;
        try checkSuccess(GetPhysicalDeviceSurfacePresentModesKHR(device, self.surface, &presentModeCount, null));

        if (presentModeCount != 0) {
            try details.presentModes.resize(presentModeCount);
            try checkSuccess(GetPhysicalDeviceSurfacePresentModesKHR(device, self.surface, &presentModeCount, details.presentModes.items.ptr));
        }

        return details;
    }

    fn findQueueFamilies(self: *Self, allocator: *std.mem.Allocator, device: c.VkPhysicalDevice) !QueueFamilyIndices {
        var indices = QueueFamilyIndices.init();

        const GetPhysicalDeviceQueueFamilyProperties = try lookup(&self.entry.handle, "vkGetPhysicalDeviceQueueFamilyProperties");

        var queueFamilyCount: u32 = 0;
        GetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, null);

        const queueFamilies = try allocator.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
        defer allocator.free(queueFamilies);
        GetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, queueFamilies.ptr);

        var i: u32 = 0;
        for (queueFamilies) |queueFamily| {
            if (queueFamily.queueCount > 0 and
                queueFamily.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0)
            {
                indices.graphicsFamily = i;
            }

            var presentSupport: c.VkBool32 = 0;
            const GetPhysicalDeviceSurfaceSupportKHR = try lookup(&self.entry.handle, "vkGetPhysicalDeviceSurfaceSupportKHR");

            try checkSuccess(GetPhysicalDeviceSurfaceSupportKHR(device, i, self.surface, &presentSupport));

            if (queueFamily.queueCount > 0 and presentSupport != 0) {
                indices.presentFamily = i;
            }

            if (indices.isComplete()) {
                break;
            }

            i += 1;
        }

        return indices;
    }

    fn checkDeviceExtensionSupport(self: *Self, allocator: *std.mem.Allocator, device: c.VkPhysicalDevice) !bool {
        var extensionCount: u32 = undefined;
        const EnumerateDeviceExtensionProperties = try lookup(&self.entry.handle, "vkEnumerateDeviceExtensionProperties");
        try checkSuccess(EnumerateDeviceExtensionProperties(device, null, &extensionCount, null));

        const availableExtensions = try allocator.alloc(c.VkExtensionProperties, extensionCount);
        defer allocator.free(availableExtensions);
        try checkSuccess(EnumerateDeviceExtensionProperties(device, null, &extensionCount, availableExtensions.ptr));

        const CStrHashMap = std.hash_map.HashMap(
            [*:0]const u8,
            void,
            CStrContext,
            std.hash_map.default_max_load_percentage,
        );
        var requiredExtensions = CStrHashMap.init(allocator.*);
        defer requiredExtensions.deinit();
        for (deviceExtensions) |device_ext| {
            _ = try requiredExtensions.put(device_ext, {});
        }

        for (availableExtensions) |extension| {
            _ = requiredExtensions.remove(@ptrCast(&extension.extensionName));
        }

        return requiredExtensions.count() == 0;
    }
};

const CStrContext = struct {
    const Self = @This();
    pub fn hash(self: Self, a: [*:0]const u8) u64 {
        _ = self;
        // FNV 32-bit hash
        var h: u32 = 2166136261;
        var i: usize = 0;
        while (a[i] != 0) : (i += 1) {
            h ^= a[i];
            h *%= 16777619;
        }
        return h;
    }

    pub fn eql(self: Self, a: [*:0]const u8, b: [*:0]const u8) bool {
        _ = self;
        return std.mem.orderZ(u8, a, b) == .eq;
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

    try vulkan.createSurface(&window);
    try vulkan.pickPhysicalDevice(&allocator);

    var loop = try Loop.init(&window);
    defer loop.deinit();

    while (loop.is_running()) {
        c.glfwPollEvents();
    }
}
