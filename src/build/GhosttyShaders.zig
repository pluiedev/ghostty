const GhosttyShaders = @This();
const std = @import("std");
const Config = @import("Config.zig");
const RendererBackend = @import("../renderer/backend.zig").Backend;

/// The generated `shaders.zon`, containing all the generated shader data
/// (see `src/renderer/shaders/Compiled.zig`).
zon: std.Build.LazyPath,

/// Build options used by the shader generator (and the shader table), so
/// that only the configured renderer's target is generated.
options: *std.Build.Step.Options,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    source: std.Build.LazyPath,
) !GhosttyShaders {
    const options = b.addOptions();
    options.addOption(RendererBackend, "renderer", cfg.renderer);
    options.addOption(?[]const u8, "metal_min_os_version", switch (cfg.target.result.os.tag) {
        .macos => if (cfg.target.query.os_version_min) |v| b.fmt("{f}", .{v.semver}) else null,
        else => null,
    });

    const slang_mod = b.dependency("slang", .{
        .target = b.graph.host,
        .optimize = cfg.optimize,
    }).module("slang");
    const options_mod = options.createModule();

    const mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/shaders/Compiled.zig"),
        .target = b.graph.host,
        .optimize = cfg.optimize,
    });
    mod.addImport("options", options_mod);
    mod.addImport("slang", slang_mod);

    const exe = b.addExecutable(.{
        .name = "shader_compile",
        .root_module = mod,
    });

    const cmd = b.addRunArtifact(exe);
    cmd.addFileArg(source);
    const zon = cmd.addOutputFileArg("shaders.zon");

    return .{
        .zon = zon,
        .options = options,
    };
}
