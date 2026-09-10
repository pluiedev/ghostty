//! Graphics API wrapper for Vulkan.
pub const Vulkan = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const vk = @import("vulkan");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Vulkan);
const Dmabuf = @import("Dmabuf.zig");
const Device = @import("vulkan/Device.zig");

pub const GraphicsAPI = Vulkan;
pub const Target = @import("vulkan/Target.zig");
pub const Frame = @import("vulkan/Frame.zig");
pub const RenderPass = @import("vulkan/RenderPass.zig");
pub const Pipeline = @import("vulkan/Pipeline.zig");
const bufferpkg = @import("vulkan/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("vulkan/Sampler.zig");
pub const Texture = @import("vulkan/Texture.zig");
pub const shaders = @import("vulkan/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .spv;
// The fragCoord for Vulkan shaders is +Y = down.
pub const custom_shader_y_is_down = true;

/// Triple-buffering gives the GPU room to pipeline renders without
/// having to wait on the apprt consuming previous frames.
pub const swap_chain_count = 3;

const log = std.log.scoped(.vulkan);

/// The device context.
dev: Device,

alloc: Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// Command pool for our frame command buffers.
cmd_pool: vk.CommandPool,

/// Descriptor pool for the descriptor sets owned by our frame
/// states (see `FrameState`). The pool is never reset: its sets are
/// allocated once for all frame states in a single call (see
/// `initFrameStates`) and are recycled by rewriting their contents
/// every frame.
desc_pool: vk.DescriptorPool,

/// The descriptor set layout shared by all our pipelines.
desc_layout: vk.DescriptorSetLayout,

/// The pipeline layout shared by all our pipelines.
pipeline_layout: vk.PipelineLayout,

/// Timeline semaphore used to wait for frames to complete.
timeline: vk.Semaphore,

/// The next value our timeline semaphore will be signaled with.
timeline_value: u64 = 0,

/// The current viewport size, in device pixels. This is set by
/// `setViewport` when the screen size changes.
viewport_width: u32 = 0,
viewport_height: u32 = 0,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Vulkan {
    // Initialize our own device context. Each renderer initializes
    // its own; sharing a device between surfaces would be a
    // worthwhile optimization but we prefer simple, stateless
    // initialization for now.
    var dev = try Device.init(alloc);
    errdefer dev.deinit();

    // Create our per-surface resources.
    const cmd_pool = try dev.dispatch.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = dev.graphics_queue.family,
    }, null);
    errdefer dev.dispatch.destroyCommandPool(cmd_pool, null);

    const timeline = try dev.dispatch.createSemaphore(&.{}, null);
    errdefer dev.dispatch.destroySemaphore(timeline, null);

    // Our descriptor set layout. All of our shader resources live in
    // set 0.
    //
    // Not every pipeline uses every binding; descriptors that aren't
    // statically used by a pipeline don't have to be written.
    const desc_bindings = comptime blk: {
        const Compiled = @import("shaders/Compiled.zig");
        const shader_data: Compiled = @import("shaders");
        var result: [std.meta.tags(Compiled.Resource).len]vk.DescriptorSetLayoutBinding = undefined;
        for (std.meta.tags(Compiled.Resource), 0..) |resource, i| {
            const binding = shader_data.binding(resource);
            result[i] = .{
                .binding = binding,
                .descriptor_type = switch (resource.kind()) {
                    .uniform_buffer => .uniform_buffer,
                    .storage_buffer => .storage_buffer,
                    .combined_image_sampler => .combined_image_sampler,
                },
                .descriptor_count = 1,
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            };
        }
        break :blk result;
    };
    const desc_layout = try dev.dispatch.createDescriptorSetLayout(&.{
        .binding_count = desc_bindings.len,
        .p_bindings = &desc_bindings,
    }, null);
    errdefer dev.dispatch.destroyDescriptorSetLayout(desc_layout, null);

    const pipeline_layout = try dev.dispatch.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = &.{desc_layout},
    }, null);
    errdefer dev.dispatch.destroyPipelineLayout(pipeline_layout, null);

    // Our descriptor pool. This holds the preallocated descriptor
    // sets for all of our frame states (allocated in one go, see
    // `initFrameStates`), which are recycled every frame rather than
    // reallocated, so the pool is never reset. The set list of a
    // frame state grows on demand (see `RenderPass.step`) up to the
    // capacity of this pool; beyond that, steps are skipped with a
    // warning. Every set has the same layout, so the pool must fit
    // every binding of every set.
    const max_set_count = 256;
    const pool_sizes = comptime blk: {
        const Compiled = @import("shaders/Compiled.zig");
        var sizes: std.EnumArray(Compiled.Binding.Kind, vk.DescriptorPoolSize) = .init(.{
            .uniform_buffer = .{ .type = .uniform_buffer, .descriptor_count = 0 },
            .storage_buffer = .{ .type = .storage_buffer, .descriptor_count = 0 },
            .combined_image_sampler = .{ .type = .combined_image_sampler, .descriptor_count = 0 },
        });

        for (std.meta.tags(Compiled.Resource)) |resource| {
            const size = sizes.getPtr(resource.kind());
            size.descriptor_count += 1;
        }
        for (&sizes.values) |*size| size.descriptor_count *= max_set_count;
        break :blk sizes.values;
    };
    const desc_pool = try dev.dispatch.createDescriptorPool(&.{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = max_set_count,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = &pool_sizes,
    }, null);
    errdefer dev.dispatch.destroyDescriptorPool(desc_pool, null);

    return .{
        .dev = dev,
        .alloc = alloc,
        .blending = opts.config.blending,
        .cmd_pool = cmd_pool,
        .desc_pool = desc_pool,
        .desc_layout = desc_layout,
        .pipeline_layout = pipeline_layout,
        .timeline = timeline,
    };
}

