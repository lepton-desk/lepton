//! Vulkan's set-up for the native path on Windows: vulkan-1.dll loaded at run time, an
//! instance with the Win32 surface, the device that draws and presents to it, and its swap
//! chain. The renderer (`vulkan.zig`) draws with what this makes.
//!
//! Only Vulkan 1.0 and `VK_KHR_swapchain` are used, so a 1.2 driver (this machine's R7 240
//! on Windows: 1.2.170, no dynamic rendering, measured) can still be made to draw with
//! `LEPTON_GPU=vulkan`; whether the cascade picks Vulkan on its own is the threshold's call
//! (`vulkan_threshold.zig`, `Device.caps`).

const std = @import("std");
const threshold = @import("vulkan_threshold.zig");

pub const c = @import("c_windows");

pub const Error = error{ NoLibrary, NoFunction, NoInstance, NoSurface, NoDevice, NoSwapChain, NoMemory, Vulkan };

pub const Pacing = @import("../../window/window.zig").Pacing;

fn Table(comptime names: []const [:0]const u8) type {
    @setEvalBranchQuota(50_000);
    var types: [names.len]type = undefined;
    for (names, 0..) |name, at| types[at] = @typeInfo(@field(c, "PFN_" ++ name)).optional.child;
    const attributes: [names.len]std.builtin.Type.StructField.Attributes = @splat(.{});
    return @Struct(.auto, null, names, &types, &attributes);
}

const instance_names = [_][:0]const u8{
    "vkDestroyInstance",                         "vkEnumeratePhysicalDevices",           "vkGetPhysicalDeviceProperties",
    "vkGetPhysicalDeviceQueueFamilyProperties",  "vkGetPhysicalDeviceMemoryProperties",  "vkEnumerateDeviceExtensionProperties",
    "vkCreateWin32SurfaceKHR",                   "vkDestroySurfaceKHR",                  "vkGetPhysicalDeviceSurfaceSupportKHR",
    "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", "vkGetPhysicalDeviceSurfaceFormatsKHR", "vkGetPhysicalDeviceSurfacePresentModesKHR",
    "vkCreateDevice",                            "vkGetDeviceProcAddr",
};

const device_names = [_][:0]const u8{
    "vkDestroyDevice",              "vkGetDeviceQueue",              "vkCreateSwapchainKHR",         "vkDestroySwapchainKHR",
    "vkGetSwapchainImagesKHR",      "vkAcquireNextImageKHR",         "vkQueuePresentKHR",            "vkQueueSubmit",
    "vkDeviceWaitIdle",             "vkCreateImageView",             "vkDestroyImageView",           "vkCreateRenderPass",
    "vkDestroyRenderPass",          "vkCreateFramebuffer",           "vkDestroyFramebuffer",         "vkCreateShaderModule",
    "vkDestroyShaderModule",        "vkCreatePipelineLayout",        "vkDestroyPipelineLayout",      "vkCreateGraphicsPipelines",
    "vkDestroyPipeline",            "vkCreateDescriptorSetLayout",   "vkDestroyDescriptorSetLayout", "vkCreateDescriptorPool",
    "vkDestroyDescriptorPool",      "vkAllocateDescriptorSets",      "vkUpdateDescriptorSets",       "vkCreateBuffer",
    "vkDestroyBuffer",              "vkGetBufferMemoryRequirements", "vkAllocateMemory",             "vkFreeMemory",
    "vkBindBufferMemory",           "vkMapMemory",                   "vkCreateImage",                "vkDestroyImage",
    "vkGetImageMemoryRequirements", "vkBindImageMemory",             "vkCreateSampler",              "vkDestroySampler",
    "vkCreateCommandPool",          "vkDestroyCommandPool",          "vkAllocateCommandBuffers",     "vkBeginCommandBuffer",
    "vkEndCommandBuffer",           "vkResetCommandBuffer",          "vkCmdBeginRenderPass",         "vkCmdEndRenderPass",
    "vkCmdBindPipeline",            "vkCmdBindVertexBuffers",        "vkCmdBindDescriptorSets",      "vkCmdPushConstants",
    "vkCmdSetViewport",             "vkCmdSetScissor",               "vkCmdDraw",                    "vkCmdPipelineBarrier",
    "vkCmdCopyBufferToImage",       "vkCreateFence",                 "vkDestroyFence",               "vkWaitForFences",
    "vkResetFences",                "vkCreateSemaphore",             "vkDestroySemaphore",           "vkCmdWriteTimestamp",
    "vkCreateQueryPool",            "vkDestroyQueryPool",            "vkGetQueryPoolResults",        "vkCmdResetQueryPool",
};

