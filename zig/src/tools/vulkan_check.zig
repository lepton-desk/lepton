//! Does this machine's Vulkan meet the native renderer's threshold, and does it draw?
//!
//! The first measurement for the 0.2.0 GPU renderer (`docs/plans/hazirlik-0.2.0.md`). For
//! every device the loader lists it prints what the threshold asks
//! (`core.vulkanThreshold`) and what is missing. Then, on one device — the first
//! qualifying GPU, or `LEPTON_VULKAN_DEVICE=<index>` — it creates a logical device with
//! exactly those features enabled, clears an image on the GPU through a `synchronization2`
//! barrier, copies it to host memory, waits on a timeline semaphore, and compares the
//! bytes. Every line is the driver's answer; no window is needed, so it runs anywhere the
//! loader does.

const std = @import("std");
const core = @import("lepton_core");
const threshold = core.vulkanThreshold;

const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const side = 64;
const pixel_bytes = 4;
/// The clear colour, and the bytes `R8G8B8A8_UNORM` must hold for it.
const clear_rgba = [4]f32{ 0.25, 0.5, 0.75, 1.0 };
const expected = [4]u8{ 64, 128, 191, 255 };

const Failure = error{ Vulkan, NoDevice, NoQueue, NoMemoryType, WrongPixels, ValidationFailed };

fn check(result: c.VkResult, what: []const u8) Failure!void {
    if (result == c.VK_SUCCESS) return;
    std.debug.print("vulkan       {s}: VkResult {d}\n", .{ what, result });
    return error.Vulkan;
}

fn major(version: u32) u32 {
    return (version >> 22) & 0x7f;
}
fn minor(version: u32) u32 {
    return (version >> 12) & 0x3ff;
}
fn patch(version: u32) u32 {
    return version & 0xfff;
}
fn makeVersion(maj: u32, min: u32) u32 {
    return (maj << 22) | (min << 12);
}

fn hasExtension(list: []const c.VkExtensionProperties, name: []const u8) bool {
    for (list) |extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extensionName, 0), name)) return true;
    }
    return false;
}

const Device = struct {
    handle: c.VkPhysicalDevice,
    properties: c.VkPhysicalDeviceProperties,
    caps: threshold.Caps,
    qualifies: bool,
};

fn describe(physical: c.VkPhysicalDevice) Failure!Device {
    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(physical, &properties);

    var v13: c.VkPhysicalDeviceVulkan13Features = std.mem.zeroes(c.VkPhysicalDeviceVulkan13Features);
    v13.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    var v12: c.VkPhysicalDeviceVulkan12Features = std.mem.zeroes(c.VkPhysicalDeviceVulkan12Features);
    v12.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    v12.pNext = &v13;
    var features: c.VkPhysicalDeviceFeatures2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
    features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features.pNext = &v12;
    c.vkGetPhysicalDeviceFeatures2(physical, &features);

    var count: u32 = 0;
    try check(c.vkEnumerateDeviceExtensionProperties(physical, null, &count, null), "device extensions");
    var buffer: [512]c.VkExtensionProperties = undefined;
    count = @min(count, buffer.len);
    try check(c.vkEnumerateDeviceExtensionProperties(physical, null, &count, &buffer), "device extensions");

    const caps: threshold.Caps = .{
        .api_major = major(properties.apiVersion),
        .api_minor = minor(properties.apiVersion),
        .dynamic_rendering = v13.dynamicRendering == c.VK_TRUE,
        .synchronization2 = v13.synchronization2 == c.VK_TRUE,
        .timeline_semaphore = v12.timelineSemaphore == c.VK_TRUE,
        .descriptor_indexing = v12.descriptorIndexing == c.VK_TRUE,
        .buffer_device_address = v12.bufferDeviceAddress == c.VK_TRUE,
        .max_push_constants = properties.limits.maxPushConstantsSize,
        .swapchain = hasExtension(buffer[0..count], "VK_KHR_swapchain"),
    };
    var out: [8]threshold.Requirement = undefined;
    return .{
        .handle = physical,
        .properties = properties,
        .caps = caps,
        .qualifies = threshold.missing(caps, &out).len == 0,
    };
}

