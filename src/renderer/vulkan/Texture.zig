//! Wrapper for handling textures.
const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const Self = @This();
const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

/// Options for initializing a texture.
pub const Options = struct {
    /// The device context used to create and manipulate the texture.
    dev_alloc: Device.MemoryAllocator,

    /// The transfers for one-off GPU work (uploads and readbacks).
    transfers: Device.Transfers,

    /// Format of the texture.
    format: vk.Format,

    min_filter: vk.Filter = .linear,
    mag_filter: vk.Filter = .linear,

    /// Whether the texture can be rendered to. When this is set the
    /// image gets the color attachment usage.
    renderable: bool = false,

    /// The wrap modes of our implicit sampler. Vulkan requires an
    /// explicit sampler object to sample from a texture, so we create
    /// one with these parameters for use when a render pass step does
    /// not provide its own sampler.
    wrap_s: vk.SamplerAddressMode = .clamp_to_edge,
    wrap_t: vk.SamplerAddressMode = .clamp_to_edge,
};

pub const Error = error{
    /// A Vulkan API call failed.
    VulkanFailed,
};

texture: vk.Image,
memory: vk.DeviceMemory,
view: vk.ImageView,

/// The implicit sampler for this texture, used when a render pass
/// step binds this texture without an explicit sampler.
sampler: vk.Sampler,

/// The device context needed to use the texture.
dev_alloc: Device.MemoryAllocator,
transfers: Device.Transfers,

/// The width of this texture.
width: usize,
/// The height of this texture.
height: usize,

/// Format for this texture.
format: vk.Format,

/// Initialize a texture.
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    var usage: vk.ImageUsageFlags = .{
        .sampled_bit = true,
        .transfer_dst_bit = true,
        .transfer_src_bit = true,
    };
    if (opts.renderable) usage.color_attachment_bit = true;

    const texture = opts.dev_alloc.dispatch.createImage(&.{
        .image_type = .@"2d",
        .format = opts.format,
        .extent = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch return error.VulkanFailed;
    errdefer opts.dev_alloc.dispatch.destroyImage(texture, null);

    const requirements = opts.dev_alloc.dispatch.getImageMemoryRequirements(texture);
    const memory = opts.dev_alloc.allocate(
        requirements,
        .{ .device_local_bit = true },
        null,
    ) catch return error.VulkanFailed;
    errdefer opts.dev_alloc.dispatch.freeMemory(memory, null);
    opts.dev_alloc.dispatch.bindImageMemory(texture, memory, 0) catch return error.VulkanFailed;

    const view = opts.dev_alloc.dispatch.createImageView(&.{
        .image = texture,
        .view_type = .@"2d",
        .format = opts.format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null) catch return error.VulkanFailed;
    errdefer opts.dev_alloc.dispatch.destroyImageView(view, null);

    const sampler = opts.dev_alloc.dispatch.createSampler(&.{
        .mag_filter = opts.mag_filter,
        .min_filter = opts.min_filter,
        .mipmap_mode = .nearest,
        .address_mode_u = opts.wrap_s,
        .address_mode_v = opts.wrap_t,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .compare_enable = .false,
        .min_lod = 0,
        .max_lod = vk.LOD_CLAMP_NONE,
        .compare_op = .never,
        .max_anisotropy = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    }, null) catch return error.VulkanFailed;
    errdefer opts.dev_alloc.dispatch.destroySampler(sampler, null);

    var self: Self = .{
        .texture = texture,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .dev_alloc = opts.dev_alloc,
        .transfers = opts.transfers,
        .width = width,
        .height = height,
        .format = opts.format,
    };

    self.uploadRegion(
        0,
        0,
        width,
        height,
        data,
        .undefined,
    ) catch return error.VulkanFailed;

    return self;
}

pub fn deinit(self: Self) void {
    self.dev_alloc.dispatch.destroySampler(self.sampler, null);
    self.dev_alloc.dispatch.destroyImageView(self.view, null);
    self.dev_alloc.dispatch.destroyImage(self.texture, null);
    self.dev_alloc.dispatch.freeMemory(self.memory, null);
}

/// Replace a region of the texture with the provided data.
///
/// Does NOT check the dimensions of the data to ensure correctness.
pub fn replaceRegion(
    self: *Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    self.uploadRegion(
        x,
        y,
        width,
        height,
        data,
        .shader_read_only_optimal,
    ) catch return error.VulkanFailed;
}

/// Upload pixel data to a region of the texture via a staging buffer.
/// The texture is left in the shader read only layout.
fn uploadRegion(
    self: *Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data_: ?[]const u8,
    old_layout: vk.ImageLayout,
) !void {
    // Start recording the upload.
    const cmd = try self.transfers.beginOneShot();

    // The staging buffer is bound to the command buffer below, so it
    // must stay alive until the command buffer has been submitted and
    // completed.
    const staging_buffer, const staging_memory = staging: {
        const data = data_ orelse break :staging .{
            .null_handle,
            .null_handle,
        };

        // Our data in CPU land is always arranged linearly, but that's not
        // optimal for GPU reads. Therefore we need to use a staging buffer
        // to transition between memory layouts.
        const buffer = try self.dev_alloc.dispatch.createBuffer(&.{
            .size = @max(data.len, 1),
            .usage = .{ .transfer_src_bit = true },
            .sharing_mode = .exclusive,
        }, null);

        const requirements = self.dev_alloc.dispatch.getBufferMemoryRequirements(buffer);
        const memory = try self.dev_alloc.allocate(
            requirements,
            .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            },
            null,
        );
        try self.dev_alloc.dispatch.bindBufferMemory(buffer, memory, 0);

        const mapped: [*]u8 = @ptrCast(try self.dev_alloc.dispatch.mapMemory(
            memory,
            0,
            vk.WHOLE_SIZE,
            .{},
        ));
        @memcpy(mapped[0..data.len], data);

        // Transition into write mode
        cmd.pipelineBarrier(
            .{ .top_of_pipe_bit = true },
            .{ .transfer_bit = true },
            .{},
            null,
            null,
            &.{Device.colorImageBarrier(
                self.texture,
                .{},
                .{ .transfer_write_bit = true },
                old_layout,
                .transfer_dst_optimal,
            )},
        );

        cmd.copyBufferToImage(
            buffer,
            self.texture,
            .transfer_dst_optimal,
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
                .image_offset = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .z = 0,
                },
                .image_extent = .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .depth = 1,
                },
            }},
        );
        break :staging .{ buffer, memory };
    };

    defer {
        if (staging_buffer != .null_handle) {
            self.dev_alloc.dispatch.destroyBuffer(staging_buffer, null);
        }
        if (staging_memory != .null_handle) {
            self.dev_alloc.dispatch.unmapMemory(staging_memory);
            self.dev_alloc.dispatch.freeMemory(staging_memory, null);
        }
    }

    // Regardless if any data has been written into the texture,
    // we have to transition it into a known, safe state that can be
    // sampled by our shaders.
    cmd.pipelineBarrier(
        .{ .transfer_bit = true },
        .{ .fragment_shader_bit = true },
        .{},
        null,
        null,
        &.{Device.colorImageBarrier(
            self.texture,
            .{ .transfer_write_bit = true },
            .{ .shader_read_bit = true },
            // If we copied data then the image is in the transfer destination
            // layout, otherwise it is still in whatever layout it started in
            // (and has no meaningful contents).
            if (data_) |_|
                .transfer_dst_optimal
            else
                old_layout,
            .shader_read_only_optimal,
        )},
    );
    try self.transfers.endOneShot(cmd);
}
