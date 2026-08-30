const GhosttyShaders = @This();
const std = @import("std");

source: std.Build.LazyPath,

/// Synchronize with src/renderer/shaders/shaders.slang.
pub const Entrypoint = enum {
    full_screen_vertex,
    bg_color_fragment,
    bg_image_vertex,
    bg_image_fragment,
    cell_bg_fragment,
    cell_text_vertex,
    cell_text_fragment,
    image_vertex,
    image_fragment,
};

// Generate a Metal shader based on the Slang shader and return its path.
pub fn getMetalShader(self: *const GhosttyShaders, b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(self.source);
    cmd.addArgs(&.{ "-target", "metal" });
    // Buffer 0 is reserved for the vertex buffer.
    // Shift all the other buffers by 1 to get the correct indices.
    cmd.addArgs(&.{ "-fvk-b-shift", "1", "0" });
    cmd.addArg("-o");
    return cmd.addOutputFileArg("shaders.metal");
}

/// Generate a OpenGL GLSL shader for each entrypoint based on
/// the Slang shader, and return their paths.
pub fn getOpenGLShaders(self: *const GhosttyShaders, b: *std.Build) std.EnumMap(Entrypoint, std.Build.LazyPath) {
    var shaders: std.EnumMap(Entrypoint, std.Build.LazyPath) = .{};

    for (std.meta.tags(Entrypoint)) |ep| {
        const file = b.fmt("{t}.glsl", .{ep});
        const cmd = b.addSystemCommand(&.{"slangc"});
        cmd.addFileArg(self.source);
        cmd.addArgs(&.{ "-target", "glsl" });
        cmd.addArgs(&.{ "-entry", @tagName(ep) });
        cmd.addArg("-o");
        shaders.put(ep, cmd.addOutputFileArg(file));
    }

    return shaders;
}