fn report(index: usize, device: Device) void {
    const kind = switch (device.properties.deviceType) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => "discrete",
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => "integrated",
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => "virtual",
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => "cpu",
        else => "other",
    };
    const v = device.properties.apiVersion;
    std.debug.print("device {d}     {s} ({s}), Vulkan {d}.{d}.{d}, push constants {d} B, 2D images up to {d}\n", .{
        index,
        std.mem.sliceTo(&device.properties.deviceName, 0),
        kind,
        major(v),
        minor(v),
        patch(v),
        device.caps.max_push_constants,
        device.properties.limits.maxImageDimension2D,
    });
    var out: [8]threshold.Requirement = undefined;
    const lacks = threshold.missing(device.caps, &out);
    if (lacks.len == 0) {
        std.debug.print("             meets the threshold\n", .{});
        return;
    }
    std.debug.print("             misses:", .{});
    for (lacks) |requirement| std.debug.print(" {t}", .{requirement});
    std.debug.print(" -> GLES 3 path\n", .{});
}

fn memoryType(physical: c.VkPhysicalDevice, bits: u32, wanted: c.VkMemoryPropertyFlags) Failure!u32 {
    var memory: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical, &memory);
    for (0..memory.memoryTypeCount) |index| {
        const fits = bits & (@as(u32, 1) << @intCast(index)) != 0;
        if (fits and memory.memoryTypes[index].propertyFlags & wanted == wanted) return @intCast(index);
    }
    return error.NoMemoryType;
}

fn barrier(command: c.VkCommandBuffer, image: c.VkImage, from: c.VkImageLayout, to: c.VkImageLayout, src: u64, dst: u64) void {
    var image_barrier: c.VkImageMemoryBarrier2 = std.mem.zeroes(c.VkImageMemoryBarrier2);
    image_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    image_barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT;
    image_barrier.srcAccessMask = src;
    image_barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT;
    image_barrier.dstAccessMask = dst;
    image_barrier.oldLayout = from;
    image_barrier.newLayout = to;
    image_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    image_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    image_barrier.image = image;
    image_barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    var dependency: c.VkDependencyInfo = std.mem.zeroes(c.VkDependencyInfo);
    dependency.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dependency.imageMemoryBarrierCount = 1;
    dependency.pImageMemoryBarriers = &image_barrier;
    c.vkCmdPipelineBarrier2(command, &dependency);
}