pub fn deinit(self: *Vulkan) void {
    // Wait for any outstanding frames to complete.
    self.dev.dispatch.deviceWaitIdle() catch {};

    self.dev.dispatch.destroyDescriptorPool(self.desc_pool, null);
    self.dev.dispatch.destroyPipelineLayout(self.pipeline_layout, null);
    self.dev.dispatch.destroyDescriptorSetLayout(self.desc_layout, null);
    self.dev.dispatch.destroySemaphore(self.timeline, null);
    self.dev.dispatch.destroyCommandPool(self.cmd_pool, null);

    // Tear down our device context.
    self.dev.deinit();

    self.* = undefined;
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Vulkan) !struct { width: u32, height: u32 } {
    // We need to clamp our runtime surface size to the maximum
    // possible texture size since we can't create a render target
    // larger than that.
    return .{
        .width = @min(self.viewport_width, self.dev.max_texture_size),
        .height = @min(self.viewport_height, self.dev.max_texture_size),
    };
}

/// Set the viewport to cover the given size in device pixels.
pub fn setViewport(self: *Vulkan, width: u32, height: u32) void {
    self.viewport_width = width;
    self.viewport_height = height;
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for Vulkan.
pub fn drawFrameStart(self: *Vulkan) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for Vulkan.
pub fn drawFrameEnd(self: *Vulkan) void {
    _ = self;
}

pub fn initShaders(
    self: *const Vulkan,
    alloc: Allocator,
    custom_shaders: []const []const u32,
) !shaders.Shaders {
    return try .init(
        alloc,
        self.dev.dispatch,
        self.pipeline_layout,
        custom_shaders,
    );
}

/// API-specific state for a single frame state of the generic
/// renderer's swap chain (stored in the `api_state` field of
/// `generic.Renderer.FrameState`).
///
/// The initial state for all frame states of a swap chain is
/// allocated in one go (see `initFrameStates`), which lets us create
/// the descriptor sets needed to render a typical frame with a
/// single driver call. The render passes of a frame then reuse
/// (rewrite) the frame state's sets instead of allocating a new set
/// per step. If a frame has more steps than we have sets, the set
/// list is grown on demand (see `RenderPass`).
pub const FrameState = struct {
    /// The allocator for CPU-side state (the set list).
    alloc: Allocator,

    /// The device dispatch used to allocate and free our sets.
    dispatch: vk.DeviceProxy,

    /// The pool our descriptor sets were allocated from.
    desc_pool: vk.DescriptorPool,

    /// The descriptor set layout all our sets were allocated with.
    desc_layout: vk.DescriptorSetLayout,

    /// Preallocated descriptor sets, one per render pass step. These
    /// are recycled every frame: each step rewrites the contents of
    /// its set before binding it. Grown on demand, see `RenderPass`.
    desc_sets: std.ArrayListUnmanaged(vk.DescriptorSet) = .empty,

    /// The index of the next descriptor set to use from `desc_sets`.
    /// Reset every frame by `Frame.begin`; shared across all the
    /// render passes of a frame so that no set is bound twice with
    /// different contents in the same command buffer.
    next_desc_set: usize = 0,

    /// The number of descriptor sets initially allocated for each
    /// frame state, covering the steps of a typical frame.
    pub const initial_desc_sets = 8;

    /// The collection of states for all the frame states of a swap
    /// chain, returned by `initFrameStates`.
    pub const Collection = [swap_chain_count]FrameState;

    pub fn deinit(self: *FrameState) void {
        if (self.desc_sets.items.len > 0) {
            self.dispatch.freeDescriptorSets(self.desc_pool, self.desc_sets.items) catch {};
        }
        self.desc_sets.deinit(self.alloc);
    }
};

/// Allocate the initial API-specific state for all of the frame
/// states of a swap chain in one go. The caller moves the returned
/// states into the frame states they belong to, and each frame state
/// deinits its own state.
///
/// The descriptor sets needed to render a typical frame are
/// allocated here in a single driver call.
pub fn initFrameStates(self: Vulkan) !FrameState.Collection {
    const sets_per_state = FrameState.initial_desc_sets;
    const set_count = swap_chain_count * sets_per_state;

    // Allocate all of our sets in one call.
    var sets: [set_count]vk.DescriptorSet = undefined;
    const layouts: [set_count]vk.DescriptorSetLayout = @splat(self.desc_layout);
    try self.dev.dispatch.allocateDescriptorSets(&.{
        .descriptor_pool = self.desc_pool,
        .descriptor_set_count = set_count,
        .p_set_layouts = &layouts,
    }, &sets);
    errdefer self.dev.dispatch.freeDescriptorSets(self.desc_pool, &sets) catch {};

    // Hand the sets out to our frame states.
    var remaining: []vk.DescriptorSet = &sets;
    var result: FrameState.Collection = undefined;
    for (&result) |*state| {
        state.* = .{
            .alloc = self.alloc,
            .dispatch = self.dev.dispatch,
            .desc_pool = self.desc_pool,
            .desc_layout = self.desc_layout,
        };
        try state.desc_sets.appendSlice(self.alloc, remaining[0..sets_per_state]);
        remaining = remaining[sets_per_state..];
    }

    return result;
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const Vulkan, width: usize, height: usize) !Target {
    return try .init(.{
        .dev_alloc = self.dev.dev_alloc,
        .dmabuf = self.dev.dmabuf,
        .width = width,
        .height = height,
    });
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
pub fn present(self: *Vulkan, target: Target) !ExportedFrame {
    if (target.exportDmabuf()) |dmabuf| {
        return .{ .dmabuf = dmabuf };
    } else |_| {
        // If DMABUFs fail, then use CPU buffers
        return .{ .memory = .{
            .width = @intCast(target.width),
            .height = @intCast(target.height),
            .pixels = try target.readPixels(self.alloc),
            .alloc = self.alloc,
        } };
    }
}

/// A finished frame exported for presentation by the apprt.
pub const ExportedFrame = union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

pub inline fn uniformBufferOptions(self: Vulkan) bufferpkg.Options {
    return .{
        .dev_alloc = self.dev.dev_alloc,
        .usage = .{ .uniform_buffer_bit = true },
    };
}

pub inline fn instanceBufferOptions(self: Vulkan) bufferpkg.Options {
    return .{
        .dev_alloc = self.dev.dev_alloc,
        .usage = .{ .vertex_buffer_bit = true },
    };
}

/// Cell buffers are passed in as read-only storage buffers.
pub inline fn bgBufferOptions(self: Vulkan) bufferpkg.Options {
    return .{
        .dev_alloc = self.dev.dev_alloc,
        .usage = .{ .storage_buffer_bit = true },
    };
}

// The remaining buffers are all bound as vertex buffers carrying
// instance data.
pub const fgBufferOptions = instanceBufferOptions;
pub const imageBufferOptions = instanceBufferOptions;
pub const bgImageBufferOptions = instanceBufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Vulkan) Texture.Options {
    return .{
        .dev_alloc = self.dev.dev_alloc,
        .transfers = self.dev.transfers,
        // Custom shader textures are rendered into by pipelines using
        // `Pipeline.color_format`, so they must match that format.
        .format = Pipeline.color_format,
        // textureOptions is currently only used for custom shaders,
        // which require the shader read (for when multiple shaders
        // are chained) and render target (for the final output)
        // usage.
        .renderable = true,
    };
}

pub inline fn samplerOptions(self: Vulkan) Sampler.Options {
    return .{
        .dispatch = self.dev.dispatch,

        // These parameters match Shadertoy behaviors.
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat, srgb: bool) vk.Format {
        return switch (self) {
            .gray => .r8_unorm,
            .rgba => if (srgb) .r8g8b8a8_srgb else .r8g8b8a8_unorm,
            .bgra => if (srgb) .b8g8r8a8_srgb else .b8g8r8a8_unorm,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: Vulkan,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .dev_alloc = self.dev.dev_alloc,
        .transfers = self.dev.transfers,
        .format = format.toPixelFormat(srgb),
        // We only need to read from this texture from a shader.
        .renderable = false,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Vulkan,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: vk.Format = switch (atlas.format) {
        .grayscale => .r8_unorm,
        .bgra => .b8g8r8a8_srgb,
        else => @panic("unsupported atlas format for Vulkan texture"),
    };

    return try .init(
        .{
            .dev_alloc = self.dev.dev_alloc,
            .transfers = self.dev.transfers,
            .format = format,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *Vulkan,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The API-specific state of the frame being drawn. Provides the
    /// recycled descriptor sets for the frame's render passes.
    frame_state: *FrameState,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    return try .begin(.{
        .dispatch = self.dev.dispatch,
        .queue = self.dev.graphics_queue.handle,
        .cmd_pool = self.cmd_pool,
        .frame_state = frame_state,
        .timeline = self.timeline,
        .timeline_value = &self.timeline_value,
    }, renderer, target);
}
