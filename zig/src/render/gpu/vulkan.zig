//! The draw command list (`render/scene.zig`) on Vulkan: the Windows GPU path for a device
//! past the threshold (`vulkan_threshold.zig`), first in the cascade (`windows_gpu.zig`).
//! The same 64-byte instances and shapes as the other backends (`vulkan/scene.vert|frag`,
//! SPIR-V kept beside them), one instanced draw in one render pass a frame.
//!
//! Two frames in flight (`frames`): a frame waits for its slot's fence — the frame before
//! last — before it writes that slot's instance buffer, so the CPU builds one frame while
//! the GPU draws the other, and nothing the GPU still reads is overwritten. The present mode
//! paces the frames (`Device.presentMode`): FIFO waits for the display inside
//! acquire/present, so the window does not wait as well (`pacesItself`).
//!
//! Measured on the R7 240 (AMD 22.6.1, Vulkan 1.2), Linux's 2001-shape scene unlimited: 697
//! frames a second with one frame in flight, 706 with two; the render pass takes 449 us of
//! GPU, yet each frame waited 826 us on its fence. Without acquire and present the same
//! frames ran at 1988 a second and waited 156 us: about 0.9 ms of GPU a frame is this
//! driver's present to a window, which Direct3D 11's flip model does not pay (1152 a
//! second). The cascade picks Direct3D 11 on this card in any case (below the threshold).

const std = @import("std");
const scene = @import("../scene.zig");
const atlas = @import("../atlas.zig");
const vk = @import("vulkan_device.zig");
const c = vk.c;

pub const Pacing = vk.Pacing;
pub const Error = vk.Error || error{ NoShader, NoPipeline, NoBuffer, NoTexture, DeviceLost, BelowThreshold };

const vert_spv align(4) = @embedFile("vulkan/scene_vert.spv").*;
const frag_spv align(4) = @embedFile("vulkan/scene_frag.spv").*;

/// Frames the CPU may record ahead of the GPU.
const frames = 2;

