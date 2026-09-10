//! Wrapper for handling render passes.
const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const Device = @import("Device.zig");
const assert = @import("../../quirks.zig").inlineAssert;
const Compiled = @import("../shaders/Compiled.zig");
const shaders: Compiled = @import("shaders");
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Texture = @import("Texture.zig");
const Target = @import("Target.zig");
const Vulkan = @import("../Vulkan.zig");

const log = std.log.scoped(.vulkan);

const Self = @This();

/// The primitive type of a draw call.
///
/// Note that Vulkan encodes the primitive topology in the pipeline,
/// so the draw type of a step must match the topology of its
/// pipeline's options. It is only checked with an assert.
pub const Primitive = Pipeline.Options.PrimitiveTopology;

/// Options for beginning a render pass.
pub const Options = struct {
    attachments: []const Attachment,

    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,

    uniforms: ?vk.Buffer = null,
    /// The vertex buffer, bound for vertex input.
    vertices: ?vk.Buffer = null,
    bg_cells: ?vk.Buffer = null,

    textures: Textures = .{},
    samplers: Samplers = .{},
    post: bool = false,

    draw: Draw,

    pub const Textures = struct {
        image: ?Texture = null,
        atlas_grayscale: ?Texture = null,
        atlas_color: ?Texture = null,
    };

    pub const Samplers = struct {
        image: ?Sampler = null,
        atlas_grayscale: ?Sampler = null,
        atlas_color: ?Sampler = null,
    };

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

dispatch: vk.DeviceProxy,

attachments: []const Options.Attachment,

/// The command buffer this pass is recorded into.
cmd: vk.CommandBufferProxy,

/// The frame state whose descriptor sets we recycle for our steps.
/// The set list is grown on demand when our steps exceed it.
frame_state: *Vulkan.FrameState,

/// The index of the next descriptor set to use. This is shared
/// across all the render passes of a frame (it lives on the frame)
/// so that no set is ever used twice with different contents in the
/// same command buffer.
next_desc_set: *usize,

step_number: usize = 0,

/// Begin a render pass.
pub fn begin(
    opts: Options,
    dispatch: vk.DeviceProxy,
    cmd: vk.CommandBufferProxy,
    frame_state: *Vulkan.FrameState,
    next_desc_set: *usize,
) Self {
    // Only a single color attachment is supported, matching the
    // other renderers.
    assert(opts.attachments.len == 1);
    const attachment = opts.attachments[0];

    const view: vk.ImageView = switch (attachment.target) {
        .texture => |t| t.view,
        .target => |t| t.view,
    };
    const width: u32 = switch (attachment.target) {
        .texture => |t| @intCast(t.width),
        .target => |t| @intCast(t.width),
    };
    const height: u32 = switch (attachment.target) {
        .texture => |t| @intCast(t.height),
        .target => |t| @intCast(t.height),
    };

    // Set the viewport and scissor dynamically.
    //
    // Vulkan is the only odd one out of all major graphics API since
    // its NDC space has +Y pointing DOWN instead of UP. I assume
    // this is to make NDC coordinates share the same orientation
    // as screen coordinates, but the cost is that we have to
    // flip the viewport here to keep everything from looking
    // upside down.
    cmd.setViewport(0, &.{.{
        .x = 0,
        .y = @floatFromInt(height),
        .width = @floatFromInt(width),
        .height = -@as(f32, @floatFromInt(height)),
        .min_depth = 0,
        .max_depth = 1,
    }});
    cmd.setScissor(0, &.{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = width, .height = height },
    }});

    cmd.beginRenderingKHR(&.{
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = width, .height = height },
        },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = &.{.{
            .image_view = view,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = if (attachment.clear_color) |_| .clear else .load,
            .store_op = .store,
            .clear_value = .{ .color = .{
                .float_32 = attachment.clear_color orelse @splat(0),
            } },
        }},
    });

    return .{
        .dispatch = dispatch,
        .attachments = opts.attachments,
        .cmd = cmd,
        .frame_state = frame_state,
        .next_desc_set = next_desc_set,
    };
}

