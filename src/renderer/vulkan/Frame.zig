//! Wrapper for handling frames.
const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const Device = @import("Device.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Renderer = @import("../generic.zig").Renderer(Vulkan);
const Vulkan = @import("../Vulkan.zig");

const Self = @This();

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.vulkan);

/// Options for beginning a frame.
pub const Options = struct {
    /// The device dispatch used to record and submit the frame.
    dispatch: vk.DeviceProxy,

    /// The graphics queue used to submit the frame.
    queue: vk.Queue,

    /// The command pool to allocate our command buffer from.
    cmd_pool: vk.CommandPool,

    /// The API-specific state of the frame being drawn. Provides the
    /// recycled descriptor sets for our render passes.
    frame_state: *Vulkan.FrameState,

    /// Timeline semaphore signaled when our frame completes.
    timeline: vk.Semaphore,

    /// The next value to signal `timeline` with. Incremented by
    /// `submit`.
    timeline_value: *u64,
};

dispatch: vk.DeviceProxy,
queue: vk.Queue,

frame_state: *Vulkan.FrameState,

timeline: vk.Semaphore,
timeline_value: *u64,

/// The renderer this frame belongs to.
renderer: *Renderer,

/// The target this frame is drawn in to.
target: *Target,

/// The command buffer this frame is recorded into.
cmd: vk.CommandBufferProxy,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    const dev = opts.dispatch;

    // All our GPU work is synchronous (we wait for the timeline
    // semaphore at the end of the frame), so we can safely reuse the
    // command pool state. Our descriptor sets are recycled rather
    // than reset, see `Vulkan.FrameState`.
    try dev.resetCommandPool(opts.cmd_pool, .{});

    // Start over from the first descriptor set of our frame state.
    opts.frame_state.next_desc_set = 0;

    var cmd: [1]vk.CommandBuffer = undefined;
    try dev.allocateCommandBuffers(&.{
        .command_pool = opts.cmd_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, &cmd);

    try dev.beginCommandBuffer(cmd[0], &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    return .{
        .dispatch = opts.dispatch,
        .queue = opts.queue,
        .cmd = .init(cmd[0], dev.wrapper),
        .frame_state = opts.frame_state,
        .timeline = opts.timeline,
        .timeline_value = opts.timeline_value,
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    // Transition the attachment into a renderable layout. Note this
    // discards the previous contents: the first step of the pass is
    // expected to clear. RenderPass.complete transitions texture
    // attachments back to the shader read only layout so that they
    // can be sampled again by chained passes (custom shaders).
    self.cmd.pipelineBarrier(
        .{ .top_of_pipe_bit = true },
        .{ .color_attachment_output_bit = true },
        .{},
        null,
        null,
        &.{Device.colorImageBarrier(
            switch (attachments[0].target) {
                .texture => |t| t.texture,
                .target => |t| t.image,
            },
            .{},
            .{ .color_attachment_write_bit = true },
            .undefined,
            .color_attachment_optimal,
        )},
    );

    return .begin(
        .{ .attachments = attachments },
        self.dispatch,
        self.cmd,
        self.frame_state,
        &self.frame_state.next_desc_set,
    );
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: Like the OpenGL renderer, we always wait for our frame to
/// complete on the GPU before exporting it, since the exported
/// dmabuf (or pixel data) must be ready when the apprt wants it.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    const health: Health = health: {
        self.submit() catch |err| {
            log.warn("failed to submit frame err={}", .{err});
            break :health .unhealthy;
        };

        break :health .healthy;
    };

    // If the frame is healthy, export it and push to the present queue.
    // The apprt pulls from this queue in its snapshot handler.
    if (health == .healthy) frame: {
        const frame = self.renderer.api.present(self.target.*) catch |err| {
            log.warn("failed to present render target: err={}", .{err});
            break :frame;
        };

        self.renderer.pushFrame(frame);

        // Notify the surface that it should redraw
        _ = self.renderer.surface_mailbox.push(.redraw, .forever);
    }

    // Report the health to the renderer.
    self.renderer.frameCompleted(health);
}

/// End and submit our command buffer, waiting for the GPU to finish
/// it via our timeline semaphore.
fn submit(self: *const Self) !void {
    const dev = self.dispatch;

    // The render image becomes our transfer source for the blit in
    // to the export image (or the pixel readback).
    self.cmd.pipelineBarrier(
        .{ .color_attachment_output_bit = true },
        .{ .transfer_bit = true },
        .{},
        null,
        null,
        &.{Device.colorImageBarrier(
            self.target.image,
            .{ .color_attachment_write_bit = true },
            .{ .transfer_read_bit = true },
            .color_attachment_optimal,
            .transfer_src_optimal,
        )},
    );

    // If we have an export image, blit our render image in to it and
    // transition it to the general layout, which is required for
    // external consumers of the dmabuf. Otherwise, copy our render
    // image into the target's host-visible readback buffer for CPU
    // presentation.
    if (self.target.export_image != .null_handle) {
        const export_image = self.target.export_image;
        // Transition to transfer destination.
        self.cmd.pipelineBarrier(
            .{ .top_of_pipe_bit = true },
            .{ .transfer_bit = true },
            .{},
            null,
            null,
            &.{Device.colorImageBarrier(
                export_image,
                .{},
                .{ .transfer_write_bit = true },
                .undefined,
                .transfer_dst_optimal,
            )},
        );

        // Copy our render image in to the export image.
        //
        // Note that a copy (rather than a blit) is used since blits
        // perform format conversion: blitting from an sRGB image to
        // our plain UNORM export image would decode the sRGB values,
        // exporting linear data which the apprt then displays too
        // dark. Copies are raw, and the SRGB/UNORM formats are
        // explicitly size-compatible for copies.
        self.cmd.copyImage(
            self.target.image,
            .transfer_src_optimal,
            export_image,
            .transfer_dst_optimal,
            &.{.{
                .src_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .src_offset = .{ .x = 0, .y = 0, .z = 0 },
                .dst_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
                .extent = .{
                    .width = @intCast(self.target.width),
                    .height = @intCast(self.target.height),
                    .depth = 1,
                },
            }},
        );

        // Transition to the general layout for external consumption.
        self.cmd.pipelineBarrier(
            .{ .transfer_bit = true },
            .{ .bottom_of_pipe_bit = true },
            .{},
            null,
            null,
            &.{Device.colorImageBarrier(
                export_image,
                .{ .transfer_write_bit = true },
                .{},
                .transfer_dst_optimal,
                .general,
            )},
        );
    } else if (self.target.readback) |rb| {
        // Copy our render image in to the host-visible readback
        // buffer. The copy is tightly packed (`buffer_row_length =
        // 0`), so the first `width * height * 4` bytes of the buffer
        // are the pixel data, which is what the apprt expects.
        self.cmd.copyImageToBuffer(
            self.target.image,
            .transfer_src_optimal,
            rb.buffer,
            &.{.{
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{
                    .width = @intCast(self.target.width),
                    .height = @intCast(self.target.height),
                    .depth = 1,
                },
            }},
        );
    }

    try self.cmd.endCommandBuffer();

    // Submit, signaling our timeline semaphore.
    self.timeline_value.* += 1;
    const value = self.timeline_value.*;

    var timeline_info: vk.TimelineSemaphoreSubmitInfo = .{
        .signal_semaphore_value_count = 1,
        .p_signal_semaphore_values = &.{value},
    };
    try dev.queueSubmit(
        self.queue,
        &.{.{
            .command_buffer_count = 1,
            .p_command_buffers = &.{self.cmd.handle},
            .signal_semaphore_count = 1,
            .p_signal_semaphores = &.{self.timeline},
            .p_next = &timeline_info,
        }},
        .null_handle,
    );

    // Wait for the frame to complete on the GPU.
    _ = try dev.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = &.{self.timeline},
        .p_values = &.{value},
    }, std.math.maxInt(u64));
}