/// A buffer and its memory, mapped for as long as it lives (host-visible, coherent).
const Mapped = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    bytes: [*]u8 = undefined,
    size: usize = 0,

    fn make(device: *const vk.Device, size: usize, usage: c.VkBufferUsageFlags) Error!Mapped {
        var self: Mapped = .{ .size = size };
        var info = std.mem.zeroes(c.VkBufferCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = usage;
        info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        if (device.d.vkCreateBuffer(device.device, &info, null, &self.buffer) != c.VK_SUCCESS) return error.NoBuffer;
        errdefer device.d.vkDestroyBuffer(device.device, self.buffer, null);
        var needs: c.VkMemoryRequirements = undefined;
        device.d.vkGetBufferMemoryRequirements(device.device, self.buffer, &needs);
        var allocate = std.mem.zeroes(c.VkMemoryAllocateInfo);
        allocate.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocate.allocationSize = needs.size;
        allocate.memoryTypeIndex = try device.memoryType(needs.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (device.d.vkAllocateMemory(device.device, &allocate, null, &self.memory) != c.VK_SUCCESS) return error.NoMemory;
        errdefer device.d.vkFreeMemory(device.device, self.memory, null);
        try vk.check(device.d.vkBindBufferMemory(device.device, self.buffer, self.memory, 0));
        var pointer: ?*anyopaque = null;
        try vk.check(device.d.vkMapMemory(device.device, self.memory, 0, size, 0, &pointer));
        self.bytes = @ptrCast(pointer.?);
        return self;
    }

    fn deinit(self: *Mapped, device: *const vk.Device) void {
        if (self.buffer == null) return;
        device.d.vkDestroyBuffer(device.device, self.buffer, null);
        device.d.vkFreeMemory(device.device, self.memory, null);
        self.* = .{};
    }
};

pub const Renderer = struct {
    device: vk.Device,
    swapchain: vk.Swapchain,
    pacing: Pacing,
    render_pass: c.VkRenderPass = null,
    framebuffers: [8]c.VkFramebuffer = @splat(null),
    set_layout: c.VkDescriptorSetLayout = null,
    layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,
    pool: c.VkDescriptorPool = null,
    set: c.VkDescriptorSet = null,
    commands: c.VkCommandPool = null,
    command: [frames]c.VkCommandBuffer = @splat(null),
    /// Signalled when each slot's last frame is done on the GPU.
    in_flight: [frames]c.VkFence = @splat(null),
    acquired: [frames]c.VkSemaphore = @splat(null),
    /// The slot the next frame records into.
    current: usize = 0,

    /// One per swap chain image: presenting waits on the one its image's frame signalled.
    rendered: [8]c.VkSemaphore = @splat(null),
    /// One per slot: a frame writes the buffer its slot's fence says the GPU is done with.
    instances: [frames]Mapped = @splat(.{}),
    staging: Mapped = .{},
    atlas_image: c.VkImage = null,
    atlas_memory: c.VkDeviceMemory = null,
    atlas_view: c.VkImageView = null,
    sampler: c.VkSampler = null,
    /// The atlas image has not been written yet: its first upload is the whole atlas.
    atlas_fresh: bool = true,
    /// Timestamps around each frame's drawing, once `time` has been called.
    timing: c.VkQueryPool = null,
    width: u32,
    height: u32,
    /// Bytes handed to the GPU by `draw`, all frames: the instances, and the atlas regions
    /// seen for the first time.
    uploaded: u64 = 0,

    /// Vulkan on `window`, `width` × `height` physical pixels. Any refusal is an error, and
    /// the caller tries the next backend. `require` refuses a device below the threshold
    /// (`BelowThreshold`): the cascade asks it, `LEPTON_GPU=vulkan` does not.
    pub fn open(window: c.HWND, width: u32, height: u32, pacing: Pacing, require: bool) Error!Renderer {
        var device = try vk.Device.open(window);
        errdefer device.deinit();
        if (require and !device.qualifies()) return error.BelowThreshold;
        var swapchain = try vk.Swapchain.make(&device, width, height, pacing, null);
        errdefer swapchain.deinit(&device);
        var self: Renderer = .{ .device = device, .swapchain = swapchain, .pacing = pacing, .width = width, .height = height };
        errdefer self.release();
        try self.makeRenderPass();
        try self.makeFramebuffers();
        try self.makePipeline();
        try self.makeAtlas();
        try self.makeFrame();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        _ = self.device.d.vkDeviceWaitIdle(self.device.device);
        self.release();
        self.swapchain.deinit(&self.device);
        self.device.deinit();
        self.* = undefined;
    }

    /// Everything but the swap chain and the device, each only if it was made.
    fn release(self: *Renderer) void {
        const d = &self.device.d;
        const device = self.device.device;
        if (self.timing != null) d.vkDestroyQueryPool(device, self.timing, null);
        for (self.rendered) |semaphore| if (semaphore != null) d.vkDestroySemaphore(device, semaphore, null);
        for (self.acquired) |semaphore| if (semaphore != null) d.vkDestroySemaphore(device, semaphore, null);
        for (self.in_flight) |fence| if (fence != null) d.vkDestroyFence(device, fence, null);
        if (self.commands != null) d.vkDestroyCommandPool(device, self.commands, null);
        for (&self.instances) |*buffer| buffer.deinit(&self.device);
        self.staging.deinit(&self.device);
        if (self.sampler != null) d.vkDestroySampler(device, self.sampler, null);
        if (self.atlas_view != null) d.vkDestroyImageView(device, self.atlas_view, null);
        if (self.atlas_image != null) d.vkDestroyImage(device, self.atlas_image, null);
        if (self.atlas_memory != null) d.vkFreeMemory(device, self.atlas_memory, null);
        if (self.pool != null) d.vkDestroyDescriptorPool(device, self.pool, null);
        if (self.pipeline != null) d.vkDestroyPipeline(device, self.pipeline, null);
        if (self.layout != null) d.vkDestroyPipelineLayout(device, self.layout, null);
        if (self.set_layout != null) d.vkDestroyDescriptorSetLayout(device, self.set_layout, null);
        self.destroyFramebuffers();
        if (self.render_pass != null) d.vkDestroyRenderPass(device, self.render_pass, null);
        self.rendered = @splat(null);
        self.acquired = @splat(null);
        self.in_flight = @splat(null);
        self.commands = null;
        self.sampler = null;
        self.atlas_view = null;
        self.atlas_image = null;
        self.atlas_memory = null;
        self.pool = null;
        self.pipeline = null;
        self.layout = null;
        self.set_layout = null;
        self.render_pass = null;
        self.timing = null;
    }

    /// FIFO and MAILBOX/IMMEDIATE alike wait inside acquire, present or the fence: the
    /// window only handles what is queued (`NativeWindow.present_paces`).
    pub fn pacesItself(_: *const Renderer) bool {
        return true;
    }

    /// "FIFO" or what unlimited got, for the check's report.
    pub fn presentModeName(self: *const Renderer) []const u8 {
        return switch (self.swapchain.mode) {
            c.VK_PRESENT_MODE_FIFO_KHR => "fifo",
            c.VK_PRESENT_MODE_MAILBOX_KHR => "mailbox",
            c.VK_PRESENT_MODE_IMMEDIATE_KHR => "immediate",
            else => "other",
        };
    }

    pub const Size = struct { width: u32, height: u32 };

    pub fn draw(self: *Renderer, list: *const scene.List, glyphs: *atlas.Atlas, clear: [4]f32, size: Size) Error!void {
        const d = &self.device.d;
        const device = self.device.device;
        if (size.width == 0 or size.height == 0) return;
        if (size.width != self.swapchain.extent.width or size.height != self.swapchain.extent.height) try self.resize(size);
        const slot = self.current;
        defer self.current = (slot + 1) % frames;
        const command = self.command[slot];
        try vk.check(d.vkWaitForFences(device, 1, &self.in_flight[slot], c.VK_TRUE, std.math.maxInt(u64)));
        var image: u32 = 0;
        const acquired = d.vkAcquireNextImageKHR(device, self.swapchain.handle, std.math.maxInt(u64), self.acquired[slot], null, &image);
        if (acquired == c.VK_ERROR_OUT_OF_DATE_KHR) return self.resize(size);
        if (acquired != c.VK_SUCCESS and acquired != c.VK_SUBOPTIMAL_KHR) return error.DeviceLost;
        try vk.check(d.vkResetFences(device, 1, &self.in_flight[slot]));

        const bytes = list.bytes();
        if (bytes.len > self.instances[slot].size) {
            self.instances[slot].deinit(&self.device);
            self.instances[slot] = try Mapped.make(&self.device, @max(bytes.len, self.instances[slot].size * 2, 64 * 256), c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        }
        @memcpy(self.instances[slot].bytes[0..bytes.len], bytes);
        self.uploaded += bytes.len;

        try vk.check(d.vkResetCommandBuffer(command, 0));
        var begin = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(d.vkBeginCommandBuffer(command, &begin));
        self.syncAtlas(slot, command, glyphs);
        if (self.timing != null) {
            d.vkCmdResetQueryPool(command, self.timing, 0, 2);
            d.vkCmdWriteTimestamp(command, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, self.timing, 0);
        }
        const value: c.VkClearValue = .{ .color = .{ .float32 = .{ clear[0] * clear[3], clear[1] * clear[3], clear[2] * clear[3], clear[3] } } };
        var pass = std.mem.zeroes(c.VkRenderPassBeginInfo);
        pass.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = self.render_pass;
        pass.framebuffer = self.framebuffers[image];
        pass.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent };
        pass.clearValueCount = 1;
        pass.pClearValues = &value;
        d.vkCmdBeginRenderPass(command, &pass, c.VK_SUBPASS_CONTENTS_INLINE);
        if (bytes.len > 0) {
            const extent = self.swapchain.extent;
            const viewport: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height), .minDepth = 0, .maxDepth = 1 };
            const scissor: c.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
            d.vkCmdSetViewport(command, 0, 1, &viewport);
            d.vkCmdSetScissor(command, 0, 1, &scissor);
            d.vkCmdBindPipeline(command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
            d.vkCmdBindDescriptorSets(command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.layout, 0, 1, &self.set, 0, null);
            const offset: c.VkDeviceSize = 0;
            d.vkCmdBindVertexBuffers(command, 0, 1, &self.instances[slot].buffer, &offset);
            const frame = [2]f32{ @floatFromInt(extent.width), @floatFromInt(extent.height) };
            d.vkCmdPushConstants(command, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(frame)), &frame);
            d.vkCmdDraw(command, 4, @intCast(list.instances.items.len), 0, 0);
        }
        d.vkCmdEndRenderPass(command);
        if (self.timing != null) d.vkCmdWriteTimestamp(command, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, self.timing, 1);
        try vk.check(d.vkEndCommandBuffer(command));

        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        var submit = std.mem.zeroes(c.VkSubmitInfo);
        submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &self.acquired[slot];
        submit.pWaitDstStageMask = &wait_stage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &command;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &self.rendered[image];
        if (d.vkQueueSubmit(self.device.queue, 1, &submit, self.in_flight[slot]) != c.VK_SUCCESS) return error.DeviceLost;

        var present = std.mem.zeroes(c.VkPresentInfoKHR);
        present.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &self.rendered[image];
        present.swapchainCount = 1;
        present.pSwapchains = &self.swapchain.handle;
        present.pImageIndices = &image;
        const presented = d.vkQueuePresentKHR(self.device.queue, &present);
        if (presented == c.VK_ERROR_OUT_OF_DATE_KHR or presented == c.VK_SUBOPTIMAL_KHR) return self.resize(size);
        if (presented != c.VK_SUCCESS) return error.DeviceLost;
    }

    /// Timestamps around each frame's drawing from now on (`gpuMicroseconds`).
    pub fn time(self: *Renderer) Error!void {
        var info = std.mem.zeroes(c.VkQueryPoolCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO;
        info.queryType = c.VK_QUERY_TYPE_TIMESTAMP;
        info.queryCount = 2;
        try vk.check(self.device.d.vkCreateQueryPool(self.device.device, &info, null, &self.timing));
    }

    /// The last frame's drawing on the GPU, waited for; null before `time`.
    pub fn gpuMicroseconds(self: *Renderer) ?i64 {
        if (self.timing == null) return null;
        var stamps: [2]u64 = undefined;
        const flags = c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT;
        if (self.device.d.vkGetQueryPoolResults(self.device.device, self.timing, 0, 2, @sizeOf(@TypeOf(stamps)), &stamps, @sizeOf(u64), flags) != c.VK_SUCCESS) return null;
        const ticks: f64 = @floatFromInt(stamps[1] -| stamps[0]);
        return @intFromFloat(ticks * self.device.properties.limits.timestampPeriod / 1000.0);
    }

    fn resize(self: *Renderer, size: Size) Error!void {
        _ = self.device.d.vkDeviceWaitIdle(self.device.device);
        self.destroyFramebuffers();
        const old = self.swapchain;
        self.swapchain = try vk.Swapchain.make(&self.device, size.width, size.height, self.pacing, old.handle);
        var retired = old;
        retired.deinit(&self.device);
        self.width = self.swapchain.extent.width;
        self.height = self.swapchain.extent.height;
        try self.makeFramebuffers();
        // A new swap chain may have more images than the old one: each needs its semaphore.
        try self.makeSemaphores();
    }

    fn destroyFramebuffers(self: *Renderer) void {
        for (&self.framebuffers) |*framebuffer| {
            if (framebuffer.* != null) self.device.d.vkDestroyFramebuffer(self.device.device, framebuffer.*, null);
            framebuffer.* = null;
        }
    }

    fn makeRenderPass(self: *Renderer) Error!void {
        var attachment = std.mem.zeroes(c.VkAttachmentDescription);
        attachment.format = self.swapchain.format;
        attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        const reference: c.VkAttachmentReference = .{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &reference;
        // The image is written only once the acquire semaphore has let the colour stage go.
        const dependency: c.VkSubpassDependency = .{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        var info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        info.attachmentCount = 1;
        info.pAttachments = &attachment;
        info.subpassCount = 1;
        info.pSubpasses = &subpass;
        info.dependencyCount = 1;
        info.pDependencies = &dependency;
        if (self.device.d.vkCreateRenderPass(self.device.device, &info, null, &self.render_pass) != c.VK_SUCCESS) return error.NoPipeline;
    }

    fn makeFramebuffers(self: *Renderer) Error!void {
        for (self.swapchain.views[0..self.swapchain.count], 0..) |view, index| {
            var info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            info.renderPass = self.render_pass;
            info.attachmentCount = 1;
            info.pAttachments = &view;
            info.width = self.swapchain.extent.width;
            info.height = self.swapchain.extent.height;
            info.layers = 1;
            if (self.device.d.vkCreateFramebuffer(self.device.device, &info, null, &self.framebuffers[index]) != c.VK_SUCCESS) return error.NoPipeline;
        }
    }

    fn shader(self: *Renderer, code: []align(4) const u8) Error!c.VkShaderModule {
        var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = code.len;
        info.pCode = @ptrCast(code.ptr);
        var module: c.VkShaderModule = null;
        if (self.device.d.vkCreateShaderModule(self.device.device, &info, null, &module) != c.VK_SUCCESS) return error.NoShader;
        return module;
    }

    fn makePipeline(self: *Renderer) Error!void {
        const d = &self.device.d;
        const device = self.device.device;
        const sampler_binding: c.VkDescriptorSetLayoutBinding = .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        };
        var set_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        set_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        set_info.bindingCount = 1;
        set_info.pBindings = &sampler_binding;
        if (d.vkCreateDescriptorSetLayout(device, &set_info, null, &self.set_layout) != c.VK_SUCCESS) return error.NoPipeline;
        // The frame's size, 8 bytes: within the 128 every Vulkan device guarantees.
        const push: c.VkPushConstantRange = .{ .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 8 };
        var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layout_info.setLayoutCount = 1;
        layout_info.pSetLayouts = &self.set_layout;
        layout_info.pushConstantRangeCount = 1;
        layout_info.pPushConstantRanges = &push;
        if (d.vkCreatePipelineLayout(device, &layout_info, null, &self.layout) != c.VK_SUCCESS) return error.NoPipeline;

        const vertex = try self.shader(&vert_spv);
        defer d.vkDestroyShaderModule(device, vertex, null);
        const fragment = try self.shader(&frag_spv);
        defer d.vkDestroyShaderModule(device, fragment, null);
        var stages: [2]c.VkPipelineShaderStageCreateInfo = @splat(std.mem.zeroes(c.VkPipelineShaderStageCreateInfo));
        for (&stages, [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT }, [_]c.VkShaderModule{ vertex, fragment }) |*stage, kind, module| {
            stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stage.stage = kind;
            stage.module = module;
            stage.pName = "main";
        }
        // One binding, per instance; one vec4 attribute per 16-byte field of `scene.Instance`.
        const binding: c.VkVertexInputBindingDescription = .{ .binding = 0, .stride = @sizeOf(scene.Instance), .inputRate = c.VK_VERTEX_INPUT_RATE_INSTANCE };
        const fields = [_]usize{ @offsetOf(scene.Instance, "rect"), @offsetOf(scene.Instance, "fill"), @offsetOf(scene.Instance, "border_colour"), @offsetOf(scene.Instance, "params") };
        var attributes: [fields.len]c.VkVertexInputAttributeDescription = undefined;
        for (&attributes, fields, 0..) |*attribute, offset, location| {
            attribute.* = .{ .location = @intCast(location), .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @intCast(offset) };
        }
        var input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        input.vertexBindingDescriptionCount = 1;
        input.pVertexBindingDescriptions = &binding;
        input.vertexAttributeDescriptionCount = attributes.len;
        input.pVertexAttributeDescriptions = &attributes;
        var assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
        var viewport = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewport.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport.viewportCount = 1;
        viewport.scissorCount = 1;
        var raster = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        raster.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = c.VK_POLYGON_MODE_FILL;
        raster.cullMode = c.VK_CULL_MODE_NONE;
        raster.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1;
        var multisample = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisample.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        // Premultiplied alpha, as the shaders write it.
        const blend_attachment: c.VkPipelineColorBlendAttachmentState = .{
            .blendEnable = c.VK_TRUE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        var blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 1;
        blend.pAttachments = &blend_attachment;
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dynamic = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic.dynamicStateCount = dynamic_states.len;
        dynamic.pDynamicStates = &dynamic_states;
        var info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = stages.len;
        info.pStages = &stages;
        info.pVertexInputState = &input;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewport;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pColorBlendState = &blend;
        info.pDynamicState = &dynamic;
        info.layout = self.layout;
        info.renderPass = self.render_pass;
        if (d.vkCreateGraphicsPipelines(device, null, 1, &info, null, &self.pipeline) != c.VK_SUCCESS) return error.NoPipeline;
    }

    /// The glyph atlas: an R8 image `atlas.side` square, its sampler, its descriptor, and a
    /// staging buffer the size of the atlas that dirty regions are copied through.
    fn makeAtlas(self: *Renderer) Error!void {
        const d = &self.device.d;
        const device = self.device.device;
        var image_info = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.format = c.VK_FORMAT_R8_UNORM;
        image_info.extent = .{ .width = atlas.side, .height = atlas.side, .depth = 1 };
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_info.usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        if (d.vkCreateImage(device, &image_info, null, &self.atlas_image) != c.VK_SUCCESS) return error.NoTexture;
        var needs: c.VkMemoryRequirements = undefined;
        d.vkGetImageMemoryRequirements(device, self.atlas_image, &needs);
        var allocate = std.mem.zeroes(c.VkMemoryAllocateInfo);
        allocate.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocate.allocationSize = needs.size;
        allocate.memoryTypeIndex = try self.device.memoryType(needs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (d.vkAllocateMemory(device, &allocate, null, &self.atlas_memory) != c.VK_SUCCESS) return error.NoMemory;
        try vk.check(d.vkBindImageMemory(device, self.atlas_image, self.atlas_memory, 0));
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = self.atlas_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R8_UNORM;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        if (d.vkCreateImageView(device, &view_info, null, &self.atlas_view) != c.VK_SUCCESS) return error.NoTexture;
        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        if (d.vkCreateSampler(device, &sampler_info, null, &self.sampler) != c.VK_SUCCESS) return error.NoTexture;
        self.staging = try Mapped.make(&self.device, atlas.side * atlas.side, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);

        const size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 };
        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = 1;
        pool_info.poolSizeCount = 1;
        pool_info.pPoolSizes = &size;
        if (d.vkCreateDescriptorPool(device, &pool_info, null, &self.pool) != c.VK_SUCCESS) return error.NoTexture;
        var set_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        set_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        set_info.descriptorPool = self.pool;
        set_info.descriptorSetCount = 1;
        set_info.pSetLayouts = &self.set_layout;
        try vk.check(d.vkAllocateDescriptorSets(device, &set_info, &self.set));
        const image: c.VkDescriptorImageInfo = .{ .sampler = self.sampler, .imageView = self.atlas_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &image;
        d.vkUpdateDescriptorSets(device, 1, &write, 0, null);
    }

    fn makeFrame(self: *Renderer) Error!void {
        const d = &self.device.d;
        const device = self.device.device;
        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        pool_info.queueFamilyIndex = self.device.family;
        if (d.vkCreateCommandPool(device, &pool_info, null, &self.commands) != c.VK_SUCCESS) return error.DeviceLost;
        var buffer_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        buffer_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        buffer_info.commandPool = self.commands;
        buffer_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        buffer_info.commandBufferCount = frames;
        try vk.check(d.vkAllocateCommandBuffers(device, &buffer_info, &self.command));
        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        // Signalled, so each slot's first wait returns at once.
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
        var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        for (&self.in_flight, &self.acquired) |*fence, *semaphore| {
            try vk.check(d.vkCreateFence(device, &fence_info, null, fence));
            try vk.check(d.vkCreateSemaphore(device, &semaphore_info, null, semaphore));
        }
        try self.makeSemaphores();
    }

    fn makeSemaphores(self: *Renderer) Error!void {
        var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        for (self.rendered[0..self.swapchain.count]) |*semaphore| {
            if (semaphore.* == null) try vk.check(self.device.d.vkCreateSemaphore(self.device.device, &semaphore_info, null, semaphore));
        }
    }

    /// Records the copy of the atlas region added since the last frame (all of it, the
    /// first time), between the barriers the image's layouts need.
    fn syncAtlas(self: *Renderer, slot: usize, command: c.VkCommandBuffer, glyphs: *atlas.Atlas) void {
        const d = &self.device.d;
        const dirty = glyphs.takeDirty();
        if (dirty == null and !self.atlas_fresh) return;
        const region: atlas.Region = if (self.atlas_fresh) .{ .x = 0, .y = 0, .width = atlas.side, .height = atlas.side } else dirty.?;
        // The staging buffer is shared: the other slot's frame may still be copying out of
        // it. Glyphs arrive rarely, so waiting for it then costs nothing per frame.
        for (self.in_flight, 0..) |fence, index| {
            if (index != slot) _ = self.device.d.vkWaitForFences(self.device.device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64));
        }
        for (region.y..region.y + region.height) |row| {
            const start = row * atlas.side + region.x;
            @memcpy(self.staging.bytes[start..][0..region.width], glyphs.pixels[start..][0..region.width]);
        }
        const range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        var to_copy = std.mem.zeroes(c.VkImageMemoryBarrier);
        to_copy.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        to_copy.srcAccessMask = if (self.atlas_fresh) 0 else c.VK_ACCESS_SHADER_READ_BIT;
        to_copy.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        to_copy.oldLayout = if (self.atlas_fresh) c.VK_IMAGE_LAYOUT_UNDEFINED else c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        to_copy.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_copy.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        to_copy.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        to_copy.image = self.atlas_image;
        to_copy.subresourceRange = range;
        d.vkCmdPipelineBarrier(command, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_copy);
        const copy: c.VkBufferImageCopy = .{
            .bufferOffset = @as(u64, region.y) * atlas.side + region.x,
            .bufferRowLength = atlas.side,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = @intCast(region.x), .y = @intCast(region.y), .z = 0 },
            .imageExtent = .{ .width = region.width, .height = region.height, .depth = 1 },
        };
        d.vkCmdCopyBufferToImage(command, self.staging.buffer, self.atlas_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        var to_read = to_copy;
        to_read.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        to_read.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        to_read.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_read.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        d.vkCmdPipelineBarrier(command, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &to_read);
        // Counted as the other backends count it: the glyphs' region, not the first frame's
        // clearing of the image.
        if (dirty) |added| self.uploaded += @as(u64, added.width) * added.height;
        self.atlas_fresh = false;
    }
};