pub const InstanceFns = Table(&instance_names);
pub const DeviceFns = Table(&device_names);

/// The one loaded copy of vulkan-1.dll: Windows keeps a module loaded until its last
/// `FreeLibrary`, and the renderer is opened and closed at most a few times.
fn libraryEntry() Error!c.PFN_vkGetInstanceProcAddr {
    const library = c.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll")) orelse return error.NoLibrary;
    const entry: c.PFN_vkGetInstanceProcAddr = @ptrCast(c.GetProcAddress(library, "vkGetInstanceProcAddr"));
    return entry orelse error.NoLibrary;
}

fn loadInstance(get: @typeInfo(c.PFN_vkGetInstanceProcAddr).optional.child, instance: c.VkInstance) Error!InstanceFns {
    var fns: InstanceFns = undefined;
    inline for (instance_names) |name| {
        @field(fns, name) = @ptrCast(get(instance, name.ptr) orelse return error.NoFunction);
    }
    return fns;
}

fn loadDevice(get: @typeInfo(c.PFN_vkGetDeviceProcAddr).optional.child, device: c.VkDevice) Error!DeviceFns {
    var fns: DeviceFns = undefined;
    inline for (device_names) |name| {
        @field(fns, name) = @ptrCast(get(device, name.ptr) orelse return error.NoFunction);
    }
    return fns;
}

pub fn check(result: c.VkResult) Error!void {
    if (result != c.VK_SUCCESS) return error.Vulkan;
}

/// What the threshold asks of a device, read from it (`vulkan_threshold.Caps`). Features of
/// a version the device does not report are not asked for: a 1.2 driver is not handed 1.3's
/// structure.
fn capsOf(get: @typeInfo(c.PFN_vkGetInstanceProcAddr).optional.child, instance: c.VkInstance, instance_version: u32, fns: *const InstanceFns, physical: c.VkPhysicalDevice, properties: *const c.VkPhysicalDeviceProperties) threshold.Caps {
    const version = properties.apiVersion;
    const major = c.VK_API_VERSION_MAJOR(version);
    const minor = c.VK_API_VERSION_MINOR(version);
    var v13 = std.mem.zeroes(c.VkPhysicalDeviceVulkan13Features);
    v13.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    var v12 = std.mem.zeroes(c.VkPhysicalDeviceVulkan12Features);
    v12.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    if (minor >= 3) v12.pNext = &v13;
    var features = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
    features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    if (minor >= 2) features.pNext = &v12;
    if (minor >= 1 and instance_version >= c.VK_API_VERSION_1_1) {
        const features2: c.PFN_vkGetPhysicalDeviceFeatures2 = @ptrCast(get(instance, "vkGetPhysicalDeviceFeatures2"));
        if (features2) |read| read(physical, &features);
    }
    var count: u32 = 0;
    var extensions: [512]c.VkExtensionProperties = undefined;
    if (fns.vkEnumerateDeviceExtensionProperties(physical, null, &count, null) == c.VK_SUCCESS) {
        count = @min(count, extensions.len);
        if (fns.vkEnumerateDeviceExtensionProperties(physical, null, &count, &extensions) != c.VK_SUCCESS) count = 0;
    }
    const swapchain = for (extensions[0..count]) |extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extensionName, 0), "VK_KHR_swapchain")) break true;
    } else false;
    return .{
        .api_major = major,
        .api_minor = minor,
        .dynamic_rendering = v13.dynamicRendering == c.VK_TRUE,
        .synchronization2 = v13.synchronization2 == c.VK_TRUE,
        .timeline_semaphore = v12.timelineSemaphore == c.VK_TRUE,
        .descriptor_indexing = v12.descriptorIndexing == c.VK_TRUE,
        .buffer_device_address = v12.bufferDeviceAddress == c.VK_TRUE,
        .max_push_constants = properties.limits.maxPushConstantsSize,
        .swapchain = swapchain,
    };
}