/// A logical device with the threshold's features, one cleared image read back.
fn draw(device_info: Device) Failure!void {
    const physical = device_info.handle;
    var family_count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
    var families: [16]c.VkQueueFamilyProperties = undefined;
    family_count = @min(family_count, families.len);
    c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, &families);
    const family: u32 = for (families[0..family_count], 0..) |properties, index| {
        if (properties.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) break @intCast(index);
    } else return error.NoQueue;

    var v13: c.VkPhysicalDeviceVulkan13Features = std.mem.zeroes(c.VkPhysicalDeviceVulkan13Features);
    v13.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    v13.dynamicRendering = c.VK_TRUE;
    v13.synchronization2 = c.VK_TRUE;
    var v12: c.VkPhysicalDeviceVulkan12Features = std.mem.zeroes(c.VkPhysicalDeviceVulkan12Features);
    v12.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    v12.pNext = &v13;
    v12.timelineSemaphore = c.VK_TRUE;
    v12.descriptorIndexing = c.VK_TRUE;
    v12.bufferDeviceAddress = c.VK_TRUE;

    const priority: f32 = 1.0;
    var queue_info: c.VkDeviceQueueCreateInfo = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
    queue_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_info.queueFamilyIndex = family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &priority;
    const extensions = [_][*c]const u8{"VK_KHR_swapchain"};
    var create: c.VkDeviceCreateInfo = std.mem.zeroes(c.VkDeviceCreateInfo);
    create.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    create.pNext = &v12;
    create.queueCreateInfoCount = 1;
    create.pQueueCreateInfos = &queue_info;
    create.enabledExtensionCount = extensions.len;
    create.ppEnabledExtensionNames = &extensions;
    var device: c.VkDevice = null;
    try check(c.vkCreateDevice(physical, &create, null, &device), "vkCreateDevice with the threshold's features");
    defer c.vkDestroyDevice(device, null);
    std.debug.print("device       created with the threshold's features, queue family {d}\n", .{family});
    var queue: c.VkQueue = null;
    c.vkGetDeviceQueue(device, family, 0, &queue);

    // The image the GPU clears.
    var image_info: c.VkImageCreateInfo = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
    image_info.extent = .{ .width = side, .height = side, .depth = 1 };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.usage = c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    var image: c.VkImage = null;
    try check(c.vkCreateImage(device, &image_info, null, &image), "vkCreateImage");
    defer c.vkDestroyImage(device, image, null);
    var image_needs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(device, image, &image_needs);
    var image_alloc: c.VkMemoryAllocateInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
    image_alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    image_alloc.allocationSize = image_needs.size;
    image_alloc.memoryTypeIndex = try memoryType(physical, image_needs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    var image_memory: c.VkDeviceMemory = null;
    try check(c.vkAllocateMemory(device, &image_alloc, null, &image_memory), "image memory");
    defer c.vkFreeMemory(device, image_memory, null);
    try check(c.vkBindImageMemory(device, image, image_memory, 0), "bind image memory");

    // Where the bytes come back to.
    const bytes = side * side * pixel_bytes;
    var buffer_info: c.VkBufferCreateInfo = std.mem.zeroes(c.VkBufferCreateInfo);
    buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = bytes;
    buffer_info.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    var buffer: c.VkBuffer = null;
    try check(c.vkCreateBuffer(device, &buffer_info, null, &buffer), "vkCreateBuffer");
    defer c.vkDestroyBuffer(device, buffer, null);
    var buffer_needs: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(device, buffer, &buffer_needs);
    var buffer_alloc: c.VkMemoryAllocateInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
    buffer_alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    buffer_alloc.allocationSize = buffer_needs.size;
    buffer_alloc.memoryTypeIndex = try memoryType(
        physical,
        buffer_needs.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );
    var buffer_memory: c.VkDeviceMemory = null;
    try check(c.vkAllocateMemory(device, &buffer_alloc, null, &buffer_memory), "buffer memory");
    defer c.vkFreeMemory(device, buffer_memory, null);
    try check(c.vkBindBufferMemory(device, buffer, buffer_memory, 0), "bind buffer memory");

    var pool_info: c.VkCommandPoolCreateInfo = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.queueFamilyIndex = family;
    var pool: c.VkCommandPool = null;
    try check(c.vkCreateCommandPool(device, &pool_info, null, &pool), "vkCreateCommandPool");
    defer c.vkDestroyCommandPool(device, pool, null);
    var command_info: c.VkCommandBufferAllocateInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    command_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    command_info.commandPool = pool;
    command_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    command_info.commandBufferCount = 1;
    var command: c.VkCommandBuffer = null;
    try check(c.vkAllocateCommandBuffers(device, &command_info, &command), "vkAllocateCommandBuffers");

    var begin: c.VkCommandBufferBeginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try check(c.vkBeginCommandBuffer(command, &begin), "vkBeginCommandBuffer");
    barrier(command, image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, c.VK_ACCESS_2_TRANSFER_WRITE_BIT);
    var colour: c.VkClearColorValue = undefined;
    colour.float32 = clear_rgba;
    const range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    c.vkCmdClearColorImage(command, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &colour, 1, &range);
    barrier(command, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_ACCESS_2_TRANSFER_WRITE_BIT, c.VK_ACCESS_2_TRANSFER_READ_BIT);
    var region: c.VkBufferImageCopy = std.mem.zeroes(c.VkBufferImageCopy);
    region.imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    region.imageExtent = .{ .width = side, .height = side, .depth = 1 };
    c.vkCmdCopyImageToBuffer(command, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &region);
    try check(c.vkEndCommandBuffer(command), "vkEndCommandBuffer");

    // Completion through a timeline semaphore, the threshold's own feature.
    var timeline_info: c.VkSemaphoreTypeCreateInfo = std.mem.zeroes(c.VkSemaphoreTypeCreateInfo);
    timeline_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
    timeline_info.semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE;
    var semaphore_info: c.VkSemaphoreCreateInfo = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    semaphore_info.pNext = &timeline_info;
    var semaphore: c.VkSemaphore = null;
    try check(c.vkCreateSemaphore(device, &semaphore_info, null, &semaphore), "timeline semaphore");
    defer c.vkDestroySemaphore(device, semaphore, null);

    var command_submit: c.VkCommandBufferSubmitInfo = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
    command_submit.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    command_submit.commandBuffer = command;
    var signal: c.VkSemaphoreSubmitInfo = std.mem.zeroes(c.VkSemaphoreSubmitInfo);
    signal.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
    signal.semaphore = semaphore;
    signal.value = 1;
    signal.stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    var submit: c.VkSubmitInfo2 = std.mem.zeroes(c.VkSubmitInfo2);
    submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submit.commandBufferInfoCount = 1;
    submit.pCommandBufferInfos = &command_submit;
    submit.signalSemaphoreInfoCount = 1;
    submit.pSignalSemaphoreInfos = &signal;

    const io = std.Io.Threaded.global_single_threaded.io();
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    try check(c.vkQueueSubmit2(queue, 1, &submit, null), "vkQueueSubmit2");
    const value: u64 = 1;
    var wait: c.VkSemaphoreWaitInfo = std.mem.zeroes(c.VkSemaphoreWaitInfo);
    wait.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
    wait.semaphoreCount = 1;
    wait.pSemaphores = &semaphore;
    wait.pValues = &value;
    try check(c.vkWaitSemaphores(device, &wait, std.time.ns_per_s), "vkWaitSemaphores");
    const waited = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;

    var mapped: ?*anyopaque = null;
    try check(c.vkMapMemory(device, buffer_memory, 0, bytes, 0, &mapped), "vkMapMemory");
    defer c.vkUnmapMemory(device, buffer_memory);
    const pixels: [*]const u8 = @ptrCast(mapped orelse return error.Vulkan);
    var wrong: usize = 0;
    for (0..side * side) |index| {
        const at = pixels[index * pixel_bytes ..][0..pixel_bytes];
        for (at, expected) |got, want| {
            if (@max(got, want) - @min(got, want) > 1) {
                wrong += 1;
                break;
            }
        }
    }
    std.debug.print("draw         {d}x{d} cleared on the GPU, read back: first pixel {any}, {d} wrong, {d} us submit to signal\n", .{
        side, side, pixels[0..pixel_bytes].*, wrong, @divTrunc(@max(waited, 0), std.time.ns_per_us),
    });
    if (wrong != 0) return error.WrongPixels;
}

