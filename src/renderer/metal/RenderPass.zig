//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");

const Compiled = @import("../shaders/Compiled.zig");
const shaders: Compiled = @import("shaders");
const mtl = @import("api.zig");
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Texture = @import("Texture.zig");
const Target = @import("Target.zig");

const log = std.log.scoped(.metal);

/// Options for beginning a render pass.
pub const Options = struct {
    /// MTLCommandBuffer
    command_buffer: objc.Object,
    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f64 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    /// MTLBuffer
    uniforms: ?objc.Object = null,
    /// The vertex buffer, bound for vertex input. Its register index is
    /// reserved by the pipeline's vertex descriptor.
    vertices: ?objc.Object = null,
    /// MTLBuffer
    bg_cells: ?objc.Object = null,
    textures: Textures = .{},
    /// Set of samplers to use for this step. The index maps to an index
    /// of a fragment texture, set via setFragmentSamplerState(_:index:).
    samplers: Samplers = .{},
    /// True when this step runs a shadertoy post-processing shader.
    post: bool = false,
    draw: Draw,

    /// Textures by resource, see `Compiled.Resource`.
    pub const Textures = struct {
        image: ?Texture = null,
        atlas_grayscale: ?Texture = null,
        atlas_color: ?Texture = null,
    };

    /// Samplers by resource, matching `Textures`.
    pub const Samplers = struct {
        image: ?Sampler = null,
        atlas_grayscale: ?Sampler = null,
        atlas_color: ?Sampler = null,
    };

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: mtl.MTLPrimitiveType,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

/// MTLRenderCommandEncoder
encoder: objc.Object,

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    // Create a pass descriptor
    const desc = desc: {
        const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
        const desc = MTLRenderPassDescriptor.msgSend(
            objc.Object,
            objc.sel("renderPassDescriptor"),
            .{},
        );

        // Set our color attachment to be our drawable surface.
        const attachments = objc.Object.fromId(
            desc.getProperty(?*anyopaque, "colorAttachments"),
        );
        for (opts.attachments, 0..) |at, i| {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, i)},
            );

            attachment.setProperty(
                "loadAction",
                @intFromEnum(@as(
                    mtl.MTLLoadAction,
                    if (at.clear_color != null)
                        .clear
                    else
                        .load,
                )),
            );
            attachment.setProperty(
                "storeAction",
                @intFromEnum(mtl.MTLStoreAction.store),
            );
            attachment.setProperty("texture", switch (at.target) {
                .texture => |t| t.texture.value,
                .target => |t| t.texture.value,
            });
            if (at.clear_color) |c| attachment.setProperty(
                "clearColor",
                mtl.MTLClearColor{
                    .red = c[0],
                    .green = c[1],
                    .blue = c[2],
                    .alpha = c[3],
                },
            );
        }

        break :desc desc;
    };

    // MTLRenderCommandEncoder
    const encoder = opts.command_buffer.msgSend(
        objc.Object,
        objc.sel("renderCommandEncoderWithDescriptor:"),
        .{desc.value},
    );

    return .{ .encoder = encoder };
}

/// Add a step to this render pass.
pub fn step(self: *const Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    // Set pipeline state
    self.encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{s.pipeline.state.value},
    );

    // We reserve index 0 for the vertex buffer; the shader's global
    // buffers are shifted by 1 to make room for it.
    if (s.vertices) |buf| {
        self.encoder.msgSend(
            void,
            objc.sel("setVertexBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
        );
        self.encoder.msgSend(
            void,
            objc.sel("setFragmentBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
        );
    }

    // Bind the global buffers (and textures) for both stages, at the
    // indices Slang assigned them in the Metal output.
    if (s.uniforms) |buf| {
        const index = shaders.binding(.uniforms).uniform_buffer;
        self.encoder.msgSend(
            void,
            objc.sel("setVertexBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, index) },
        );
        self.encoder.msgSend(
            void,
            objc.sel("setFragmentBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, index) },
        );
    }

    if (s.bg_cells) |buf| {
        const index = shaders.binding(.bg_cells).storage_buffer;
        self.encoder.msgSend(
            void,
            objc.sel("setVertexBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, index) },
        );
        self.encoder.msgSend(
            void,
            objc.sel("setFragmentBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, index) },
        );
    }

    // Set textures and samplers.
    inline for (.{
        .{ .resource = .image_texture, .field = "image" },
        .{ .resource = .atlas_grayscale, .field = "atlas_grayscale" },
        .{ .resource = .atlas_color, .field = "atlas_color" },
    }) |entry| {
        const binding = shaders.binding(entry.resource).combined_image_sampler;
        if (@field(s.textures, entry.field)) |tex| {
            self.encoder.msgSend(
                void,
                objc.sel("setVertexTexture:atIndex:"),
                .{ tex.texture.value, @as(c_ulong, binding.texture) },
            );
            self.encoder.msgSend(
                void,
                objc.sel("setFragmentTexture:atIndex:"),
                .{ tex.texture.value, @as(c_ulong, binding.texture) },
            );
        }

        if (@field(s.samplers, entry.field)) |sampler| {
            self.encoder.msgSend(
                void,
                objc.sel("setFragmentSamplerState:atIndex:"),
                .{ sampler.sampler.value, @as(c_ulong, binding.sampler) },
            );
        }
    }

    // Draw!
    self.encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
        .{
            @intFromEnum(s.draw.type),
            @as(c_ulong, 0),
            @as(c_ulong, s.draw.vertex_count),
            @as(c_ulong, s.draw.instance_count),
        },
    );
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    self.encoder.msgSend(void, objc.sel("endEncoding"), .{});
}
