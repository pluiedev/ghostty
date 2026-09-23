//! The OpenGL device context.
//!
//! This holds the EGL display and config used to create EGL
//! contexts, each corresponding to a surface, its renderer
//! object and its render thread.
//!
//! TODO: If there's a way to prefer certain devices like in
//! Vulkan or Metal we should do it here.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;

const log = std.log.scoped(.opengl);

/// The EGL display.
///
/// Since we use the default display, this is torn down
/// automagically by the OS.
display: *egl.Display,

/// The EGL config used to create surface renderer contexts. Chosen
/// once here so that all contexts share compatible capabilities.
config: *egl.Config,

pub fn init(alloc: Allocator) !Device {
    _ = alloc;

    try egl.load();

    const display: *egl.Display = try .initPlatform(
        egl.c.EGL_PLATFORM_SURFACELESS_MESA,
        egl.c.EGL_DEFAULT_DISPLAY,
        null,
    );

    log.info("EGL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
    log.info("EGL extensions={s}", .{display.queryString(.extensions) orelse "(unknown)"});

    // Choose a config. We need a config that is renderable with
    // OpenGL and a RGBA8 color buffer.
    const config = egl.Config.choose(display, &.{
        egl.c.EGL_SURFACE_TYPE,    0,
        egl.c.EGL_RENDERABLE_TYPE, egl.c.EGL_OPENGL_BIT,
        egl.c.EGL_RED_SIZE,        8,
        egl.c.EGL_GREEN_SIZE,      8,
        egl.c.EGL_BLUE_SIZE,       8,
        egl.c.EGL_ALPHA_SIZE,      8,
    }) catch |err| {
        log.warn("failed to choose config err={}", .{err});
        return err;
    };

    return .{
        .display = display,
        .config = config,
    };
}

pub fn deinit(self: *Device) void {
    // Do not destroy the EGL display here as
    // it is shared across the entire process.
    // It will get automatically torn down by the OS.
    _ = self;
}