/// The instance, the window's surface, and the device that draws and presents to it.
pub const Device = struct {
    instance: c.VkInstance,
    fns: InstanceFns,
    surface: c.VkSurfaceKHR,
    physical: c.VkPhysicalDevice,
    properties: c.VkPhysicalDeviceProperties,
    memory: c.VkPhysicalDeviceMemoryProperties,
    caps: threshold.Caps,
    device: c.VkDevice,
    d: DeviceFns,
    queue: c.VkQueue,
    family: u32,

    pub fn name(self: *const Device) []const u8 {
        return std.mem.sliceTo(&self.properties.deviceName, 0);
    }

    /// Whether the device passes the threshold the cascade picks Vulkan by.
    pub fn qualifies(self: *const Device) bool {
        var out: [8]threshold.Requirement = undefined;
        return threshold.missing(self.caps, &out).len == 0;
    }

    pub fn open(window: c.HWND) Error!Device {
        const get = (try libraryEntry()).?;
        const create_instance: c.PFN_vkCreateInstance = @ptrCast(get(null, "vkCreateInstance"));
        const extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_win32_surface" };
        var application = std.mem.zeroes(c.VkApplicationInfo);
        application.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        application.pEngineName = "Lepton";
        // 1.1 where the loader has it: the threshold reads features through
        // `vkGetPhysicalDeviceFeatures2` (1.1), which a 1.0 instance must not call — its
        // pointer is handed out all the same, and calling it crashed at address 0 (measured).
        const loader_version = instanceVersion(get);
        application.apiVersion = if (loader_version >= c.VK_API_VERSION_1_1) c.VK_API_VERSION_1_1 else c.VK_API_VERSION_1_0;
        var instance_info = std.mem.zeroes(c.VkInstanceCreateInfo);
        instance_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        instance_info.pApplicationInfo = &application;
        instance_info.enabledExtensionCount = extensions.len;
        instance_info.ppEnabledExtensionNames = @ptrCast(&extensions);
        var instance: c.VkInstance = null;
        if ((create_instance orelse return error.NoFunction)(&instance_info, null, &instance) != c.VK_SUCCESS) return error.NoInstance;
        const fns = loadInstance(get, instance) catch |err| {
            const destroy: c.PFN_vkDestroyInstance = @ptrCast(get(instance, "vkDestroyInstance"));
            if (destroy) |d| d(instance, null);
            return err;
        };
        errdefer fns.vkDestroyInstance(instance, null);

        var surface_info = std.mem.zeroes(c.VkWin32SurfaceCreateInfoKHR);
        surface_info.sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
        surface_info.hinstance = c.GetModuleHandleW(null);
        surface_info.hwnd = window;
        var surface: c.VkSurfaceKHR = null;
        if (fns.vkCreateWin32SurfaceKHR(instance, &surface_info, null, &surface) != c.VK_SUCCESS) return error.NoSurface;
        errdefer fns.vkDestroySurfaceKHR(instance, surface, null);

        // The first device with a queue family that draws and presents to this surface.
        var count: u32 = 0;
        try check(fns.vkEnumeratePhysicalDevices(instance, &count, null));
        var physicals: [8]c.VkPhysicalDevice = undefined;
        count = @min(count, physicals.len);
        try check(fns.vkEnumeratePhysicalDevices(instance, &count, &physicals));
        for (physicals[0..count]) |physical| {
            var families: [16]c.VkQueueFamilyProperties = undefined;
            var family_count: u32 = families.len;
            fns.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, &families);
            for (families[0..family_count], 0..) |family, index| {
                if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
                var present: c.VkBool32 = c.VK_FALSE;
                if (fns.vkGetPhysicalDeviceSurfaceSupportKHR(physical, @intCast(index), surface, &present) != c.VK_SUCCESS or present == c.VK_FALSE) continue;
                var self: Device = .{
                    .instance = instance,
                    .fns = fns,
                    .surface = surface,
                    .physical = physical,
                    .properties = undefined,
                    .memory = undefined,
                    .caps = undefined,
                    .device = null,
                    .d = undefined,
                    .queue = null,
                    .family = @intCast(index),
                };
                fns.vkGetPhysicalDeviceProperties(physical, &self.properties);
                fns.vkGetPhysicalDeviceMemoryProperties(physical, &self.memory);
                self.caps = capsOf(get, instance, application.apiVersion, &fns, physical, &self.properties);
                if (!self.caps.swapchain) continue;
                try self.makeDevice();
                return self;
            }
        }
        return error.NoDevice;
    }

    fn makeDevice(self: *Device) Error!void {
        const priority: f32 = 1;
        var queue_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
        queue_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = self.family;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &priority;
        const extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        var info = std.mem.zeroes(c.VkDeviceCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        info.queueCreateInfoCount = 1;
        info.pQueueCreateInfos = &queue_info;
        info.enabledExtensionCount = extensions.len;
        info.ppEnabledExtensionNames = @ptrCast(&extensions);
        if (self.fns.vkCreateDevice(self.physical, &info, null, &self.device) != c.VK_SUCCESS) return error.NoDevice;
        self.d = loadDevice(self.fns.vkGetDeviceProcAddr, self.device) catch |err| {
            const destroy: c.PFN_vkDestroyDevice = @ptrCast(self.fns.vkGetDeviceProcAddr(self.device, "vkDestroyDevice"));
            if (destroy) |d| d(self.device, null);
            return err;
        };
        self.d.vkGetDeviceQueue(self.device, self.family, 0, &self.queue);
    }

    pub fn deinit(self: *Device) void {
        self.d.vkDestroyDevice(self.device, null);
        self.fns.vkDestroySurfaceKHR(self.instance, self.surface, null);
        self.fns.vkDestroyInstance(self.instance, null);
    }

    /// A memory type `bits` allows with every flag of `wanted`.
    pub fn memoryType(self: *const Device, bits: u32, wanted: c.VkMemoryPropertyFlags) Error!u32 {
        for (0..self.memory.memoryTypeCount) |index| {
            const allowed = bits & (@as(u32, 1) << @intCast(index)) != 0;
            if (allowed and self.memory.memoryTypes[index].propertyFlags & wanted == wanted) return @intCast(index);
        }
        return error.NoMemory;
    }

    /// The present mode `pacing` asks for: FIFO (every driver has it) at the display's
    /// refresh; unlimited, IMMEDIATE (tears) else MAILBOX (newest frame wins) else FIFO.
    pub fn presentMode(self: *const Device, pacing: Pacing) c.VkPresentModeKHR {
        if (pacing == .display) return c.VK_PRESENT_MODE_FIFO_KHR;
        var modes: [8]c.VkPresentModeKHR = undefined;
        var count: u32 = modes.len;
        if (self.fns.vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical, self.surface, &count, &modes) != c.VK_SUCCESS) return c.VK_PRESENT_MODE_FIFO_KHR;
        for ([_]c.VkPresentModeKHR{ c.VK_PRESENT_MODE_IMMEDIATE_KHR, c.VK_PRESENT_MODE_MAILBOX_KHR }) |wanted| {
            for (modes[0..count]) |mode| if (mode == wanted) return mode;
        }
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }
};

