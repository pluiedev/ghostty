//! Represents a render target.
//!
//! In this case, an image-backed render target. The color attachment
//! is a texture instead of an implicitly windowing-owned surface so
//! that we can export the rendered frame as a dma-buf for
//! presentation by the apprt.
//!
//! We use two images:
//!
//!   - `image`: `R8G8B8A8_SRGB`, optimally tiled. We render to this.
//!     Rendering to an sRGB image makes the GPU automatically convert
//!     linear shader output to sRGB on write. This is required for the
//!     linear-blending color pipeline to produce correct output.
//!
//!   - `export_image`: `R8G8B8A8_UNORM`, linearly tiled. This is the
//!     image we actually export as a dma-buf. Some drivers can't
//!     export sRGB textures to dma-buf, so we blit the rendered sRGB
//!     image into this plain RGBA8 image (the blit copies the
//!     already-sRGB-encoded pixel values verbatim) and export that
//!     instead.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const vk = @import("vulkan");
const Device = @import("Device.zig");
const Dmabuf = @import("../Dmabuf.zig");

const log = std.log.scoped(.vulkan);

/// Options for initializing a Target
pub const Options = struct {
    /// The device context used to create and manipulate the target.
    dev_alloc: Device.MemoryAllocator,

    /// The context for exporting the target as a dmabuf, or null if
    /// the device doesn't support it.
    dmabuf: ?Device.Dmabuf,

    /// Desired width
    width: usize,
    /// Desired height
    height: usize,

    /// Pixel format for the render image
    format: vk.Format = .r8g8b8a8_srgb,
};

dev_alloc: Device.MemoryAllocator,

/// The image we render to.
image: vk.Image = .null_handle,
memory: vk.DeviceMemory = .null_handle,
view: vk.ImageView = .null_handle,

/// A plain linear RGBA8 image that we blit `image` into for dma-buf
/// export, or null if the device doesn't support exporting dmabufs.
export_image: vk.Image = .null_handle,
export_memory: vk.DeviceMemory = .null_handle,

/// Host-visible readback buffer for CPU presentation, if the target
/// can't be exported as a dmabuf.
readback: ?Readback = null,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    var self: Self = .{
        .dev_alloc = opts.dev_alloc,
        .width = opts.width,
        .height = opts.height,
    };
    errdefer self.deinit();

    // Our render image, optimally tiled, in device local memory.
    self.image = try opts.dev_alloc.dispatch.createImage(&.{
        .image_type = .@"2d",
        .format = opts.format,
        .extent = .{
            .width = @intCast(opts.width),
            .height = @intCast(opts.height),
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{
            .color_attachment_bit = true,
            .transfer_src_bit = true,
            .transfer_dst_bit = true,
            .sampled_bit = true,
        },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);

    const requirements = opts.dev_alloc.dispatch.getImageMemoryRequirements(self.image);
    self.memory = try opts.dev_alloc.allocate(
        requirements,
        .{ .device_local_bit = true },
        null,
    );
    try opts.dev_alloc.dispatch.bindImageMemory(self.image, self.memory, 0);

    self.view = try opts.dev_alloc.dispatch.createImageView(&.{
        .image = self.image,
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
    }, null);

    // Our export image, linearly tiled, in exportable memory. If the
    // device doesn't support dmabuf export we leave it null and fall
    // back to CPU presentation, for which we need a host-visible
    // buffer that the frame's command buffer copies the rendered
    // image into (see `Frame.submit`).
    if (opts.dmabuf) |dmabuf| {
        if (initExportImage(opts, dmabuf)) |result| {
            self.export_image = result[0];
            self.export_memory = result[1];
        } else |err| {
            log.warn(
                "failed to export dmabuf, falling back to CPU representation err={}",
                .{err},
            );
        }
    }

    if (self.export_image == .null_handle) {
        self.readback = try initReadback(&self);
    }

    return self;
}

/// Host-visible buffer that our frame copies the rendered image
/// into for CPU presentation, persistently mapped.
pub const Readback = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: [*]u8,
};

