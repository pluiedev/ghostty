//! Represents a render target.
//!
//! In this case, a texture-backed framebuffer. The color attachment is a
//! `GL_TEXTURE_2D` texture instead of a renderbuffer so that we can create
//! an EGLImage from it and export the rendered frame as a dma-buf for
//! presentation by the apprt.
//!
//! We use two textures:
//!
//!   - `texture`: `GL_SRGB8_ALPHA8`. We render to this. With
//!     `GL_FRAMEBUFFER_SRGB` enabled, the GPU automatically converts linear
//!     shader output to sRGB on write. This is required for the
//!     linear-blending color pipeline to produce correct output.
//!
//!   - `export_texture`: `GL_RGBA8`. This is the texture we actually export
//!     as a dma-buf. Mesa cannot export `GL_SRGB8_ALPHA8` textures to
//!     dma-buf, so we blit the rendered sRGB texture into this plain RGBA8
//!     texture (the blit copies the already-sRGB-encoded pixel values
//!     verbatim) and export that instead.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const log = std.log.scoped(.opengl);

/// Options for initializing a Target
pub const Options = struct {
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,
};

/// The framebuffer we render to.
framebuffer: gl.Framebuffer,

/// The sRGB color attachment texture we render to.
texture: gl.Texture,

/// A plain RGBA8 texture + framebuffer that we blit `texture` into for
/// dma-buf export. Mesa can't export sRGB textures, so we blit the
/// already-sRGB-encoded pixels into this non-sRGB texture and export it.
export_texture: gl.Texture,
export_framebuffer: gl.Framebuffer,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    const texture = try gl.Texture.create();
    errdefer texture.destroy();
    {
        const bound_tex = try texture.bind(.@"2D");
        defer bound_tex.unbind();
        try bound_tex.parameter(.MinFilter, @intFromEnum(gl.Texture.MinFilter.nearest));
        try bound_tex.parameter(.MagFilter, @intFromEnum(gl.Texture.MagFilter.nearest));
        try bound_tex.parameter(.WrapS, @intFromEnum(gl.Texture.Wrap.clamp_to_edge));
        try bound_tex.parameter(.WrapT, @intFromEnum(gl.Texture.Wrap.clamp_to_edge));
        try bound_tex.image2D(
            0,
            .srgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .UnsignedByte,
            null,
        );
        try bound_tex.parameter(.BaseLevel, @as(gl.c.GLint, 0));
        try bound_tex.parameter(.MaxLevel, @as(gl.c.GLint, 0));
    }

    const fbo = try gl.Framebuffer.create();
    errdefer fbo.destroy();
    {
        const bound_fbo = try fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2D", texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("render framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }

    // --- Export texture (plain RGBA8, for dma-buf export) ---
    const export_texture = try gl.Texture.create();
    errdefer export_texture.destroy();
    {
        const bound_tex = try export_texture.bind(.@"2D");
        defer bound_tex.unbind();
        try bound_tex.parameter(.MinFilter, @intFromEnum(gl.Texture.MinFilter.nearest));
        try bound_tex.parameter(.MagFilter, @intFromEnum(gl.Texture.MagFilter.nearest));
        try bound_tex.parameter(.WrapS, @intFromEnum(gl.Texture.Wrap.clamp_to_edge));
        try bound_tex.parameter(.WrapT, @intFromEnum(gl.Texture.Wrap.clamp_to_edge));
        try bound_tex.image2D(
            0,
            .rgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .UnsignedByte,
            null,
        );
        try bound_tex.parameter(.BaseLevel, @as(gl.c.GLint, 0));
        try bound_tex.parameter(.MaxLevel, @as(gl.c.GLint, 0));
    }

    const export_fbo = try gl.Framebuffer.create();
    errdefer export_fbo.destroy();
    {
        const bound_fbo = try export_fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2D", export_texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("export framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }

    return .{
        .framebuffer = fbo,
        .texture = texture,
        .width = opts.width,
        .height = opts.height,
    };
}

/// Blit the rendered sRGB texture into the plain RGBA8 export texture.
/// Call this before exporting `export_texture` as a dma-buf. The blit
/// copies the already-sRGB-encoded pixel values verbatim (no color
/// conversion) because the destination is a non-sRGB format.
pub fn blitForExport(self: *const Self) !void {
    // Disable GL_FRAMEBUFFER_SRGB during the blit. With it enabled, the
    // blit would read from the sRGB source (converting to linear) and
    // write to the non-sRGB destination (keeping linear), producing dark
    // output. We want a verbatim copy of the already-sRGB-encoded bytes.
    gl.glad.context.Disable.?(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.glad.context.Enable.?(gl.c.GL_FRAMEBUFFER_SRGB);

    // Bind the render FBO as read, the export FBO as draw.
    gl.glad.context.BindFramebuffer.?(
        gl.c.GL_READ_FRAMEBUFFER,
        self.framebuffer.id,
    );
    defer gl.glad.context.BindFramebuffer.?(
        gl.c.GL_READ_FRAMEBUFFER,
        0,
    );

    gl.glad.context.BindFramebuffer.?(
        gl.c.GL_DRAW_FRAMEBUFFER,
        self.export_framebuffer.id,
    );
    defer gl.glad.context.BindFramebuffer.?(
        gl.c.GL_DRAW_FRAMEBUFFER,
        0,
    );

    gl.glad.context.BlitFramebuffer.?(
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        gl.c.GL_COLOR_BUFFER_BIT,
        gl.c.GL_NEAREST,
    );
}

pub fn deinit(self: *Self) void {
    self.framebuffer.destroy();
    self.texture.destroy();
}