/// The swap chain and one view of each of its images.
pub const Swapchain = struct {
    handle: c.VkSwapchainKHR,
    format: c.VkFormat,
    extent: c.VkExtent2D,
    mode: c.VkPresentModeKHR,
    images: [8]c.VkImage = undefined,
    views: [8]c.VkImageView = undefined,
    count: u32 = 0,

    /// A swap chain of `width`×`height` (or the surface's own extent, when it has one),
    /// handed `old` to replace on a resize.
    pub fn make(device: *const Device, width: u32, height: u32, pacing: Pacing, old: c.VkSwapchainKHR) Error!Swapchain {
        const fns = &device.fns;
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(fns.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device.physical, device.surface, &capabilities));
        var formats: [32]c.VkSurfaceFormatKHR = undefined;
        var format_count: u32 = formats.len;
        _ = fns.vkGetPhysicalDeviceSurfaceFormatsKHR(device.physical, device.surface, &format_count, &formats);
        if (format_count == 0) return error.NoSwapChain;
        // BGRA, not sRGB: the shaders write the colours as given, as the other backends do.
        var format = formats[0];
        for (formats[0..format_count]) |candidate| {
            if (candidate.format == c.VK_FORMAT_B8G8R8A8_UNORM) format = candidate;
        }
        const extent: c.VkExtent2D = if (capabilities.currentExtent.width != std.math.maxInt(u32)) capabilities.currentExtent else .{
            .width = std.math.clamp(width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
            .height = std.math.clamp(height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
        };
        if (extent.width == 0 or extent.height == 0) return error.NoSwapChain;
        var wanted_images = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount != 0) wanted_images = @min(wanted_images, capabilities.maxImageCount);
        const mode = device.presentMode(pacing);
        var info = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        info.surface = device.surface;
        info.minImageCount = wanted_images;
        info.imageFormat = format.format;
        info.imageColorSpace = format.colorSpace;
        info.imageExtent = extent;
        info.imageArrayLayers = 1;
        info.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        info.preTransform = capabilities.currentTransform;
        info.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        info.presentMode = mode;
        info.clipped = c.VK_TRUE;
        info.oldSwapchain = old;
        var self: Swapchain = .{ .handle = null, .format = format.format, .extent = extent, .mode = mode };
        if (device.d.vkCreateSwapchainKHR(device.device, &info, null, &self.handle) != c.VK_SUCCESS) return error.NoSwapChain;
        errdefer device.d.vkDestroySwapchainKHR(device.device, self.handle, null);
        self.count = self.images.len;
        try check(device.d.vkGetSwapchainImagesKHR(device.device, self.handle, &self.count, &self.images));
        for (self.images[0..self.count], 0..) |image, index| {
            var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = image;
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = self.format;
            view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            if (device.d.vkCreateImageView(device.device, &view_info, null, &self.views[index]) != c.VK_SUCCESS) {
                for (self.views[0..index]) |view| device.d.vkDestroyImageView(device.device, view, null);
                return error.NoSwapChain;
            }
        }
        return self;
    }

    pub fn deinit(self: *Swapchain, device: *const Device) void {
        for (self.views[0..self.count]) |view| device.d.vkDestroyImageView(device.device, view, null);
        device.d.vkDestroySwapchainKHR(device.device, self.handle, null);
        self.count = 0;
    }
};

/// The highest Vulkan the loader offers an instance: 1.0 when it has no
/// `vkEnumerateInstanceVersion` (a 1.0 loader).
fn instanceVersion(get: @typeInfo(c.PFN_vkGetInstanceProcAddr).optional.child) u32 {
    const enumerate: c.PFN_vkEnumerateInstanceVersion = @ptrCast(get(null, "vkEnumerateInstanceVersion"));
    var version: u32 = c.VK_API_VERSION_1_0;
    if (enumerate) |ask| {
        if (ask(&version) != c.VK_SUCCESS) return c.VK_API_VERSION_1_0;
    }
    return version;
}