pub fn main() !void {
    var instance_extensions: u32 = 0;
    try check(c.vkEnumerateInstanceExtensionProperties(null, &instance_extensions, null), "instance extensions");
    var listed: [64]c.VkExtensionProperties = undefined;
    instance_extensions = @min(instance_extensions, listed.len);
    try check(c.vkEnumerateInstanceExtensionProperties(null, &instance_extensions, &listed), "instance extensions");
    var loader_version: u32 = 0;
    try check(c.vkEnumerateInstanceVersion(&loader_version), "vkEnumerateInstanceVersion");
    std.debug.print("loader       Vulkan {d}.{d}.{d}, wayland surface {s}, xcb surface {s}\n", .{
        major(loader_version),
        minor(loader_version),
        patch(loader_version),
        if (hasExtension(listed[0..instance_extensions], "VK_KHR_wayland_surface")) "yes" else "no",
        if (hasExtension(listed[0..instance_extensions], "VK_KHR_xcb_surface")) "yes" else "no",
    });

    var app: c.VkApplicationInfo = std.mem.zeroes(c.VkApplicationInfo);
    app.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "lepton-vulkan-check";
    app.pEngineName = "lepton";
    app.apiVersion = makeVersion(1, 3);
    // `VK_KHR_swapchain` (a threshold requirement) needs `VK_KHR_surface` on the instance;
    // the validation layer caught the probe enabling one without the other.
    var extensions: [4][*c]const u8 = undefined;
    var extension_count: u32 = 0;
    extensions[extension_count] = "VK_KHR_surface";
    extension_count += 1;
    if (hasExtension(listed[0..instance_extensions], "VK_KHR_wayland_surface")) {
        extensions[extension_count] = "VK_KHR_wayland_surface";
        extension_count += 1;
    }
    // Khronos validation, when installed and not turned off: every misuse of the API is
    // counted and fails the check. `LEPTON_VULKAN_VALIDATION=0` runs without it.
    const validate = validationWanted() and try hasLayer("VK_LAYER_KHRONOS_validation");
    const layers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
    if (validate) {
        extensions[extension_count] = "VK_EXT_debug_utils";
        extension_count += 1;
    }
    var create: c.VkInstanceCreateInfo = std.mem.zeroes(c.VkInstanceCreateInfo);
    create.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create.pApplicationInfo = &app;
    create.enabledExtensionCount = extension_count;
    create.ppEnabledExtensionNames = &extensions;
    if (validate) {
        create.enabledLayerCount = layers.len;
        create.ppEnabledLayerNames = &layers;
    }
    var instance: c.VkInstance = null;
    try check(c.vkCreateInstance(&create, null, &instance), "vkCreateInstance");
    defer c.vkDestroyInstance(instance, null);
    const messenger = if (validate) try listen(instance) else null;
    defer if (messenger) |handle| stopListening(instance, handle);
    std.debug.print("validation   {s}\n", .{if (validate) "Khronos layer on" else "off (layer not installed, or LEPTON_VULKAN_VALIDATION=0)"});

    var count: u32 = 0;
    try check(c.vkEnumeratePhysicalDevices(instance, &count, null), "physical devices");
    var handles: [8]c.VkPhysicalDevice = undefined;
    count = @min(count, handles.len);
    try check(c.vkEnumeratePhysicalDevices(instance, &count, &handles), "physical devices");
    if (count == 0) {
        std.debug.print("vulkan       no device -> GLES 3 path\n", .{});
        return error.NoDevice;
    }

    var devices: [8]Device = undefined;
    for (handles[0..count], 0..) |handle, index| {
        devices[index] = try describe(handle);
        report(index, devices[index]);
    }

    const forced: ?usize = if (std.c.getenv("LEPTON_VULKAN_DEVICE")) |text|
        std.fmt.parseInt(usize, std.mem.span(text), 10) catch null
    else
        null;
    const chosen: usize = if (forced) |index| index else blk: {
        for (devices[0..count], 0..) |device, index| {
            if (device.qualifies and device.properties.deviceType != c.VK_PHYSICAL_DEVICE_TYPE_CPU) break :blk index;
        }
        for (devices[0..count], 0..) |device, index| {
            if (device.qualifies) break :blk index;
        }
        std.debug.print("vulkan       no device meets the threshold -> GLES 3 path\n", .{});
        return error.NoDevice;
    };
    if (chosen >= count) return error.NoDevice;
    std.debug.print("chosen       device {d}: {s}\n", .{ chosen, std.mem.sliceTo(&devices[chosen].properties.deviceName, 0) });
    try draw(devices[chosen]);
    if (validate) {
        std.debug.print("validation   {d} errors, {d} warnings\n", .{ validation_errors, validation_warnings });
        if (validation_errors != 0) return error.ValidationFailed;
    }
}