/// Add a step to this render pass.
///
/// TODO: Errors are silently ignored in this function, maybe they shouldn't be?
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    // The topology of the draw call is fixed by the pipeline.
    std.debug.assert(s.draw.type == s.pipeline.topology);

    self.cmd.bindPipeline(.graphics, s.pipeline.pipeline);

    defer self.step_number += 1;

    // Get our descriptor set. We recycle the sets that were
    // preallocated with our frame state by rewriting their contents.
    // If we run out of sets (a frame with an unusually large number
    // of steps, e.g. many Kitty images), we grow the frame state's
    // set list. The new sets are recycled like the rest.
    const set = self.descSet() catch |err| {
        log.warn("failed to allocate descriptor set err={}", .{err});
        return;
    };

    // Collect our descriptor writes. Each write owns its descriptor
    // info.
    const Write = struct {
        binding: u32,
        info: union(enum) {
            uniform_buffer: vk.DescriptorBufferInfo,
            storage_buffer: vk.DescriptorBufferInfo,
            combined_image_sampler: vk.DescriptorImageInfo,
        },
    };

    var list: [std.meta.tags(Compiled.Resource).len]Write = undefined;
    var len: usize = 0;

    // Uniforms.
    if (s.uniforms) |ubo| {
        list[len] = .{
            .binding = if (s.post)
                Compiled.post_uniforms_binding
            else
                shaders.binding(.uniforms),
            .info = .{ .uniform_buffer = .{
                .buffer = ubo,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            } },
        };
        len += 1;
    }

    inline for (.{
        .{ .resource = Compiled.Resource.bg_cells, .field = "bg_cells" },
    }) |entry| {
        if (@field(s, entry.field)) |buf| {
            list[len] = .{
                .binding = shaders.binding(entry.resource),
                .info = .{ .storage_buffer = .{
                    .buffer = buf,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                } },
            };
            len += 1;
        }
    }

    // Textures, paired with samplers as combined image samplers to
    // match the `Sampler2D` resources of the Slang shader.
    inline for (.{
        .{ .resource = Compiled.Resource.image_texture, .texture = "image", .sampler = "image" },
        .{ .resource = Compiled.Resource.atlas_grayscale, .texture = "atlas_grayscale", .sampler = "atlas_grayscale" },
        .{ .resource = Compiled.Resource.atlas_color, .texture = "atlas_color", .sampler = "atlas_color" },
    }) |entry| {
        const binding = shaders.binding(entry.resource);
        if (@field(s.textures, entry.texture)) |tex| {
            const sampler: vk.Sampler = if (@field(s.samplers, entry.sampler)) |s_|
                s_.sampler
            else
                tex.sampler;
            list[len] = .{
                .binding = binding,
                .info = .{ .combined_image_sampler = .{
                    .sampler = sampler,
                    .image_view = tex.view,
                    .image_layout = .shader_read_only_optimal,
                } },
            };
            len += 1;
        }
    }

    // Generate the Vulkan descriptor writes, pointing at our staged
    // infos. Uniforms are the uniform buffer at binding 1; every
    // other buffer is a storage buffer, and every image is a
    // combined image sampler.
    var writes: [std.meta.tags(Compiled.Resource).len]vk.WriteDescriptorSet = undefined;
    for (list[0..len], 0..) |*w, i| {
        writes[i] = .{
            .dst_set = set,
            .dst_binding = w.binding,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = switch (w.info) {
                .uniform_buffer => .uniform_buffer,
                .storage_buffer => .storage_buffer,
                .combined_image_sampler => .combined_image_sampler,
            },
            .p_buffer_info = switch (w.info) {
                .uniform_buffer, .storage_buffer => |*info| @ptrCast(info),
                .combined_image_sampler => &.{},
            },
            .p_image_info = switch (w.info) {
                .combined_image_sampler => |*info| @ptrCast(info),
                .uniform_buffer, .storage_buffer => &.{},
            },
            .p_texel_buffer_view = &.{},
        };
    }
    self.dispatch.updateDescriptorSets(writes[0..len], null);

    self.cmd.bindDescriptorSets(
        .graphics,
        s.pipeline.pipeline_layout,
        0,
        &.{set},
        &.{},
    );

    // Bind the vertex buffer for vertex input, if any.
    if (s.vertices) |vbo| {
        self.cmd.bindVertexBuffers(0, &.{vbo}, &.{0});
    }

    // Draw!
    self.cmd.draw(
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
        0,
        0,
    );
}

/// Get the descriptor set for the current step, growing our frame
/// state's set list if we've run out. The returned set must have its
/// contents written before being bound.
fn descSet(self: *Self) !vk.DescriptorSet {
    const state = self.frame_state;
    const i = self.next_desc_set.*;
    self.next_desc_set.* += 1;

    if (i < state.desc_sets.items.len) return state.desc_sets.items[i];

    // We've run out of preallocated sets: append a new one. The
    // initial sets for all frame states are still allocated in one
    // go (see `Vulkan.initFrameStates`); this only happens for
    // frames with an unusual number of steps.
    const slot = try state.desc_sets.addOne(state.alloc);
    errdefer state.desc_sets.items.len -= 1;

    var sets: [1]vk.DescriptorSet = undefined;
    try self.dispatch.allocateDescriptorSets(&.{
        .descriptor_pool = state.desc_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = &.{state.desc_layout},
    }, &sets);
    slot.* = sets[0];

    return sets[0];
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    self.cmd.endRenderingKHR();

    switch (self.attachments[0].target) {
        // If our attachment was a texture, transition it back to the
        // shader read only layout so that it can be sampled by the
        // steps of subsequent passes, e.g. chained custom shaders
        // which render between textures.
        .texture => |texture| self.cmd.pipelineBarrier(
            .{ .color_attachment_output_bit = true },
            .{ .fragment_shader_bit = true },
            .{},
            null,
            null,
            &.{Device.colorImageBarrier(
                texture.texture,
                .{ .color_attachment_write_bit = true },
                .{ .shader_read_bit = true },
                .color_attachment_optimal,
                .shader_read_only_optimal,
            )},
        ),
        .target => {},
    }
}
