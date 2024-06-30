const std = @import("std");
const c = @import("c.zig");
const buildin = @import("builtin");

const enableValidationLayers = std.debug.runtime_safety;
const validationLayers = [_][*:0]const u8{"VK_LAYER_LUNARG_standard_validation"};
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
    globalDevice: c.VkDevice,
    graphicsQueue: c.VkQueue,
    presentQueue: c.VkQueue,
    swapChainImages: []c.VkImage,
    swapChain: c.VkSwapchainKHR,
    swapChainImageFormat: c.VkFormat,
    swapChainExtent: c.VkExtent2D,
    swapChainImageViews: []c.VkImageView,
    renderPass: c.VkRenderPass,
    pipelineLayout: c.VkPipelineLayout,
    graphicsPipeline: c.VkPipeline,
    swapChainFramebuffers: []c.VkFramebuffer,
    commandPool: c.VkCommandPool,
    commandBuffers: []c.VkCommandBuffer,

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
            .globalDevice = undefined,
            .graphicsQueue = undefined,
            .presentQueue = undefined,
            .swapChainImages = undefined,
            .swapChain = undefined,
            .swapChainImageFormat = undefined,
            .swapChainExtent = undefined,
            .swapChainImageViews = undefined,
            .renderPass = undefined,
            .pipelineLayout = undefined,
            .graphicsPipeline = undefined,
            .swapChainFramebuffers = undefined,
            .commandPool = undefined,
            .commandBuffers = undefined,
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

    fn createLogicalDevice(self: *Self, allocator: *std.mem.Allocator) !void {
        const indices = try self.findQueueFamilies(allocator, self.physicalDevice);

        var queueCreateInfos = std.ArrayList(c.VkDeviceQueueCreateInfo).init(allocator.*);
        defer queueCreateInfos.deinit();
        const all_queue_families = [_]u32{ indices.graphicsFamily.?, indices.presentFamily.? };
        const uniqueQueueFamilies = if (indices.graphicsFamily.? == indices.presentFamily.?)
            all_queue_families[0..1]
        else
            all_queue_families[0..2];

        var queuePriority: f32 = 1.0;
        for (uniqueQueueFamilies) |queueFamily| {
            const queueCreateInfo = c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = queueFamily,
                .queueCount = 1,
                .pQueuePriorities = &queuePriority,
                .pNext = null,
                .flags = 0,
            };
            try queueCreateInfos.append(queueCreateInfo);
        }

        const deviceFeatures = c.VkPhysicalDeviceFeatures{
            .robustBufferAccess = 0,
            .fullDrawIndexUint32 = 0,
            .imageCubeArray = 0,
            .independentBlend = 0,
            .geometryShader = 0,
            .tessellationShader = 0,
            .sampleRateShading = 0,
            .dualSrcBlend = 0,
            .logicOp = 0,
            .multiDrawIndirect = 0,
            .drawIndirectFirstInstance = 0,
            .depthClamp = 0,
            .depthBiasClamp = 0,
            .fillModeNonSolid = 0,
            .depthBounds = 0,
            .wideLines = 0,
            .largePoints = 0,
            .alphaToOne = 0,
            .multiViewport = 0,
            .samplerAnisotropy = 0,
            .textureCompressionETC2 = 0,
            .textureCompressionASTC_LDR = 0,
            .textureCompressionBC = 0,
            .occlusionQueryPrecise = 0,
            .pipelineStatisticsQuery = 0,
            .vertexPipelineStoresAndAtomics = 0,
            .fragmentStoresAndAtomics = 0,
            .shaderTessellationAndGeometryPointSize = 0,
            .shaderImageGatherExtended = 0,
            .shaderStorageImageExtendedFormats = 0,
            .shaderStorageImageMultisample = 0,
            .shaderStorageImageReadWithoutFormat = 0,
            .shaderStorageImageWriteWithoutFormat = 0,
            .shaderUniformBufferArrayDynamicIndexing = 0,
            .shaderSampledImageArrayDynamicIndexing = 0,
            .shaderStorageBufferArrayDynamicIndexing = 0,
            .shaderStorageImageArrayDynamicIndexing = 0,
            .shaderClipDistance = 0,
            .shaderCullDistance = 0,
            .shaderFloat64 = 0,
            .shaderInt64 = 0,
            .shaderInt16 = 0,
            .shaderResourceResidency = 0,
            .shaderResourceMinLod = 0,
            .sparseBinding = 0,
            .sparseResidencyBuffer = 0,
            .sparseResidencyImage2D = 0,
            .sparseResidencyImage3D = 0,
            .sparseResidency2Samples = 0,
            .sparseResidency4Samples = 0,
            .sparseResidency8Samples = 0,
            .sparseResidency16Samples = 0,
            .sparseResidencyAliased = 0,
            .variableMultisampleRate = 0,
            .inheritedQueries = 0,
        };

        const createInfo = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,

            .queueCreateInfoCount = @intCast(queueCreateInfos.items.len),
            .pQueueCreateInfos = queueCreateInfos.items.ptr,

            .pEnabledFeatures = &deviceFeatures,

            .enabledExtensionCount = @intCast(deviceExtensions.len),
            .ppEnabledExtensionNames = &deviceExtensions,
            .enabledLayerCount = if (enableValidationLayers) @intCast(validationLayers.len) else 0,
            .ppEnabledLayerNames = if (enableValidationLayers) &validationLayers else null,

            .pNext = null,
            .flags = 0,
        };

        const CreateDevice = try lookup(&self.entry.handle, "vkCreateDevice");
        try checkSuccess(CreateDevice(self.physicalDevice, &createInfo, null, &self.globalDevice));

        const GetDeviceQueue = try lookup(&self.entry.handle, "vkGetDeviceQueue");

        GetDeviceQueue(self.globalDevice, indices.graphicsFamily.?, 0, &self.graphicsQueue);
        GetDeviceQueue(self.globalDevice, indices.presentFamily.?, 0, &self.presentQueue);
    }

    fn chooseSwapSurfaceFormat(availableFormats: []c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
        if (availableFormats.len == 1 and availableFormats[0].format == c.VK_FORMAT_UNDEFINED) {
            return c.VkSurfaceFormatKHR{
                .format = c.VK_FORMAT_B8G8R8A8_UNORM,
                .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
            };
        }

        for (availableFormats) |availableFormat| {
            if (availableFormat.format == c.VK_FORMAT_B8G8R8A8_UNORM and
                availableFormat.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return availableFormat;
            }
        }

        return availableFormats[0];
    }
    fn chooseSwapPresentMode(availablePresentModes: []c.VkPresentModeKHR) c.VkPresentModeKHR {
        var bestMode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR;

        for (availablePresentModes) |availablePresentMode| {
            if (availablePresentMode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                return availablePresentMode;
            } else if (availablePresentMode == c.VK_PRESENT_MODE_IMMEDIATE_KHR) {
                bestMode = availablePresentMode;
            }
        }

        return bestMode;
    }

    fn chooseSwapExtent(capabilities: c.VkSurfaceCapabilitiesKHR, window: *Window) c.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        } else {
            var actualExtent = c.VkExtent2D{
                .width = @intCast(window.width),
                .height = @intCast(window.height),
            };

            actualExtent.width = @max(capabilities.minImageExtent.width, @min(capabilities.maxImageExtent.width, actualExtent.width));
            actualExtent.height = @max(capabilities.minImageExtent.height, @min(capabilities.maxImageExtent.height, actualExtent.height));

            return actualExtent;
        }
    }

    fn createSwapChain(self: *Self, allocator: *std.mem.Allocator, window: *Window) !void {
        var swapChainSupport = try self.querySwapChainSupport(allocator, self.physicalDevice);
        defer swapChainSupport.deinit();

        const surfaceFormat = chooseSwapSurfaceFormat(swapChainSupport.formats.items);
        const presentMode = chooseSwapPresentMode(swapChainSupport.presentModes.items);
        const extent = chooseSwapExtent(swapChainSupport.capabilities, window);

        var imageCount: u32 = swapChainSupport.capabilities.minImageCount + 1;
        if (swapChainSupport.capabilities.maxImageCount > 0 and
            imageCount > swapChainSupport.capabilities.maxImageCount)
        {
            imageCount = swapChainSupport.capabilities.maxImageCount;
        }

        const indices = try self.findQueueFamilies(allocator, self.physicalDevice);
        const queueFamilyIndices = [_]u32{ indices.graphicsFamily.?, indices.presentFamily.? };

        const different_families = indices.graphicsFamily.? != indices.presentFamily.?;

        var createInfo = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,

            .minImageCount = imageCount,
            .imageFormat = surfaceFormat.format,
            .imageColorSpace = surfaceFormat.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,

            .imageSharingMode = if (different_families) c.VK_SHARING_MODE_CONCURRENT else c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = if (different_families) @as(u32, 2) else @as(u32, 0),
            .pQueueFamilyIndices = if (different_families) &queueFamilyIndices else &([_]u32{ 0, 0 }),

            .preTransform = swapChainSupport.capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = presentMode,
            .clipped = c.VK_TRUE,

            .oldSwapchain = null,

            .pNext = null,
            .flags = 0,
        };

        const CreateSwapchainKHR = try lookup(&self.entry.handle, "vkCreateSwapchainKHR");
        const GetSwapchainImagesKHR = try lookup(&self.entry.handle, "vkGetSwapchainImagesKHR");

        try checkSuccess(CreateSwapchainKHR(self.globalDevice, &createInfo, null, &self.swapChain));

        try checkSuccess(GetSwapchainImagesKHR(self.globalDevice, self.swapChain, &imageCount, null));
        self.swapChainImages = try allocator.alloc(c.VkImage, imageCount);
        try checkSuccess(GetSwapchainImagesKHR(self.globalDevice, self.swapChain, &imageCount, self.swapChainImages.ptr));

        self.swapChainImageFormat = surfaceFormat.format;
        self.swapChainExtent = extent;
    }

    fn createImageViews(self: *Self, allocator: *std.mem.Allocator) !void {
        self.swapChainImageViews = try allocator.alloc(c.VkImageView, self.swapChainImages.len);
        errdefer allocator.free(self.swapChainImageViews);

        for (self.swapChainImages, 0..) |swap_chain_image, i| {
            const createInfo = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = swap_chain_image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swapChainImageFormat,
                .components = c.VkComponentMapping{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },

                .pNext = null,
                .flags = 0,
            };

            const CreateImageView = try lookup(&self.entry.handle, "vkCreateImageView");
            try checkSuccess(CreateImageView(self.globalDevice, &createInfo, null, &self.swapChainImageViews[i]));
        }
    }

    fn createRenderPass(self: *Self) !void {
        const colorAttachment = c.VkAttachmentDescription{
            .format = self.swapChainImageFormat,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .flags = 0,
        };

        const colorAttachmentRef = [1]c.VkAttachmentReference{c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        }};

        const subpass = [_]c.VkSubpassDescription{c.VkSubpassDescription{
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = @as(*const [1]c.VkAttachmentReference, &colorAttachmentRef),

            .flags = 0,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        }};

        const dependency = [_]c.VkSubpassDependency{c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,

            .dependencyFlags = 0,
        }};

        const renderPassInfo = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&colorAttachment),
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,

            .pNext = null,
            .flags = 0,
        };

        const CreateRenderPass = try lookup(&self.entry.handle, "vkCreateRenderPass");
        try checkSuccess(CreateRenderPass(self.globalDevice, &renderPassInfo, null, &self.renderPass));
    }

    fn createShaderModule(self: *Self, code: []align(@alignOf(u32)) const u8) !c.VkShaderModule {
        const createInfo = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = code.len,
            .pCode = std.mem.bytesAsSlice(u32, code).ptr,

            .pNext = null,
            .flags = 0,
        };
        const CreateShaderModule = try lookup(&self.entry.handle, "vkCreateShaderModule");

        var shaderModule: c.VkShaderModule = undefined;
        try checkSuccess(CreateShaderModule(self.globalDevice, &createInfo, null, &shaderModule));

        return shaderModule;
    }

    fn createGraphicsPipeline(self: *Self) !void {
        const vertShaderCode align(4) = @embedFile("vert.spv").*;
        const fragShaderCode align(4) = @embedFile("frag.spv").*;

        const vertShaderModule = try self.createShaderModule(&vertShaderCode);
        const fragShaderModule = try self.createShaderModule(&fragShaderCode);

        const vertShaderStageInfo = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vertShaderModule,
            .pName = "main",

            .pNext = null,
            .flags = 0,
            .pSpecializationInfo = null,
        };

        const fragShaderStageInfo = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = fragShaderModule,
            .pName = "main",
            .pNext = null,
            .flags = 0,

            .pSpecializationInfo = null,
        };

        const shaderStages = [_]c.VkPipelineShaderStageCreateInfo{ vertShaderStageInfo, fragShaderStageInfo };

        const vertexInputInfo = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 0,
            .vertexAttributeDescriptionCount = 0,

            .pVertexBindingDescriptions = null,
            .pVertexAttributeDescriptions = null,
            .pNext = null,
            .flags = 0,
        };

        const inputAssembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
            .pNext = null,
            .flags = 0,
        };

        const viewport = [_]c.VkViewport{c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swapChainExtent.width),
            .height = @floatFromInt(self.swapChainExtent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        }};

        const scissor = [_]c.VkRect2D{c.VkRect2D{
            .offset = c.VkOffset2D{ .x = 0, .y = 0 },
            .extent = self.swapChainExtent,
        }};

        const viewportState = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &scissor,

            .pNext = null,
            .flags = 0,
        };

        const rasterizer = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = c.VK_CULL_MODE_BACK_BIT,
            .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,

            .pNext = null,
            .flags = 0,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
        };

        const multisampling = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .sampleShadingEnable = c.VK_FALSE,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .pNext = null,
            .flags = 0,
            .minSampleShading = 0,
            .pSampleMask = null,
            .alphaToCoverageEnable = 0,
            .alphaToOneEnable = 0,
        };

        const colorBlendAttachment = c.VkPipelineColorBlendAttachmentState{
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
            .blendEnable = c.VK_FALSE,

            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
        };

        const colorBlending = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &colorBlendAttachment,
            .blendConstants = [_]f32{ 0, 0, 0, 0 },

            .pNext = null,
            .flags = 0,
        };

        const pipelineLayoutInfo = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 0,
            .pushConstantRangeCount = 0,
            .pNext = null,
            .flags = 0,
            .pSetLayouts = null,
            .pPushConstantRanges = null,
        };

        const CreatePipelineLayout = try lookup(&self.entry.handle, "vkCreatePipelineLayout");
        try checkSuccess(CreatePipelineLayout(self.globalDevice, &pipelineLayoutInfo, null, &self.pipelineLayout));

        const pipelineInfo = [_]c.VkGraphicsPipelineCreateInfo{c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = @intCast(shaderStages.len),
            .pStages = &shaderStages,
            .pVertexInputState = &vertexInputInfo,
            .pInputAssemblyState = &inputAssembly,
            .pViewportState = &viewportState,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pColorBlendState = &colorBlending,
            .layout = self.pipelineLayout,
            .renderPass = self.renderPass,
            .subpass = 0,
            .basePipelineHandle = null,

            .pNext = null,
            .flags = 0,
            .pTessellationState = null,
            .pDepthStencilState = null,
            .pDynamicState = null,
            .basePipelineIndex = 0,
        }};

        const CreateGraphicsPipelines = try lookup(&self.entry.handle, "vkCreateGraphicsPipelines");
        try checkSuccess(CreateGraphicsPipelines(
            self.globalDevice,
            null,
            @intCast(pipelineInfo.len),
            &pipelineInfo,
            null,
            @as(*[1]c.VkPipeline, &self.graphicsPipeline),
        ));

        const DestroyShaderModule = try lookup(&self.entry.handle, "vkDestroyShaderModule");
        DestroyShaderModule(self.globalDevice, fragShaderModule, null);
        DestroyShaderModule(self.globalDevice, vertShaderModule, null);
    }

    fn createFramebuffers(self: *Self, allocator: *std.mem.Allocator) !void {
        self.swapChainFramebuffers = try allocator.alloc(c.VkFramebuffer, self.swapChainImageViews.len);

        const CreateFramebuffer = try lookup(&self.entry.handle, "vkCreateFramebuffer");

        for (self.swapChainImageViews, 0..) |swap_chain_image_view, i| {
            const attachments = [_]c.VkImageView{swap_chain_image_view};

            const framebufferInfo = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = self.renderPass,
                .attachmentCount = 1,
                .pAttachments = &attachments,
                .width = self.swapChainExtent.width,
                .height = self.swapChainExtent.height,
                .layers = 1,

                .pNext = null,
                .flags = 0,
            };

            try checkSuccess(CreateFramebuffer(self.globalDevice, &framebufferInfo, null, &self.swapChainFramebuffers[i]));
        }
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
    width: i32,
    height: i32,

    fn init(width: i32, height: i32) !Self {
        if (c.glfwInit() == 0) return error.GlfwInitFailed;

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);

        const window = c.glfwCreateWindow(width, height, "Vulkan", null, null) orelse return error.GlfwCreateWindowFailed;
        return .{
            .instance = window,
            .width = width,
            .height = height,
        };
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

    var window = try Window.init(800, 600);
    defer window.deinit();

    var entry = try Entry.init();
    defer entry.deinit();

    var vulkan = try Vulkan.init(&allocator, entry);
    defer vulkan.deinit();

    try vulkan.createSurface(&window);
    try vulkan.pickPhysicalDevice(&allocator);
    try vulkan.createLogicalDevice(&allocator);
    try vulkan.createSwapChain(&allocator, &window);
    try vulkan.createImageViews(&allocator);
    try vulkan.createRenderPass();
    try vulkan.createGraphicsPipeline();
    try vulkan.createFramebuffers(&allocator);

    var loop = try Loop.init(&window);
    defer loop.deinit();

    while (loop.is_running()) {
        c.glfwPollEvents();
    }
}