var validation_errors: u32 = 0;
var validation_warnings: u32 = 0;

fn validationWanted() bool {
    const value = std.c.getenv("LEPTON_VULKAN_VALIDATION") orelse return true;
    return !(value[0] == '0' and value[1] == 0);
}

fn hasLayer(name: []const u8) Failure!bool {
    var count: u32 = 0;
    try check(c.vkEnumerateInstanceLayerProperties(&count, null), "instance layers");
    var layers: [64]c.VkLayerProperties = undefined;
    count = @min(count, layers.len);
    try check(c.vkEnumerateInstanceLayerProperties(&count, &layers), "instance layers");
    for (layers[0..count]) |layer| {
        if (std.mem.eql(u8, std.mem.sliceTo(&layer.layerName, 0), name)) return true;
    }
    return false;
}

fn onMessage(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    _: c.VkDebugUtilsMessageTypeFlagsEXT,
    data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) c.VkBool32 {
    const error_bit = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    if (severity & error_bit != 0) validation_errors += 1 else validation_warnings += 1;
    const text: [*:0]const u8 = if (data != null and data.*.pMessage != null) data.*.pMessage else "(no message)";
    std.debug.print("validation   {s}: {s}\n", .{ if (severity & error_bit != 0) "error" else "warning", text });
    return c.VK_FALSE;
}

fn listen(instance: c.VkInstance) Failure!c.VkDebugUtilsMessengerEXT {
    const create_fn: c.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    const create = create_fn orelse return error.Vulkan;
    var info: c.VkDebugUtilsMessengerCreateInfoEXT = std.mem.zeroes(c.VkDebugUtilsMessengerCreateInfoEXT);
    info.sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    info.messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    info.messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    info.pfnUserCallback = &onMessage;
    var messenger: c.VkDebugUtilsMessengerEXT = null;
    try check(create(instance, &info, null, &messenger), "vkCreateDebugUtilsMessengerEXT");
    return messenger;
}

fn stopListening(instance: c.VkInstance, messenger: c.VkDebugUtilsMessengerEXT) void {
    const destroy_fn: c.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT"));
    if (destroy_fn) |destroy| destroy(instance, messenger, null);
}
