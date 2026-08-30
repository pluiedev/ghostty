//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const Compiled = @import("../shaders/Compiled.zig");
const shaders: Compiled = @import("shaders");
const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("buffer.zig").Buffer;

/// Options for beginning a render pass.
pub const Options = struct {
    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
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

    uniforms: ?gl.Buffer = null,
    /// The vertex buffer, bound for vertex input via the VAO.
    vertices: ?gl.Buffer = null,
    bg_cells: ?gl.Buffer = null,

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
        type: gl.Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

attachments: []const Options.Attachment,

step_number: usize = 0,

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    return .{
        .attachments = opts.attachments,
    };
}

/// Add a step to this render pass.
///
/// TODO: Errors are silently ignored in this function, maybe they shouldn't be?
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    const pbind = s.pipeline.program.use() catch return;
    defer pbind.unbind();

    const vaobind = s.pipeline.vao.bind() catch return;
    defer vaobind.unbind();

    const fbobind = switch (self.attachments[0].target) {
        .target => |t| t.framebuffer.bind(.framebuffer) catch return,
        .texture => |t| bind: {
            const fbobind = s.pipeline.fbo.bind(.framebuffer) catch return;
            fbobind.texture2D(.color0, t.target, t.texture, 0) catch {
                fbobind.unbind();
                return;
            };
            break :bind fbobind;
        },
    };
    defer fbobind.unbind();

    defer self.step_number += 1;

    // If we have a clear color and this is the
    // first step in the pass, go ahead and clear.
    if (self.step_number == 0) if (self.attachments[0].clear_color) |c| {
        gl.clearColor(c[0], c[1], c[2], c[3]);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
    };

    if (s.uniforms) |ubo| {
        const binding: u32 = if (s.post)
            Compiled.post_uniforms_binding
        else
            shaders.binding(.uniforms);
        _ = ubo.bindBase(.uniform, binding) catch return;
    }

    inline for (.{
        .{ .resource = Compiled.Resource.bg_cells, .field = "bg_cells" },
    }) |entry| {
        if (@field(s, entry.field)) |buf| {
            const binding = shaders.binding(entry.resource);
            _ = buf.bindBase(.storage, binding) catch return;
        }
    }

    // Bind the vertex buffer for vertex input.
    if (s.vertices) |vbo| vaobind.bindVertexBuffer(
        0,
        vbo.id,
        0,
        @intCast(s.pipeline.stride),
    ) catch return;

    // Bind relevant texture units.
    inline for (.{
        .{ .resource = Compiled.Resource.image_texture, .texture = "image", .sampler = "image" },
        .{ .resource = Compiled.Resource.atlas_grayscale, .texture = "atlas_grayscale", .sampler = "atlas_grayscale" },
        .{ .resource = Compiled.Resource.atlas_color, .texture = "atlas_color", .sampler = "atlas_color" },
    }) |entry| {
        const binding = shaders.binding(entry.resource);
        if (@field(s.textures, entry.texture)) |tex| {
            gl.Texture.active(binding) catch return;
            _ = tex.texture.bind(tex.target) catch return;
        }

        if (@field(s.samplers, entry.sampler)) |sampler| {
            _ = sampler.sampler.bind(binding) catch return;
        }
    }

    if (s.pipeline.blending_enabled) {
        gl.enable(gl.c.GL_BLEND) catch return;
        gl.blendFunc(gl.c.GL_ONE, gl.c.GL_ONE_MINUS_SRC_ALPHA) catch return;
    } else {
        gl.disable(gl.c.GL_BLEND) catch return;
    }

    gl.drawArraysInstanced(
        s.draw.type,
        0,
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
    ) catch return;
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    _ = self;
    gl.flush();
}