fn initReadback(self: *Self) !Readback {
    const size = self.width * self.height * 4;
    const buffer = try self.dev_alloc.dispatch.createBuffer(&.{
        .size = size,
        .usage = .{ .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    errdefer self.dev_alloc.dispatch.destroyBuffer(buffer, null);

    const requirements = self.dev_alloc.dispatch.getBufferMemoryRequirements(buffer);
    const memory = try self.dev_alloc.allocate(
        requirements,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        null,
    );
    errdefer self.dev_alloc.dispatch.freeMemory(memory, null);
    try self.dev_alloc.dispatch.bindBufferMemory(buffer, memory, 0);

    const mapped: [*]u8 = @ptrCast(try self.dev_alloc.dispatch.mapMemory(memory, 0, vk.WHOLE_SIZE, .{}));

    return .{
        .buffer = buffer,
        .memory = memory,
        .mapped = mapped,
    };
}

fn initExportImage(
    opts: Options,
    dmabuf: Device.Dmabuf,
) !struct { vk.Image, vk.DeviceMemory } {
    // Check that the format is exportable with linear tiling.
    var external_props: vk.ExternalImageFormatProperties = .{
        .external_memory_properties = .{
            .external_memory_features = .{},
            .export_from_imported_handle_types = .{},
            .compatible_handle_types = .{},
        },
    };
    var props_result: vk.ImageFormatProperties2 = .{
        .image_format_properties = undefined,
        .p_next = &external_props,
    };
    var external_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
        .handle_type = .{ .dma_buf_bit_ext = true },
    };
    dmabuf.instance.getPhysicalDeviceImageFormatProperties2(
        dmabuf.pdev,
        &.{
            .p_next = &external_info,
            .format = .r8g8b8a8_unorm,
            .type = .@"2d",
            .tiling = .linear,
            .usage = .{
                .transfer_dst_bit = true,
                .transfer_src_bit = true,
            },
        },
        &props_result,
    ) catch |err| {
        log.warn("failed to get image format properties err={}", .{err});
        return err;
    };

    if (!external_props.external_memory_properties.external_memory_features.exportable_bit) {
        return error.NotExportable;
    }

    const export_image = opts.dev_alloc.dispatch.createImage(&.{
        .image_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .extent = .{
            .width = @intCast(opts.width),
            .height = @intCast(opts.height),
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .linear,
        .usage = .{
            .transfer_dst_bit = true,
            .transfer_src_bit = true,
        },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
        .p_next = &vk.ExternalMemoryImageCreateInfo{
            .handle_types = .{ .dma_buf_bit_ext = true },
        },
    }, null) catch |err| {
        log.warn("failed to create dmabuf export image err={}", .{err});
        return err;
    };
    errdefer opts.dev_alloc.dispatch.destroyImage(export_image, null);

    const export_requirements = opts.dev_alloc.dispatch.getImageMemoryRequirements(export_image);
    const export_memory = opts.dev_alloc.allocate(
        export_requirements,
        .{},
        .{ .dma_buf_bit_ext = true },
    ) catch |err| {
        log.warn("failed to allocate dmabuf export memory err={}", .{err});
        return err;
    };

    opts.dev_alloc.dispatch.bindImageMemory(export_image, export_memory, 0) catch |err| {
        log.warn("failed to bind dmabuf export memory err={}", .{err});
        return err;
    };

    return .{ export_image, export_memory };
}

pub fn deinit(self: *Self) void {
    if (self.readback) |rb| {
        self.dev_alloc.dispatch.unmapMemory(rb.memory);
        self.dev_alloc.dispatch.destroyBuffer(rb.buffer, null);
        self.dev_alloc.dispatch.freeMemory(rb.memory, null);
    }
    if (self.export_memory != .null_handle) self.dev_alloc.dispatch.freeMemory(self.export_memory, null);
    if (self.export_image != .null_handle) self.dev_alloc.dispatch.destroyImage(self.export_image, null);
    if (self.view != .null_handle) self.dev_alloc.dispatch.destroyImageView(self.view, null);
    if (self.memory != .null_handle) self.dev_alloc.dispatch.freeMemory(self.memory, null);
    if (self.image != .null_handle) self.dev_alloc.dispatch.destroyImage(self.image, null);
}

/// Export the current contents of this target as a dma-buf. The
/// caller takes ownership of the returned dmabuf and its planes.
///
/// The image must have been rendered to and blitted to the export
/// image (see `Frame.complete`).
pub fn exportDmabuf(self: *const Self) !Dmabuf {
    const export_image = self.export_image;
    const export_memory = self.export_memory;
    if (export_image == .null_handle or export_memory == .null_handle) {
        return error.DmabufUnsupported;
    }

    // Export our memory as a dma-buf fd.
    const fd = try self.dev_alloc.dispatch.getMemoryFdKHR(&.{
        .memory = export_memory,
        .handle_type = .{ .dma_buf_bit_ext = true },
    });

    // Get the layout of the image. Linear images are tightly packed
    // (with possible row padding, hence the stride).
    const layout = self.dev_alloc.dispatch.getImageSubresourceLayout(export_image, &.{
        .aspect_mask = .{ .color_bit = true },
        .mip_level = 0,
        .array_layer = 0,
    });

    // There is only ever one plane for the vast majority of export formats,
    // except for those marked explicitly as multiplanar (e.g. YUV formats).
    var planes: Dmabuf.Planes = .{ .count = 1 };
    planes.fds[0] = fd;
    planes.strides[0] = @intCast(layout.row_pitch);
    planes.offsets[0] = 0;

    // DRM fourcc for DRM_FORMAT_ABGR8888
    const fourcc = std.mem.readInt(u32, "AB24", .little);

    // Modifiers are 64 bits in length in total, 56 bits for the type and 8 for
    // the vendor. Implicit/invalid is indicated with all lower 56 bits set.
    const implicit_modifier = std.math.maxInt(u56);

    return .{
        .width = @intCast(self.width),
        .height = @intCast(self.height),
        .fourcc = fourcc,
        .modifier = implicit_modifier,
        .premultiplied = true,
        .planes = planes,
    };
}

/// Read the current contents of the target into CPU memory.
///
/// This is used by the CPU readback presentation fallback. The
/// frame's command buffer copies the rendered image into our
/// readback buffer (see `Frame.submit`); since `present` only runs
/// after the frame's GPU work has completed, the contents are
/// guaranteed to be ready. The returned data is tightly-packed
/// RGBA8 with premultiplied alpha, i.e. `width * 4` bytes per row,
/// containing sRGB-encoded values, the same as the OpenGL
/// renderer's readback.
pub fn readPixels(self: *const Self, alloc: std.mem.Allocator) ![]u8 {
    const rb = self.readback orelse return error.ReadbackUnsupported;

    // Our copy is tightly packed (`buffer_row_length = 0`), so the
    // first `width * height * 4` bytes of the buffer are the pixel
    // data, which is what the apprt expects.
    return try alloc.dupe(u8, rb.mapped[0 .. self.width * self.height * 4]);
}
